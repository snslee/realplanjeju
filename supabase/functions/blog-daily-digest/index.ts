// blog-daily-digest v3 (2026-05-28)
// 6채널 통일 양식 + mk_metrics 직접 + 잠자는 거인 + 액션 아이템
// 설계: v2.3 §7 + 마케팅 admin v1.0

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const sb = createClient(SUPABASE_URL, SUPABASE_KEY);

async function getSecret(name: string): Promise<string> {
  const { data, error } = await sb.rpc("realplan_get_secret", { secret_name: name });
  if (error) throw new Error(`getSecret ${name}: ${error.message}`);
  return data as string;
}

function escapeHtml(s: string): string {
  if (!s) return "";
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

function fmt(n: number | null | undefined, suffix: string = ""): string {
  if (n === null || n === undefined || n === 0) return "-";
  return n.toLocaleString("ko-KR") + suffix;
}

function fmtPct(n: number | null | undefined): string {
  if (n === null || n === undefined || n === 0) return "-";
  return n.toFixed(2) + "%";
}

async function sendTelegram(token: string, chatId: string, text: string): Promise<boolean> {
  const res = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text, parse_mode: "HTML", disable_web_page_preview: true }),
  });
  return res.ok;
}

Deno.serve(async (_req: Request) => {
  try {
    const tgToken = await getSecret("realplan_telegram_token");
    const tgChat = await getSecret("realplan_telegram_chat_id");

    // 1. 어제 발행 + 24h 성과 + 잠자는 거인 (RPC 직접)
    const { data: yPerf, error: yErr } = await sb.rpc("rpc_blog_yesterday_performance");
    if (yErr) throw new Error(`rpc_blog_yesterday_performance: ${yErr.message}`);
    const perf = yPerf as any;

    const yesterday = perf?.yesterday || new Date(Date.now() - 86400000).toISOString().slice(0, 10);
    const counts = perf?.counts || {};
    const total = perf?.total || 0;
    const posts = (perf?.posts || []) as any[];
    const giants = (perf?.sleeping_giants || []) as any[];

    // 2. 어제 슬롯 예정 (계획 vs 실제)
    const { data: planned } = await sb
      .from("mk_blog_slots")
      .select("채널")
      .eq("발행일", yesterday);
    const plannedCounts: Record<string, number> = {};
    (planned || []).forEach((p: any) => {
      plannedCounts[p.채널] = (plannedCounts[p.채널] || 0) + 1;
    });
    const totalPlanned = (planned || []).length;

    // 3. 상위노출 진입 (진입판정 ✅·⚠️·🔶)
    const { data: rankEntries } = await sb
      .from("mk_blog_publish_log")
      .select("채널, rss_제목, 진입판정, d_plus_7_rank, d_plus_14_rank, d_plus_30_rank")
      .in("진입판정", ["✅1~5위", "⚠️6~10위", "🔶11~30위"])
      .order("발행일", { ascending: false })
      .limit(3);

    // 4. 메시지 구성
    const CHANNELS = ["블A네이버", "블A티스토리", "블B네이버", "블B티스토리", "블C네이버", "블C티스토리"];
    let msg = `📊 <b>블로그 일일 리포트 (${yesterday})</b>\n\n`;

    // 발행 카운트
    msg += `✅ <b>어제 발행 (중복 제거 후 ${total}건)</b>\n`;
    for (const ch of CHANNELS) {
      const actual = counts[ch] || 0;
      const planned = plannedCounts[ch] || 0;
      const icon = actual === planned ? "✅" : actual < planned ? "⚠️" : "➕";
      msg += `  • ${ch}: ${actual}건`;
      if (planned > 0 && planned !== actual) msg += ` (계획 ${planned})`;
      msg += ` ${icon}\n`;
    }
    if (totalPlanned > 0) {
      const ratio = Math.round((total / totalPlanned) * 100);
      msg += `  ───────────────\n  실제 ${total}건 / 계획 ${totalPlanned}건 (${ratio}%)\n\n`;
    } else {
      msg += "\n";
    }

    // 어제 발행 글 24h 성과
    if (posts.length > 0) {
      msg += `📈 <b>어제 발행 글 24h 성과</b>\n\n`;
      const byChannel: Record<string, any[]> = {};
      for (const p of posts) {
        if (!byChannel[p.채널]) byChannel[p.채널] = [];
        byChannel[p.채널].push(p);
      }
      let cardIdx = 1;
      for (const ch of CHANNELS) {
        const list = byChannel[ch] || [];
        if (list.length === 0) continue;
        for (const p of list) {
          const titleTrim = (p.제목 || "").length > 35 ? p.제목.slice(0, 35) + "…" : p.제목 || "";
          const isTistory = ch.includes("티스토리");
          msg += `<b>${cardIdx}. [${ch}]</b> ${escapeHtml(titleTrim)}\n`;
          if (isTistory) {
            msg += `   클릭 ${fmt(p.클릭)} / 노출 ${fmt(p.노출)} / CTR ${fmtPct(p.ctr)}\n`;
            msg += `   평균 순위 ${p.순위 > 0 ? p.순위.toFixed(1) + "위" : "-"}\n`;
          } else {
            msg += `   조회 ${fmt(p.조회)} / 좋아요 ${fmt(p.좋아요)} / 댓글 ${fmt(p.댓글)}\n`;
            msg += `   체류 ${fmt(p.체류초, "초")} / 전환 ${fmt(p.전환)} / ROI ${fmtPct(p.roi)}\n`;
          }
          msg += `\n`;
          cardIdx++;
        }
      }
    }

    // 잠자는 거인
    if (giants && giants.length > 0) {
      msg += `⚡ <b>잠자는 거인 (즉시 액션)</b>\n`;
      for (const g of giants) {
        msg += `• [${g.채널}] 노출 ${fmt(g.노출)} / 클릭 ${fmt(g.클릭)} / ${g.순위.toFixed(1)}위\n`;
      }
      msg += `→ 제목 한 줄 추가 권장\n\n`;
    }

    // 상위노출 진입
    if (rankEntries && rankEntries.length > 0) {
      msg += `🏆 <b>상위노출 진입 (최근 3건)</b>\n`;
      for (const r of rankEntries) {
        const title = (r.rss_제목 || "").length > 30 ? r.rss_제목.slice(0, 30) + "…" : r.rss_제목 || "";
        msg += `• ${r.진입판정} [${r.채널}] ${escapeHtml(title)}\n`;
      }
      msg += `\n`;
    }

    // 액션 아이템
    const todayDate = new Date();
    const isFirstDay = todayDate.getDate() === 1;
    if (isFirstDay) {
      msg += `📁 <b>월간 네이버 통계 zip 요청</b>\n• 이번 달 1일 = 다운로드 필요\n• 폴더: D:\\자동화\\온라인마케팅 부서\\📊 DB\\월간 채널 성과 DB\\\n\n`;
    }

    msg += `→ marketing.realplanjeju.com 자세히`;

    await sendTelegram(tgToken, tgChat, msg);

    return new Response(JSON.stringify({
      ok: true,
      version: "v3",
      total_posts: total,
      planned: totalPlanned,
      giants: giants?.length || 0,
      entries: rankEntries?.length || 0
    }), {
      headers: { "Content-Type": "application/json" }
    });
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, error: (e as Error).message }), {
      status: 500,
      headers: { "Content-Type": "application/json" }
    });
  }
});
