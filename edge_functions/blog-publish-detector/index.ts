// blog-publish-detector v9.0 — 키워드 자동 매칭 복사 + 텔레그램 즉시알림 (2026-05-30)
// v8 대비 변경:
//   1) syncToSlot → { slotId, keyword } 반환
//   2) 발행로그 UPDATE 시 핵심키워드 자동 복사 (슬롯 키워드 → 발행로그)
//   3) User-Agent realplan-blog-detector/9.0

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

const CHANNELS = [
  { name: '블A네이버',    rss: 'https://rss.blog.naver.com/realplan_travel.xml' },
  { name: '블A티스토리',  rss: 'https://wowjj8631.tistory.com/rss' },
  { name: '블B네이버',    rss: 'https://rss.blog.naver.com/realplan_event.xml' },
  { name: '블B티스토리',  rss: 'https://realplan-event.tistory.com/rss' },
  { name: '블C네이버',    rss: 'https://rss.blog.naver.com/realplan_marketing.xml' },
  { name: '블C티스토리',  rss: 'https://realplan-marketing.tistory.com/rss' }
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

function unwrapCdata(s: string): string { return s.replace(/^<!\[CDATA\[/, '').replace(/\]\]>$/, '').trim(); }
function normalizeUrl(u: string): string {
  let url = unwrapCdata(u);
  url = url.replace(/\?fromRss=true&trackingCode=rss$/, '');
  return url.trim();
}
function unescapeEntities(s: string): string {
  return s
    .replace(/&mdash;/g, '—').replace(/&#8212;/g, '—').replace(/&#x2014;/gi, '—')
    .replace(/&ndash;/g, '–').replace(/&#8211;/g, '–').replace(/&#x2013;/gi, '–')
    .replace(/&middot;/g, '·').replace(/&#183;/g, '·').replace(/&#xb7;/gi, '·')
    .replace(/&nbsp;/g, ' ').replace(/&#160;/g, ' ').replace(/&#xa0;/gi, ' ')
    .replace(/&hellip;/g, '…').replace(/&#8230;/g, '…').replace(/&#x2026;/gi, '…')
    .replace(/&apos;/g, "'").replace(/&#39;/g, "'")
    .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&');
}
function escapeHtml(s: string): string { return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
function dPlusDate(days: number): string {
  const d = new Date(Date.now() + days * 86400000);
  return `${d.getMonth() + 1}/${d.getDate()}`;
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

async function sendPostNotification(channel: string, title: string, url: string, slotMatched: boolean) {
  const titleTrim = title.length > 45 ? title.slice(0, 45) + '…' : title;
  const matchBadge = slotMatched ? '✅ 슬롯매칭' : '⚠️ 슬롯미매칭';
  const msg = [
    `🚀 <b>블로그 발행 감지</b>`,
    ``,
    `채널: <b>${channel}</b>`,
    `제목: ${escapeHtml(titleTrim)}`,
    `${matchBadge}`,
    ``,
    `D+7 측정: ${dPlusDate(7)} · D+14: ${dPlusDate(14)}`,
    `<a href="${url}">${url.slice(0, 60)}</a>`,
    ``,
    `→ <a href="https://realplanjeju.com/admin/marketing.html">마케팅 대시보드</a>`
  ].join('\n');
  await sendTelegram(msg);
}

async function parseRSS(url: string): Promise<{ title: string, link: string, pubDate: string }[]> {
  try {
    const r = await fetch(url, { headers: { 'User-Agent': 'realplan-blog-detector/9.0' } });
    if (!r.ok) return [];
    const xml = await r.text();
    const items: { title: string, link: string, pubDate: string }[] = [];
    const itemRegex = /<item[\s\S]*?<\/item>/g;
    const matches = xml.match(itemRegex) || [];
    for (const m of matches) {
      let title = (m.match(/<title>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/title>/)?.[1] || '').trim();
      let link  = (m.match(/<link>([\s\S]*?)<\/link>/)?.[1] || '').trim();
      const pubDate = (m.match(/<pubDate>([\s\S]*?)<\/pubDate>/)?.[1] || '').trim();
      link  = normalizeUrl(link);
      title = unescapeEntities(unwrapCdata(title));
      if (title && link) items.push({ title, link, pubDate });
    }
    return items;
  } catch (e) { console.error("rss err", url, e); return []; }
}

async function syncToSlot(channelName: string, rssTitle: string, url: string): Promise<{ slotId: string; keyword: string | null } | null> {
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
    const cleanRssTitle = unescapeEntities(rssTitle);
    let best: { slot: any; sim: number } | null = null;
    for (const s of slots) {
      const sim = Math.max(levSim(s.최종제목 || '', cleanRssTitle), levSim(s.핵심키워드 || '', cleanRssTitle));
      if (!best || sim > best.sim) best = { slot: s, sim };
    }
    if (!best || best.sim < 0.30) return null;
    const existingLog = Array.isArray(best.slot.실행로그) ? best.slot.실행로그 : [];
    if (existingLog.some((e: any) => e.url === url)) return null;
    const logEntry = { step: '발행감지', url, ts: new Date().toISOString(), sim: parseFloat(best.sim.toFixed(2)) };
    const updateData: any = { 실행로그: [...existingLog, logEntry] };
    if (isTistory && !best.slot.티스토리포스트id) updateData.티스토리포스트id = url;
    if (best.slot.상태 === 'pending') updateData.상태 = 'completed';
    const { error } = await supabase.from('mk_blog_slots').update(updateData).eq('id', best.slot.id);
    if (error) { console.error('syncToSlot err', error); return null; }
    return { slotId: best.slot.id, keyword: best.slot.핵심키워드 || null };
  } catch (e) { console.error('syncToSlot err', channelName, e); return null; }
}

Deno.serve(async (_req) => {
  const today     = new Date().toISOString().slice(0, 10);
  const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
  let totalNew = 0;
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
      const matchedSlot = await syncToSlot(ch.name, it.title, it.link);
      if (matchedSlot) {
        slotMatched++;
        const upd: any = { 매칭_슬롯_id: matchedSlot.slotId, 상태: '슬롯매칭' };
        if (matchedSlot.keyword) upd.핵심키워드 = matchedSlot.keyword;
        await supabase.from('mk_blog_publish_log').update(upd).eq('외부_url', it.link);
      }
      newCount++;
      await sendPostNotification(ch.name, it.title, it.link, !!matchedSlot);
    }
    totalNew += newCount;
    channelStats.push({ ch: ch.name, 신규: newCount, 감지: detectedCount, 슬롯매칭: slotMatched });
  }

  if (totalNew > 0) {
    try {
      await fetch(`${SUPABASE_URL}/functions/v1/notion-publish-url-pusher`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${SUPABASE_SERVICE_KEY}` },
        body: JSON.stringify({ trigger: 'chained_from_publish_detector_v9' })\
      });
    } catch (e) { console.error('chain err', e); }
  }

  return new Response(
    JSON.stringify({ ok: true, totalNew, channelStats, version: 'v9.0' }),
    { headers: { 'Content-Type': 'application/json' } }
  );
});
