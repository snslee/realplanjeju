// Edge Function: agent-digest v1.0 / 45차 / 2026-05-14
// 일일 18:00 KST 발송 (pg_cron) / snslee82 단독 / 조건부
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

const SMTP_USER = "realplan01@naver.com";
const SMTP_HOST = "smtp.naver.com";
const ALERT_TO = "snslee82@gmail.com"; // 단독
const NAVER_SMTP_PASS = Deno.env.get("NAVER_SMTP_PASS") ?? "";

async function sendEmail(subject: string, html: string): Promise<boolean> {
  if (!NAVER_SMTP_PASS) { console.error("NAVER_SMTP_PASS 미설정"); return false; }
  try {
    const conn = await Deno.connectTls({ hostname: SMTP_HOST, port: 465 });
    const enc = new TextEncoder();
    const dec = new TextDecoder();
    const buf = new Uint8Array(4096);
    const send = async (s: string) => {
      await conn.write(enc.encode(s));
      const n = await conn.read(buf);
      return dec.decode(buf.subarray(0, n!));
    };
    await conn.read(buf);
    await send(`EHLO realplanjeju\r\n`);
    await send(`AUTH LOGIN\r\n`);
    await send(btoa(SMTP_USER) + "\r\n");
    await send(btoa(NAVER_SMTP_PASS) + "\r\n");
    await send(`MAIL FROM:<${SMTP_USER}>\r\n`);
    await send(`RCPT TO:<${ALERT_TO}>\r\n`);
    await send(`DATA\r\n`);
    const body = `From: ${SMTP_USER}\r\nTo: ${ALERT_TO}\r\nSubject: =?UTF-8?B?${btoa(unescape(encodeURIComponent(subject)))}?=\r\nMIME-Version: 1.0\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n${html}\r\n.\r\n`;
    await conn.write(enc.encode(body));
    await conn.read(buf);
    await send(`QUIT\r\n`);
    conn.close();
    return true;
  } catch (e) {
    console.error("SMTP 실패:", e);
    return false;
  }
}

function renderHtml(d: any, dateStr: string): string {
  const top3 = (d["HITL_TOP3"] || []).map((r: any) => `
    <tr style="border-bottom:1px solid #eee">
      <td style="padding:6px"><span style="background:#FAEEDA;color:#854F0B;padding:2px 6px;border-radius:4px;font-size:11px">${r["대상유형"]}</span> ${r["대상id"]}</td>
      <td style="padding:6px;text-align:right;color:#BA7517;font-weight:500">${r["점수"]}</td>
      <td style="padding:6px;color:#666">${(r["사유"] || "").substring(0, 60)}</td>
    </tr>`).join("");
  return `<div style="font-family:Apple SD Gothic Neo,sans-serif;max-width:520px;margin:0 auto;background:#fff;padding:20px">
<div style="font-size:18px;font-weight:500">🤖 에이전트 일일 다이제스트</div>
<div style="color:#888;font-size:12px;margin-bottom:16px">${dateStr} · 리얼플랜제주</div>
<table style="width:100%;border-collapse:collapse;margin-bottom:14px">
<tr>
  <td style="background:#f5f5f5;padding:10px;border-radius:8px;width:50%"><div style="font-size:11px;color:#888">오늘 채점</div><div style="font-size:18px;font-weight:500">${d["오늘_채점"]} 건</div></td>
  <td style="width:6px"></td>
  <td style="background:#FAEEDA;padding:10px;border-radius:8px;width:50%"><div style="font-size:11px;color:#BA7517">HITL 대기</div><div style="font-size:18px;font-weight:500;color:#BA7517">${d["HITL_대기"]} 건</div></td>
</tr>
<tr><td colspan="3" style="height:6px"></td></tr>
<tr>
  <td style="background:#f5f5f5;padding:10px;border-radius:8px"><div style="font-size:11px;color:#888">월 비용</div><div style="font-size:18px;font-weight:500">$${d["월_예상비용_USD"]} / $100</div></td>
  <td></td>
  <td style="background:#f5f5f5;padding:10px;border-radius:8px"><div style="font-size:11px;color:#888">사고</div><div style="font-size:18px;font-weight:500;color:${d["사고"] === 0 ? "#1D9E75" : "#A32D2D"}">${d["사고"]} 건</div></td>
</tr>
</table>
${top3 ? `<div style="font-size:13px;font-weight:500;margin-bottom:6px">🚦 HITL 대기 Top 3</div>
<table style="width:100%;border-collapse:collapse;font-size:12px;margin-bottom:14px">
<tr style="color:#888;border-bottom:1px solid #ddd"><th style="text-align:left;padding:6px">대상</th><th style="text-align:right;padding:6px">점수</th><th style="text-align:left;padding:6px">사유</th></tr>
${top3}</table>` : ""}
<div style="background:#f5f5f5;padding:10px;border-radius:8px;font-size:12px;margin-bottom:14px">
<div style="color:#888;margin-bottom:4px">📝 발송 조건</div>HITL ≥ 1 OR 월 비용 ≥ $80 OR 사고 시. 조용한 날 = 무발송.</div>
<a href="https://realplanjeju.com/admin.html#admin-agent" style="display:block;text-align:center;padding:10px;background:#E6F1FB;color:#185FA5;border-radius:8px;font-size:13px;font-weight:500;text-decoration:none">관리자에서 처리하기 →</a>
<div style="font-size:11px;color:#aaa;text-align:center;margin-top:16px;line-height:1.5">리얼플랜제주 주식회사 · 819-87-02344<br>agent-digest EF · sql/049 · v1.0</div>
</div>`;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: { "Access-Control-Allow-Origin": "*" } });
  }
  try {
    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const body = await req.json().catch(() => ({}));
    const force = body.force === true;

    const { data: digest, error } = await supabase.rpc("rpc_agent_daily_digest");
    if (error) throw new Error("RPC 실패: " + JSON.stringify(error));

    const condMet = digest["발송조건_충족"] === true;
    const willSend = force || condMet;

    if (!willSend) {
      return new Response(JSON.stringify({
        ok: true, sent: false, reason: "조용한 날 (HITL 0 · 사고 0 · 비용 안전)",
        digest: digest
      }), { status: 200, headers: { "Content-Type": "application/json" } });
    }

    const now = new Date();
    const kst = new Date(now.getTime() + 9 * 3600 * 1000);
    const dateStr = `${kst.getUTCFullYear()}-${String(kst.getUTCMonth()+1).padStart(2,'0')}-${String(kst.getUTCDate()).padStart(2,'0')} (${["일","월","화","수","목","금","토"][kst.getUTCDay()]}) 18:00`;
    const subject = `[에이전트 다이제스트] ${dateStr.substring(0,10)} · HITL ${digest["HITL_대기"]}건 대기`;
    const html = renderHtml(digest, dateStr);

    const sent = await sendEmail(subject, html);

    // 발송 로그 hr_audit_handoff 적재
    await supabase.from("hr_audit_handoff").insert({
      에이전트id: "rp_agent_digest_v1",
      대상유형: "다이제스트",
      대상id: `digest-${dateStr.substring(0,10)}`,
      점수: sent ? 10 : 0,
      사유: sent ? `발송 완료 → ${ALERT_TO}` : "SMTP 실패",
      평가루브릭: "digest_v1",
      hitl상태: sent ? "auto_pass" : "blocked",
      메타: digest,
    });

    return new Response(JSON.stringify({
      ok: sent, sent, recipient: ALERT_TO, subject, digest
    }), { status: 200, headers: { "Content-Type": "application/json" } });
  } catch (err: any) {
    return new Response(JSON.stringify({ error: err?.message || String(err) }),
      { status: 500, headers: { "Content-Type": "application/json" } });
  }
});