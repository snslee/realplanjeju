-- ============================================================================
-- 015_rpc_update_quotation_status.sql  (v3 — 운영 적용 최종)
-- 작성일: 2026-04-26
-- 작성자: Claude (대표님 승인 — 결정 #38)
-- 목적:
--   견적 상태 변경 (수락 / 거절 / 만료 / 무효화) SECURITY DEFINER RPC
--   v2.5까지의 직접 UPDATE 패턴을 대체 (RLS 우회).
--
-- 수정 이력:
--   v1 (적용·실패): RETURNS TABLE 컬럼명 견적번호·상태 → ambiguous column 에러 (42702)
--   v2 (적용·실패): r_ prefix 적용 → 타입 불일치 에러 (42804, varchar vs text)
--   v3 (적용·PASS): r_ prefix + RETURN QUERY 안에 ::TEXT 명시 cast
--
-- 핵심 학습:
--   1. RETURNS TABLE의 컬럼명은 함수 본문 SELECT에서 ambiguous 충돌 가능
--      → r_ prefix로 회피
--   2. quotations 테이블의 견적번호·상태·발송_실패_사유는 varchar(N)
--      → RETURN QUERY SELECT에서 ::TEXT 명시 cast 필수
--
-- 적용 방법:
--   Supabase Dashboard → SQL Editor → New query → 전체 복사 → Run
--   (DROP FUNCTION 포함 destructive 다이얼로그 → Run this query 클릭)
-- ============================================================================

DROP FUNCTION IF EXISTS public.rpc_update_quotation_status(uuid, text, text);

CREATE OR REPLACE FUNCTION public.rpc_update_quotation_status(
  _quotation_id UUID,
  _new_status TEXT,
  _reason TEXT DEFAULT NULL
)
RETURNS TABLE(
  r_quotation_id UUID,
  r_견적번호 TEXT,
  r_상태_이전 TEXT,
  r_상태_이후 TEXT,
  r_발송_실패_사유 TEXT,
  r_updated_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old_status TEXT;
  v_qno TEXT;
  v_reason_field TEXT;
BEGIN
  -- 1. admin 검증 (snslee82 / gomsook6805)
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  -- 2. 상태 enum 검증
  IF _new_status NOT IN ('수락','거절','만료','무효화') THEN
    RAISE EXCEPTION 'invalid status: % (allowed: 수락 / 거절 / 만료 / 무효화)', _new_status;
  END IF;

  -- 3. 견적 존재 + 현재 상태 조회 (varchar → text cast)
  SELECT q.상태::TEXT, q.견적번호::TEXT INTO v_old_status, v_qno
    FROM public.quotations q
    WHERE q.id = _quotation_id;

  IF v_qno IS NULL THEN
    RAISE EXCEPTION 'Quotation not found: %', _quotation_id
      USING ERRCODE = 'P0002';
  END IF;

  -- 4. 사유 필드 합성 (거절·무효화)
  v_reason_field := NULL;
  IF _new_status = '거절' AND _reason IS NOT NULL AND length(trim(_reason)) > 0 THEN
    v_reason_field := '[거절] ' || _reason;
  ELSIF _new_status = '무효화' AND _reason IS NOT NULL AND length(trim(_reason)) > 0 THEN
    v_reason_field := '[무효화] ' || _reason;
  END IF;

  -- 5. UPDATE
  UPDATE public.quotations
    SET 상태 = _new_status,
        발송_실패_사유 = COALESCE(v_reason_field, public.quotations.발송_실패_사유),
        updated_at = now()
    WHERE id = _quotation_id;

  -- 6. 결과 반환 — varchar 컬럼은 ::TEXT 명시 cast 필수
  RETURN QUERY
    SELECT
      q.id,
      q.견적번호::TEXT,
      v_old_status,
      q.상태::TEXT,
      q.발송_실패_사유::TEXT,
      q.updated_at
    FROM public.quotations q
    WHERE q.id = _quotation_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_update_quotation_status(uuid, text, text) TO anon, authenticated;

-- ============================================================================
-- 운영 검증 결과 (2026-04-26):
--   ✅ Q-EVENT-2026-006 (작성중) → 무효화 PASS
--   ✅ "무효화 완료" 토스트 + 카드 자동 새로고침 정상
-- ============================================================================
