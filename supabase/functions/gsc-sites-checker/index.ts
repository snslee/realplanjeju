// gsc-sites-checker v1.0 — 52차 P0-C 도움 (임시 사용)
// GSC 사이트 인증 상태 + 데이터 표시 여부 진단

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } }
);

async function getSecret(name: string): Promise<string | null> {
  const { data } = await supabase.rpc('realplan_get_secret', { secret_name: name });
  return data as string;
}

async function getAccessToken(): Promise<string | null> {
  const clientId = await getSecret('realplan_gsc_oauth_client_id');
  const clientSecret = await getSecret('realplan_gsc_oauth_client_secret');
  const refreshToken = await getSecret('realplan_gsc_oauth_refresh_token');
  if (!clientId || !clientSecret || !refreshToken) return null;
  const r = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: clientId, client_secret: clientSecret,
      refresh_token: refreshToken, grant_type: 'refresh_token'
    })
  });
  if (!r.ok) return null;
  const j = await r.json();
  return j.access_token;
}

Deno.serve(async (_req) => {
  const token = await getAccessToken();
  if (!token) return new Response(JSON.stringify({ ok: false, err: 'oauth fail' }), { status: 500 });

  // 1. sites.list — 인증된 모든 사이트 조회
  const sitesR = await fetch('https://searchconsole.googleapis.com/webmasters/v3/sites', {
    headers: { 'Authorization': `Bearer ${token}` }
  });
  const sitesJ = await sitesR.json();
  const sites = (sitesJ.siteEntry || []).map((s: any) => ({
    siteUrl: s.siteUrl,
    permissionLevel: s.permissionLevel
  }));

  // 2. 4 타겟 사이트 각각 최근 7일 데이터 조회
  const TARGETS = [
    'sc-domain:realplanjeju.com',
    'sc-domain:wowjj8631.tistory.com',
    'sc-domain:realplan-event.tistory.com',
    'sc-domain:realplan-marketing.tistory.com'
  ];
  const endDate = new Date(Date.now() - 86400000).toISOString().slice(0,10);
  const startDate = new Date(Date.now() - 8 * 86400000).toISOString().slice(0,10);
  const dataCheck: any[] = [];

  for (const site of TARGETS) {
    const verified = sites.find((s: any) => s.siteUrl === site);
    let dataRows = 0, dataErr = null, sumImp = 0, sumClk = 0;
    if (verified) {
      try {
        const r = await fetch(
          `https://searchconsole.googleapis.com/webmasters/v3/sites/${encodeURIComponent(site)}/searchAnalytics/query`,
          {
            method: 'POST',
            headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' },
            body: JSON.stringify({ startDate, endDate, dimensions: ['page'], rowLimit: 100 })
          }
        );
        if (r.ok) {
          const j = await r.json();
          dataRows = (j.rows || []).length;
          for (const row of (j.rows || [])) {
            sumImp += row.impressions || 0;
            sumClk += row.clicks || 0;
          }
        } else {
          dataErr = `HTTP ${r.status}`;
        }
      } catch (e) { dataErr = String(e); }
    }
    dataCheck.push({
      site,
      인증여부: !!verified,
      권한: verified?.permissionLevel || null,
      존재하는_데이터행: dataRows,
      총_노출: sumImp,
      총_클릭: sumClk,
      데이터_호출_오류: dataErr
    });
  }

  return new Response(JSON.stringify({
    ok: true,
    조회_일자: { startDate, endDate },
    인증_사이트_전체: sites,
    타겟_4사이트: dataCheck
  }, null, 2), {
    headers: { 'Content-Type': 'application/json; charset=utf-8' }
  });
});
