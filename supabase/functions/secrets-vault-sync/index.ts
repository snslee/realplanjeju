// Supabase Edge Function: secrets-vault-sync v1.2 (RPC 인자명 정정)
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
async function sha256(text: string): Promise<string> {
  const buf = new TextEncoder().encode(text);
  const hash = await crypto.subtle.digest("SHA-256", buf);
  return Array.from(new Uint8Array(hash)).map(b => b.toString(16).padStart(2, "0")).join("");
}
serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const vaultNames = [
      "realplan_anthropic_api_key", "realplan_cron_internal_secret",
      "realplan_gsc_oauth_client_id", "realplan_gsc_oauth_client_secret", "realplan_gsc_oauth_refresh_token",
      "realplan_naver_ad_api_key", "realplan_naver_ad_customer_id", "realplan_naver_ad_secret_key",
      "realplan_naver_search_client_id", "realplan_naver_search_client_secret", "realplan_notion_token",
    ];
    const result: any = { ok: true, checked_at: new Date().toISOString(), hashes: {}, mismatches: [], missing: [] };
    for (const name of vaultNames) {
      try {
        const { data, error } = await supabase.rpc("realplan_get_secret", { secret_name: name });
        if (error || !data) { result.missing.push({ name, reason: error?.message || "data null" }); continue; }
        const hash = await sha256(String(data));
        const hashSlice = hash.slice(0, 16);
        result.hashes[name] = hashSlice;
        const { data: existing } = await supabase.from("secrets_inventory").select("id, 비고").eq("시크릿_이름", name).maybeSingle();
        if (existing) {
          const prevMeta = String(existing.비고 || "");
          const prevHashMatch = prevMeta.match(/hash16:([0-9a-f]{16})/);
          if (prevHashMatch && prevHashMatch[1] !== hashSlice) result.mismatches.push({ name, prev: prevHashMatch[1], now: hashSlice });
          const newMeta = (prevMeta.replace(/hash16:[0-9a-f]+/, "").trim() + ` hash16:${hashSlice}`).trim();
          await supabase.from("secrets_inventory").update({ 비고: newMeta, 마지막_점검일: new Date().toISOString() }).eq("id", existing.id);
        }
      } catch (e: any) { result.missing.push({ name, reason: String(e?.message).slice(0, 60) }); }
    }
    result.email_sent = false;
    return json(result);
  } catch (e: any) { return json({ ok: false, error: String(e?.message) }, 500); }
});
