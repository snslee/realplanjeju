-- ============================================================================
-- 031_contracts_payment.sql
-- 작성일: 2026-05-01 (Phase E / 포트원 + 토스페이먼츠 / 영세 0.5%)
-- 목적: contracts 테이블에 결제 관련 컬럼 추가
--   결제_상태: pending/paid/cancelled/failed/refunded
--   결제_방식: card/virtual_account/transfer/unpaid
--   결제_PG: tosspayments/inicis/kakaopay/naverpay/none
--   결제_링크_url: 포트원 결제 링크 (카카오 알림톡 발송)
--   결제_거래id: 포트원 imp_uid (Webhook 매칭)
-- 의존: sql/001 (contracts) / sql/030 (provider 컬럼)
-- 정합: 통합 설계서 v1.1 §5 (포트원 + 토스페이먼츠 / 영세 0.5%)
-- 라이브 적용: Supabase migration 20260501080304 (2026-05-01)
-- D드라이브 복원: 2026-05-03 (30차 회기 / Supabase에서 추출)
-- ============================================================================

ALTER TABLE public.contracts
  ADD COLUMN IF NOT EXISTS 결제_상태          varchar(20) NOT NULL DEFAULT 'pending'
    CHECK (결제_상태 IN ('pending','paid','cancelled','failed','refunded','partial')),
  ADD COLUMN IF NOT EXISTS 결제_방식          varchar(20)
    CHECK (결제_방식 IS NULL OR 결제_방식 IN ('card','virtual_account','transfer','kakaopay','naverpay','unpaid')),
  ADD COLUMN IF NOT EXISTS 결제_PG            varchar(20)
    CHECK (결제_PG IS NULL OR 결제_PG IN ('tosspayments','inicis','nicepayments','kakaopay','naverpay','portone','none')),
  ADD COLUMN IF NOT EXISTS 결제_링크_url      text,
  ADD COLUMN IF NOT EXISTS 결제_거래id        varchar(100),
  ADD COLUMN IF NOT EXISTS merchant_uid       varchar(100),
  ADD COLUMN IF NOT EXISTS 결제일             timestamptz,
  ADD COLUMN IF NOT EXISTS 결제_금액          bigint,
  ADD COLUMN IF NOT EXISTS 영세_수수료율      numeric(5,2),
  ADD COLUMN IF NOT EXISTS 결제_웹훅_payload  jsonb,
  ADD COLUMN IF NOT EXISTS 정산_상태          varchar(20) DEFAULT 'pending'
    CHECK (정산_상태 IN ('pending','settled','holding','dispute'));

COMMENT ON COLUMN public.contracts.결제_상태       IS 'pending → paid → (refunded/cancelled)';
COMMENT ON COLUMN public.contracts.결제_방식       IS 'card·virtual_account·transfer·kakaopay·naverpay';
COMMENT ON COLUMN public.contracts.결제_PG         IS 'tosspayments·inicis·nicepayments·portone(통합)';
COMMENT ON COLUMN public.contracts.결제_링크_url   IS '포트원 결제 링크 (카카오 알림톡·이메일 발송)';
COMMENT ON COLUMN public.contracts.결제_거래id     IS '포트원 imp_uid (Webhook 매칭)';
COMMENT ON COLUMN public.contracts.merchant_uid    IS '주문번호 (자체 발급 / 보통 contracts.계약번호 = merchant_uid)';
COMMENT ON COLUMN public.contracts.영세_수수료율   IS '영세 0.5 / 중소1 1.0 / 일반 3.4 / 6개월 단위 갱신';
COMMENT ON COLUMN public.contracts.정산_상태       IS 'pending=PG 정산 대기 / settled=정산 완료';

CREATE INDEX IF NOT EXISTS idx_contracts_결제_상태 ON public.contracts(결제_상태);
CREATE INDEX IF NOT EXISTS idx_contracts_결제_거래id ON public.contracts(결제_거래id) WHERE 결제_거래id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_contracts_merchant_uid ON public.contracts(merchant_uid) WHERE merchant_uid IS NOT NULL;
