// Supabase Edge Function: payment-webhook v1.0 (Phase E / 포트원)
// Created: 2026-05-01 / RealPlan Jeju Co., Ltd.
// Backup: 2026-05-20 (Track D 0-① 위험 차단)
import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const PORTONE_API_KEY = Deno.env.get("PORTONE_API_KEY") ?? "";
const PORTONE_API_SECRET = Deno.env.get("PORTONE_API_SECRET") ?? "";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, x-imp-secret",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(d: any, s = 200) {
  return new Response(JSON.stringify(d), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

async function verifyPortonePayment(impUid: string): Promise<{ ok: boolean; data?: any; error?: string }> {
  if (!PORTONE_API_KEY || !PORTONE_API_SECRET) {
    return { ok: false, error: "PORTONE_API_KEY/SECRET 미등록 / Phase E2 활성화 필요" };
  }
  try {
    const tokenRes = await fetch("https://api.iamport.kr/users/getToken", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ imp_key: PORTONE_API_KEY, imp_secret: PORTONE_API_SECRET }),
    });
    const tokenJson = await tokenRes.json();
    if (tokenJson.code !== 0) return { ok: false, error: "토큰 실패: " + tokenJson.message };
    const accessToken = tokenJson.response.access_token;

    const payRes = await fetch(`https://api.iamport.kr/payments/${impUid}`, {
      headers: { Authorization: accessToken },
    });
    const payJson = await payRes.json();
    if (payJson.code !== 0) return { ok: false, error: "결제 조회 실패: " + payJson.message };

    return { ok: true, data: payJson.response };
  } catch (e: any) {
    return { ok: false, error: e?.message || String(e) };
  }
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  let body: any = {};
  try { body = await req.json(); }
  catch { return json({ ok: false, error: "Invalid JSON" }, 400); }

  const { imp_uid, merchant_uid, status } = body;
  if (!merchant_uid) return json({ ok: false, error: "merchant_uid 필수" }, 400);

  const { data: contract, error: cErr } = await supabase
    .from("contracts")
    .select("*")
    .eq("merchant_uid", merchant_uid)
    .single();
  if (cErr || !contract) {
    console.warn("[payment-webhook] contract not found", { merchant_uid });
    return json({ ok: false, error: "contract not found", merchant_uid }, 404);
  }

  let verified: any = null;
  let paidAmount: number | null = null;
  let paymentMethod: string | null = null;
  if (PORTONE_API_KEY && imp_uid) {
    const ver = await verifyPortonePayment(imp_uid);
    if (!ver.ok) {
      console.warn("[payment-webhook] portone verify fail", ver.error);
      await supabase.from("contracts").update({
        결제_웹훅_payload: { ...body, _verify_error: ver.error },
      }).eq("id", contract.id);
      return json({ ok: false, error: "verify failed", detail: ver.error }, 502);
    }
    verified = ver.data;
    paidAmount = verified?.amount;
    paymentMethod = verified?.pay_method;
  }

  const portoneStatus = (status || verified?.status || "").toLowerCase();
  let newStatus: string;
  if (portoneStatus === "paid") newStatus = "paid";
  else if (portoneStatus === "cancelled" || portoneStatus === "canceled") newStatus = "cancelled";
  else if (portoneStatus === "failed") newStatus = "failed";
  else if (portoneStatus === "refunded") newStatus = "refunded";
  else if (portoneStatus === "ready") newStatus = "pending";
  else newStatus = portoneStatus || "pending";

  const expectedAmount = contract.결제_금액 || contract.계약금액 || 0;
  if (paidAmount !== null && Math.abs(paidAmount - expectedAmount) > 100) {
    console.warn("[payment-webhook] amount mismatch", { paid: paidAmount, expected: expectedAmount });
    await supabase.from("contracts").update({
      결제_웹훅_payload: { ...body, verified, _amount_mismatch: true },
    }).eq("id", contract.id);
    return json({ ok: false, error: "amount mismatch", paid: paidAmount, expected: expectedAmount }, 400);
  }

  const updates: any = {
    결제_상태: newStatus,
    결제_거래id: imp_uid || null,
    결제_웹훅_payload: { ...body, verified },
    updated_at: new Date().toISOString(),
  };
  if (newStatus === "paid") {
    updates.결제일 = new Date().toISOString();
    if (paidAmount !== null) updates.결제_금액 = paidAmount;
    if (paymentMethod) {
      const m = paymentMethod.toLowerCase();
      if (m.includes("card")) updates.결제_방식 = "card";
      else if (m.includes("vbank") || m.includes("virtual")) updates.결제_방식 = "virtual_account";
      else if (m.includes("trans") || m.includes("bank")) updates.결제_방식 = "transfer";
      else if (m.includes("kakao")) updates.결제_방식 = "kakaopay";
      else if (m.includes("naver")) updates.결제_방식 = "naverpay";
    }
  }
  await supabase.from("contracts").update(updates).eq("id", contract.id);

  return json({
    ok: true,
    contract_id: contract.id,
    contract_number: contract.계약번호,
    merchant_uid,
    imp_uid: imp_uid || null,
    new_status: newStatus,
    verified: !!verified,
    paid_amount: paidAmount,
  });
});
