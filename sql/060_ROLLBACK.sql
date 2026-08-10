-- ============================================================================
-- sql/060_ROLLBACK — 2026-08-10 번들 되돌리기 (함수 3종 변경 전 원문)
-- ============================================================================
-- 사용법: 이 파일 전체를 그대로 실행하면 2026-08-10 이전 상태로 복귀한다.
-- 데이터 백업본: quotations_bak_20260810 / contracts_bak_20260810 / quotation_items_bak_20260810
-- 데이터 복구가 필요하면 (이번 번들은 데이터 변경 0건이라 원칙적으로 불필요):
--   BEGIN;
--   DELETE FROM public.quotations;      INSERT INTO public.quotations      SELECT * FROM public.quotations_bak_20260810;
--   DELETE FROM public.contracts;       INSERT INTO public.contracts       SELECT * FROM public.contracts_bak_20260810;
--   DELETE FROM public.quotation_items; INSERT INTO public.quotation_items SELECT * FROM public.quotation_items_bak_20260810;
--   COMMIT;
-- 화면 롤백: git revert (admin.html 직전 정본 커밋 = 0f106ed)
-- ============================================================================

-- 1) rpc_next_quotation_no (변경 전)
CREATE OR REPLACE FUNCTION public.rpc_next_quotation_no("_사업부" text)
 RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_prefix text; v_year text; v_max int; v_next int;
BEGIN
  v_prefix := CASE _사업부
    WHEN '국내여행' THEN 'TOUR' WHEN '행사이벤트' THEN 'EVENT'
    WHEN '온라인마케팅' THEN 'MKT' WHEN '마케팅교육' THEN 'EDU'
    ELSE 'GEN' END;
  v_year := to_char(now(), 'YYYY');
  SELECT COALESCE(MAX((regexp_replace("견적번호", '^.*-(\d+)$', '\1'))::int), 0)
    INTO v_max FROM public.quotations
   WHERE "견적번호" LIKE 'Q-' || v_prefix || '-' || v_year || '-%';
  v_next := v_max + 1;
  RETURN 'Q-' || v_prefix || '-' || v_year || '-' || lpad(v_next::text, 3, '0');
END;
$function$;

-- 2) rpc_create_quotation (변경 전 = sql/045 판)
--    ※부모 분기가 부모 번호를 그대로 INSERT 하므로 재견적은 다시 100% 실패한다.
--      되돌릴 때는 이 점을 알고 되돌릴 것.
-- 3) rpc_update_quotation_status (변경 전)
--    ※수락 시 계약이 이미 있으면 조용히 건너뛴다(금액 미반영).
--
-- 위 2·3의 전문(全文)은 아래 경로에 원문 그대로 보관:
--   sql/045_rpc_create_quotation_retry.sql        (rpc_create_quotation 변경 전)
--   sql/012_phase2a_quotations_extend.sql         (구 설계 참조)
--   Supabase 마이그레이션 sql_033/040             (rpc_update_quotation_status 변경 전)
-- 되돌릴 때는 해당 파일을 그대로 실행한다.

NOTIFY pgrst, 'reload schema';
