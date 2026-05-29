// telegram-queue-flush v1.0 — 53차 조용시간 큐 일괄 발송
// 매일 07:05 KST cron

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

async function sendTelegram(msg: string) {
  const t = await getSecret('realplan_telegram_token');
  const c = await getSecret('realplan_telegram_chat_id');
  if (!t || !c) return false;
  const r = await fetch(`https://api.telegram.org/bot${t}/sendMessage`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: c, text: msg, parse_mode: 'HTML', disable_web_page_preview: true })
  });
  return r.ok;
}

Deno.serve(async (_req) => {
  // 조용시간 멸 큐 모두 발송
  const { data: pending } = await supabase.from('mk_notification_queue')
    .select('id, 이벤트_코드, 메시지, 우선순위')
    .eq('발송완료', false)
    .lte('발송_예정시각', new Date().toISOString())
    .order('우선순위', { ascending: true })
    .limit(50);

  if (!pending || pending.length === 0) {
    return new Response(JSON.stringify({ ok: true, sent: 0, msg: 'no pending' }), { headers: { 'Content-Type': 'application/json' } });
  }

  // 다이제스트 방식: P1 이상은 개별 / P2·P3는 다이제스트 통합 발송
  const p0p1 = pending.filter(p => ['P0','P1'].includes(p.우선순위));
  const p2p3 = pending.filter(p => ['P2','P3'].includes(p.우선순위));

  let sent = 0;

  // P0·P1 개별 발송
  for (const p of p0p1) {
    const ok = await sendTelegram(`⚡️ <b>조용시간 멸 큐 (${p.우선순위})</b>\n\n${p.메시지}`);
    if (ok) {
      await supabase.from('mk_notification_queue').update({ 발송완료: true, 발송_시각: new Date().toISOString() }).eq('id', p.id);
      sent++;
    }
    await new Promise(rs => setTimeout(rs, 400));
  }

  // P2·P3 다이제스트 통합
  if (p2p3.length > 0) {
    let digest = `🌅 <b>조용시간 멸 다이제스트 (07 KST)</b>\n\n일반 ${p2p3.length}건 양도 발송\n\n`;
    const maxList = Math.min(p2p3.length, 10);
    for (let i = 0; i < maxList; i++) {
      const m = p2p3[i].메시지.slice(0, 200);
      digest += `${i+1}・ ${m}\n\n`;
    }
    if (p2p3.length > 10) digest += `… 외 ${p2p3.length - 10}건`;
    const ok = await sendTelegram(digest);
    if (ok) {
      const ids = p2p3.map(p => p.id);
      await supabase.from('mk_notification_queue').update({ 발송완료: true, 발송_시각: new Date().toISOString() }).in('id', ids);
      sent += p2p3.length;
    }
  }

  return new Response(JSON.stringify({ ok: true, sent, total_pending: pending.length, version: 'v1' }), {
    headers: { 'Content-Type': 'application/json' }
  });
});
