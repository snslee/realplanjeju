// notion-blog-sync v2.0 — 51-3차 자가시정 (컬럼명 정합)
// 노션 스케줄DB → mk_blog_slots PULL (슬롯제목(방향) + 확정제목)

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });
const SCHEDULE_DB = "edca409c-2843-486f-93a0-ff303f9b9904";

async function getSecret(n: string) { const { data } = await supabase.rpc('realplan_get_secret', { secret_name: n }); return data as string | null; }

Deno.serve(async (_req) => {
  const token = await getSecret("realplan_notion_token");
  if (!token) return new Response(JSON.stringify({ ok: false, err: 'no token' }), { status: 500 });

  const since = new Date(Date.now() - 90 * 86400000).toISOString().slice(0, 10);
  let allPages: any[] = [];
  let cursor: string | undefined = undefined;
  for (let i = 0; i < 5; i++) {
    const body: any = { page_size: 100, filter: { property: '발행일', date: { on_or_after: since } } };
    if (cursor) body.start_cursor = cursor;
    const r = await fetch(`https://api.notion.com/v1/databases/${SCHEDULE_DB}/query`, {
      method: "POST",
      headers: { 'Authorization': `Bearer ${token}`, 'Notion-Version': '2022-06-28', 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    });
    if (!r.ok) { console.error('notion', r.status); break; }
    const j = await r.json();
    allPages = allPages.concat(j.results || []);
    if (!j.has_more) break;
    cursor = j.next_cursor;
  }

  let synced = 0;
  for (const p of allPages) {
    const props = p.properties || {};
    const slotTitle = props['슬롯제목(방향)']?.title?.map((t: any) => t.plain_text).join('') || '';
    const confirmed = props['확정제목']?.rich_text?.map((t: any) => t.plain_text).join('') || '';
    const 제목 = confirmed || slotTitle;
    const 채널 = props['채널']?.select?.name || '';
    const 발행일 = props['발행일']?.date?.start || null;
    const 슬롯유형 = props['슬롯유형']?.select?.name || '정보성';
    const 핵심키워드 = props['핵심키워드']?.rich_text?.map((t: any) => t.plain_text).join('') || '';
    const 네이버_상태 = props['네이버_상태']?.select?.name || '';
    const 티스토리_상태 = props['티스토리_상태']?.select?.name || '';
    if (!제목 || !채널) continue;

    const 상태 = (채널.includes('네이버') ? 네이버_상태 : 티스토리_상태).toLowerCase();
    const 매핑상태 = 상태.includes('발행완료') ? 'completed' : (상태.includes('완료') ? 'ready' : 'pending');

    const { data: existing } = await supabase.from('mk_blog_slots').select('id').eq('노션페이지id', p.id).maybeSingle();
    if (existing) {
      await supabase.from('mk_blog_slots').update({
        최종제목: 제목, 채널, 발행일, 슬롯유형,
        핵심키워드, 상태: 매핑상태, 수정일: new Date().toISOString()
      }).eq('id', existing.id);
    } else {
      await supabase.from('mk_blog_slots').insert({
        노션페이지id: p.id, 최종제목: 제목, 채널, 발행일,
        슬롯유형, 핵심키워드, 상태: 매핑상태, 콘텐츠방향: ''
      });
    }
    synced++;
  }

  return new Response(JSON.stringify({ ok: true, synced, total: allPages.length, version: 'v2.0' }), {
    headers: { 'Content-Type': 'application/json' }
  });
});
