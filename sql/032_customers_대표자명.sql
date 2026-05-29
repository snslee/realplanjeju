-- sql/032_customers_대표자명.sql
-- 31차 v2.18-B-2-인프라 / 옵션 A2 / 2026-05-03
-- 목적: customers 테이블에 대표자명 컬럼 추가
--   → 계약서 갑 측 서명란 자동 매핑 인프라 (jsPDF B-1 의존)
-- 영향: 0 (nullable / 기존 4건 row NULL 정합)
-- 회귀: 0 (rpc_update_customer는 _updates jsonb 동적 처리)

ALTER TABLE customers
  ADD COLUMN IF NOT EXISTS 대표자명 varchar(50);

COMMENT ON COLUMN customers.대표자명 IS
  '갑(고객) 측 대표자명 — 계약서 갑 측 서명란 자동 매핑용 / 31차 추가 / sql/032';
