// notion-publish-url-pusher v3.0 — B4 (임계값 0.45, 실패 상태 재처리 추가)
// 스키마 정합: 슬롯제목(방향)+확정제목 + 채널 필터 + URL type

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const SCHEDULE_DB = "edca409c-2843-486f-93a0-ff303f9b9904";

async function getSecret(n: string) { const { data } = await supabase.rpc('realplan_get_secret', { secret_name: n }); return data as string | null; }

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

function getNotionTitle(props: any): string {
  const titleProp = props['슬롯제목(방향)'];
  const confirmedProp = props['확정제목'];
  const confirmed = confirmedProp?.rich_text?.map((t: any) => t.plain_text).join('') || '';
  const slot = titleProp?.title?.map((t: any) => t.plain_text).join('') || '';
  return confirmed || slot;
}

// mk_blog_slots에서 해당 채널의 최종제목도 보조 매칭 후보로 활용
async function getSlotTitle(channelName: string, rssTitle: string): Promise<string> {
  const since = new Date(Date.now() - 90 * 86400000).toISOString().slice(0, 10);
  const { data: slots } = await supabase
    .from('mk_blog_slots')
    .select('최종제목')
    .eq('채널', channelName)
    .gte('발행일', since)
    .limit(60);
  if (!slots) return rssTitle;
  let best = { title: rssTitle, sim: 0 };
  for (const s of slots) {
    const sim = levSim(s.최종제목 || '', rssTitle);
    if (sim > best.sim) best = { title: s.최종제목 || rssTitle, sim };
  }
  return best.sim >= 0.45 ? best.title : rssTitle;
}

Deno.serve(async (_req) => {
  const token = await getSecret('realplan_notion_token');
  if (!token) return new Response(JSON.stringify({ ok: false, err: 'notion token' }), { status: 500 });

  // v3: '감지됨', '슬롯매칭', '실패' 상태 모두 처리 (실패 재처리 추가)
  const { data: detected } = await supabase.from('mk_blog_publish_log')
    .select('id,발행일,채널,외부_url,rss_제목,상태')
    .in('상태', ['감지됨', '슬롯매칭', '실패'])
    .order('자동감지_시각', { ascending: false }).limit(50);
  if (!detected || detected.length === 0) {
    return new Response(JSON.stringify({ ok: true, pushed: 0, msg: '대상 없음' }));
  }

  let pushed = 0, lowSim = 0, errors = 0;
  const log: string[] = [];

  const channelGroups: Record<string, typeof detected> = {};
  for (const d of detected) {
    if (!channelGroups[d.채널]) channelGroups[d.채널] = [];
    channelGroups[d.채널].push(d);
  }

  for (const channel of Object.keys(channelGroups)) {
    const isNaver = channel.includes('네이버');
    const urlPropName = isNaver ? '네이버_발행URL' : '티스토리_발행URL';
    const statusPropName = isNaver ? '네이버_상태' : '티스토리_상태';

    const filter: any = {
      and: [
        { property: '채널', select: { equals: channel } },
        { property: urlPropName, url: { is_empty: true } }
      ]
    };
    let allSlots: any[] = [];
    let cursor: string | undefined = undefined;
    for (let page = 0; page < 5; page++) {
      const body: any = { page_size: 100, filter };
      if (cursor) body.start_cursor = cursor;
      const r = await notionApi(token, `/databases/${SCHEDULE_DB}/query`, 'POST', body);
      if (!r) { errors++; break; }
      allSlots = allSlots.concat(r.results || []);
      if (!r.has_more) break;
      cursor = r.next_cursor;
    }
    log.push(`[${channel}] 빈값 슬롯: ${allSlots.length}건`);

    if (allSlots.length === 0) {
      const filter2: any = {
        and: [
          { property: '채널', select: { equals: channel } },
          { or: [
            { property: statusPropName, select: { equals: '대기' } },
            { property: statusPropName, select: { equals: '완료' } }
          ]}
        ]
      };
      const r2 = await notionApi(token, `/databases/${SCHEDULE_DB}/query`, 'POST', { page_size: 100, filter: filter2 });
      allSlots = r2?.results || [];
      log.push(`  대기/완료 상태 슬롯: ${allSlots.length}건`);
    }

    for (const det of channelGroups[channel]) {
      // v3: RSS 제목 + mk_blog_slots 최종제목 둘 다 시도
      const slotTitle = await getSlotTitle(channel, det.rss_제목 || '');
      const candidateTitles = [det.rss_제목 || '', slotTitle].filter((t, i, a) => a.indexOf(t) === i);

      let best: { slot: any, sim: number, title: string } | null = null;
      for (const slot of allSlots) {
        const notionTitle = getNotionTitle(slot.properties);
        if (!notionTitle) continue;
        for (const cTitle of candidateTitles) {
          const sim = levSim(notionTitle, cTitle);
          if (!best || sim > best.sim) best = { slot, sim, title: notionTitle };
        }
      }

      // v3: 임계값 0.50 → 0.45로 완화
      if (!best) {
        lowSim++;
        log.push(`  ❌ [${det.채널}] 슬롯 없음: ${(det.rss_제목 || '').slice(0, 30)}`);
        await supabase.from('mk_blog_publish_log').update({ 상태: '실패' }).eq('id', det.id);
        continue;
      }
      if (best.sim < 0.45) {
        lowSim++;
        log.push(`  ⚠️ 유사도 ${best.sim.toFixed(2)}: ${(det.rss_제목||'').slice(0,25)} ↔ ${(best.title||'').slice(0,25)}`);
        await supabase.from('mk_blog_publish_log').update({ 상태: '실패' }).eq('id', det.id);
        continue;
      }

      const updateProps: any = {};
      updateProps[urlPropName] = { url: det.외부_url };
      updateProps[statusPropName] = { select: { name: '발행완료' } };
      const patchResult = await notionApi(token, `/pages/${best.slot.id}`, 'PATCH', { properties: updateProps });
      if (patchResult) {
        await supabase.from('mk_blog_publish_log').update({ 상태: '노션반영' }).eq('id', det.id);
        pushed++;
        log.push(`  ✅ [${best.sim.toFixed(2)}] ${(det.rss_제목||'').slice(0,30)}`);
      } else {
        errors++;
        log.push(`  ❌ PATCH 실패: ${(det.rss_제목||'').slice(0,30)}`);
      }
      await new Promise(r => setTimeout(r, 350));
    }
  }

  const tg = await getSecret('realplan_telegram_token');
  const ci = await getSecret('realplan_telegram_chat_id');
  if (tg && ci && (pushed > 0 || lowSim > 0 || errors > 0)) {
    const msg = `📥 <b>노션 발행URL PUSH v3</b>\n\n✅ 성공: ${pushed}건\n⚠️ 유사도 부족: ${lowSim}건\n❌ 에러: ${errors}건\n\n${log.slice(0, 25).join('\n')}`;
    await fetch(`https://api.telegram.org/bot${tg}/sendMessage`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: ci, text: msg.slice(0, 4000), parse_mode: 'HTML' })
    });
  }

  return new Response(JSON.stringify({ ok: true, pushed, lowSim, errors, total: detected.length, log, version: 'v3.0' }), {
    headers: { 'Content-Type': 'application/json' }
  });
});
