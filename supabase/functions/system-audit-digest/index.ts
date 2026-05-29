// system-audit-digest v3 — 중복 알림 제거 (룰_코드 기준 dedup)
// 58차 버그픽스: hourly 중복 INSERT로 인한 경고 3~5회 반복 발송 수정
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const kstNow = () => new Date().toLocaleString("ko-KR", { timeZone: "Asia/Seoul" });

// 룰_코드 기준 중복 제거 (최신 1건만 유지)
const dedup = (arr: any[]) => {
  const seen = new Set<string>();
  return arr.filter(l => {
    if (seen.has(l.룰_코드)) return false;
    seen.add(l.룰_코드);
    return true;
  });
};

Deno.serve(async (_req: Request) => {
  const supa = createClient(SUPABASE_URL, SERVICE_ROLE);
  try {
    const { data: lmData } = await supa.rpc("realplan_audit_learning_mode");
    const isLearning = Boolean(lmData);

    const { data: logs, error: logErr } = await supa.from("hr_audit_log")
      .select("감사축, 룰_코드, 심각도, 상태, 메시지, 발생시각")
      .gte("발생시각", new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())
      .order("발생시각", { ascending: false });
    if (logErr) throw new Error(`로그 조회 실패: ${logErr.message}`);

    const all = (logs ?? []) as any[];

    // 중복 제거: 동일 룰_코드 중 최신 1건만 사용
    const all_dd = dedup(all);
    const 경고 = all_dd.filter(l => l.상태 === "경고" && l.심각도 !== "SUGGEST");
    const 오류 = all_dd.filter(l => l.상태 === "오류");
    const 개선 = all_dd.filter(l => l.심각도 === "SUGGEST");

    const 요약_축 = (축명: string, 축: string) => {
      const items = all_dd.filter(l => l.감사축 === 축 && l.심각도 !== "SUGGEST");
      const w = items.filter(i => i.상태 === "경고").length;
      const e = items.filter(i => i.상태 === "오류").length;
      const n = items.filter(i => i.상태 === "정상").length;
      const ico = e > 0 ? "🔴" : w > 0 ? "⚠️" : "✅";
      return `${ico} <b>${축명}</b>: 정상 ${n} / 경고 ${w} / 오류 ${e}`;
    };

    const lines = [
      `<b>📦 리얼플랜제주 감사 일일 다이제스트</b>`,
      `${kstNow()} 기준 / 최근 24시간\n`,
      요약_축("A EF 헬스", "A_EF헬스"),
      요약_축("B DB 무결성", "B_DB무결성"),
      요약_축("C 3축 동기", "C_3축동기"),
      요약_축("D 결재흐름", "D_결재흐름"),
      요약_축("E 보안 시크릿", "E_보안시크릿"),
    ];

    if (오류.length > 0 || 경고.length > 0) {
      lines.push("\n<b>⚠️ 주요 경고·오류</b>");
      [...오류, ...경고].slice(0, 10).forEach((l, i) => lines.push(`${i + 1}. [${l.감사축}] ${l.메시지}`));
    } else {
      lines.push("\n<b>✅ 24시간 이상 없음 — 시스템 정상</b>");
    }

    if (개선.length > 0) {
      lines.push("\n<b>💡 시스템 개선 제안 (F축)</b>");
      개선.slice(0, 5).forEach((l, i) => lines.push(`${i + 1}. ${l.메시지}`));
      lines.push(`<i>(전체 ${개선.length}건 / audit.html 에서 풀 확인)</i>`);
    }

    if (isLearning) lines.push(`\n<i>(학습모드 운영중)</i>`);
    const 메시지 = lines.join("\n");

    let 알림됨 = false;
    let 채널_결과: any = { skipped: true };
    if (!isLearning) {
      try {
        const tg = await fetch(`${SUPABASE_URL}/functions/v1/telegram-notifier`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "Authorization": `Bearer ${SERVICE_ROLE}` },
          body: JSON.stringify({ 메시지, 심각도: 오류.length > 0 ? "P2" : "P3", 제목: `일일 다이제스트 / 경고 ${경고.length} · 오류 ${오류.length} · 개선 ${개선.length}` })
        });
        채널_결과 = await tg.json();
        알림됨 = 채널_결과.ok ?? false;
      } catch (e: any) { 채널_결과 = { ok: false, error: e.message }; }
    }

    return new Response(JSON.stringify({
      ok: true, 학습모드: isLearning, 메시지,
      분석_요약: { 전체_raw: all.length, 중복제거_후: all_dd.length, 정상: all_dd.filter(l => l.상태 === "정상").length, 경고: 경고.length, 오류: 오류.length, 개선제안: 개선.length },
      알림됨, 채널_결과
    }), { headers: { "Content-Type": "application/json" } });
  } catch (err: any) {
    return new Response(JSON.stringify({ ok: false, error: err.message }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
