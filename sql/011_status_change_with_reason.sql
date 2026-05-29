-- ============================================================================
-- 011_status_change_with_reason.sql
-- 작성일: 2026-04-25 (Day 4-5)
-- 목적: 고객상태 변경 RPC + 변경사유 강제 (취소·이탈) + 트리거 보강
-- 정책 (Day 4-5 사전 점검):
--   1) 11단계 정본화 (현재 가동 그대로)
--   2) 취소·이탈 변경 시 변경사유 필수
--   3) 변경사유는 set_config('app.status_reason')로 트리거에 전달
--   4) admin 외 customers.고객상태 직접 UPDATE 금지 (RPC 강제)
--   5) SECURITY DEFINER + #variable_conflict use_column
-- 적용: Supabase SQL Editor → 전체 복사 → Run
-- ============================================================================

-- ============================================================================
-- Section 1. log_status_change 트리거 함수 보강
-- ============================================================================
-- - 변경사유 set_config 읽음
-- - 취소·이탈 시 변경사유 필수 검증
-- - status_history INSERT
-- ============================================================================

CREATE OR REPLACE FUNCTION public.log_status_change()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  _reason text;
  _email text;
BEGIN
  IF OLD.고객상태 IS DISTINCT FROM NEW.고객상태 THEN
    -- RPC가 set_config('app.status_reason', ...)로 전달
    _reason := nullif(current_setting('app.status_reason', true), '');
    _email  := coalesce(nullif(auth.jwt()->>'email', ''), 'system');

    -- 취소·이탈 시 변경사유 필수
    IF NEW.고객상태 IN ('취소', '이탈')
       AND (_reason IS NULL OR _reason = '') THEN
      RAISE EXCEPTION '취소·이탈 변경 시 변경사유 필수 (rpc_update_customer_status 경유 필요)';
    END IF;

    INSERT INTO public.status_history
      (customer_id, 이전상태, 다음상태, 변경자, 변경사유, created_at)
    VALUES
      (NEW.id, OLD.고객상태, NEW.고객상태, _email, _reason, now());
  END IF;
  RETURN NEW;
END;
$$;


-- ============================================================================
-- Section 2. rpc_update_customer_status — 상태 변경 전용 RPC
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_update_customer_status(
  _customer_id uuid,
  _new_status  varchar,
  _reason      text DEFAULT NULL
)
RETURNS SETOF public.customers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  _allowed varchar[] := ARRAY[
    '신규문의','접수','확인','상담중','견적발송',
    '계약대기','계약완료','진행중','종료','이탈','취소'
  ];
  _email text;
  _current_status varchar;
BEGIN
  -- admin 검증
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  _email := lower(auth.jwt()->>'email');
  IF _email IS NULL OR _email = '' THEN
    RAISE EXCEPTION 'email not found in jwt';
  END IF;

  -- 입력 검증
  IF _customer_id IS NULL THEN
    RAISE EXCEPTION 'customer_id is required';
  END IF;

  IF _new_status IS NULL OR _new_status = '' THEN
    RAISE EXCEPTION 'new_status is required';
  END IF;

  IF NOT (_new_status = ANY(_allowed)) THEN
    RAISE EXCEPTION 'invalid status: % (allowed: 신규문의·접수·확인·상담중·견적발송·계약대기·계약완료·진행중·종료·이탈·취소)', _new_status;
  END IF;

  -- 취소·이탈 시 변경사유 필수
  IF _new_status IN ('취소', '이탈')
     AND (_reason IS NULL OR trim(_reason) = '') THEN
    RAISE EXCEPTION '취소·이탈 상태 변경 시 변경사유 필수';
  END IF;

  -- 현재 상태 확인 (변경 없으면 skip)
  SELECT 고객상태 INTO _current_status
    FROM public.customers
    WHERE id = _customer_id AND deleted_at IS NULL
    FOR UPDATE;

  IF _current_status IS NULL THEN
    RAISE EXCEPTION 'customer not found or deleted';
  END IF;

  IF _current_status = _new_status THEN
    -- 변경 없음 — 그대로 반환
    RETURN QUERY SELECT * FROM public.customers WHERE id = _customer_id;
    RETURN;
  END IF;

  -- 변경사유를 트리거에 전달 (transaction-local)
  PERFORM set_config(
    'app.status_reason',
    coalesce(trim(_reason), ''),
    true  -- transaction-local
  );

  -- UPDATE → trg_status_log 자동 발동 → status_history INSERT
  UPDATE public.customers
    SET 고객상태 = _new_status,
        마지막접촉일시 = now(),
        updated_at = now()
    WHERE id = _customer_id;

  -- context 클리어
  PERFORM set_config('app.status_reason', '', true);

  RETURN QUERY SELECT * FROM public.customers WHERE id = _customer_id;
END;
$$;

GRANT EXECUTE ON FUNCTION
  public.rpc_update_customer_status(uuid, varchar, text)
  TO anon, authenticated;


-- ============================================================================
-- 검증 쿼리 (적용 후)
-- ============================================================================

-- V1. 함수 등록
-- SELECT p.proname, p.prosecdef, pg_get_function_arguments(p.oid)
-- FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
-- WHERE n.nspname='public'
--   AND p.proname IN ('log_status_change','rpc_update_customer_status')
-- ORDER BY p.proname;

-- V2. GRANT 확인
-- SELECT routine_name, grantee, privilege_type
-- FROM information_schema.routine_privileges
-- WHERE routine_schema='public' AND routine_name='rpc_update_customer_status';

-- V3. 변경사유 강제 (DB 레벨에서 동작 — JWT 없으면 admin 검증에서 막힘)
-- SELECT * FROM public.rpc_update_customer_status(
--   (SELECT id FROM customers WHERE 접수번호='TOUR-2026-001'),
--   '상담중',
--   '상담 시작'
-- );

-- ============================================================================
-- 끝.
-- ============================================================================
