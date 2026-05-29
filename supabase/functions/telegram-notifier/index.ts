// telegram-notifier v2 — P1 즉시 알림 + 일일 다이제스트
// 49-1차 fix: RPC 파라미터 secret_name (p_name X)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

async function getSecret(supa: any, name: string): Promise<string | null> {
  const { data, error } = await supa.rpc("realplan_get_secret", { secret_name: name });
  if (error || !data) {
    const { data: d2 } = await supa.schema("realplan").rpc("get_secret", { secret_name: name });
    return d2 ?? null;
  }
  return data;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ ok: false, error: "POST only" }), { status: 405, headers: { "Content-Type": "application/json" } });
  }

  try {
    const body = await req.json();
    const { 메시지, 심각도 = "P2", 제목 = "리얼플랜 감사", chat_id_override } = body;

    if (!메시지) return new Response(JSON.stringify({ ok: false, error: "메시지 필수" }), { status: 400, headers: { "Content-Type": "application/json" } });

    const supa = createClient(SUPABASE_URL, SERVICE_ROLE);
    const token = await getSecret(supa, "realplan_telegram_token");
    const chatId = chat_id_override || await getSecret(supa, "realplan_telegram_chat_id");

    if (!token || !chatId) return new Response(JSON.stringify({ ok: false, error: "Vault: realplan_telegram_token + realplan_telegram_chat_id 등록 필요" }), { status: 500, headers: { "Content-Type": "application/json" } });

    const emoji = 심각도 === "P1" ? "🚨" : 심각도 === "P2" ? "⚠️" : "ℹ️";
    const text = `${emoji} <b>${제목}</b>\n${메시지}\n\n<i>리얼플랜제주 감사 시스템 / ${new Date().toLocaleString("ko-KR", { timeZone: "Asia/Seoul" })}</i>`;

    const tgRes = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ chat_id: chatId, text, parse_mode: "HTML", disable_notification: 심각도 === "P3" })
    });

    const tgJson = await tgRes.json();
    if (!tgJson.ok) return new Response(JSON.stringify({ ok: false, error: tgJson.description || "telegram error", telegram: tgJson }), { status: 500, headers: { "Content-Type": "application/json" } });

    return new Response(JSON.stringify({ ok: true, message_id: tgJson.result?.message_id }), { headers: { "Content-Type": "application/json" } });
  } catch (err: any) {
    return new Response(JSON.stringify({ ok: false, error: err.message }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
