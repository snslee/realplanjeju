-- sql/033 — 견적 수락 시 contracts 자동 생성 hook (Phase A1 회귀 정정)
-- 32차 후속 / 2026-05-03
-- 28차 메모리에서 "Phase A1 라이브"로 보고됐으나 실제 RPC 본체에 contracts INSERT 누락 발견
-- 본 마이그레이션으로 정정 / 견적 수락 시 contracts 자동 생성 hook 라이브 가동

CREATE OR REPLACE FUNCTION public.rpc_update_quotation_status(
  _quotation_id uuid, _new_status text, _reason text DEFAULT NULL::text
)
RETURNS TABLE(r_quotation_id uuid, "r_견적번호" text, "r_상태_이전" text, "r_상태_이후" text, "r_발송_실패_사유" text, r_updated_at timestamp with time zone)
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
BEGIN
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  IF _new_status NOT IN ('수락','거절','만료','무효화') THEN
    RAISE EXCEPTION 'invalid status: % (allowed: 수락/거절/만료/무효화)', _new_status;
  END IF;

  SELECT q.상태::TEXT, q.견적번호::TEXT INTO v_old_status, v_qno
    FROM public.quotations q
    WHERE q.id = _quotation_id;

  IF v_qno IS NULL THEN
    RAISE EXCEPTION 'Quotation not found: %', _quotation_id
      USING ERRCODE = 'P0002';
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

  -- ✨ 33차 신규: 견적 수락 시 contracts 자동 INSERT (Phase A1 hook)
  IF _new_status = '수락' THEN
    v_contract_no := 'C-' || SUBSTRING(v_qno FROM 3);

    SELECT EXISTS (SELECT 1 FROM public.contracts WHERE 계약번호 = v_contract_no)
      INTO v_contract_exists;

    IF NOT v_contract_exists THEN
      INSERT INTO public.contracts (
        customer_id, quotation_id, 계약번호, 계약금액,
        계약기간_시작, 계약기간_종료,
        작성자, 상태, provider,
        서명상태, 서명_상태_세부, 결제_상태,
        발송_횟수
      )
      SELECT
        q.customer_id, q.id, v_contract_no, COALESCE(q.견적금액, 0),
        c.시작일, c.종료일,
        COALESCE(auth.email(), 'system'),
        '작성중', 'self',
        '미서명', 'pending', 'pending',  -- v2: 서명상태 한글 enum 정정
        0
      FROM public.quotations q
      JOIN public.customers c ON c.id = q.customer_id
      WHERE q.id = _quotation_id;
    END IF;
  END IF;

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
$function$;
