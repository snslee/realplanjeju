-- sql/058d — realplan_audit_count guard 완화 (49-1차 hotfix / 2026-05-21)
-- F_AUDIT_SELF_HEALTH·F_EF_VERSION_OLD SQL guard 통과 회복

CREATE OR REPLACE FUNCTION public.realplan_audit_count(p_sql TEXT)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count BIGINT;
  v_normalized TEXT;
BEGIN
  v_normalized := lower(trim(p_sql));
  IF NOT (v_normalized LIKE 'select %') THEN
    RAISE EXCEPTION 'realplan_audit_count: SELECT 쿼리만 허용 (입력: %)', p_sql;
  END IF;
  IF v_normalized ~ '\m(insert|update|delete|drop|alter|create|truncate|grant|revoke)\M' THEN
    RAISE EXCEPTION 'realplan_audit_count: 변경 키워드 차단 (입력: %)', p_sql;
  END IF;

  EXECUTE p_sql INTO v_count;
  RETURN COALESCE(v_count, 0);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'realplan_audit_count error: % / sql=%', SQLERRM, p_sql;
  RETURN -1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.realplan_audit_count(TEXT) TO service_role;

-- F_DEAD_RPC 단순화 (pg_stat_statements 없이도 작동)
UPDATE public.hr_audit_rule SET
  임계치 = jsonb_build_object('sql','SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid WHERE n.nspname=''public'' AND p.proname LIKE ''rpc_%''','threshold',999999),
  설명 = 'RPC 함수 인벤토리 (모니터링용 / 임계치 999999 = 발견만 / advisor 통합 후 활성화)'
WHERE 룰_코드='F_DEAD_RPC';

NOTIFY pgrst, 'reload schema';
