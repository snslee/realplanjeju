// Supabase Edge Function: secrets-monitor v1.0
// Created: 2026-05-20 / Track A+D 번들 B-2
// - 매주 월요일 09:00 KST (pg_cron) 호출
// - 60일/30일/7일 전 만료 임박 시크릿 → 이메일 발송 (snslee82@gmail.com)
// - secrets_alert_log로 중복 발송 방지
// Backup: 2026-05-20 (Track D 정합)

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

function tierForDays(days: number): { kind: string; label: string; color: string } | null {
  if (days <= 0) return { kind: "expired", label: "만료", color: "#C00000" };
  if (days <= 7) return { kind: "7d_critical", label: "7일 이내 만료", color: "#C00000" };
  if (days <= 30) return { kind: "30d_warning", label: "30일 이내 만료", color: "#ED7D31" };
  if (days <= 60) return { kind: "60d_warning", label: "60일 이내 만료", color: "#FFC000" };
  return null;
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { data: expiring, error: rpcErr } = await supabase.rpc("rpc_secrets_expiring", { _days: 60 });
    if (rpcErr) return json({ ok: false, error: rpcErr.message }, 500);

    const list = expiring || [];
    if (list.length === 0) {
      return json({ ok: true, count: 0, message: "만료 임박 시크릿 없음" });
    }

    const today = new Date().toISOString().slice(0, 10);
    const toAlert: any[] = [];
    for (const s of list) {
      const tier = tierForDays(s.r_남은_일수);
      if (!tier) continue;
      const { data: dup } = await supabase
        .from("secrets_alert_log")
        .select("id")
        .eq("시크릿_이름", s.r_시크릿_이름)
        .eq("알림_종류", tier.kind)
        .eq("발송_일자", today)
        .maybeSingle();
      if (!dup) toAlert.push({ ...s, tier });
    }

    if (toAlert.length === 0) {
      return json({ ok: true, count: 0, message: "중복 알림 제외 후 발송 대상 없음", checked: list.length });
    }

    if (!SMTP_PASS) return json({ ok: false, error: "NAVER_SMTP_PASS 미등록" }, 500);

    const rows = toAlert.map((s: any) => `
      <tr>
        <td style="padding:6px 12px;border-bottom:1px solid #e2e8f0">${s.r_시크릿_이름}</td>
        <td style="padding:6px 12px;border-bottom:1px solid #e2e8f0">${s.r_분류}</td>
        <td style="padding:6px 12px;border-bottom:1px solid #e2e8f0;color:${s.tier.color};font-weight:600">${s.tier.label}</td>
        <td style="padding:6px 12px;border-bottom:1px solid #e2e8f0">${s.r_만료일}</td>
        <td style="padding:6px 12px;border-bottom:1px solid #e2e8f0;text-align:center">${s.r_남은_일수}일</td>
        <td style="padding:6px 12px;border-bottom:1px solid #e2e8f0;color:#64748b;font-size:12px">${s.r_위치_D드라이브 || '-'}</td>
      </tr>`).join("");

    const html = `<div style="font-family:'Malgun Gothic','맑은 고딕',sans-serif;font-size:14px;line-height:1.7;color:#1f2937;max-width:760px">
      <h2 style="color:#1A4F8B;margin:0 0 14px 0">시크릿 만료 알림</h2>
      <p>안녕하세요, 이동환 대표님.</p>
      <p>아래 ${toAlert.length}건의 시크릿이 만료 임박 상태입니다.</p>
      <table style="border-collapse:collapse;margin:14px 0;width:100%">
        <thead><tr style="background:#D5E8F0">
          <th style="padding:8px 12px;text-align:left">시크릿</th>
          <th style="padding:8px 12px;text-align:left">분류</th>
          <th style="padding:8px 12px;text-align:left">단계</th>
          <th style="padding:8px 12px;text-align:left">만료일</th>
          <th style="padding:8px 12px;text-align:center">남은 일수</th>
          <th style="padding:8px 12px;text-align:left">위치</th>
        </tr></thead>
        <tbody>${rows}</tbody>
      </table>
      <hr style="border:none;border-top:0.5px solid #e2e8f0;margin:20px 0">
      <div style="font-size:12px;color:#64748b">리얼플랜제주 주식회사 / secrets-monitor v1.0 / 매주 월요일 09:00 KST 자동 발송</div>
    </div>`;

    const tr = nodemailer.createTransport({
      host: "smtp.naver.com", port: 465, secure: true,
      auth: { user: SMTP_USER, pass: SMTP_PASS },
    });

    let sent = 0;
    try {
      await tr.sendMail({
        from: `"리얼플랜제주" <${SMTP_USER}>`,
        to: RECIPIENT,
        subject: `[리얼플랜제주] 시크릿 만료 알림 — ${toAlert.length}건`,
        html,
      });
      sent = 1;

      for (const s of toAlert) {
        await supabase.from("secrets_alert_log").insert({
          시크릿_이름: s.r_시크릿_이름,
          알림_종류: s.tier.kind,
          발송_일자: today,
          수신자_이메일: RECIPIENT,
          결과: "sent",
        });
      }
    } catch (e: any) {
      return json({ ok: false, error: "SMTP 발송 실패", detail: String(e?.message) }, 500);
    }

    return json({
      ok: true,
      count: toAlert.length,
      sent,
      recipient: RECIPIENT,
      details: toAlert.map((s: any) => ({ name: s.r_시크릿_이름, days: s.r_남은_일수, tier: s.tier.kind })),
    });
  } catch (e: any) {
    return json({ ok: false, error: String(e?.message) }, 500);
  }
});
