// winning-formula-updater v1.0 — D+N 측정 데이터 → mk_blog_winning_formula 자동 갱신 (2026-05-30)
// 실행: 수동 트리거 | 향후 pg_cron 주 1회 월요일 연동 가능
// 로직:
//   1) mk_blog_publish_log에서 d_plus_7_rank IS NOT NULL 레코드 조회
//   2) 매칭_슬롯_id로 mk_blog_slots JOIN → 슬롯유형·시즌 파악
//   3) 채널+슬롯유형 기준 집계 (평균순위, 10위이내율, 샘플수)
//   4) mk_blog_winning_formula UPSERT
//   5) 텔레그램 알림

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const SUPABASE_URL         = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false }
});

async function getSecret(name: string): Promise<string | null> {
  const { data } = await supabase.rpc('realplan_get_secret', { secret_name: name });
  return data as string;
}

async function sendTelegram(msg: string) {
  try {
    const token  = await getSecret('realplan_telegram_token');
    const chatId = await getSecret('realplan_telegram_chat_id');
    if (!token || !chatId) return;
    await fetch(`https://api.telegram.org/bot${token}/sendMessage`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: chatId, text: msg, parse_mode: 'HTML', disable_web_page_preview: true })
    });
  } catch (e) { console.error('tg err', e); }
}

// 시즌 판별 (발행월 기반)
function getSeason(dateStr: string): string {
  const month = new Date(dateStr).getMonth() + 1;
  if (month >= 3 && month <= 5) return '봄';
  if (month >= 6 && month <= 8) return '여름';
  if (month >= 9 && month <= 11) return '가을';
  return '겨울';
}

Deno.serve(async (_req) => {
  // ① D+7 측정 완료된 발행 로그 조회
  const { data: logs, error: logErr } = await supabase
    .from('mk_blog_publish_log')
    .select('채널, 발행일, 매칭_슬롯_id, d_plus_7_rank, d_plus_14_rank, 핵심키워드')
    .not('d_plus_7_rank', 'is', null)
    .not('매칭_슬롯_id', 'is', null)
    .order('발행일', { ascending: false })
    .limit(500);

  if (logErr) {
    await sendTelegram(`❌ <b>승리공식 업데이터 실패</b>\n\n발행로그 조회 오류: ${logErr.message}`);
    return new Response(JSON.stringify({ ok: false, error: logErr.message }), { status: 500 });
  }
  if (!logs || logs.length === 0) {
    return new Response(JSON.stringify({ ok: true, message: 'D+7 측정 완료 데이터 없음', updated: 0 }));
  }

  // ② 슬롯 정보 배치 조회
  const slotIds = [...new Set(logs.map(l => l.매칭_슬롯_id).filter(Boolean))];
  const { data: slots } = await supabase
    .from('mk_blog_slots')
    .select('id, 슬롯유형, 발행일')
    .in('id', slotIds);
  const slotMap = new Map((slots || []).map(s => [s.id, s]));

  // ③ 채널+슬롯유형 기준 집계
  const groups: Record<string, {
    채널: string; 슬롯유형: string; 시즌: string;
    ranks: number[]; sample: number;
  }> = {};

  for (const log of logs) {
    const slot = slotMap.get(log.매칭_슬롯_id);
    const slotType = slot?.슬롯유형 || '정보성';
    const season = getSeason(log.발행일 || new Date().toISOString());
    const key = `${log.채널}|${slotType}`;

    if (!groups[key]) {
      groups[key] = { 채널: log.채널, 슬롯유형: slotType, 시즌: season, ranks: [], sample: 0 };
    }
    if (log.d_plus_7_rank) groups[key].ranks.push(log.d_plus_7_rank);
    groups[key].sample++;
  }

  // ④ mk_blog_winning_formula UPSERT
  let updatedCount = 0;
  const errors: string[] = [];

  for (const [, g] of Object.entries(groups)) {
    if (g.ranks.length === 0) continue;
    const avgRank   = g.ranks.reduce((a, b) => a + b, 0) / g.ranks.length;
    const top10Rate = (g.ranks.filter(r => r <= 10).length / g.ranks.length) * 100;
    const achieved  = g.ranks.filter(r => r <= 10).length;

    const { data: existing } = await supabase
      .from('mk_blog_winning_formula')
      .select('id')
      .eq('채널', g.채널)
      .eq('슬롯유형', g.슬롯유형)
      .eq('시즌', g.시즌)
      .maybeSingle();

    const payload: any = {
      채널: g.채널,
      슬롯유형: g.슬롯유형,
      시즌: g.시즌,
      d7_평균순위: parseFloat(avgRank.toFixed(1)),
      d7_10위이내율: parseFloat(top10Rate.toFixed(1)),
      d7_달성횟수: achieved,
      샘플수: g.sample,
      학습_상태: g.sample >= 5 ? 'stable' : 'learning',
      last_updated: new Date().toISOString().slice(0, 10),
    };

    let err;
    if (existing) {
      ({ error: err } = await supabase.from('mk_blog_winning_formula').update(payload).eq('id', existing.id));
    } else {
      ({ error: err } = await supabase.from('mk_blog_winning_formula').insert(payload));
    }

    if (err) { errors.push(`${g.채널}/${g.슬롯유형}: ${err.message}`); }
    else updatedCount++;
  }

  // ⑤ 텔레그램 알림
  const topGroups = Object.values(groups)
    .sort((a, b) => (b.ranks.filter(r => r <= 10).length / (b.ranks.length || 1)) - (a.ranks.filter(r => r <= 10).length / (a.ranks.length || 1)))
    .slice(0, 3);

  const lines = [
    `🏆 <b>승리공식 DB 갱신 완료</b>`,
    ``,
    `분석 샘플: <b>${logs.length}건</b>`,
    `갱신 그룹: <b>${updatedCount}개</b>`,
    ``,
    `📊 TOP 3 채널/유형:`,
    ...topGroups.map(g => {
      const r = g.ranks;
      const top10 = r.length > 0 ? ((r.filter(x => x <= 10).length / r.length) * 100).toFixed(0) : '0';
      const avg = r.length > 0 ? (r.reduce((a, b) => a + b, 0) / r.length).toFixed(1) : '-';
      return `• ${g.채널} / ${g.슬롯유형} — 평균${avg}위 / 10위이내 ${top10}%`;
    }),
    ``,
    errors.length > 0 ? `⚠️ 오류 ${errors.length}건: ${errors[0]}` : `✅ 오류 없음`,
    `→ <a href="https://realplanjeju.com/admin/marketing.html">마케팅 대시보드</a>`
  ];
  await sendTelegram(lines.join('\n'));

  return new Response(
    JSON.stringify({ ok: true, analyzed: logs.length, updated: updatedCount, errors }),
    { headers: { 'Content-Type': 'a