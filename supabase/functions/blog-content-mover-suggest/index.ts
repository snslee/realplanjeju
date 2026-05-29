// blog-content-mover-suggest v1.0 — 51-2차 Phase A (Step 9 흡수 → 알림 모드)
// 매일 22:15 KST / 1~10위 진입 글 docx 경로 + 추천 이동 위치 알림

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
  const { data: candidates } = await supabase.from('mk_blog_publish_log')
    .select('id,발행일,채널,외부_url,rss_제목,진입판정,docx_경로')
    .in('진입판정', ['★2705上5위', '⚠️6~10위', '✅시1~5위'])
    .eq('이동알림_발송됨', false);

  if (!candidates || candidates.length === 0) {
    return new Response(JSON.stringify({ ok: true, count: 0 }));
  }

  const tg = await getSecret('realplan_telegram_token');
  const ci = await getSecret('realplan_telegram_chat_id');

  let msg = `📦 <b>상위노출 진입 - docx 이동 안내 (22:15 KST)</b>\n\n`;
  for (const c of candidates) {
    const yyyymm = (c.발행일 || '').slice(0, 7);
    const recommendedDst = `D:\\자동화\\온라인마케팅 부서\\블로그\\상위노출\\${yyyymm}\\`;
    msg += `• [${c.진입판정}] ${c.채널}\n  제목: ${(c.rss_제목 || '').slice(0, 40)}\n  URL: ${c.외부_url}\n  원본 docx: ${c.docx_경로 || '확인 필요'}\n  이동 위치: ${recommendedDst}\n\n`;
    await supabase.from('mk_blog_publish_log').update({ 이동알림_발송됨: true }).eq('id', c.id);
  }
  msg += `⚠️ 이동은 OS 수작업 또는 Windows 작업 스케줄러로 처리 (admin/blog.html 승률 탭에서 확인)`;

  if (tg && ci) {
    await fetch(`https://api.telegram.org/bot${tg}/sendMessage`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: ci, text: msg, parse_mode: 'HTML' })
    });
  }

  return new Response(JSON.stringify({ ok: true, count: candidates.length }), {
    headers: { 'Content-Type': 'application/json' }
  });
});
