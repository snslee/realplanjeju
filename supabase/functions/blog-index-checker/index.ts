// blog-index-checker v1.0 — 51-2차 Phase A (Step 1 흡수)
// 매일 11:30 KST / 어제 발행글 색인 확인

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

async function getSecret(name: string): Promise<string | null> {
  const { data, error } = await supabase.rpc('realplan_get_secret', { secret_name: name });
  if (error) return null;
  return data as string;
}

async function naverSearch(id: string, sec: string, q: string) {
  const r = await fetch(`https://openapi.naver.com/v1/search/blog?query=${encodeURIComponent(q)}&display=10`,
    { headers: { 'X-Naver-Client-Id': id, 'X-Naver-Client-Secret': sec } });
  if (!r.ok) return null;
  return await r.json();
}

Deno.serve(async (_req) => {
  const id = await getSecret('realplan_naver_search_client_id');
  const sec = await getSecret('realplan_naver_search_client_secret');
  if (!id || !sec) return new Response(JSON.stringify({ ok: false, err: 'secret' }), { status: 500 });

  const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
  const { data: pubs } = await supabase.from('mk_blog_publish_log').select('id,채널,외부_url').eq('발행일', yesterday);
  if (!pubs || pubs.length === 0) {
    return new Response(JSON.stringify({ ok: true, count: 0, msg: '어제 발행글 0건' }));
  }

  let OK = 0, FAIL = 0, NONE = 0;
  for (const p of pubs) {
    // URL의 슬러그 명시적 검색
    const slug = p.외부_url.split('/').pop() || '';
    const q = `site:${new URL(p.외부_url).hostname} ${slug}`.slice(0, 60);
    const result = await naverSearch(id, sec, q);
    let 상태: 'OK' | '실패' | '없음' = '없음';
    if (result?.items?.length > 0) {
      상태 = result.items.some((it: any) => (it.link || '').includes(slug)) ? 'OK' : '실패';
    } else {
      상태 = '없음';
    }
    await supabase.from('mk_search_index').upsert({
      측정_일자: yesterday, 채널: p.채널, 외부_url: p.외부_url, 색인_상태: 상태, 검색_엔진: 'naver'
    }, { onConflict: '측정_일자,외부_url,검색_엔진' });
    if (상태 === 'OK') OK++;
    else if (상태 === '실패') FAIL++;
    else NONE++;
    await new Promise(r => setTimeout(r, 80));
  }

  return new Response(JSON.stringify({ ok: true, OK, FAIL, NONE, total: pubs.length }), {
    headers: { 'Content-Type': 'application/json' }
  });
});
