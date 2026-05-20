-- sql/052: 서류 사후 수정 기능 인프라
-- 2026-05-20 / 48차 / v2.25 번들
-- 옵션 B: 인플레이스 + 수정차수 자동 증가 + status_history 자동 기록

ALTER TABLE public.contracts
  ADD COLUMN IF NOT EXISTS "수정차수" smallint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS "수정사유" text;

ALTER TABLE public.official_documents
  ADD COLUMN IF NOT EXISTS "수정차수" smallint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS "수정사유" text;

COMMENT ON COLUMN public.contracts."수정차수" IS '수정 횟수 / 1=원본 / 미서명만 수정 가능';
COMMENT ON COLUMN public.official_documents."수정차수" IS '수정 횟수 / 1=원본';

-- 본문 = Supabase 마이그레이션 sql_052_revision_columns_and_rpcs 참조
-- RPC 3종: rpc_update_quotation_with_revision / rpc_update_contract_with_revision / rpc_update_official_doc_with_revision
-- 모두 _수정사유 NOT NULL / status_history 자동 기록 / GRANT EXECUTE TO authenticated

NOTIFY pgrst, 'reload schema';
