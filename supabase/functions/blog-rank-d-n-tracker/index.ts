// blog-rank-d-n-tracker v2.0 — 53차 (이모지 정합 + 변동 즉시 알림 + 미진입 포함)
// 매일 22 KST / D+7·14·30·90 장입판정 + 대표 텍레그램 알림

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false, autoRefreshToken: false } }
);

const CHANNEL_DOMAINS: Record<string, string[]> = {
  '블A네이버': ['blog.naver.com/realplan_travel'],
  '블A티스토리': ['wowjj8631.tistory.com'],
  '블B네이버': ['blog.naver.com/realplan_event'],
  '블B티스토리': ['realplan-event.tistory.com'],
  '블C네이버': ['blog.naver.com/realplan_marketing'],
  '블C티스토리': ['realplan-marketing.tistory.com']
};

async function getSecret(name: string): Promise<string | null> {
  const { data } = await supabase.rpc('realplan_get_secret', { secret_name: name });
  return data as string;
}

async function naverBlogSearch(id: string, sec: string, q: string, display = 100) {
  const url = `https://openapi.naver.com/v1/search/blog?query=${encodeURIComponent(q)}&display=${display}`;
  const r = await fetch(url, { headers: { 'X-Naver-Client-Id': id, 'X-Naver-Client-Secret': sec } });
  if (!r.ok) return null;
  return await r.json();
}

async function sendTelegram(msg: string) {
  const t = await getSecret('realplan_telegram_token');
  const c = await getSecret('realplan_telegram_chat_id');
  if (!t || !c) return;
  await fetch(`https://api.telegram.org/bot${t}/sendMessage`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: c, text: msg, parse_mode: 'HTML', disable_web_page_preview: true })
  });
}

Deno.serve(async (_req) => {
  const id = await getSecret('realplan_naver_search_client_id');
  const sec = await getSecret('realplan_naver_search_client_secret');
  if (!id || !sec) return new Response(JSON.stringify({ ok: false, err: 'secret' }), { status: 500 });

  const events: { d: number; ch: string; rank: number | null; 판정: string | null; kw: string; url: string; }[] = [];
  let totalMeasured = 0;

  for (const d of [7, 14, 30, 90]) {
    const { data: due } = await supabase.rpc('rpc_due_for_d_n_check', { _d: d });
    if (!due || due.length === 0) continue;
    for (const r of due) {
      if (!r.r_핵심키워드) continue;
      const result = await naverBlogSearch(id, sec, r.r_핵심키워드, 100);
      const items = result?.items || [];
      const domains = CHANNEL_DOMAINS[r.r_채널] || [];
      let rank: number | null = null;
      for (let i = 0; i < items.length; i++) {
        const link = items[i].link || '';
        const urlTail = r.r_외부_url.split('/').pop() || '';
        if (link === r.r_외부_url || domains.some(dm => link.includes(dm) && link.includes(urlTail))) {
          rank = i + 1; break;
        }
      }
      const { data: 판정 } = await supabase.rpc('rpc_update_d_n_rank', { _id: r.r_id, _d: d, _rank: rank });
      totalMeasured++;
      events.push({ d, ch: r.r_채널, rank, 판정: 판정 as string, kw: r.r_핵심키워드, url: r.r_외부_url });
      await new Promise(rs => setTimeout(rs, 80));
    }
  }

  // ✅ 즉시 알림 정책 v2: D+30 판정 소식은 건수 분각 알림 / D+7·14·90는 1~10위 진입 시만 알림
  for (const e of events) {
    let shouldNotify = false;
    let emoji = '';
    let body = '';
    if (e.d === 30) {
      shouldNotify = true;
      if (e.판정 === '✅ 1~5위') emoji = '🎉';
      else if (e.판정 === '⚠️ 6~10위') emoji = '⚠️';
      else if (e.판정 === '🔶 11~30위') emoji = '🔶';
      else emoji = '❌';
      body = `${emoji} <b>D+30 장입 판정 (최종)</b>\n\n● <b>${e.ch}</b> | ${e.판정}\n● 키워드: ${e.kw}\n● 순위: ${e.rank ?? '미진입'}\n● URL: ${e.url}`;
    } else if ((e.d === 7 || e.d === 14) && e.rank !== null && e.rank <= 10) {
      shouldNotify = true;
      emoji = e.rank <= 5 ? '🚀' : '📈';
      body = `${emoji} <b>D+${e.d} 조기 진입!</b>\n\n● <b>${e.ch}</b> | ${e.rank}위\n● 키워드: ${e.kw}\n● URL: ${e.url}`;
    } else if (e.d === 90 && e.rank !== null && e.rank <= 30) {
      shouldNotify = true;
      emoji = e.rank <= 5 ? '🏆' : '📊';
      body = `${emoji} <b>D+90 장기 프레이서스</b>\n\n● <b>${e.ch}</b> | ${e.rank}위\n● 키워드: ${e.kw}\n● URL: ${e.url}`;
    }
    if (shouldNotify) {
      await sendTelegram(body);
      await new Promise(rs => setTimeout(rs, 400));  // 텔레그램 rate limit
    }
  }

  // 요약 텍레그램 (건수 요약)
  if (totalMeasured > 0) {
    const d30Notified = events.filter(e => e.d === 30).length;
    const earlyEntries = events.filter(e => (e.d === 7 || e.d === 14) && e.rank !== null && e.rank <= 10).length;
    let summaryMsg = `📈 <b>D+N 일일 요약 (22 KST)</b>\n\n● 총 측정: ${totalMeasured}건\n● D+30 판정: ${d30Notified}건\n● D+7/14 조기 진입: ${earlyEntries}건`;
    await sendTelegram(summaryMsg);
  }

  return new Response(JSON.stringify({ ok: true, totalMeasured, events_count: events.length, version: 'v2' }), {
    headers: { 'Content-Type': 'application/json' }
  });
});
