// blog-skill-suggest v1.0 — 51차 Phase 2
// 매주 월 09 KST / CTR≥5% 글 표현 패턴 → hr_audit_log SUGGEST 적재
// 스킬 자체는 미변경 / 결과만 제안

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

async function getSecret(name: string): Promise<string | null> {
  const { data, error } = await supabase.rpc('realplan_get_secret', { secret_name: name });
  if (error) return null;
  return data as string;
}

async function sendTelegram(msg: string) {
  try {
    const token = await getSecret('realplan_telegram_token');
    const chatId = await getSecret('realplan_telegram_chat_id');
    if (!token || !chatId) return;
    await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: chatId, text: msg, parse_mode: 'HTML' })
    });
  } catch (e) { console.error("tg err", e); }
}

Deno.serve(async (_req) => {
  try {
    const { data: winners } = await supabase.rpc('rpc_blog_weekly_winners', { _days: 7 });
    if (!winners || winners.length === 0) {
      return new Response(JSON.stringify({ ok: true, count: 0, msg: 'no winners this week' }));
    }
    const channelStats: Record<string, { count: number, avgCtr: number, avgRank: number }> = {};
    for (const w of winners) {
      const ch = w.r_채널 || 'unknown';
      if (!channelStats[ch]) channelStats[ch] = { count: 0, avgCtr: 0, avgRank: 0 };
      channelStats[ch].count++;
      channelStats[ch].avgCtr += Number(w.r_ctr_pct || 0);
      channelStats[ch].avgRank += Number(w.r_평균_순위 || 0);
    }
    const summary: string[] = [];
    for (const ch in channelStats) {
      const s = channelStats[ch];
      summary.push(`${ch}: ${s.count}건 / CTR ${(s.avgCtr/s.count).toFixed(1)}% / 순위 ${(s.avgRank/s.count).toFixed(1)}`);
    }
    // hr_audit_log에 SUGGEST 적재
    await supabase.from('hr_audit_log').insert({
      감사축: 'F_시스템개선',
      룰_코드: 'F_BLOG_WINNER_PATTERN',
      심각도: 'SUGGEST',
      상태: 'OPEN',
      메시지: `주간 승리 글 ${winners.length}건 분석 → 스킬 패치 후보`,
      세부데이터: { winners: winners.slice(0, 20), channelStats },
      학습모드: false
    });
    await sendTelegram(`🎯 <b>주간 승리공식 후보 (월 09 KST)</b>\n\n${summary.join('\n')}\n\n총 ${winners.length}건 / audit.html 스킬패치후보 탭에서 승인`);
    return new Response(JSON.stringify({ ok: true, count: winners.length, channelStats }), {
      headers: { 'Content-Type': 'application/json' }
    });
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, err: String(e) }), { status: 500 });
  }
});
