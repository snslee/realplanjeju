// Supabase Edge Function: create-payment v1.0 (Phase E / 포트원 + 토스페이먼츠 / 영세 0.5%)
// Created: 2026-05-01 / RealPlan Jeju Co., Ltd.
// Backup: 2026-05-20 (Track D 0-① 위험 차단)
import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
import nodemailer from "npm:nodemailer@6.9.7";

const SMTP_HOST = "smtp.naver.com";
const SMTP_PORT = 465;
const SMTP_USER = Deno.env.get("NAVER_SMTP_USER") ?? "realplan01@naver.com";
const SMTP_PASS = Deno.env.get("NAVER_SMTP_PASS") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const PORTONE_API_KEY = Deno.env.get("PORTONE_API_KEY") ?? "";
const PORTONE_API_SECRET = Deno.env.get("PORTONE_API_SECRET") ?? "";
const PORTONE_CHANNEL_KEY = Deno.env.get("PORTONE_CHANNEL_KEY") ?? "";
const REALPLAN_BASE_URL = Deno.env.get("REALPLAN_BASE_URL") ?? "https://realplanjeju.com";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

let transporter: any = null;
function getTransporter() {
  if (!transporter) {
    transporter = nodemailer.createTransport({
      host: SMTP_HOST, port: SMTP_PORT, secure: true,
      auth: { user: SMTP_USER, pass: SMTP_PASS },
      connectionTimeout: 30_000, greetingTimeout: 15_000, socketTimeout: 60_000,
    });
  }
  return transporter;
}

function json(d: any, s = 200) {
  return new Response(JSON.stringify(d), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

function safe(s: any): string {
  return String(s ?? "").replace(/[<>&"]/g, (c) =>
    ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" } as any)[c]);
}

function won(n: any): string {
  return Number(n || 0).toLocaleString() + "원";
}

function getRate(grade: string): number {
  if (grade === "영세") return 0.5;
  if (grade === "중소1") return 1.0;
  if (grade === "중소2") return 1.4;
  if (grade === "중소3") return 1.6;
  return 3.4;
}

function getDeptAccount(bu: string): { 은행: string; 계좌번호: string; 예금주: string } {
  const map: any = {
    "국내여행": { 은행: "NH농협", 계좌번호: "301-0384-9381-21", 예금주: "리얼플랜제주(주)" },
    "행사이벤트": { 은행: "NH농협", 계좌번호: "301-0312-7698-71", 예금주: "리얼플랜제주(주)" },
    "온라인마케팅": { 은행: "NH농협", 계좌번호: "301-0312-7698-71", 예금주: "리얼플랜제주(주)" },
    "마케팅교육": { 은행: "NH농협", 계좌번호: "301-0345-1194-81", 예금주: "리얼플랜제주(주)" },
  };
  return map[bu] || { 은행: "NH농협", 계좌번호: "사업부 미지정", 예금주: "리얼플랜제주(주)" };
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  let payload: any = {};
  try { payload = await req.json(); }
  catch { return json({ ok: false, error: "Invalid JSON" }, 400); }

  const { contract_id, payment_method, amount, recipient_email, force_pg, 매출등급 } = payload;
  if (!contract_id) return json({ ok: false, error: "contract_id 필수" }, 400);
  const method: string = payment_method || "transfer";
  const grade: string = 매출등급 || "영세";
  const rate = getRate(grade);

  try {
    const { data: contract, error: cErr } = await supabase
      .from("contracts")
      .select("*, customers!inner(*)")
      .eq("id", contract_id)
      .single();
    if (cErr || !contract) return json({ ok: false, error: "계약 조회 실패" }, 404);

    const customer = contract.customers;
    const toEmail = recipient_email || customer.이메일;
    const finalAmount = amount || contract.계약금액 || 0;
    const merchantUid = contract.계약번호 + "-" + Date.now();
    const acc = getDeptAccount(customer.사업부);
    const usePg = (force_pg || (PORTONE_API_KEY && PORTONE_API_KEY.length > 5)) ? "portone" : "none";

    let paymentLinkUrl = "";
    let pgUsed = "none";

    if (usePg === "portone" && PORTONE_API_KEY) {
      paymentLinkUrl = `${REALPLAN_BASE_URL}/payment.html?merchant_uid=${encodeURIComponent(merchantUid)}&contract=${encodeURIComponent(contract_id)}&amount=${finalAmount}&method=${method}`;
      pgUsed = "portone";
    } else {
      paymentLinkUrl = "";
      pgUsed = "none";
    }

    const updates: any = {
      결제_링크_url: paymentLinkUrl || null,
      결제_방식: method,
      결제_pg: pgUsed === "portone" ? "portone" : "none",
      merchant_uid: merchantUid,
      영세_수수료율: rate,
      결제_금액: finalAmount,
    };
    await supabase.from("contracts").update(updates).eq("id", contract_id);

    if (toEmail && SMTP_PASS) {
      const html = `<div style="font-family:'Malgun Gothic','맑은 고딕',sans-serif;font-size:14px;line-height:1.7;color:#1f2937;max-width:680px">
        <h2 style="color:#1A4F8B;margin:0 0 14px 0">결제 안내</h2>
        <p>안녕하세요, <strong>${safe(customer.회사명)}</strong> ${safe(customer.담당자명)} 담당자님.</p>
        <p>계약이 체결되어 결제 안내 드립니다.</p>
        <table style="border-collapse:collapse;margin:14px 0">
          <tr><td style="padding:6px 12px 6px 0;color:#64748b;width:120px">계약번호</td><td><strong>${safe(contract.계약번호)}</strong></td></tr>
          <tr><td style="padding:6px 12px 6px 0;color:#64748b">결제금액</td><td><strong>${won(finalAmount)}</strong> (영세 ${rate}% 수수료)</td></tr>
          <tr><td style="padding:6px 12px 6px 0;color:#64748b">결제방식</td><td>${method === "card" ? "신용카드" : method === "virtual_account" ? "가상계좌" : method === "kakaopay" ? "카카오페이" : "계좌이체"}</td></tr>
          <tr><td style="padding:6px 12px 6px 0;color:#64748b">주문번호</td><td>${safe(merchantUid)}</td></tr>
        </table>
        ${paymentLinkUrl ? `<p style="margin:18px 0"><a href="${paymentLinkUrl}" style="display:inline-block;padding:12px 24px;background:#1A4F8B;color:#fff;text-decoration:none;border-radius:6px;font-weight:600">결제하기</a></p>` : `<div style="margin:18px 0;padding:14px;background:#f8fafc;border-left:3px solid #1A4F8B;border-radius:4px">
          <strong>계좌이체 안내</strong><br>
          ${acc.은행} ${acc.계좌번호}<br>
          예금주: ${acc.예금주}<br>
          입금자명: ${safe(customer.회사명)}-${safe(contract.계약번호)}
          </div>`}
        <p style="margin:16px 0;font-size:13px;color:#64748b">결제 관련 문의: 1577-2296 / realplan01@naver.com</p>
        <hr style="border:none;border-top:0.5px solid #e2e8f0;margin:20px 0">
        <div style="font-size:12px;color:#64748b">
          리얼플랜제주 주식회사 · 공동대표 이동환 · 김현숙<br>
          사업자: 819-87-02344 | T 1577-2296
        </div>
      </div>`;
      try {
        await getTransporter().sendMail({
          from: `"리얼플랜제주 주식회사" <${SMTP_USER}>`,
          to: toEmail,
          subject: `[리얼플랜제주] 결제 안내 — ${contract.계약번호}`,
          html,
        });
      } catch (e) {
        console.error("[create-payment SMTP]", e);
      }
    }

    return json({
      ok: true,
      contract_id,
      contract_number: contract.계약번호,
      merchant_uid: merchantUid,
      payment_link_url: paymentLinkUrl,
      pg: pgUsed,
      method,
      amount: finalAmount,
      매출등급: grade,
      수수료율: rate,
      account: pgUsed === "none" ? acc : null,
      sent_to: toEmail || null,
      portone_active: PORTONE_API_KEY ? true : false,
    });
  } catch (e: any) {
    console.error("[create-payment]", e);
    return json({ ok: false, error: (e?.message || String(e)).slice(0, 500) }, 500);
  }
});
