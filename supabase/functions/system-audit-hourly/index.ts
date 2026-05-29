// system-audit-hourly v2 — 6축 + F축 시스템 개선 제안 추가
// 49-1차 / sql/058+058b+058c+058d 정합 / SUGGEST 심각도 추가
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

interface Rule { id: string; 룰_코드: string; 감사축: string; 룰_이름: string; 점검_방법: string; 임계치: any; 심각도: string; }

async function checkSqlCount(supa: any, rule: Rule) {
  const sql = rule.임계치?.sql;
  if (!sql) return { 상태: "정상", 메시지: "SQL 없음", 세부: {} };
  const { data, error } = await supa.rpc("realplan_audit_count", { p_sql: sql });
  if (error) return { 상태: "오류", 메시지: `RPC 실패: ${error.message}`, 세부: { error: error.message } };
  const count = Number(data ?? 0);
  if (count < 0) return { 상태: "오류", 메시지: "SQL 실행 실패 (-1)", 세부: { count } };
  const threshold = Number(rule.임계치?.threshold ?? 1);
  if (count >= threshold) return { 상태: "경고", 메시지: `${rule.룰_이름}: ${count}건 감지 (임계치 ${threshold})`, 세부: { count, threshold } };
  return { 상태: "정상", 메시지: `${rule.룰_이름}: 0건 이상 없음`, 세부: { count, threshold } };
}

const skipCheck = (rule: Rule, reason: string) => ({ 상태: "정상", 메시지: `${rule.룰_이름}: ${rule.점검_방법} 연동 준비중`, 세부: { skipped: true, reason } });

Deno.serve(async (_req: Request) => {
  const startTime = Date.now();
  const supa = createClient(SUPABASE_URL, SERVICE_ROLE);
  try {
    const { data: lmData } = await supa.rpc("realplan_audit_learning_mode");
    const isLearning = Boolean(lmData);
    const { data: rules, error: rulesErr } = await supa.from("hr_audit_rule").select("id, 룰_코드, 감사축, 룰_이름, 점검_방법, 임계치, 심각도").eq("활성", true);
    if (rulesErr) throw new Error(`룰 조회 실패: ${rulesErr.message}`);

    const logs: any[] = [];
    for (const r of (rules as Rule[]) ?? []) {
      let result;
      switch (r.점검_방법) {
        case "sql_count": result = await checkSqlCount(supa, r); break;
        case "log_query": result = skipCheck(r, "log API 연동 다음 회기"); break;
        case "file_check": result = skipCheck(r, "GitHub API 연동 다음 회기"); break;
        case "advisor_check": result = skipCheck(r, "Mgmt API 토큰 다음 회기"); break;
        default: result = { 상태: "정상", 메시지: `미지원: ${r.점검_방법}`, 세부: {} };
      }
      let 심각도_적용: string;
      if (result.상태 === "정상") 심각도_적용 = "INFO";
      else if (r.감사축 === "F_시스템개선" && result.상태 === "경고") 심각도_적용 = "SUGGEST";
      else 심각도_적용 = r.심각도;

      logs.push({ 감사축: r.감사축, 룰_코드: r.룰_코드, 심각도: 심각도_적용, 상태: result.상태, 메시지: result.메시지, 세부데이터: result.세부, 학습모드: isLearning });
    }
    if (logs.length > 0) {
      const { error: insErr } = await supa.from("hr_audit_log").insert(logs);
      if (insErr) throw new Error(`로그 INSERT 실패: ${insErr.message}`);
    }
    const p1Errors = logs.filter(l => l.심각도 === "P1" && (l.상태 === "오류" || l.상태 === "경고"));
    let 알림수 = 0;
    if (!isLearning && p1Errors.length > 0) {
      const 메시지 = p1Errors.map(e => `• [${e.감사축}] ${e.메시지}`).join("\n");
      try {
        await fetch(`${SUPABASE_URL}/functions/v1/telegram-notifier`, {
          method: "POST",
          headers: { "Content-Type": "application/json", "Authorization": `Bearer ${SERVICE_ROLE}` },
          body: JSON.stringify({ 메시지, 심각도: "P1", 제목: `P1 긴급 알림 (${p1Errors.length}건)` })
        });
        알림수 = p1Errors.length;
      } catch (e) { /* silent */ }
    }
    return new Response(JSON.stringify({
      ok: true, 학습모드: isLearning, 룰_수: rules?.length ?? 0,
      정상: logs.filter(l => l.상태 === "정상").length,
      경고: logs.filter(l => l.상태 === "경고" && l.심각도 !== "SUGGEST").length,
      오류: logs.filter(l => l.상태 === "오류").length,
      개선제안: logs.filter(l => l.심각도 === "SUGGEST").length,
      알림수, 소요시간ms: Date.now() - startTime
    }), { headers: { "Content-Type": "application/json" } });
  } catch (err: any) {
    return new Response(JSON.stringify({ ok: false, error: err.message }), { status: 500, headers: { "Content-Type": "application/json" } });
  }
});
