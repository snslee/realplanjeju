// blog-publish-detector v4.2 — syncToSlot 임계값 0.45 → 0.30
// 변경사항 (v4.1 대비):
//   1) syncToSlot 유사도 임계값 0.45 → 0.30
//      RSS 발행 제목과 슬롯 최종제목이 달라도 매칭 가능하도록 개선
//      핵심키워드도 유사도 비교에 병행 활용 (Math.max)
//
// v4.1 변경사항:
//   1) syncToSlot() 반환값: boolean → string|null (슬롯ID 반환)
//   2) 슬롯 매칭 성공 시 mk_blog_publish_log.매칭_슬롯_id + 상태='슬롯매칭' 저장
//      → notion-publish-url-pusher v4 Strategy 1 (직접ID) 활성화

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

const CHANNELS = [
  { name: '블A네이버', rss: 'https://rss.blog.naver.com/realplan_travel.xml' },
  { name: '블A티스토리', rss: 'https://wowjj8631.tistory.com/rss' },
  { name: '블B네이버', rss: 'https://rss.blog.naver.com/realplan_event.xml' },
  { name: '블B티스토리', rss: 'https://realplan-event.tistory.com/rss' },
  { name: '블C네이버', rss: 'https://rss.blog.naver.com/realplan_marketing.xml' },
  { name: '블C티스토리', rss: 'https://realplan-marketing.tistory.com/rss' }
];

async function getSecret(name: string): Promise<string | null> {
  const { data } = await supabase.rpc('realplan_get_secret', { secret_name: name });
  return data as string;
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

function unwrapCdata(s: string): string {
  return s.replace(/^<!\[CDATA\[/, '').replace(/\]\]>$/, '').trim();
}
function normalizeUrl(u: string): string {
  let url = unwrapCdata(u);
  url = url.replace(/\?fromRss=true&trackingCode=rss$/, '');
  return url.trim();
}
function unescapeEntities(s: string): string {
  return s.replace(/&amp;middot;/g, '·').replace(/&middot;/g, '·')
          .replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"');
}
function escapeHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

async function parseRSS(url: string): Promise<{ title: string, link: string, pubDate: string }[]> {
  try {
    const r = await fetch(url, { headers: { 'User-Agent': 'realplan-blog-detector/4.2' } });
    if (!r.ok) return [];
    const xml = await r.text();
    const items: { title: string, link: string, pubDate: string }[] = [];
    const itemRegex = /<item[\s\S]*?<\/item>/g;
    const matches = xml.match(itemRegex) || [];
    for (const m of matches) {
      let title = (m.match(/<title>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/title>/)?.[1] || '').trim();
      let link = (m.match(/<link>([\s\S]*?)<\/link>/)?.[1] || '').trim();
      const pubDate = (m.match(/<pubDate>([\s\S]*?)<\/pubDate>/)?.[1] || '').trim();
      link = normalizeUrl(link);
      title = unescapeEntities(unwrapCdata(title));
      if (title && link) items.push({ title, link, pubDate });
    }
    return items;
  } catch (e) { console.error("rss err", url, e); return []; }
}

async function sendTelegram(msg: string) {
  try {
    const token = await getSecret('realplan_telegram_token');
    const chatId = await getSecret('realplan_telegram_chat_id');
    if (!token || !chatId) return;
    await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: chatId, text: msg, parse_mode: 'HTML', disable_web_page_preview: true })
    });
  } catch (e) { console.error("tg err", e); }
}

// v4.2: 임계값 0.30 / 핵심키워드 병행 비교
async function syncToSlot(channelName: string, rssTitle: string, url: string): Promise<string | null> {
  try {
    const isTistory = channelName.includes('티스토리');
    const since = new Date(Date.now() - 90 * 86400000).toISOString().slice(0, 10);
    const { data: slots } = await supabase
      .from('mk_blog_slots')
      .select('id, 최종제목, 핵심키워드, 실행로그, 티스토리포스트id, 상태')
      .eq('채널', channelName)
      .gte('발행일', since)
      .limit(60);

    if (!slots || slots.length === 0) return null;

    let best: { slot: any; sim: number } | null = null;
    for (const s of slots) {
      const sim1 = levSim(s.최종제목 || '', rssTitle);
      const sim2 = levSim(s.핵심키워드 || '', rssTitle);
      const sim = Math.max(sim1, sim2);
      if (!best || sim > best.sim) best = { slot: s, sim };
    }
    if (!best || best.sim < 0.30) return null;

    const existingLog = Array.isArray(best.slot.실행로그) ? best.slot.실행로그 : [];
    if (existingLog.some((e: any) => e.url === url)) return null;

    const logEntry = { step: '발행감지', url, ts: new Date().toISOString(), sim: parseFloat(best.sim.toFixed(2)) };
    const newLog = [...existingLog, logEntry];

    const updateData: any = { 실행로그: newLog };
    if (isTistory && !best.slot.티스토리포스트id) {
      updateData.티스토리포스트id = url;
    }
    if (best.slot.상태 === 'pending') {
      updateData.상태 = 'completed';
    }

    const { error } = await supabase.from('mk_blog_slots').update(updateData).eq('id', best.slot.id);
    if (error) { console.error('syncToSlot update err', error); return null; }
    return best.slot.id;
  } catch (e) {
    console.error('syncToSlot err', channelName, e);
    return null;
  }
}

Deno.serve(async (_req) => {
  const today = new Date().toISOString().slice(0, 10);
  const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
  let totalNew = 0;
  const newPosts: { channel: string; title: string; url: string }[] = [];
  const channelStats: { ch: string; 신규: number; 감지: number; 슬롯매칭: number }[] = [];

  for (const ch of CHANNELS) {
    const items = await parseRSS(ch.rss);
    let newCount = 0, detectedCount = 0, slotMatched = 0;
    for (const it of items.slice(0, 10)) {
      detectedCount++;
      const { data: dup } = await supabase.from('mk_blog_publish_log').select('id').eq('외부_url', it.link).maybeSingle();
      if (dup) continue;
      const pubDateStr = it.pubDate ? new Date(it.pubDate).toISOString().slice(0, 10) : today;
      if (pubDateStr < yesterday) continue;
      await supabase.from('mk_blog_publish_log').insert({
        발행일: pubDateStr, 채널: ch.name, 외부_url: it.link, rss_제목: it.title, 상태: '감지됨'
      });
      const matchedSlotId = await syncToSlot(ch.name, it.title, it.link);
      if (matchedSlotId) {
        slotMatched++;
        await supabase.from('mk_blog_publish_log')
          .update({ 매칭_슬롯_id: matchedSlotId, 상태: '슬롯매칭' })
          .eq('외부_url', it.link);
      }
      newCount++;
      newPosts.push({ channel: ch.name, title: it.title, url: it.link });
    }
    totalNew += newCount;
    channelStats.push({ ch: ch.name, 신규: newCount, 감지: detectedCount, 슬롯매칭: slotMatched });
  }

  if (totalNew > 0) {
    try {
      await fetch(`${SUPABASE_URL}/functions/v1/notion-publish-url-pusher`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${SUPABASE_SERVICE_KEY}` },
        body: JSON.stringify({ trigger: 'chained_from_publish_detector_v4' })
      });
    } catch (e) { console.error('chain err', e); }

    let msg = `📢 <b>블로그 발행 감지 (11 KST)</b>\n\n`;
    const totalMatched = channelStats.reduce((a, s) => a + s.슬롯매칭, 0);
    msg += `<b>신규 ${totalNew}건 · 슬롯매칭 ${totalMatched}건</b>\n\n`;
    const maxList = Math.min(newPosts.length, 5);
    for (let i = 0; i < maxList; i++) {
      const p = newPosts[i];
      const titleTrim = p.title.length > 40 ? p.title.slice(0, 40) + '...' : p.title;
      msg += `${i+1}・ <b>${p.channel}</b>\n   ${escapeHtml(titleTrim)}\n   ${p.url}\n\n`;
    }
    if (newPosts.length > 5) msg += `… 외 ${newPosts.length - 5}건\n\n`;
    msg += `→ 노션 PUSH 자동 연계 (11:30 KST 매칭 확인)`;
    await sendTelegram(msg);
  }

  return new Response(JSON.stringify({ ok: true, totalNew, channelStats, version: 'v4.2' }), {
    headers: { 'Content-Type': 'application/json' }
  });
});
                                                                                                                                                                                                                                                    