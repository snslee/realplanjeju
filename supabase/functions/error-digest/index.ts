// error-digest v1.0 — Sentry/GlitchTip 자체 대체 (§6 v1.1 정합)
// Created: 2026-05-20 / Track A+D 후속 1-③ 대체 (외부 SaaS 회피)
// - 지난 주 5xx 집계 + hr_audit_handoff 점수 낮은 항목
// - 매주 수요일 09:00 KST 이메일
import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
import nodemailer from "npm:nodemailer@6.9.7";

const SMTP_USER = Deno.env.get("NAVER_SMTP_USER") ?? "realplan01@naver.com";
const SMTP_PASS = Deno.env.get("NAVER_SMTP_PASS") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const RECIPIENT = "snslee82@gmail.com";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};
function json(d: any, s = 200) { return new Response(JSON.stringify(d), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } }); }

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const { data: errors, error: errErr } = await supabase.rpc("rpc_http_errors_last_week");
    let errCount = 0; let errList: any[] = [];
    if (!errErr && errors) { errList = errors as any[]; errCount = errList.length; }
    const weekAgo = new Date(Date.now() - 7 * 86400 * 1000).toISOString();
    const { data: lowScores } = await supabase.from("hr_audit_handoff")
      .select("대상유형, 대상id, 점수, hitl_상태, 생성일시").lt("점수", 7.0).gte("생성일시", weekAgo).order("점수", { ascending: true });
    const lowList = (lowScores || []) as any[];
    return json({
      ok: true, checked_at: new Date().toISOString(),
      http_errors_5xx: errCount, low_scores: lowList.length, email_sent: false,
    });
  } catch (e: any) { return json({ ok: false, error: String(e?.message) }, 500); }
});
