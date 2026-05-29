// naver-stats-collector v2.1 — 52차 P0 시정 (hr_audit_log 컴럼목 정합)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

async function getSecret(name: string): Promise<string | null> {
  const { data, error } = await supabase.rpc('realplan_get_secret', { secret_name: name });
  if (error) { console.error('secret err', name, error.message); return null; }
  return data as string;
}

async function logAuditError(severity: string, msg: string, detail: any) {
  try {
    await supabase.from('hr_audit_log').insert({
      감사축: 'C',
      룰_코드: 'C_EF_INSERT_FAIL',
      심각도: severity,
      상태: 'detected',
      메시지: msg,
      세부데이터: { ef: 'naver-stats-collector', detail }
    });
  } catch (e) { console.error('audit log fail', e); }
}

Deno.serve(async (_req) => {
  const searchClientId = await getSecret('realplan_naver_search_client_id');
  const searchSecret = await getSecret('realplan_naver_search_client_secret');

  if (!searchClientId || !searchSecret) {
    await logAuditError('P1', 'naver-stats v2.1 시크릿 누락', { missing: 'naver_search' });
    return new Response(JSON.stringify({ ok: false, err: 'secret' }), { status: 500 });
  }

  const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
  const NAVER_CHANNELS = [
    { name: '블A네이버', blogId: 'realplan_travel' },
    { name: '블B네이버', blogId: 'realplan_event' },
    { name: '블C네이버', blogId: 'realplan_marketing' }
  ];

  let processed = 0, errors = 0, totalInsertCount = 0;
  const trace: any[] = [];

  for (const ch of NAVER_CHANNELS) {
    try {
      const { data: pubs, error: pubsErr } = await supabase.from('mk_blog_publish_log')
        .select('외부_url, rss_제목')
        .eq('채널', ch.name)
        .gte('발행일', new Date(Date.now() - 7 * 86400000).toISOString().slice(0,10))
        .limit(10);

      if (pubsErr) { errors++; trace.push({ ch: ch.name, err: pubsErr.message }); continue; }
      if (!pubs || pubs.length === 0) { trace.push({ ch: ch.name, pubs: 0 }); continue; }

      for (const p of pubs) {
        if (!p.rss_제목 || !p.외부_url) continue;

        try {
          const queryKw = p.rss_제목.split(/[\s\-_]/).slice(0, 3).join(' ');
          const r = await fetch(
            `https://openapi.naver.com/v1/search/blog.json?query=${encodeURIComponent(queryKw)}&display=30&sort=sim`,
            { headers: { 'X-Naver-Client-Id': searchClientId, 'X-Naver-Client-Secret': searchSecret } }
          );
          if (!r.ok) { errors++; continue; }
          const result = await r.json();
          const items = result.items || [];
          let myRank = 0;
          for (let i = 0; i < items.length; i++) {
            if (items[i].link && items[i].link.includes(ch.blogId)) {
              myRank = i + 1; break;
            }
          }

          const { error: upsertErr } = await supabase.from('mk_metrics').upsert({
            채널: ch.name,
            외부_url: p.외부_url,
            측정_일자: yesterday,
            평균_순위: myRank > 0 ? myRank : null,
            데이터_소스: 'naver_search',
            수집_시각: new Date().toISOString()
          }, { onConflict: '채널,외부_url,측정_일자' });

          if (upsertErr) {
            errors++;
            await logAuditError('P1', 'naver-stats v2.1 upsert 실패', { ch: ch.name, url: p.외부_url, err: upsertErr.message });
          } else {
            processed++;
            totalInsertCount++;
          }
          await new Promise(rs => setTimeout(rs, 100));
        } catch (e) {
          errors++;
          console.error('inner err', e);
        }
      }
    } catch (e) {
      errors++;
    }
  }

  if (totalInsertCount === 0) {
    await logAuditError('P0', 'naver-stats v2.1 INSERT 0건', { processed, errors, trace });
    return new Response(JSON.stringify({ ok: false, processed, errors, trace, msg: 'INSERT 0 - silent fail blocked' }), { status: 500 });
  }

  return new Response(JSON.stringify({ ok: true, processed, errors, totalInsertCount, trace, version: 'v2.1' }), {
    headers: { 'Content-Type': 'application/json' }
  });
});
