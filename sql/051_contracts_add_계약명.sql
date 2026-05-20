-- sql/051: contracts.계약명 컬럼 추가 + 견적서→계약 자동 연계 회복
-- 2026-05-20 / 48차 / v2.25 번들
-- 메모리 학습: 47차 "함수 의존성 충돌 0건" 보고 부정확
-- 근본 원인: rpc_update_quotation_status 함수가 contracts.계약명 INSERT 시도
--           → 컬럼 부재로 견적서 수락 100% 실패
-- 정합 흐름: 견적서.제목 → 계약.계약명 → 공문.계약명 (3단 자동 연계)
--           rpc_update_quotation_status (q.제목 → c.계약명)
--           trg_offdoc_autofill (c.계약명 → o.계약명)

ALTER TABLE public.contracts
  ADD COLUMN IF NOT EXISTS "계약명" varchar(200);

COMMENT ON COLUMN public.contracts."계약명" IS
  '견적서.제목 자동 매핑 / 공문.계약명으로 trg_offdoc_autofill 트리거 자동 복사';

-- 기존 계약 4건 backfill (quotations.제목 → contracts.계약명)
UPDATE public.contracts c
   SET "계약명" = q."제목"
  FROM public.quotations q
 WHERE c.quotation_id = q.id
   AND (c."계약명" IS NULL OR c."계약명" = '');

-- PostgREST 스키마 캐시 갱신 (PGRST204 방지 / 메모리 표준)
NOTIFY pgrst, 'reload schema';
