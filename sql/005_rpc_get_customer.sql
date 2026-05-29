-- ============================================================================
-- 005_rpc_get_customer.sql
-- 작성일: 2026-04-25 (Day 4-1)
-- 목적: 문의 상세 [개요 탭] 조회용 SECURITY DEFINER RPC 추가
-- 배경:
--   v0.8까지는 rpc_list_customers (SECURITY DEFINER) 만 사용해서 customers
--   테이블에 GRANT가 없어도 작동. Day 4-1에서 sb.from('customers').select()
--   직접 SELECT 시도 → "permission denied for table customers" 에러.
--   PostgreSQL 권한 모델: GRANT 검사 → RLS 평가 순.
--   GRANT 추가는 layered security 위반이므로 RPC 신규 작성으로 해결.
-- 적용 방법: Supabase SQL Editor에 전체 복사 → Run
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_get_customer(_접수번호 text)
RETURNS SETOF public.customers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- 두 분(snslee82, gomsook6805)만 통과
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  RETURN QUERY
    SELECT *
    FROM public.customers
    WHERE 접수번호 = _접수번호
      AND deleted_at IS NULL
    LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_get_customer(text) TO anon, authenticated;

-- 검증 쿼리 (postgres role · SUPER USER로 직접 호출)
-- SELECT 접수번호, 회사명, 사업부, 고객상태 FROM rpc_get_customer('TOUR-2026-001');
-- SELECT 접수번호, 회사명, 사업부, 고객상태 FROM rpc_get_customer('EVENT-2026-001');
-- SELECT 접수번호 FROM rpc_get_customer('NOT-EXIST'); -- 0 rows
