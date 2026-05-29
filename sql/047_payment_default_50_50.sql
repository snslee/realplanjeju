-- ============================================================================
-- sql/047 — rpc_update_quotation_status v4 (결제 디폴트 50/50 + 견적-계약 연동)
-- ============================================================================
-- 작성일: 2026-05-06 (v1.3 정합)
-- 목적:
--   sql/040 v3의 결제 디폴트 30/70 → **50/50** 정정 (사용자 결정 A안)
--   견적서 결제조건에 "계약금 50% + 잔금 50%" (기본) 또는 "계약금 30% + 잔금 70%" 명시 시 그대로 전파
-- 정합:
--   v1.3 §3 P1 잔여 패치 / 18원칙 §2 변경사항 승인 후
--   admin.html v2.22 라디오 UI 패치(별 승인 대기)와 짝
-- 회귀:
--   - 시그니처 동일 (admin.html 호출부 변경 X)
--   - 견적서에 결제조건이 명시된 케이스는 그대로 (정규식 추출 우선)
--   - 결제조건 미입력 케이스만 디폴트 변경 (30 → 50)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_update_quotation_status(
  _quotation_id uuid, _new_status text, _reason text DEFAULT NULL::text
)
RETURNS TABLE(
  r_quotation_id uuid, "r_견적번호" text, "r_상태_이전" text, "r_상태_이후" text,
  "r_발송_실패_사유" text, r_updated_at timestamp with time zone
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_old_status TEXT;
  v_qno TEXT;
  v_reason_field TEXT;
  v_contract_no TEXT;
  v_contract_exists BOOLEAN;
  v_deposit_rate NUMERIC;
  v_balance_rate NUMERIC;
  v_payment_terms TEXT;
BEGIN
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  IF _new_status NOT IN ('수락','거절','만료','무효화') THEN
    RAISE EXCEPTION 'invalid status: % (allowed: 수락/거절/만료/무효화)', _new_status;
  END IF;

  SELECT q.상태::TEXT, q.견적번호::TEXT INTO v_old_status, v_qno
    FROM public.quotations q WHERE q.id = _quotation_id;

  IF v_qno IS NULL THEN
    RAISE EXCEPTION 'Quotation not found: %', _quotation_id USING ERRCODE = 'P0002';
  END IF;

  v_reason_field := NULL;
  IF _new_status = '거절' AND _reason IS NOT NULL AND length(trim(_reason)) > 0 THEN
    v_reason_field := '[거절] ' || _reason;
  ELSIF _new_status = '무효화' AND _reason IS NOT NULL AND length(trim(_reason)) > 0 THEN
    v_reason_field := '[무효화] ' || _reason;
  END IF;

  UPDATE public.quotations
    SET 상태 = _new_status,
        발송_실패_사유 = COALESCE(v_reason_field, public.quotations.발송_실패_사유),
        updated_at = now()
    WHERE id = _quotation_id;

  IF _new_status = '수락' THEN
    v_contract_no := 'C-' || SUBSTRING(v_qno FROM 3);

    SELECT EXISTS (SELECT 1 FROM public.contracts WHERE 계약번호 = v_contract_no)
      INTO v_contract_exists;

    IF NOT v_contract_exists THEN
      -- 견적서 결제조건 파싱 → 계약금/잔금 비율 추출
      SELECT q.결제조건 INTO v_payment_terms
        FROM public.quotations q WHERE q.id = _quotation_id;

      -- ⭐ sql/047 핵심 변경: 디폴트 30 → 50
      v_deposit_rate := COALESCE(
        NULLIF(substring(COALESCE(v_payment_terms, '') from '계약금[^0-9]*([0-9]+)'), '')::numeric,
        50  -- A안: 50/50 디폴트 (sql/040 v3의 30 → 50 정정)
      );
      v_balance_rate := COALESCE(
        NULLIF(substring(COALESCE(v_payment_terms, '') from '잔금[^0-9]*([0-9]+)'), '')::numeric,
        100 - v_deposit_rate
      );

      -- 50/50 또는 30/70 둘 중 하나 강제 (그 외 비율은 견적서에 명시된 경우만 인정)
      -- (검증: 비율 합 100% / 견적-계약 연동 정합)
      IF (v_deposit_rate + v_balance_rate) <> 100 THEN
        RAISE WARNING 'sql/047: 계약금(%) + 잔금(%) <> 100. 견적번호=% / 50/50 강제',
          v_deposit_rate, v_balance_rate, v_qno;
        v_deposit_rate := 50;
        v_balance_rate := 50;
      END IF;

      INSERT INTO public.contracts (
        customer_id, quotation_id, 계약번호, 계약금액, 계약명,
        계약기간_시작, 계약기간_종료,
        계약금비율, 잔금비율,
        작성자, 상태, provider,
        서명상태, 서명_상태_세부, 결제_상태,
        발송_횟수
      )
      SELECT
        q.customer_id, q.id, v_contract_no, COALESCE(q.견적금액, 0),
        COALESCE(q.제목, ''),
        c.시작일, c.종료일,
        v_deposit_rate, v_balance_rate,
        COALESCE(auth.email(), 'system'),
        '작성중', 'self',
        '미서명', 'pending', 'pending',
        0
      FROM public.quotations q
      JOIN public.customers c ON c.id = q.customer_id
      WHERE q.id = _quotation_id;
    END IF;
  END IF;

  RETURN QUERY
    SELECT q.id, q.견적번호::TEXT, v_old_status, q.상태::TEXT, q.발송_실패_사유::TEXT, q.updated_at
      FROM public.quotations q WHERE q.id = _quotation_id;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_update_quotation_status(uuid, text, text) TO authenticated, service_role, anon;

COMMENT ON FUNCTION public.rpc_update_quotation_status(uuid, text, text) IS
  'sql/047 — 결제 디폴트 50/50 (A안) + 견적-계약 연동 / 견적서 명시 시 그대로 / 미입력 시 50/50';

-- ============================================================================
-- 검증 쿼리 (라이브 적용 후)
-- ============================================================================
-- (1) 결제조건 명시 케이스 (50/50)
-- INSERT INTO quotations(...결제조건...) VALUES (..., '계약금 50% + 잔금 50%');
-- → 수락 시 contracts INSERT (50/50 정확)
--
-- (2) 결제조건 명시 케이스 (30/70)
-- INSERT INTO quotations(...결제조건...) VALUES (..., '계약금 30% + 잔금 70%');
-- → 수락 시 contracts INSERT (30/70 정확)
--
-- (3) 결제조건 미입력 케이스
-- INSERT INTO quotations(...결제조건...) VALUES (..., NULL);
-- → 수락 시 contracts INSERT (50/50 디폴트)
--
-- (4) 비정상 비율 케이스 (60/30 같은 합 90)
-- → WARNING + 50/50 강제
-- ============================================================================
