// notion-rank-pusher v1.0 (2026-05-28)
// 노션 콘텐츠 스케줄DB 직접 조회 → mk_rank_tracker 매칭 → D+N·진입판정 PATCH + 텔레그램 알림
// 정합: v2.1 §13 / 53차 마스터플랜 (노션 = 블로그 슬롯 SSoT)

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const NOTION_DB_ID = "edca409c-2843-486f-93a0-ff303f9b9904"; // 콘텐츠 스케줄DB 신규

const sb = createClient(SUPABASE_URL, SUPABASE_KEY);

async function getSecret(name: string): Promise<string> {
  const { data, error } = await sb.rpc("realplan_get_secret", { secret_name: name });
  if (error) throw new Error(`getSecret ${name}: ${error.message}`);
  return data as string;
}

function normalizeUrl(u: string | null): string | null {
  if (!u) return null;
  return u.replace(/<!\[CDATA\[(.*?)\]\]>/g, "$1")
          .replace(/\?fromRss=true.*$/, "")
          .replace(/\/$/, "");
}

function judgement(rank: number | null): string | null {
  if (rank === null) return null;
  if (rank >= 1 && rank <= 5) return "✅1~5위";
  if (rank >= 6 && rank <= 10) return "⚠️6~10위";
  if (rank >= 11 && rank <= 30) return "🔶11~30위";
  return "❌미진입";
}

async function notionQuery(token: string, dbId: string, startCursor?: string): Promise<any> {
  const body: any = { page_size: 100 };
  if (startCursor) body.start_cursor = startCursor;
  const res = await fetch(`https://api.notion.com/v1/databases/${dbId}/query`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${token}`,
      "Notion-Version": "2022-06-28",
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
  return await res.json();
}

async function notionPatch(token: string, pageId: string, props: any): Promise<boolean> {
  const res = await fetch(`https://api.notion.com/v1/pages/${pageId}`, {
    method: "PATCH",
    headers: {
      "Authorization": `Bearer ${token}`,
      "Notion-Version": "2022-06-28",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ properties: props }),
  });
  return res.ok;
}

async function findRank(채널: string, url: string | null, 발행일: string, dRange: [number, number]): Promise<number | null> {
  if (!url || !발행일) return null;
  const nUrl = normalizeUrl(url);
  if (!nUrl) return null;
  const start = new Date(발행일);
  start.setDate(start.getDate() + dRange[0]);
  const end = new Date(발행일);
  end.setDate(end.getDate() + dRange[1]);
  const startStr = start.toISOString().slice(0, 10);
  const endStr = end.toISOString().slice(0, 10);

  const { data, error } = await sb
    .from("mk_rank_tracker")
    .select("순위, 자체_url, 측정_일자")
    .eq("채널", 채널)
    .gte("측정_일자", startStr)
    .lte("측정_일자", endStr);

  if (error || !data) return null;
  let best: number | null = null;
  for (const r of data) {
    if (normalizeUrl(r.자체_url as string) === nUrl) {
      if (best === null || (r.순위 as number) < best) best = r.순위 as number;
    }
  }
  return best;
}

async function sendTelegram(token: string, chatId: string, text: string): Promise<boolean> {
  const res = await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ chat_id: chatId, text, parse_mode: "HTML", disable_web_page_preview: false }),
  });
  return res.ok;
}

Deno.serve(async (req: Request) => {
  const stats = { scanned: 0, patched: 0, alerts: 0, errors: [] as string[] };
  try {
    const notionToken = await getSecret("realplan_notion_token");
    const tgToken = await getSecret("realplan_telegram_token");
    const tgChat = await getSecret("realplan_telegram_chat_id");

    let cursor: string | undefined = undefined;
    let pages: any[] = [];
    do {
      const q: any = await notionQuery(notionToken, NOTION_DB_ID, cursor);
      pages = pages.concat(q.results || []);
      cursor = q.has_more ? q.next_cursor : undefined;
    } while (cursor);

    for (const p of pages) {
      stats.scanned += 1;
      try {
        const props = p.properties;
        const 채널 = props["채널"]?.select?.name;
        const 발행일 = props["발행일"]?.date?.start;
        if (!채널 || !발행일) continue;
        const isNaver = 채널.includes("네이버");
        const url = isNaver ? props["네이버_발행URL"]?.url : props["티스토리_발행URL"]?.url;
        if (!url) continue;

        const d7 = await findRank(채널, url, 발행일, [4, 10]);
        const d14 = await findRank(채널, url, 발행일, [11, 17]);
        const d30 = await findRank(채널, url, 발행일, [27, 33]);
        const d90 = await findRank(채널, url, 발행일, [85, 95]);
        const bestForJudge = d30 ?? d14 ?? d7;
        const j = judgement(bestForJudge);

        if (d7 === null && d14 === null && d30 === null && d90 === null && !j) continue;

        const patchProps: any = {};
        if (d7 !== null) patchProps["D+7_순위"] = { number: d7 };
        if (d14 !== null) patchProps["D+14_순위"] = { number: d14 };
        if (d30 !== null) patchProps["D+30_순위"] = { number: d30 };
        if (d90 !== null) patchProps["D+90_순위"] = { number: d90 };
        if (j) patchProps["진입판정"] = { select: { name: j } };

        const ok = await notionPatch(notionToken, p.id, patchProps);
        if (ok) {
          stats.patched += 1;
          // 진입판정 ✅·⚠️·🔶 시 텔레그램
          if (j === "✅1~5위" || j === "⚠️6~10위" || j === "🔶11~30위") {
            const title = props["슬롯제목(방향)"]?.title?.[0]?.plain_text || props["확정제목"]?.rich_text?.[0]?.plain_text || "(제목없음)";
            const text = `🏆 <b>상위노출 진입!</b>\n\n📝 ${title}\n📊 채널: ${채널}\n🎯 ${j}\n📈 D+7=${d7 ?? "-"} / D+14=${d14 ?? "-"} / D+30=${d30 ?? "-"}\n🔗 ${url}`;
            const sent = await sendTelegram(tgToken, tgChat, text);
            if (sent) stats.alerts += 1;
          }
        }
      } catch (e) {
        stats.errors.push(`${p.id}: ${(e as Error).message}`);
      }
    }

    return new Response(JSON.stringify({ ok: true, stats }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, error: (e as Error).message, stats }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
