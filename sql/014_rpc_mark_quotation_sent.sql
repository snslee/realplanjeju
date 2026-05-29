-- ============================================================
-- 014_rpc_mark_quotation_sent.sql
-- Phase 2a 단계 4 — Make S-12 시나리오용 RPC
-- 작성일: 2026-04-26
-- 작성자: Claude (대표님 승인 / 6대 결정사항 전부 승인)
-- ============================================================
--
-- 목적:
--   Make Webhook이 Naver SMTP로 견적 메일 발송 성공 시 호출.
--   ① quotations.상태 = '발송완료' + 발송일시 = now() 자동 기록
--   ② customers.고객상태 = '견적발송' 자동 전이
--      (단, 이미 진행/완료/이탈/취소 단계는 변경 안 함 - 역행 방지)
--   ③ 발송 실패 시는 별도 RPC (rpc_mark_quotation_failed) 호출
--
-- 호출 주체:
--   Make 시나리오 (service_role JWT 사용 — Connection 등록)
--
-- 보안:
--   SECURITY DEFINER로 RLS 우회
--   GRANT EXECUTE TO service_role 만 (anon·authenticated 차단)
-- ============================================================

-- ① rpc_mark_quotation_sent (성공 시)
DROP FUNCTION IF EXISTS rpc_mark_quotation_sent(uuid, jsonb, timestamptz);

CREATE OR REPLACE FUNCTION rpc_mark_quotation_sent(
  _quotation_id UUID,
  _recipients JSONB DEFAULT NULL,  -- 수신자 메타 (감사용)
  _sent_at TIMESTAMPTZ DEFAULT now()
)
RETURNS TABLE(
  quotation_id UUID,
  견적번호 TEXT,
  상태 TEXT,
  발송일시 TIMESTAMPTZ,
  customer_id UUID,
  고객상태_이전 TEXT,
  고객상태_이후 TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_customer_id UUID;
  v_old_status TEXT;
  v_new_status TEXT;
  v_qno TEXT;
BEGIN
  -- 0. 견적 존재·customer_id 조회
  SELECT customer_id, 견적번호 INTO v_customer_id, v_qno
    FROM quotations
    WHERE id = _quotation_id;

  IF v_customer_id IS NULL THEN
    RAISE EXCEPTION 'Quotation not found: %', _quotation_id
      USING ERRCODE = 'P0002';
  END IF;

  -- 1. 견적 상태 = '발송완료' + 발송일시 기록
  UPDATE quotations
    SET 상태 = '발송완료',
        발송일시 = _sent_at,
        발송_실패_사유 = NULL,  -- 이전 실패 기록이 있다면 클리어
        updated_at = now()
    WHERE id = _quotation_id;

  -- 2. 고객상태 자동 전이 ('견적발송')
  --    단, 이미 후속 단계(계약대기·계약완료·진행중·종료·이탈·취소)면 역행 방지
  SELECT 고객상태 INTO v_old_status
    FROM customers WHERE id = v_customer_id;

  IF v_old_status NOT IN ('계약대기','계약완료','진행중','종료','이탈','취소') THEN
    UPDATE customers
      SET 고객상태 = '견적발송',
          마지막접촉일시 = _sent_at,
          updated_at = now()
      WHERE id = v_customer_id;
    v_new_status := '견적발송';
  ELSE
    v_new_status := v_old_status;  -- 변경 없음
  END IF;

  -- 3. 결과 반환
  RETURN QUERY SELECT
    _quotation_id,
    v_qno,
    '발송완료'::TEXT,
    _sent_at,
    v_customer_id,
    v_old_status,
    v_new_status;
END $$;

COMMENT ON FUNCTION rpc_mark_quotation_sent(uuid, jsonb, timestamptz) IS
  'Phase 2a S-12: Make Webhook 호출용. 견적 발송 성공 시 quotations.상태 + customers.고객상태 자동 전이. service_role 전용.';

-- ============================================================
-- ② rpc_mark_quotation_failed (실패 시)
-- ============================================================
DROP FUNCTION IF EXISTS rpc_mark_quotation_failed(uuid, text);

CREATE OR REPLACE FUNCTION rpc_mark_quotation_failed(
  _quotation_id UUID,
  _error_reason TEXT
)
RETURNS TABLE(
  quotation_id UUID,
  견적번호 TEXT,
  상태 TEXT,
  발송_실패_사유 TEXT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_qno TEXT;
BEGIN
  IF _error_reason IS NULL OR length(trim(_error_reason)) = 0 THEN
    RAISE EXCEPTION 'Error reason is required';
  END IF;

  SELECT 견적번호 INTO v_qno
    FROM quotations WHERE id = _quotation_id;

  IF v_qno IS NULL THEN
    RAISE EXCEPTION 'Quotation not found: %', _quotation_id
      USING ERRCODE = 'P0002';
  END IF;

  -- 상태는 변경 안 함 (작성중·재발송 등 그대로 유지) / 사유만 기록
  UPDATE quotations
    SET 발송_실패_사유 = _error_reason,
        updated_at = now()
    WHERE id = _quotation_id;

  RETURN QUERY SELECT
    _quotation_id,
    v_qno,
    (SELECT q.상태 FROM quotations q WHERE q.id = _quotation_id),
    _error_reason;
END $$;

COMMENT ON FUNCTION rpc_mark_quotation_failed(uuid, text) IS
  'Phase 2a S-12: Make Webhook 호출용. 견적 발송 실패 시 발송_실패_사유만 기록. service_role 전용.';

-- ============================================================
-- ③ GRANT (service_role 전용 / anon·authenticated 차단)
-- ============================================================
REVOKE ALL ON FUNCTION rpc_mark_quotation_sent(uuid, jsonb, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION rpc_mark_quotation_failed(uuid, text) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION rpc_mark_quotation_sent(uuid, jsonb, timestamptz) TO service_role;
GRANT EXECUTE ON FUNCTION rpc_mark_quotation_failed(uuid, text) TO service_role;

-- ============================================================
-- ④ 검증 쿼리 (적용 직후 실행)
-- ============================================================

-- V1) 함수 존재 확인 (2건 반환되어야 함)
SELECT proname, prosecdef AS security_definer, pronargs AS arg_count
  FROM pg_proc
  WHERE proname IN ('rpc_mark_quotation_sent','rpc_mark_quotation_failed');

-- V2) GRANT 검증 (service_role만 허용)
SELECT routine_name, grantee, privilege_type
  FROM information_schema.routine_privileges
  WHERE routine_name IN ('rpc_mark_quotation_sent','rpc_mark_quotation_failed')
  ORDER BY routine_name, grantee;

-- V3) anon·authenticated 차단 확인 (위 V2 결과에 anon/authenticated 행 없어야 함)

-- V4) 함수 시그니처 확인
SELECT
  p.proname,
  pg_get_function_identity_arguments(p.oid) AS args,
  pg_get_function_result(p.oid) AS returns
FROM pg_proc p
WHERE p.proname IN ('rpc_mark_quotation_sent','rpc_mark_quotation_failed');

-- ============================================================
-- 성공 시 결과 (참고)
-- ============================================================
-- V1 결과:
--   rpc_mark_quotation_failed | true | 2
--   rpc_mark_quotation_sent   | true | 3
--
-- V2 결과 (service_role 행만 있어야 함):
--   rpc_mark_quotation_failed | service_role | EXECUTE
--   rpc_mark_quotation_sent   | service_role | EXECUTE
--
-- V4 결과:
--   rpc_mark_quotation_failed | _quotation_id uuid, _error_reason text | TABLE(quotation_id uuid, 견적번호 text, 상태 text, 발송_실패_사유 text)
--   rpc_mark_quotation_sent   | _quotation_id uuid, _recipients jsonb DEFAULT NULL::jsonb, _sent_at timestamp with time zone DEFAULT now() | TABLE(quotation_id uuid, 견적번호 text, 상태 text, 발송일시 timestamp with time zone, customer_id uuid, 고객상태_이전 text, 고객상태_이후 text)
-- ============================================================
