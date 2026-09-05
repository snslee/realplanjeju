// sitemap-submit v4.1 — 2026-09-05 대표 승인 (2단계 A3)
// 변경점 (v4.0 → v4.1)
//  ★SITES 에 marketing.realplanjeju.com(홈B) 추가. v4.0 은 홈A + 티스토리 3곳뿐이라
//   홈B 는 사이트맵 도달 점검·제출 대상에서 통째로 빠져 있었다(2026-09-05 실측 확인).
//   홈B 실측: sitemap.xml HTTP 200 · robots.txt AI 크롤러 전면 허용.
// v4.0 — 2026-08-04 대표 승인: 텔레그램 직발송 폐지 → 큐 경유
// v3.1까지는 마케팅방으로 직발송했으나 사이트맵 제출은 SEO 인프라=시스템 성격이라 재분류.
// 목적지는 mk_notification_route 정본이 정한다(SITEMAP_SUBMIT → 시스템방).
// v3: 사이트맵 도달성(GET 200) 체크. GSC 제출은 OAuth 가 webmasters(쓰기) 스코프일 때만 성공.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });

const SITES = [
  { site: 'https://realplanjeju.com/', sitemap: 'https://realplanjeju.com/sitemap.xml' },
  { site: 'https://marketing.realplanjeju.com/', sitemap: 'https://marketing.realplanjeju.com/sitemap.xml' },
  { site: 'https://wowjj8631.tistory.com/', sitemap: 'https://wowjj8631.tistory.com/sitemap.xml' },
  { site: 'https://realplan-event.tistory.com/', sitemap: 'https://realplan-event.tistory.com/sitemap.xml' },
  { site: 'https://realplan-marketing.tistory.com/', sitemap: 'https://realplan-marketing.tistory.com/sitemap.xml' }
];

async function getSecret(name: string): Promise<string | null> {
  const { data, error } = await supabase.rpc('realplan_get_secret', { secret_name: name });
  if (error) return null; return data as string;
}

// ★v4.0: 큐에만 적재한다
async function enqueue(code: string, msg: string, priority = 'P3') {
  try {
    const { error } = await supabase.from('mk_notification_queue').insert({
      '이벤트_코드': code, '메시지': msg, '우선순위': priority,
      '발송_예정시각': new Date().toISOString()
    });
    if (error) console.error('enqueue err', code, error);
  } catch (e) { console.error('enqueue err', code, e); }
}

async function getGscToken(): Promise<string | null> {
  const ci = await getSecret('realplan_gsc_oauth_client_id');
  const cs = await getSecret('realplan_gsc_oauth_client_secret');
  const rt = await getSecret('realplan_gsc_oauth_refresh_token');
  if (!ci || !cs || !rt) return null;
  const r = await fetch('https://oauth2.googleapis.com/token', { method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded'}, body:new URLSearchParams({client_id:ci,client_secret:cs,refresh_token:rt,grant_type:'refresh_token'}) });
  if (!r.ok) return null; return (await r.json()).access_token;
}

Deno.serve(async () => {
  const token = await getGscToken();
  const results: { site:string, reach:string, gsc:string }[] = [];
  for (const s of SITES) {
    let reach = 'err';
    try { const g = await fetch(s.sitemap, { method:'GET' }); reach = g.ok ? 'ok' : `err ${g.status}`; } catch(e){ reach = 'ex'; }
    let gsc = 'skip';
    if (token) {
      try {
        const r = await fetch(`https://searchconsole.googleapis.com/webmasters/v3/sites/${encodeURIComponent(s.site)}/sitemaps/${encodeURIComponent(s.sitemap)}`, { method:'PUT', headers:{'Authorization':`Bearer ${token}`} });
        if (r.ok) gsc = 'ok'; else if (r.status === 403) gsc = 'scope재인증필요'; else gsc = `err ${r.status}`;
      } catch(e){ gsc = 'ex'; }
    }
    results.push({ site:s.site, reach, gsc });
  }
  const bad = results.filter(r => r.reach !== 'ok').length;
  let msg = `🗺 <b>Sitemap 주간 체크</b> — 대상 ${SITES.length}곳 · 도달 이상 ${bad}건\n\n`;
  for (const r of results) msg += `- ${r.site}\n  도달: ${r.reach} / 제출: ${r.gsc}\n`;
  msg += `\n※ 제출=scope재인증필요 면 GSC OAuth 를 webmasters(쓰기) 스코프로 1회 재인증. 구글은 robots.txt 로 자동 발견되므로 도달=ok 면 색인은 정상.`;
  await enqueue('SITEMAP_SUBMIT', msg, bad > 0 ? 'P2' : 'P3');

  return new Response(JSON.stringify({ ok:true, ver:'v4.1', 대상:SITES.length, results }), { headers:{'Content-Type':'application/json'} });
});
