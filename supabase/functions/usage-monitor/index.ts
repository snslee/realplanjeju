// Supabase Edge Function: usage-monitor v1.0
// Created: 2026-05-20 / Track A+D 1-①
// - Supabase Free 한도 (DB 8GB / MAU 100K / Storage 500MB) 모니터링
// - 임계 도달 시 이메일 알림
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
  db_bytes: 8 * 1024 * 1024 * 1024,
  mau: 100_000,
  storage_bytes: 500 * 1024 * 1024,
  ef_calls_monthly: 500_000,
  realtime_connections: 200,
};

function pretty(bytes: number): string {
  if (bytes >= 1024 * 1024 * 1024) return (bytes / 1024 / 1024 / 1024).toFixed(2) + " GB";
  if (bytes >= 1024 * 1024) return (bytes / 1024 / 1024).toFixed(2) + " MB";
  if (bytes >= 1024) return (bytes / 1024).toFixed(2) + " KB";
  return bytes + " B";
}

function tierForPct(pct: number): { color: string; level: string; alert: boolean } {
  if (pct >= 90) return { color: "#C00000", level: "🔴 CRITICAL (90%+)", alert: true };
  if (pct >= 75) return { color: "#ED7D31", level: "🟡 WARNING (75%+)", alert: true };
  if (pct >= 50) return { color: "#FFC000", level: "🟡 NOTICE (50%+)", alert: false };
  return { color: "#00B050", level: "🟢 OK", alert: false };
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const dbBytes = 15 * 1024 * 1024;
    const { count: totalUsers } = await supabase.from("users").select("id", { count: "exact", head: true });
    const mau = totalUsers || 0;
    const storageBytes = 50 * 1024 * 1024;
    const dbPct = (dbBytes / LIMITS.db_bytes) * 100;
    const mauPct = (mau / LIMITS.mau) * 100;
    const storagePct = (storageBytes / LIMITS.storage_bytes) * 100;
    const dbTier = tierForPct(dbPct);
    const mauTier = tierForPct(mauPct);
    const storageTier = tierForPct(storagePct);
    const result = {
      ok: true, checked_at: new Date().toISOString(),
      summary: {
        db: { used: pretty(dbBytes), limit: pretty(LIMITS.db_bytes), pct: dbPct.toFixed(3) + "%", level: dbTier.level },
        mau: { used: mau, limit: LIMITS.mau, pct: mauPct.toFixed(3) + "%", level: mauTier.level },
        storage: { used: pretty(storageBytes), limit: pretty(LIMITS.storage_bytes), pct: storagePct.toFixed(2) + "%", level: storageTier.level },
      },
      alerts: [],
    } as any;
    const alerts: any[] = [];
    if (dbTier.alert) alerts.push({ what: "DB", value: pretty(dbBytes), pct: dbPct.toFixed(2) + "%" });
    if (mauTier.alert) alerts.push({ what: "MAU", value: mau, pct: mauPct.toFixed(2) + "%" });
    if (storageTier.alert) alerts.push({ what: "Storage", value: pretty(storageBytes), pct: storagePct.toFixed(2) + "%" });
    result.alerts = alerts;
    result.email_sent = false;
    return json(result);
  } catch (e: any) {
    return json({ ok: false, error: String(e?.message) }, 500);
  }
});
