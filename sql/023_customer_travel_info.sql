-- ====================================================================
-- sql/023 — customer 도착·출발시간·인원 컬럼 추가 + RPC 신규
-- v2.12 Phase 5 / 2026-04-30
-- 회사 표준 견적서 양식 정합 (admin v2.12)
-- ====================================================================

-- 1. customers 테이블 컬럼 추가 (한글 컬럼 표준 / IF NOT EXISTS 안전)
ALTER TABLE customers
  ADD COLUMN IF NOT EXISTS 도착시간    TIME,
  ADD COLUMN IF NOT EXISTS 출발시간    TIME,
  ADD COLUMN IF NOT EXISTS 인원_성인   INTEGER,
  ADD COLUMN IF NOT EXISTS 인원_아동   INTEGER;

COMMENT ON COLUMN customers.도착시간   IS 'v2.12: 서울→제주 도착 시간 (국내여행 견적서 자동 매핑)';
COMMENT ON COLUMN customers.출발시간   IS 'v2.12: 제주→서울 출발 시간 (국내여행 견적서 자동 매핑)';
COMMENT ON COLUMN customers.인원_성인  IS 'v2.12: 견적서 1인 상품요금 계산용';
COMMENT ON COLUMN customers.인원_아동  IS 'v2.12: 견적서 1인 상품요금 계산용';


-- 2. RPC 신규: rpc_get_customer_travel_info
--    [용도] admin 견적 작성 화면 영역 2 [👤 고객 정보 불러오기] 버튼 호출
--    [매핑] customers.시작일 → 여행_시작일 / 종료일 → 여행_종료일 (admin state 정합)
DROP FUNCTION IF EXISTS public.rpc_get_customer_travel_info(uuid);

CREATE OR REPLACE FUNCTION public.rpc_get_customer_travel_info(_customer_id uuid)
RETURNS TABLE(
  여행_시작일  DATE,
  도착시간    TIME,
  여행_종료일  DATE,
  출발시간    TIME,
  인원_성인   INTEGER,
  인원_아동   INTEGER
)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    시작일       AS 여행_시작일,
    도착시간,
    종료일       AS 여행_종료일,
    출발시간,
    인원_성인,
    인원_아동
  FROM customers
  WHERE id = _customer_id
    AND deleted_at IS NULL
  LIMIT 1;
$$;

COMMENT ON FUNCTION public.rpc_get_customer_travel_info(uuid)
IS 'v2.12 Phase 5: 견적 작성 시 고객 여행 정보 자동 매핑 / admin 영역 2 [고객 정보 불러오기] 버튼';


-- 3. 권한 부여 (authenticated 역할)
GRANT EXECUTE ON FUNCTION public.rpc_get_customer_travel_info(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_get_customer_travel_info(uuid) TO service_role;


-- 4. 검증 쿼리 (대표님 Supabase 적용 후 확인용)
-- SELECT column_name, data_type FROM information_schema.columns
--   WHERE table_name='customers' AND column_name IN ('도착시간','출발시간','인원_성인','인원_아동');
--   → 4 행 반환되어야 함
--
-- SELECT * FROM rpc_get_customer_travel_info('고객ID-UUID');
--   → 1 행 반환 (여행_시작일·도착시간·여행_종료일·출발시간·인원_성인·인원_아동)


-- ====================================================================
-- 적용 방법 (대표님 Supabase 손 작업)
-- 1) Supabase SQL Editor 열기
-- 2) 본 파일 전체 복사 → 붙여넣기 → RUN
-- 3) 검증 쿼리 실행 (4 컬럼 확인 + RPC 동작 확인)
-- 4) admin.html에서 [👤 고객 정보 불러오기] 버튼 동작 확인
-- ====================================================================
