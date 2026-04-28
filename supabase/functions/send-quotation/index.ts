// Supabase Edge Function: send-quotation v2.7
// Phase 2a stage 4 + v2.7 doc_type 3-way branch (quote / delivery / statement)
// Created: 2026-04-26 / v2.7 patched: 2026-04-28
// RealPlan Jeju Co., Ltd.

import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
import nodemailer from "npm:nodemailer@6.9.7";

// Environment variables
const SMTP_HOST = "smtp.naver.com";
const SMTP_PORT = 465;
const SMTP_USER = Deno.env.get("NAVER_SMTP_USER") ?? "realplan01@naver.com";
const SMTP_PASS = Deno.env.get("NAVER_SMTP_PASS") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

// CORS headers
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// SMTP transporter (lazy singleton)
let transporter: ReturnType<typeof nodemailer.createTransport> | null = null;
function getTransporter() {
  if (!transporter) {
    transporter = nodemailer.createTransport({
      host: SMTP_HOST,
      port: SMTP_PORT,
      secure: true,
      auth: { user: SMTP_USER, pass: SMTP_PASS },
      connectionTimeout: 30_000,
      greetingTimeout: 15_000,
      socketTimeout: 60_000,
    });
  }
  return transporter;
}

// Supabase client (service_role)
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// v2.7 NEW: doc_type meta resolver
function getDocMeta(docType: string, qNumber: string) {
  switch (docType) {
    case "delivery":
      return {
        label: "납품서",
        number: (qNumber ?? "").replace(/^Q-/, "D-"),
        body: "납품 완료 사실을 알려드리며, 납품서를 첨부해 드립니다. 수령 확인 후 회신 부탁드립니다.",
      };
    case "statement":
      return {
        label: "거래명세서",
        number: (qNumber ?? "").replace(/^Q-/, "T-"),
        body: "거래 명세 확인을 위해 거래명세서를 첨부해 드립니다. 본 거래명세서는 세금계산서 발행 근거이며, 세금계산서는 별도 발행 예정입니다.",
      };
    case "quote":
    default:
      return {
        label: "견적서",
        number: qNumber ?? "",
        body: "요청하신 견적서를 첨부해 드립니다. 검토 후 아래 연락처로 회신 주시면 신속히 다음 단계 안내 드리겠습니다.",
      };
  }
}

// Build HTML body (v2.7: docType branch)
function buildHtml(p: any, docType: string): string {
  const safe = (s: any) => String(s ?? "").replace(/[<>&"]/g, (c) =>
    ({ "<": "&lt;", ">": "&gt;", "&": "&amp;", '"': "&quot;" } as any)[c]);
  const meta = getDocMeta(docType, p.견적번호);
  return `<div style="font-family:'Malgun Gothic','맑은 고딕',sans-serif;font-size:14px;line-height:1.7;color:#222">
    <p>안녕하세요, <strong>리얼플랜제주 주식회사</strong>입니다.</p>
    <p>${meta.body}</p>
    <table style="border-collapse:collapse;margin:14px 0">
      <tr><td style="padding:4px 12px 4px 0;color:#666">${meta.label}번호</td><td><strong>${safe(meta.number)}</strong></td></tr>
      <tr><td style="padding:4px 12px 4px 0;color:#666">사업부</td><td>${safe(p.사업부)}</td></tr>
      <tr><td style="padding:4px 12px 4px 0;color:#666">제목</td><td>${safe(p.제목)}</td></tr>
    </table>
    <p style="margin-top:18px">감사합니다.<br>
      <strong>리얼플랜제주 주식회사</strong> | 1577-2296 | realplan01@naver.com
    </p>
  </div>`;
}

// Main handler
serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ ok: false, error: "Method not allowed" }), {
      status: 405,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  let payload: any = {};
  try {
    payload = await req.json();
  } catch {
    return new Response(JSON.stringify({ ok: false, error: "Invalid JSON" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  // v2.7: extract doc_type (default 'quote')
  const { quotation_id, 견적번호, 수신자, pdf_base64, pdf_filename, 제목, doc_type } = payload;
  const docType: string = doc_type || "quote";
  const docMeta = getDocMeta(docType, 견적번호);

  if (!수신자?.email) {
    return new Response(JSON.stringify({ ok: false, error: "수신자.email 필수" }), {
      status: 400,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
  if (!SMTP_PASS) {
    return new Response(JSON.stringify({ ok: false, error: "Server SMTP not configured (NAVER_SMTP_PASS)" }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const attachments: any[] = [];
  if (pdf_base64 && typeof pdf_base64 === "string" && pdf_base64.length > 100) {
    attachments.push({
      filename: pdf_filename || `${docMeta.number || "document"}.pdf`,
      content: pdf_base64,
      encoding: "base64",
    });
  }

  try {
    // v2.7: subject branch by docType
    const info = await getTransporter().sendMail({
      from: `"리얼플랜제주 주식회사" <${SMTP_USER}>`,
      to: 수신자.email,
      subject: `[리얼플랜제주] ${제목 ?? ""} ${docMeta.label} (${docMeta.number})`.trim(),
      html: buildHtml(payload, docType),
      attachments,
    });

    // v2.7: RPC only when docType is quote (avoid status regression on delivery/statement)
    if (docType === "quote" && quotation_id && quotation_id !== "00000000-0000-0000-0000-000000000000") {
      const { error: rpcErr } = await supabase.rpc("rpc_mark_quotation_sent", {
        _quotation_id: quotation_id,
        _recipients: [{
          email: 수신자.email,
          회사명: 수신자.회사명 ?? null,
          담당자: 수신자.담당자 ?? null,
        }],
      });
      if (rpcErr) console.error("[rpc_mark_quotation_sent]", rpcErr);
    }

    return new Response(JSON.stringify({
      ok: true,
      doc_type: docType,
      doc_label: docMeta.label,
      doc_number: docMeta.number,
      quotation_id,
      recipient: 수신자.email,
      messageId: info.messageId,
      sent_at: new Date().toISOString(),
    }), {
      status: 200,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });

  } catch (e: any) {
    console.error("[send-quotation]", e);
    const errMsg = (e?.message || String(e)).slice(0, 500);

    // v2.7: failure RPC also only when docType is quote
    if (docType === "quote" && quotation_id && quotation_id !== "00000000-0000-0000-0000-000000000000") {
      try {
        await supabase.rpc("rpc_mark_quotation_failed", {
          _quotation_id: quotation_id,
          _error_reason: errMsg,
        });
      } catch (e2) {
        console.error("[rpc_mark_quotation_failed]", e2);
      }
    }

    return new Response(JSON.stringify({ ok: false, doc_type: docType, error: errMsg }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
