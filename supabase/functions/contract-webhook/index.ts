// Supabase Edge Function: contract-webhook v1.0 (Phase D1)
// Created: 2026-05-01 / RealPlan Jeju Co., Ltd.
// - 모두싸인 / 이폼사인 / self 웹훅 통합 엔드포인트
// - 필드 URL: https://iodfqlkeiwxyuojwcozv.supabase.co/functions/v1/contract-webhook?provider=modusign|eformsign|self
// - HMAC 서명 검증 (Phase D2 활성화 시 필수)
// Backup: 2026-05-20 (Track D 0-① 위험 차단)
import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const MODUSIGN_WEBHOOK_SECRET = Deno.env.get("MODUSIGN_WEBHOOK_SECRET") ?? "";
const EFORMSIGN_WEBHOOK_SECRET = Deno.env.get("EFORMSIGN_WEBHOOK_SECRET") ?? "";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Signature, X-Modusign-Signature, X-Eformsign-Signature",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(data: any, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function mapStatus(provider: string, event: string): string | null {
  const e = (event || "").toLowerCase();
  if (provider === "modusign") {
    if (e === "document.viewed") return "viewed";
    if (e === "document.signing.completed" || e === "document.signed") return "completed";
    if (e === "document.rejected") return "declined";
    if (e === "document.expired") return "expired";
  } else if (provider === "eformsign") {
    if (e === "viewed" || e === "document_viewed") return "viewed";
    if (e === "completed" || e === "document_completed") return "completed";
    if (e === "rejected" || e === "document_rejected") return "declined";
    if (e === "expired") return "expired";
  } else if (provider === "self") {
    if (e === "viewed") return "viewed";
    if (e === "signed" || e === "completed") return "completed";
    if (e === "declined") return "declined";
  }
  return null;
}

async function findContractByEnvelope(envelopeId: string, contractId?: string) {
  if (contractId) {
    const { data } = await supabase.from("contracts").select("*").eq("id", contractId).single();
    if (data) return data;
  }
  if (envelopeId) {
    const { data } = await supabase.from("contracts").select("*").eq("envelope_id", envelopeId).single();
    if (data) return data;
  }
  return null;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  const url = new URL(req.url);
  const provider = url.searchParams.get("provider") || "self";

  let body: any = {};
  try { body = await req.json(); }
  catch { return json({ ok: false, error: "Invalid JSON" }, 400); }

  let envelopeId: string | null = null;
  let event: string = "";
  let signedPdfUrl: string | null = null;
  let identityVerification: any = null;

  if (provider === "modusign") {
    envelopeId = body.documentId || body.document_id || body.id || null;
    event = body.event || body.eventType || "";
    signedPdfUrl = body.completedFileUrl || body.signed_pdf_url || null;
    identityVerification = body.identityVerification || null;
  } else if (provider === "eformsign") {
    envelopeId = body.document_id || body.documentId || body.id || null;
    event = body.event_type || body.event || "";
    signedPdfUrl = body.completed_pdf_url || body.signed_pdf_url || null;
    identityVerification = body.signer_info || null;
  } else {
    envelopeId = body.envelope_id || body.contract_id || null;
    event = body.event || "";
    signedPdfUrl = body.signed_pdf_url || null;
    identityVerification = body.identity_verification || null;
  }

  const contractId = body.contract_id || null;
  const contract = await findContractByEnvelope(envelopeId || "", contractId);

  if (!contract) {
    console.warn("[contract-webhook] contract not found", { provider, envelopeId, contractId });
    return json({ ok: false, error: "contract not found", provider, envelope_id: envelopeId }, 404);
  }

  const newStatus = mapStatus(provider, event);
  const updates: any = { webhook_payload: body, updated_at: new Date().toISOString() };

  if (newStatus) {
    updates.서명_상태_세부 = newStatus;
    if (newStatus === "viewed") {
      // 마지막 마지막_일자 갱신
    } else if (newStatus === "completed") {
      updates.서명상태 = "완료";
      updates.상태 = "체결";
      updates.서명일 = new Date().toISOString().slice(0, 10);
      updates.을_서명일 = new Date().toISOString();
      if (signedPdfUrl) updates.서명_pdf_url = signedPdfUrl;
    } else if (newStatus === "declined" || newStatus === "expired") {
      updates.상태 = "해지";
    }
  }

  if (identityVerification) {
    updates.본인확인_정보 = identityVerification;
  }

  await supabase.from("contracts").update(updates).eq("id", contract.id);

  if (newStatus === "completed" && signedPdfUrl) {
    try {
      await supabase.rpc("rpc_upsert_file_attachment", {
        _payload: {
          customer_id: contract.customer_id,
          카테고리: "계약서_체결본",
          파일명: contract.계약번호 + "_체결본.pdf",
          storage_path: "docs/" + contract.customer_id + "/계약서_체결본/" + contract.계약번호 + "_체결본.pdf",
          mime_타입: "application/pdf",
          파일크기: 0,
          자동첨부_공문: true,
          자동첨부_정산: true,
          보존기간_년: 5,
          권한: "manager_plus",
          업로더: "contract-webhook",
        },
      });
    } catch (e) {
      console.warn("[contract-webhook] file_attachment INSERT 실패", e);
    }
  }

  return json({
    ok: true,
    provider,
    envelope_id: envelopeId,
    contract_id: contract.id,
    new_status: newStatus,
    event,
  });
});
