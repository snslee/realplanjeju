// notion-publish-url-pusher v4.2 — Strategy 0 신규 (pending 슬롯 RSS 직접 보완)
// 변경사항 (v4.1 대비):
//   Strategy 0 신규: mk_blog_slots.상태='pending' + 발행일<=오늘 + 노션페이지id 있음
//                   → 채널별 RSS 직접 조회 → 제목유사도(0.25) 매칭 → Notion PATCH 자동화
//                   blog-publish-detector 감지 누락 케이스 자동 보완
//
// v4.1 변경사항:
//   6) findNotionPageId 날짜 윈도우: ±7일 → ±2일 (미래 슬롯 오매칭 방지)
// v4.0 변경사항:
//   1) Notion DB 검색 폐기 → mk_blog_slots.노션페이지id 직접 조회
//   2) PATCH 검증 강화: 성공 확인 후에만 '노션반영' 마킹
//   3) 매칭 전략 계층화: 직접ID → 제목유사도(0.30) → 단일슬롯 safe fallback
//   4) mk_blog_slots.상태 동시 업데이트
//   5) PATCH 실패 시 오류_메시지 기록

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

const CHANNEL_RSS: Record<string, string> = {
  '블A네이버': 'https://rss.blog.naver.com/realplan_travel.xml',
  '블A티스토리': 'https://wowjj8631.tistory.com/rss',
  '블B네이버': 'https://rss.blog.naver.com/realplan_event.xml',
  '블B티스토리': 'https://realplan-event.tistory.com/rss',
  '블C네이버': 'https://rss.blog.naver.com/realplan_marketing.xml',
  '블C티스토리': 'https://realplan-marketing.tistory.com/rss',
};

async function getSecret(n: string) {
  const { data } = await supabase.rpc('realplan_get_secret', { secret_name: n });
  return data as string | null;
}

function levSim(a: string, b: string): number {
  if (!a || !b) return 0;
  a = a.toLowerCase().replace(/[\s\W_]/g, '');
  b = b.toLowerCase().replace(/[\s\W_]/g, '');
  if (a === b) return 1;
  const m = a.length, n = b.length;
  if (m === 0 || n === 0) return 0;
  const dp: number[][] = Array.from({ length: m + 1 }, () => new Array(n + 1).fill(0));
  for (let i = 0; i <= m; i++) dp[i][0] = i;
  for (let j = 0; j <= n; j++) dp[0][j] = j;
  for (let i = 1; i <= m; i++)
    for (let j = 1; j <= n; j++)
      dp[i][j] = a[i-1] === b[j-1] ? dp[i-1][j-1] : 1 + Math.min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1]);
  return 1 - dp[m][n] / Math.max(m, n);
}

async function notionApi(token: string, path: string, method: string, body?: any) {
  const r = await fetch(`https://api.notion.com/v1${path}`, {
    method,
    headers: {
      'Authorization': `Bearer ${token}`,
      'Notion-Version': '2022-06-28',
      'Content-Type': 'application/json'
    },
    body: body ? JSON.stringify(body) : undefined
  });
  if (!r.ok) {
    const err = await r.text();
    console.error(`notion ${method} ${path}`, r.status, err.slice(0, 300));
    return null;
  }
  return await r.json();
}

// RSS 파싱 (Strategy 0용)
async function fetchRSS(channel: string): Promise<{ title: string; link: string; pubDate: string }[]> {
  const rssUrl = CHANNEL_RSS[channel];
  if (!rssUrl) return [];
  try {
    const r = await fetch(rssUrl, { headers: { 'User-Agent': 'realplan-notion-pusher/4.2' } });
    if (!r.ok) return [];
    const xml = await r.text();
    const items: { title: string; link: string; pubDate: string }[] = [];
    const itemRegex = /<item[\s\S]*?<\/item>/g;
    const matches = xml.match(itemRegex) || [];
    for (const m of matches.slice(0, 20)) {
      let title = (m.match(/<title>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/title>/)?.[1] || '').trim();
      let link = (m.match(/<link>([\s\S]*?)<\/link>/)?.[1] || '').trim();
      const pubDate = (m.match(/<pubDate>([\s\S]*?)<\/pubDate>/)?.[1] || '').trim();
      link = link.replace(/\?fromRss=true&trackingCode=rss$/, '').trim();
      title = title.replace(/^<!\[CDATA\[/, '').replace(/\]\]>$/, '').trim()
                   .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&middot;/g, '·');
      if (title && link) items.push({ title, link, pubDate });
    }
    return items;
  } catch (e) { console.error('fetchRSS err', channel, e); return []; }
}

// Strategy 0: pending 슬롯 → RSS 직접 조회 → Notion URL 자동 삽입
async function processPendingSlots(token: string): Promise<{ fixed: number; log: string[] }> {
  const today = new Date().toISOString().slice(0, 10);
  const log: string[] = [];
  let fixed = 0;

  const { data: pendingSlots } = await supabase.from('mk_blog_slots')
    .select('id, 채널, 최종제목, 핵심키워드, 노션페이지id, 발행일')
    .eq('상태', 'pending')
    .lte('발행일', today)
    .not('노션페이지id', 'is', null)
    .order('발행일', { ascending: false })
    .limit(20);

  if (!pendingSlots || pendingSlots.length === 0) return { fixed: 0, log: ['Strategy0: pending 슬롯 없음'] };

  const rssCache: Record<string, { title: string; link: string; pubDate: string }[]> = {};

  for (const slot of pendingSlots) {
    if (!rssCache[slot.채널]) {
      rssCache[slot.채널] = await fetchRSS(slot.채널);
    }
    const rssItems = rssCache[slot.채널];
    if (!rssItems || rssItems.length === 0) continue;

    // 제목 + 핵심키워드 유사도 비교
    let best: { item: any; sim: number } | null = null;
    for (const item of rssItems) {
      const sim1 = levSim(slot.최종제목 || '', item.title);
      const sim2 = levSim(slot.핵심키워드 || '', item.title);
      const sim = Math.max(sim1, sim2);
      if (!best || sim > best.sim) best = { item, sim };
    }

    if (!best || best.sim < 0.25) {
      log.push(`⏭ [S0] 유사도부족(${best?.sim.toFixed(2)||'0'}) [${slot.채널}]: ${(slot.최종제목||'').slice(0,25)}`);
      continue;
    }

    // 이미 publish_log에 있는지 확인
    const { data: existing } = await supabase.from('mk_blog_publish_log')
      .select('id, 매칭_슬롯_id').eq('외부_url', best.item.link).maybeSingle();

    // Notion PATCH
    const isNaver = slot.채널.includes('네이버');
    const isTistory = slot.채널.includes('티스토리');
    const urlPropName = isNaver ? '네이버_발행URL' : '티스토리_발행URL';
    const statusPropName = isNaver ? '네이버_상태' : '티스토리_상태';

    const updateProps: any = {};
    updateProps[urlPropName] = { url: best.item.link };
    updateProps[statusPropName] = { select: { name: '발행완료' } };

    const patchResult = await notionApi(token, `/pages/${slot.노션페이지id}`, 'PATCH', { properties: updateProps });

    if (patchResult) {
      // mk_blog_slots 완료 처리
      const slotUpdate: any = { 상태: 'completed', 수정일: new Date().toISOString() };
      if (isTistory) slotUpdate.티스토리포스트id = best.item.link;
      await supabase.from('mk_blog_slots').update(slotUpdate).eq('id', slot.id);

      // publish_log 갱신 or INSERT
      const pubDate = best.item.pubDate ? new Date(best.item.pubDate).toISOString().slice(0, 10) : slot.발행일;
      if (existing) {
        await supabase.from('mk_blog_publish_log')
          .update({ 상태: '노션반영', 매칭_슬롯_id: slot.id })
          .eq('id', existing.id);
      } else {
        await supabase.from('mk_blog_publish_log').insert({
          발행일: pubDate, 채널: slot.채널, 외부_url: best.item.link,
          rss_제목: best.item.title, 상태: '노션반영', 매칭_슬롯_id: slot.id
        });
      }
      fixed++;
      log.push(`✅ [S0 / sim ${best.sim.toFixed(2)}] [${slot.채널}] ${(slot.최종제목||'').slice(0,25)}`);
    } else {
      log.push(`❌ [S0] PATCH실패 [${slot.채널}]: ${(slot.최종제목||'').slice(0,25)}`);
    }

    await new Promise(r => setTimeout(r, 350));
  }

  return { fixed, log };
}

// Strategy 1~3: publish_log 기반 노션 PUSH (기존 로직)
async function findNotionPageId(
  matchingSlotId: string | null,
  channel: string,
  rssTitle: string,
  publishDate: string
): Promise<{ notionPageId: string; slotId: string; sim: number; method: string } | null> {

  if (matchingSlotId) {
    const { data } = await supabase.from('mk_blog_slots')
      .select('id, 노션페이지id, 최종제목')
      .eq('id', matchingSlotId)
      .single();
    if (data?.노션페이지id) {
      return { notionPageId: data.노션페이지id, slotId: data.id, sim: 1.0, method: '직접ID' };
    }
  }

  const baseDate = new Date(publishDate);
  const fromDate = new Date(baseDate.getTime() - 2 * 86400000).toISOString().slice(0, 10);
  const toDate = new Date(ba