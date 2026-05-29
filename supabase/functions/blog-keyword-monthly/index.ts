// blog-keyword-monthly v1.0 — 51-2차 Phase A (Step 4 흡수)
// 매주 월 09:30 KST / 상위 50 키워드 검색량 갱신

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

Deno.serve(async (_req) => {
  const currentMonth = new Date().toISOString().slice(0, 7);
  // 상위 50 키워드 (카테고리별 균환 추출)
  const cats = ['국내여행', '행사이벤트', '온라인마케팅'];
  let processed = 0;
  for (const cat of cats) {
    const { data: kws } = await supabase.from('mk_keywords').select('키워드,카테고리,검색량,경쟁도')
      .eq('카테고리', cat).eq('활성', true).order('검색량', { ascending: false }).limit(17);
    if (!kws) continue;
    for (const k of kws) {
      await supabase.from('mk_keyword_monthly').upsert({
        측정_월: currentMonth, 키워드: k.키워드, 카테고리: k.카테고리,
        검색량: k.검색량, 경쟁도: k.경쟁도
      }, { onConflict: '측정_월,키워드' });
      processed++;
    }
  }
  // 텔레그램 알림
  const tg = await getSecret('realplan_telegram_token');
  const ci = await getSecret('realplan_telegram_chat_id');
  if (tg && ci) {
    await fetch(`https://api.telegram.org/bot${tg}/sendMessage`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: ci, text: `📈 <b>월간 키워드 갱신 (월 09:30)</b>\n\n${currentMonth} / ${processed}건`, parse_mode: 'HTML' })
    });
  }
  return new Response(JSON.stringify({ ok: true, currentMonth, processed }), { headers: { 'Content-Type': 'application/json' } });
});
