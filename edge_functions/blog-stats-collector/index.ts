// blog-stats-collector v3.0 — 59차 P1 결함 수정
// 변경: publish_log 최근 60일 URL 직접 GSC 조회 추가 → 티스토리 매칭률 개선
// 기존 top-N 수집 유지 + 신규 발행글 직접 쿼리 병행

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } }
);

const GSC_SITES = [
  { siteUrl: 'https://wowjj8631.tistory.com/', 채널: '블A티스토리' },
  { siteUrl: 'https://realplan-event.tistory.com/', 채널: '블B티스토리' },
  { siteUrl: 'https://realplan-marketing.tistory.com/', 채널: '블C티스토리' }
];

async function getSecret(name: string): Promise<string | null> {
  const { data } = await supabase.rpc('realplan_get_secret', { secret_name: name });
  return data as string;
}

async function getAccessToken(): Promise<string | null> {
  const id = await getSecret('realplan_gsc_oauth_client_id');
  const sec = await getSecret('realplan_gsc_oauth_client_secret');
  const rt = await getSecret('realplan_gsc_oauth_refresh_token');
  if (!id || !sec || !rt) return null;
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ client_id: id, client_secret: sec, refresh_token: rt, grant_type: 'refresh_token' })
  });
  if (!r.ok) return null;
  return (await r.json()).access_token;
}

async function logAuditError(severity: string, msg: string, detail: any) {
  try {
    await supabase.from('hr_audit_log').insert({
      감사축: 'C', 룰_코드: 'C_EF_INSERT_FAIL', 심각도: severity,
      상태: 'detected', 메시지: msg,
      세부데이터: { ef: 'blog-stats-collector', detail }
    });
  } catch (e) { console.error('audit fail', e); }
}

async function gscQuery(token: string, siteUrl: string, body: object): Promise<any[] | null> {
  const r = await fetch(
    `https://searchconsole.googleapis.com/webmasters/v3/sites/${encodeURIComponent(siteUrl)}/searchAnalytics/query`,
    { method: 'POST', headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
  );
  if (!r.ok) return null;
  return (await r.json()).rows || [];
}

async function upsertMetric(채널: string, url: string, date: string, row: any): Promise<boolean> {
  const { error } = await supabase.from('mk_metrics').upsert({
    채널, 외부_url: url, 측정_일자: date,
    노출_수: Math.round(row.impressions || 0),
    클릭_수: Math.round(row.clicks || 0),
    ctr_pct: (row.ctr || 0) * 100,
    평균_순위: row.position || null,
    데이터_소스: 'gsc',
    수집_시각: new Date().toISOString()
  }, { onConflict: '채널,외부_url,측정_일자' });
  return !error;
}

Deno.serve(async (_req) => {
  const token = await getAccessToken();
  if (!token) {
    await logAuditError('P1', 'blog-stats v3 OAuth 실패', {});
    return new Response(JSON.stringify({ ok: false, err: 'oauth' }), { status: 500 });
  }

  const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
  const startDate8d = new Date(Date.now() - 8 * 86400000).toISOString().slice(0, 10);
  const startDate60d = new Date(Date.now() - 60 * 86400000).toISOString().slice(0, 10);
  let totalInserts = 0, errors = 0;
  const trace: any[] = [];

  for (const site of GSC_SITES) {
    try {
      const rows = await gscQuery(token, site.siteUrl, {
        startDate: startDate8d, endDate: yesterday, dimensions: ['page'], rowLimit: 500
      });
      if (rows === null) { errors++; trace.push({ step: 'top-n', site: site.채널, err: 'api fail' }); continue; }
      trace.push({ step: 'top-n', site: site.채널, rows: rows.length });
      for (const row of rows) {
        const url = row.keys?.[0] || '';
        if (!url) continue;
        const ok = await upsertMetric(site.채널, url, yesterday, row);
        if (ok) totalInserts++; else errors++;
      }
    } catch (e) { errors++; trace.push({ step: 'top-n', site: site.채널, err: String(e) }); }
  }

  try {
    const { data: publishUrls } = await supabase.from('mk_blog_publish_log')
      .select('채널, 외부_url').gte('발행일', startDate60d);
    if (publishUrls && publishUrls.length > 0) {
      for (const site of GSC_SITES) {
        const siteUrls = publishUrls.filter(r =>
          r.채널 === site.채널 && r.외부_url?.startsWith(site.siteUrl.replace(/\/$/, ''))
        );
        if (siteUrls.length === 0) continue;
        const urlsToQuery = siteUrls.slice(0, 20);
        let directHits = 0;
        for (const urlRow of urlsToQuery) {
          try {
            const rows = await gscQuery(token, site.siteUrl, {
              startDate: startDate60d, endDate: yesterday, dimensions: ['page'],
              dimensionFilterGroups: [{ filters: [{ dimension: 'page', operator: 'equals', expression: urlRow.외부_url }] }],
              rowLimit: 1
            });
            if (rows === null || rows.length === 0) {
              await upsertMetric(site.채널, urlRow.외부_url, yesterday, { impressions: 0, clicks: 0, ctr: 0, position: null });
              totalInserts++;
            } else {
              const ok = await upsertMetric(site.채널, urlRow.외부_url, yesterday, rows[0]);
              if (ok) { totalInserts++; directHits++; }
            }
          } catch (_e) {}
        }
        trace.push({ step: 'direct', site: site.채널, queried: urlsToQuery.length, hits: directHits });
      }
    }
  } catch (e) { trace.push({ step: 'direct', err: String(e) }); }

  if (totalInserts === 0 && errors === 0) {
    await logAuditError('P3', 'blog-stats v3 GSC lag (데이터 0)', { trace });
  }
  return new Response(JSON.stringify({ ok: true, totalInserts, errors, trace, version: 'v3' }), {
    headers: { 'Content-Type': 'application/json' }
  });
});
