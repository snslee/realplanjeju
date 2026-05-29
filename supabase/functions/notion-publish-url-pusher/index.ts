// notion-publish-url-pusher v4.3 — Strategy 4 신규 (STAGE 7 신규 슬롯 Notion 직접 조회 fallback)
// 변경사항 (v4.2 대비):
//   Strategy 4 신규: publish_log 슬롯 미매칭 시 Notion 스케줄DB 직접 조회 fallback
//                   mk_blog_slots에 없는 STAGE 7 신규 생성 슬롯도 자동 매칭 가능
//                   채널+날짜±2일 필터 → 확정제목 유사도(0.25) → Notion PATCH 자동화
//
// v4.2 변경사항:
//   Strategy 0 신규: mk_blog_slots.상태='pending' + 발행일<=오늘 + 노션페이지id 있음
//                   → 채널별 RSS 직접 조회 → 제목유사도(0.25) 매칭 → Notion PATCH 자동화
//                   blog-publish-detector 감지 누락 케이스 자동 보완
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

const SCHEDULE_DB_ID = 'edca409c2843486f93a0ff303f9b9904'; // 📅 콘텐츠 스케줄DB 신규 (2026.04.21~)

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
    const r = await fetch(rssUrl, { headers: { 'User-Agent': 'realplan-notion-pusher/4.3' } });
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

// Strategy 4: Notion 스케줄DB 직접 조회 fallback
// mk_blog_slots에 없는 STAGE 7 신규 생성 슬롯 처리용
async function findNotionPageDirect(
  token: string,
  channel: string,
  rssTitle: string,
  publishDate: string
): Promise<{ notionPageId: string; sim: number } | null> {
  const baseDate = new Date(publishDate);
  const fromDate = new Date(baseDate.getTime() - 2 * 86400000).toISOString().slice(0, 10);
  const toDate   = new Date(baseDate.getTime() + 2 * 86400000).toISOString().slice(0, 10);

  const resp = await notionApi(token, `/databases/${SCHEDULE_DB_ID}/query`, 'POST', {
    filter: {
      and: [
        { property: '채널',  select: { equals: channel } },
        { property: '발행일', date:   { on_or_after:  fromDate } },
        { property: '발행일', date:   { on_or_before: toDate   } }
      ]
    },
    page_size: 30
  });
  if (!resp?.results?.length) return null;

  let best: { notionPageId: string; sim: number } | null = null;
  for (const page of resp.results) {
    const titleArr = page.properties?.['확정제목']?.title;
    const title    = (titleArr?.[0]?.plain_text || '').trim();
    if (!title) continue;
    const sim = Math.max(levSim(title, rssTitle), levSim(title, rssTitle));
    if (!best || sim > best.sim) best = { notionPageId: page.id.replace(/-/g, ''), sim };
  }
  return (best && best.sim >= 0.25) ? best : null;
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
  const toDate = new Date(baseDate.getTime() + 2 * 86400000).toISOString().slice(0, 10);

  const { data: slots } = await supabase.from('mk_blog_slots')
    .select('id, 노션페이지id, 최종제목, 발행일, 상태')
    .eq('채널', channel)
    .gte('발행일', fromDate)
    .lte('발행일', toDate)
    .not('노션페이지id', 'is', null)
    .order('발행일', { ascending: false });

  if (!slots || slots.length === 0) return null;

  let best: { slot: any; sim: number } | null = null;
  for (const s of slots) {
    const sim = levSim(s.최종제목 || '', rssTitle);
    if (!best || sim > best.sim) best = { slot: s, sim };
  }
  if (best && best.sim >= 0.30) {
    return { notionPageId: best.slot.노션페이지id, slotId: best.slot.id, sim: best.sim, method: '제목유사도' };
  }

  const validSlots = slots.filter(s => s.노션페이지id);
  if (validSlots.length === 1) {
    return { notionPageId: validSlots[0].노션페이지id, slotId: validSlots[0].id, sim: 0, method: '단일슬롯fallback' };
  }

  return null;
}

Deno.serve(async (_req) => {
  const token = await getSecret('realplan_notion_token');
  if (!token) return new Response(JSON.stringify({ ok: false, err: 'notion token' }), { status: 500 });

  // ── Strategy 0: pending 슬롯 RSS 직접 보완 ──
  const { fixed: s0Fixed, log: s0Log } = await processPendingSlots(token);

  // ── Strategy 1~3: publish_log 기반 처리 ──
  const { data: detected } = await supabase.from('mk_blog_publish_log')
    .select('id, 발행일, 채널, 외부_url, rss_제목, 상태, 매칭_슬롯_id')
    .in('상태', ['감지됨', '슬롯매칭', '실패'])
    .order('자동감지_시각', { ascending: false })
    .limit(50);

  let pushed = 0, noSlot = 0, errors = 0;
  const log: string[] = [...s0Log];

  if (detected && detected.length > 0) {
    for (const det of detected) {
      const isNaver = det.채널.includes('네이버');
      const urlPropName = isNaver ? '네이버_발행URL' : '티스토리_발행URL';
      const statusPropName = isNaver ? '네이버_상태' : '티스토리_상태';

      const match = await findNotionPageId(
        det.매칭_슬롯_id,
        det.채널,
        det.rss_제목 || '',
        det.발행일
      );

      if (!match) {
        // Strategy 4: Notion 스케줄DB 직접 조회 fallback (STAGE 7 신규 슬롯 대응)
        const notionMatch = await findNotionPageDirect(token, det.채널, det.rss_제목 || '', det.발행일);
        if (notionMatch) {
          log.push(`🔍 [S4 Notion직접 / sim ${notionMatch.sim.toFixed(2)}] [${det.채널}] ${(det.rss_제목 || '').slice(0, 25)}`);
          const s4Props: any = {};
          s4Props[urlPropName]    = { url: det.외부_url };
          s4Props[statusPropName] = { select: { name: '발행완료' } };
          const s4Patch = await notionApi(token, `/pages/${notionMatch.notionPageId}`, 'PATCH', { properties: s4Props });
          if (s4Patch) {
            await supabase.from('mk_blog_publish_log')
              .update({ 상태: '노션반영', 오류_메시지: null })
              .eq('id', det.id);
            pushed++;
            log.push(`  ✅ [S4] PATCH 성공 → 노션반영`);
          } else {
            errors++;
            await supabase.from('mk_blog_publish_log')
              .update({ 상태: '실패', 오류_메시지: `[S4] Notion PATCH 실패 (pageId: ${notionMatch.notionPageId.slice(0, 8)}...)` })
              .eq('id', det.id);
            log.push(`  ❌ [S4] PATCH 실패 → '실패' 유지`);
          }
          await new Promise(r => setTimeout(r, 350));
        } else {
          noSlot++;
          log.push(`❌ 슬롯 미매칭 [${det.채널}]: ${(det.rss_제목 || '').slice(0, 30)}`);
          await supabase.from('mk_blog_publish_log')
            .update({ 상태: '실패', 오류_메시지: '슬롯 미매칭 (노션페이지id 없음, S4 Notion조회도 실패)' })
            .eq('id', det.id);
        }
        continue;
      }

      log.push(`🔍 [${match.method} / sim ${match.sim.toFixed(2)}] ${(det.rss_제목 || '').slice(0, 25)}`);

      const updateProps: any = {};
      updateProps[urlPropName] = { url: det.외부_url };
      updateProps[statusPropName] = { select: { name: '발행완료' } };

      const patchResult = await notionApi(token, `/pages/${match.notionPageId}`, 'PATCH', { properties: updateProps });

      if (patchResult) {
        await supabase.from('mk_blog_publish_log')
          .update({ 상태: '노션반영', 매칭_슬롯_id: match.slotId, 오류_메시지: null })
          .eq('id', det.id);
        await supabase.from('mk_blog_slots')
          .update({ 상태: 'completed', 수정일: new Date().toISOString() })
          .eq('id', match.slotId)
          .neq('상태', 'completed');
        pushed++;
        log.push(`  ✅ PATCH 성공 → 노션반영 + 슬롯 completed`);
      } else {
        errors++;
        await supabase.from('mk_blog_publish_log')
          .update({ 상태: '실패', 오류_메시지: `Notion PATCH 실패 (pageId: ${match.notionPageId.slice(0, 8)}...)` })
          .eq('id', det.id);
        log.push(`  ❌ PATCH 실패 → '실패' 유지`);
      }

      await new Promise(r => setTimeout(r, 350));
    }
  }

  // 텔레그램 알림
  const tg = await getSecret('realplan_telegram_token');
  const ci = await getSecret('realplan_telegram_chat_id');
  if (tg && ci && (pushed > 0 || noSlot > 0 || errors > 0 || s0Fixed > 0)) {
    const msg = `📥 <b>노션 발행URL PUSH v4.3</b>\n\n✅ Strategy0(보완): ${s0Fixed}건\n✅ Strategy1~3: ${pushed}건\n❌ 슬롯없음: ${noSlot}건\n⚠️ PATCH실패: ${errors}건\n\n${log.slice(0, 25).join('\n')}`;
    await fetch(`https://api.telegram.org/bot${tg}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: ci, text: msg.slice(0, 4000), parse_mode: 'HTML' })
    });
  }

  return new Response(
    JSON.stringify({ ok: true, strategy0Fixed: s0Fixed, pushed, noSlot, errors, total: detected?.length || 0, log, version: 'v4.3' }),
    { headers: { 'Content-Type': 'application/json' } }
  );
});
