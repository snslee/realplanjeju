// Supabase Edge Function: api-cost-monitor v1.0
// Created: 2026-05-20 / Track A+D 1-②
// - mk_api_logs 기반 일·월 비용 추적 (Anthropic·네이버)
// - 한도 도달 시 이메일 알림
import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
import nodemailer from "npm:nodemailer@6.9.7";

const SMTP_USER = Deno.env.get("NAVER_SMTP_USER") ?? "realplan01@naver.com";
const SMTP_PASS = Deno.env.get("NAVER_SMTP_PASS") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const RECIPIENT = "snslee82@gmail.com";

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

function json(d: any, s = 200) {
  return new Response(JSON.stringify(d), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

const LIMITS = {
  anthropic_usd_monthly: 50,
  naver_search_daily: 25000,
  naver_ad_monthly: 1000,
};

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const monthStart = new Date();
    monthStart.setDate(1); monthStart.setHours(0, 0, 0, 0);
    const todayStart = new Date(); todayStart.setHours(0, 0, 0, 0);
    const { data: logs } = await supabase.from("mk_api_logs").select("api_name, cost_usd, called_at").gte("called_at", monthStart.toISOString());
    let anthropicMonthly = 0, naverSearchToday = 0, naverAdMonthly = 0;
    for (const r of (logs || [])) {
      const api = String(r.api_name || "").toLowerCase();
      const cost = Number(r.cost_usd || 0);
      const called = new Date(r.called_at);
      if (api.includes("anthropic") || api.includes("claude")) anthropicMonthly += cost;
      else if (api.includes("naver_search") || api.includes("naver-search")) { if (called >= todayStart) naverSearchToday += 1; }
      else if (api.includes("naver_ad") || api.includes("naver-ad")) naverAdMonthly += 1;
    }
    const anthropicPct = (anthropicMonthly / LIMITS.anthropic_usd_monthly) * 100;
    const alerts: any[] = [];
    if (anthropicPct >= 80) alerts.push({ api: "Anthropic", used: "$" + anthropicMonthly.toFixed(2), pct: anthropicPct.toFixed(1) });
    return json({
      ok: true, checked_at: new Date().toISOString(),
      logs_count: (logs || []).length,
      summary: { anthropic: { used_usd: anthropicMonthly.toFixed(2), limit_usd: LIMITS.anthropic_usd_monthly, pct: anthropicPct.toFixed(1) + "%" } },
      alerts, email_sent: false,
    });
  } catch (e: any) { return json({ ok: false, error: String(e?.message) }, 500); }
});
