// blog-rank-tracker v2.0 — 51-2차 Phase A (Step 2 흡수: 30 → 100위 확장)

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, { auth: { persistSession: false, autoRefreshToken: false } });

const CHANNEL_DOMAINS: Record<string, string[]> = {
  '블A네이버': ['blog.naver.com/realplan_travel'],
  '블A티스토리': ['wowjj8631.tistory.com'],
  '블B네이버': ['blog.naver.com/realplan_event'],
  '블B티스토리': ['realplan-event.tistory.com'],
  '블C네이버': ['blog.naver.com/realplan_marketing'],
  '블C티스토리': ['realplan-marketing.tistory.com']
};
const CATEGORY_CHANNEL: Record<string, string[]> = {
  '국내여행': ['블A네이버','블A티스토리'],
  '행사이벤트': ['블B네이버','블B티스토리'],
  '온라인마케팅': ['블C네이버','블C티스토리']
};
async function getSecret(n: string) { const { data } = await supabase.rpc('realplan_get_secret', { secret_name: n }); return data as string | null; }
async function searchBlog(id: string, sec: string, q: string, display = 100) {
  const r = await fetch(`https://openapi.naver.com/v1/search/blog?query=${encodeURIComponent(q)}&display=${display}`, { headers: { 'X-Naver-Client-Id': id, 'X-Naver-Client-Secret': sec } });
  if (!r.ok) return null;
  return await r.json();
}
Deno.serve(async (_req) => {
  const id = await getSecret('realplan_naver_search_client_id');
  const sec = await getSecret('realplan_naver_search_client_secret');
  if (!id || !sec) return new Response(JSON.stringify({ ok: false, err: 'secret' }), { status: 500 });
  const { data: keywords } = await supabase.from('mk_keywords').select('카테고리,키워드,검색량').eq('활성', true).order('검색량', { ascending: false }).limit(30);
  if (!keywords) return new Response(JSON.stringify({ ok: true, processed: 0 }));
  let processed = 0, top10 = 0;
  for (const kw of keywords) {
    const channels = CATEGORY_CHANNEL[kw.카테고리] || [];
    try {
      const result = await searchBlog(id, sec, kw.키워드, 100);
      const items = result?.items || [];
      for (const ch of channels) {
        const domains = CHANNEL_DOMAINS[ch] || [];
        let foundRank: number | null = null, foundUrl: string | null = null;
        for (let i = 0; i < items.length; i++) {
          const link = items[i].link || '';
          if (domains.some(d => link.includes(d))) { foundRank = i + 1; foundUrl = link; break; }
        }
        await supabase.rpc('rpc_upsert_mk_rank', {
          _키워드: kw.키워드, _채널: ch, _자체_url: foundUrl, _순위: foundRank,
          _검색_결과_수: result?.total || items.length, _검색_엔진: 'naver'
        });
        if (foundRank && foundRank <= 10) top10++;
        processed++;
      }
      await new Promise(r => setTimeout(r, 100));
    } catch (e) { console.error('rank err', kw.키워드, e); }
  }
  return new Response(JSON.stringify({ ok: true, processed, top10, version: 'v2.0' }), { headers: { 'Content-Type': 'application/json' } });
});
