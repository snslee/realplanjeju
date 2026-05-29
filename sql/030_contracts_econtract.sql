-- ============================================================================
-- 030_contracts_econtract.sql
-- 작성일: 2026-05-01 (Phase D1 / 전자계약 시스템 Adapter 패턴)
-- 목적: contracts 테이블에 전자계약 통합 컬럼 추가
--   provider: 'self' (jsPDF+이메일) / 'modusign' / 'eformsign' (D2 활성화)
--   envelope_id: SaaS Provider의 계약 식별자
--   서명_PDF_URL: 체결본 Storage 경로 (file_attachments 카테고리=계약서_체결본 자동 등록)
--   서명_상태_세부: 8단계 (pending → sent → viewed → signed_갑 → signed_을 → completed)
-- 의존: sql/001 (contracts) / sql/029 (file_attachments)
-- 정합: 통합 설계서 v1.1 §4 (Adapter 패턴 / self·modusign·eformsign)
-- 라이브 적용: Supabase migration 20260501080238 (2026-05-01)
-- D드라이브 복원: 2026-05-03 (30차 회기 / Supabase에서 추출)
-- ============================================================================

ALTER TABLE public.contracts
  ADD COLUMN IF NOT EXISTS provider           varchar(20) NOT NULL DEFAULT 'self'
    CHECK (provider IN ('self','modusign','eformsign')),
  ADD COLUMN IF NOT EXISTS envelope_id        varchar(100),
  ADD COLUMN IF NOT EXISTS 서명_PDF_URL       text,
  ADD COLUMN IF NOT EXISTS 서명_상태_세부     varchar(20) NOT NULL DEFAULT 'pending'
    CHECK (서명_상태_세부 IN ('pending','sent','viewed','signed_갑','signed_을','completed','declined','expired')),
  ADD COLUMN IF NOT EXISTS 본인확인_정보      jsonb,
  ADD COLUMN IF NOT EXISTS webhook_payload    jsonb,
  ADD COLUMN IF NOT EXISTS 발송_횟수          smallint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS 마지막_발송일      timestamptz,
  ADD COLUMN IF NOT EXISTS 갑_서명일          timestamptz,
  ADD COLUMN IF NOT EXISTS 을_서명일          timestamptz;

COMMENT ON COLUMN public.contracts.provider          IS 'self=jsPDF+이메일 / modusign·eformsign=Phase D2';
COMMENT ON COLUMN public.contracts.envelope_id       IS 'SaaS Provider 계약 식별자';
COMMENT ON COLUMN public.contracts.서명_PDF_URL      IS '체결본 Storage 경로 (docs/{customer_id}/계약서_체결본/...)';
COMMENT ON COLUMN public.contracts.서명_상태_세부    IS 'pending→sent→viewed→signed_갑→signed_을→completed';
COMMENT ON COLUMN public.contracts.본인확인_정보     IS '카카오/문자OTP 결과 jsonb';
COMMENT ON COLUMN public.contracts.webhook_payload   IS 'Provider webhook 마지막 페이로드 보관';

CREATE INDEX IF NOT EXISTS idx_contracts_envelope ON public.contracts(envelope_id) WHERE envelope_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_contracts_상태_세부 ON public.contracts(서명_상태_세부);
CREATE INDEX IF NOT EXISTS idx_contracts_provider ON public.contracts(provider);
