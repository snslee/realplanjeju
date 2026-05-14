-- ============================================================
-- sql/049 — 에이전트 일일 다이제스트 RPC + pg_cron (45차 / 2026-05-14)
-- ============================================================
-- 정합: 23_에이전트시스템_v1.0.md §10 + §6 v1.1 + 4축 운영룰
-- ============================================================

-- 1) rpc_agent_daily_digest — KPI + HITL Top 3 통합 JSON
CREATE OR REPLACE FUNCTION public.rpc_agent_daily_digest()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_오늘_채점     INT;
  v_HITL_대기     INT;
  v_월_호출수     INT;
  v_auto_pass비율 NUMERIC;
  v_사고          INT;
  v_HITL_TOP3     JSON;
BEGIN
  -- 오늘 채점
  SELECT COUNT(*) INTO v_오늘_채점
  FROM public.hr_audit_handoff
  WHERE 에이전트id IS NOT NULL AND 실행시각 >= date_trunc('day', now() AT TIME ZONE 'Asia/Seoul');

  -- HITL 대기
  SELECT COUNT(*) INTO v_HITL_대기
  FROM public.hr_audit_handoff
  WHERE hitl상태 = 'pending';

  -- 월 누적 호출
  SELECT COUNT(*) INTO v_월_호출수
  FROM public.hr_audit_handoff
  WHERE 에이전트id IS NOT NULL AND 실행시각 >= date_trunc('month', now());

  -- auto_pass 비율 (오늘)
  SELECT COALESCE(ROUND(100.0 * COUNT(*) FILTER (WHERE hitl상태='auto_pass') / NULLIF(COUNT(*),0), 1), 0)
    INTO v_auto_pass비율
  FROM public.hr_audit_handoff
  WHERE 에이전트id IS NOT NULL AND 실행시각 >= date_trunc('day', now() AT TIME ZONE 'Asia/Seoul');

  -- 사고 (점수 < 3 OR 'blocked')
  SELECT COUNT(*) INTO v_사고
  FROM public.hr_audit_handoff
  WHERE 실행시각 >= date_trunc('day', now() AT TIME ZONE 'Asia/Seoul')
    AND (점수 < 3 OR hitl상태 = 'blocked');

  -- HITL Top 3 (오래된 순)
  SELECT json_agg(row_to_json(t)) INTO v_HITL_TOP3 FROM (
    SELECT id, 대상유형, 대상id, 점수, 사유, 실행시각
    FROM public.hr_audit_handoff
    WHERE hitl상태 = 'pending'
    ORDER BY 실행시각 ASC
    LIMIT 3
  ) t;

  RETURN json_build_object(
    '오늘_채점', v_오늘_채점,
    'HITL_대기', v_HITL_대기,
    'auto_pass_비율', v_auto_pass비율,
    '월_호출수', v_월_호출수,
    '월_예상비용_USD', ROUND(v_월_호출수 * 0.01, 2),
    '사고', v_사고,
    'HITL_TOP3', COALESCE(v_HITL_TOP3, '[]'::json),
    '발송조건_충족', (v_HITL_대기 >= 1 OR v_월_호출수 >= 8000 OR v_사고 >= 1),
    '생성시각', now()
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_agent_daily_digest() TO service_role, authenticated;

-- 2) pg_cron 매일 18:00 KST = 09:00 UTC
-- (이미 pg_cron + pg_net 활성화 / 44차 확인)
SELECT cron.schedule(
  'agent-digest-daily-18',
  '0 9 * * *',
  $cron$
  SELECT net.http_post(
    url := 'https://iodfqlkeiwxyuojwcozv.supabase.co/functions/v1/agent-digest',
    headers := jsonb_build_object('Content-Type','application/json'),
    body := jsonb_build_object('trigger','pg_cron')
  );
  $cron$
);

COMMENT ON FUNCTION public.rpc_agent_daily_digest() IS
  '에이전트 일일 다이제스트 KPI + HITL Top3 / 45차 sql/049 v1.0';

-- 3) PostgREST 캐시 강제 갱신 (44차 학습 / feedback_postgrest_schema_cache)
NOTIFY pgrst, 'reload schema';