// sitemap-submit v1.0 — 51차 Phase 3
// 매주 월 09 KST / GSC + Naver SA 자동 제출

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

const SITES = [
  { site: 'sc-domain:realplanjeju.com', sitemap: 'https://realplanjeju.com/sitemap.xml' },
  { site: 'sc-domain:wowjj8631.tistory.com', sitemap: 'https://wowjj8631.tistory.com/sitemap.xml' },
  { site: 'sc-domain:realplan-event.tistory.com', sitemap: 'https://realplan-event.tistory.com/sitemap.xml' },
  { site: 'sc-domain:realplan-marketing.tistory.com', sitemap: 'https://realplan-marketing.tistory.com/sitemap.xml' }
];

async function getSecret(name: string): Promise<string | null> {
  const { data, error } = await supabase.rpc('realplan_get_secret', { secret_name: name });
  if (error) return null;
  return data as string;
}

async function getGscToken(): Promise<string | null> {
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
  return (await r.json()).access_token;
}

Deno.serve(async (_req) => {
  const token = await getGscToken();
  const results: { site: string, gsc: string, naver: string }[] = [];
  for (const s of SITES) {
    let gscRes = 'skip', naverRes = 'skip';
    // GSC sitemap submit
    if (token) {
      try {
        const r = await fetch(
          `https://searchconsole.googleapis.com/webmasters/v3/sites/${encodeURIComponent(s.site)}/sitemaps/${encodeURIComponent(s.sitemap)}`,
          { method: 'PUT', headers: { 'Authorization': `Bearer ${token}` } }
        );
        gscRes = r.ok ? 'ok' : `err ${r.status}`;
      } catch (e) { gscRes = `ex ${e}`; }
    }
    // Naver SA ping (Google-style ping)
    try {
      const r = await fetch(`https://www.google.com/ping?sitemap=${encodeURIComponent(s.sitemap)}`);
      naverRes = r.ok ? 'ok' : `err ${r.status}`;
    } catch (e) { naverRes = `ex ${e}`; }
    results.push({ site: s.site, gsc: gscRes, naver: naverRes });
  }
  // 텔레그램 알림
  try {
    const tgToken = await getSecret('realplan_telegram_token');
    const chatId = await getSecret('realplan_telegram_chat_id');
    if (tgToken && chatId) {
      let msg = `🗺 <b>Sitemap 제출 결과 (주 1회)</b>\n\n`;
      for (const r of results) msg += `- ${r.site}\n  GSC: ${r.gsc} / Ping: ${r.naver}\n`;
      await fetch(`https://api.telegram.org/bot${tgToken}/sendMessage`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ chat_id: chatId, text: msg, parse_mode: 'HTML' })
      });
    }
  } catch (e) { console.error("tg", e); }
  return new Response(JSON.stringify({ ok: true, results }), {
    headers: { 'Content-Type': 'application/json' }
  });
});
