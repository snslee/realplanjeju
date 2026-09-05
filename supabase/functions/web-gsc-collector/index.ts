// web-gsc-collector v2.0 — 2026-09-05 대표 승인 (2단계 A2·A3)
// 변경점 (v1.0 → v2.0)
//  1) ★page 차원 신설. v1.0 은 dimensions:['query'] 뿐이라 「어느 페이지가」를 아예 못 쟀다.
//     그래서 mk_metrics 의 홈페이지 행이 0건이었다 — 죽은 게 아니라 기능이 없었다.
//  2) ★홈B(marketing.realplanjeju.com) 추가. v1.0 은 홈A 속성만 시도했다.
//  3) ★mk_metrics 적재 신설(데이터_소스='gsc_home'). 채널='홈페이지A'/'홈페이지B'.
//     기존 'gsc'(티스토리)와 소스값을 갈라 부분인덱스·기존 쿼리를 건드리지 않는다.
//  4) 기존 web_gsc_검색어 적재는 그대로 둔다 — 데이터는 후퇴시키지 않는다.
//  5) 속성별·단계별 try/catch 로 행단위 예외를 격리한다(규칙 123).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

async function gs(n: string) { const { data } = await supabase.rpc('realplan_get_secret', { secret_name: n }); return data as string | null; }

async function token() {
  const id = await gs('realplan_gsc_oauth_client_id'), sec = await gs('realplan_gsc_oauth_client_secret'), rt = await gs('realplan_gsc_oauth_refresh_token');
  const r = await fetch('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams({ client_id: id!, client_secret: sec!, refresh_token: rt!, grant_type: 'refresh_token' }) });
  const j = await r.json(); return j.access_token as string || null;
}

async function q(tok: string, site: string, body: any) {
  const r = await fetch(`https://searchconsole.googleapis.com/webmasters/v3/sites/${encodeURIComponent(site)}/searchAnalytics/query`, { method: 'POST', headers: { 'Authorization': `Bearer ${tok}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  return { status: r.status, j: r.ok ? await r.json() : await r.text() };
}

// ★홈A/홈B 판별 — v_ai_channel_asset 과 같은 명명을 쓴다
function chOf(url: string): string | null {
  if (/marketing\.realplanjeju\.com/i.test(url)) return '홈페이지B';
  if (/realplanjeju\.com/i.test(url)) return '홈페이지A';
  return null;
}

const PROPS = [
  'sc-domain:realplanjeju.com',
  'https://realplanjeju.com/',
  'https://marketing.realplanjeju.com/',
  'https://www.realplanjeju.com/',
];

Deno.serve(async (req) => {
  const out: any = { ver: 'v2.0', page: {}, query: {}, tried: [] as any[], err: [] as string[] };
  try {
    const u = new URL(req.url);
    const debug = u.searchParams.get('debug');
    const tok = await token();
    if (!tok) return new Response(JSON.stringify({ ok: false, err: 'token fail', ver: 'v2.0' }), { status: 500, headers: { 'Content-Type': 'application/json' } });

    const end = new Date(Date.now() - 2 * 864e5).toISOString().slice(0, 10);
    const start = new Date(Date.now() - 30 * 864e5).toISOString().slice(0, 10);
    const today = new Date(Date.now() + 9 * 3600e3).toISOString().slice(0, 10);

    // ── ① page 차원 (신설) — 문서별 성과
    const pageRows = new Map<string, any>();  // key: 채널|url
    for (const s of PROPS) {
      try {
        const r = await q(tok, s, { startDate: start, endDate: end, dimensions: ['page'], rowLimit: 500 });
        out.tried.push({ site: s, dim: 'page', status: r.status, rows: r.status === 200 ? (r.j?.rows?.length ?? 0) : 0 });
        if (r.status !== 200 || !r.j?.rows) continue;
        for (const x of r.j.rows) {
          const url = String(x.keys?.[0] ?? '');
          const ch = chOf(url);
          if (!ch) continue;
          const k = ch + '|' + url;
          const prev = pageRows.get(k);
          // 같은 URL 이 여러 속성에서 잡히면 노출이 큰 쪽을 남긴다(도메인속성 우선 효과)
          if (!prev || (x.impressions ?? 0) > (prev.노출_수 ?? 0)) {
            pageRows.set(k, {
              채널: ch, 외부_url: url, 측정_일자: today,
              노출_수: Math.round(x.impressions ?? 0),
              클릭_수: Math.round(x.clicks ?? 0),
              ctr_pct: x.impressions ? Math.round((x.clicks ?? 0) / x.impressions * 10000) / 100 : 0,
              평균_순위: x.position ?? null,
              데이터_소스: 'gsc_home',
              수집_시각: new Date().toISOString(),
            });
          }
        }
      } catch (e) { out.err.push(`page:${s}:${String(e).slice(0, 120)}`); }
    }
    const ups = [...pageRows.values()];
    out.page.수집 = ups.length;
    out.page.홈A = ups.filter(r => r.채널 === '홈페이지A').length;
    out.page.홈B = ups.filter(r => r.채널 === '홈페이지B').length;

    if (!debug && ups.length) {
      try {
        const { error } = await supabase.from('mk_metrics').upsert(ups, { onConflict: '채널,외부_url,측정_일자' });
        if (error) { out.err.push('mk_metrics:' + error.message.slice(0, 200)); out.page.적재 = 0; }
        else out.page.적재 = ups.length;
      } catch (e) { out.err.push('mk_metrics_ex:' + String(e).slice(0, 150)); out.page.적재 = 0; }
    }

    // ── ② query 차원 (v1.0 유지) — 데이터 후퇴 금지
    try {
      let qrows: any[] = [], used = '';
      for (const s of PROPS) {
        const r = await q(tok, s, { startDate: start, endDate: end, dimensions: ['query'], rowLimit: 100 });
        out.tried.push({ site: s, dim: 'query', status: r.status });
        if (r.status === 200 && r.j?.rows) { qrows = r.j.rows; used = s; break; }
      }
      out.query.property = used || null;
      out.query.수집 = qrows.length;
      if (!debug && qrows.length) {
        const up = qrows.map((x: any) => ({ 검색어: x.keys[0], 클릭: x.clicks || 0, 노출: x.impressions || 0, 순위: x.position || null, 수집일: today }));
        const { error } = await supabase.from('web_gsc_검색어').upsert(up, { onConflict: '검색어,수집일' });
        if (error) out.err.push('web_gsc:' + error.message.slice(0, 200));
        else out.query.적재 = up.length;
      }
    } catch (e) { out.err.push('query:' + String(e).slice(0, 150)); }

    out.기간 = `${start}~${end}`;
    out.ok = out.err.length === 0;
    return new Response(JSON.stringify(out), { headers: { 'Content-Type': 'application/json' } });
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, ver: 'v2.0', err: String(e).slice(0, 300) }), { status: 500, headers: { 'Content-Type': 'application/json' } });
  }
});
