// tistory-reeval-weekly v1.0 — 티스토리 주간 자동 재평가 → 텔레그램
// rpc_tistory_reeval(주제표류·30일미진입·2페이지최적화후보) 호출 → 조치대상 있을 때만/주간 요약 전송
// pg_cron: tistory-reeval-weekly-mon (30 2 * * 1 = 매주 월 11:30 KST)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
async function getSecret(n: string): Promise<string | null> { const { data } = await supabase.rpc('realplan_get_secret', { secret_name: n }); return data as string; }
async function sendTelegram(msg: string) {
  const token = await getSecret('realplan_telegram_token'); const chatId = await getSecret('realplan_telegram_chat_id');
  if (!token || !chatId) return false;
  const r = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ chat_id: chatId, text: msg, parse_mode: 'HTML', disable_web_page_preview: true }) });
  return r.ok;
}
function esc(s: any) { return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
Deno.serve(async (req) => {
  const url = new URL(req.url);
  const always = url.searchParams.get('always') === '1';
  const { data, error } = await supabase.rpc('rpc_tistory_reeval');
  if (error || !data) return new Response(JSON.stringify({ ok: false, error: error?.message }), { status: 500 });
  const drift = data['주제표류'] || []; const miss = data['미진입30일'] || []; const p2 = data['2페이지최적화후보'] || [];
  const watch = data['관찰군_14_30일'] || 0; const p1 = data['1페이지글수'] || 0;
  const actionable = drift.length + miss.length + p2.length;
  const lines: string[] = [`📊 <b>티스토리 주간 재평가</b> (주제 최적화)`, ``];
  if (actionable === 0) {
    lines.push(`✅ 이번 주 조치 대상 <b>없음</b> — 정상 축적 중`);
    lines.push(`· 1페이지 유지: ${p1}개 · 관찰군(14~30일 미진입): ${watch}건`);
  } else {
    if (drift.length) { lines.push(`⚠️ <b>주제표류</b> (노출≥10, 의도≠실제검색어) ${drift.length}건`); for (const d of drift.slice(0, 8)) lines.push(`· [${esc(d['의도'])}] → "${esc(d['실제검색어'])}" (노출 ${d['노출']})`); lines.push(``); }
    if (miss.length) { lines.push(`🔴 <b>30일↑ 미진입</b> (노출0 → 재작성/키워드재지정) ${miss.length}건`); for (const m of miss.slice(0, 8)) lines.push(`· [${esc(m['채널'])}] ${esc(m['키워드'])} (${esc(m['발행일'])})`); lines.push(``); }
    if (p2.length) { lines.push(`🟡 <b>2페이지 최적화후보</b> (제목·도입부 보강시 1페이지) ${p2.length}건`); for (const q of p2.slice(0, 8)) lines.push(`· [${esc(q['키워드'])}] 순위 ${q['순위']} · 노출 ${q['노출']}`); }
  }
  lines.push(``); lines.push(`→ <a href="https://realplanjeju.com/admin/marketing.html">마케팅 대시보드</a>`);
  let sent = false;
  if (actionable > 0 || always) sent = await sendTelegram(lines.join('\n'));
  return new Response(JSON.stringify({ ok: true, actionable, drift: drift.length, miss: miss.length, p2: p2.length, watch, p1, sent, version: 'v1.0' }), { headers: { 'Content-Type': 'application/json' } });
});
