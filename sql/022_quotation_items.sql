-- ============================================================================
-- 022_quotation_items.sql
-- 묶음 5: 통합 품목 모델 (quotation_items 정규화 + quotations 보강 5컬럼 + RPC 7종)
-- 작성일: 2026-04-29 (22차 회기)
-- 작성자: Claude (개발사업부 AI 컨설턴트)
-- 승인자: 이동환 대표 (룰 v3 §18 8단계 절대 순서 / 본 회기 명시 승인)
-- 의존성: sql/001~016 + 017a + 020a + 020 v2 + 021 + 021b 라이브 적용 완료
-- 통합 정합: v1.2 §A.8 / 회사 맞춤형 8항목 / 4사업부 (국내·행사·온라인·교육)
-- 적용 순서: 본 파일(022) → admin.html v2.11 → Edge Function 보강
-- ============================================================================
-- 핵심 설계:
--  · quotation_items 신규 정규화 테이블 (21컬럼 / GENERATED 금액 / RLS 정합)
--  · quotations 보강 5컬럼 (안_번호·인원_성인·인원_아동·박일수·비고_PDF노출)
--  · 기존 quotations.세부항목 jsonb = legacy 보존 (A안 / 점진 마이그)
--  · RPC 7종 (list / upsert / delete / clone_proposal / itinerary / summary / recalc)
--  · RLS = sql/021 admin_permissions 매트릭스 fallback (영역='견적관리')
-- ============================================================================

BEGIN;

-- ============================================================================
-- SECTION 1. quotations 보강 5컬럼
-- ============================================================================

ALTER TABLE quotations
  ADD COLUMN IF NOT EXISTS 안_번호 INT DEFAULT 1,
  ADD COLUMN IF NOT EXISTS 인원_성인 INT,
  ADD COLUMN IF NOT EXISTS 인원_아동 INT,
  ADD COLUMN IF NOT EXISTS 박일수 INT,
  ADD COLUMN IF NOT EXISTS 비고_PDF노출 BOOLEAN DEFAULT TRUE;

ALTER TABLE quotations DROP CONSTRAINT IF EXISTS ck_quotations_안_번호;
ALTER TABLE quotations ADD CONSTRAINT ck_quotations_안_번호
  CHECK (안_번호 IS NULL OR 안_번호 BETWEEN 1 AND 9);

COMMENT ON COLUMN quotations.안_번호 IS '복수 견적 안 (1차·2차·3차) / DEFAULT 1';
COMMENT ON COLUMN quotations.인원_성인 IS '국내여행 성인 인원 / 1인 단가 산출';
COMMENT ON COLUMN quotations.인원_아동 IS '국내여행 아동 인원';
COMMENT ON COLUMN quotations.박일수 IS '국내여행 N박M일 (정수 = 박)';
COMMENT ON COLUMN quotations.비고_PDF노출 IS '비고 박스 PDF 노출 여부';

-- ============================================================================
-- SECTION 2. quotation_items 테이블 신설 (21컬럼)
-- ============================================================================

CREATE TABLE IF NOT EXISTS quotation_items (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  quotation_id UUID NOT NULL REFERENCES quotations(id) ON DELETE CASCADE,

  -- 안·정렬
  안_번호 INT NOT NULL DEFAULT 1,
  정렬순서 INT NOT NULL DEFAULT 0,

  -- 카테고리 (사업부별 dropdown 추천 / 자유 입력 허용 / CHECK X)
  카테고리_대분류 VARCHAR(50),
  카테고리_소분류 VARCHAR(50),

  -- 품명 (견적서 정확 표기 / 일정표 짧은 표기 분리)
  품목명 VARCHAR(200) NOT NULL,
  일정_표시 VARCHAR(150),

  -- 국내여행 일정 필드
  일차 INT,
  시간 TIME,
  식사_컬럼 VARCHAR(4),

  -- 수량·단가·금액 (GENERATED)
  수량 NUMERIC(12,2) NOT NULL DEFAULT 1,
  단위 VARCHAR(20),
  단가 NUMERIC(12,2) NOT NULL DEFAULT 0,
  금액 NUMERIC(14,2) GENERATED ALWAYS AS (수량 * 단가) STORED,
  판매가 NUMERIC(12,2),

  -- 비고
  비고 TEXT,

  -- 카탈로그 연동
  product_id UUID REFERENCES product_catalog(id) ON DELETE SET NULL,

  -- 표시 제어 (일정표·견적서)
  일정표_표시 BOOLEAN NOT NULL DEFAULT FALSE,
  견적서_표시 BOOLEAN NOT NULL DEFAULT TRUE,

  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- CHECK 제약
ALTER TABLE quotation_items DROP CONSTRAINT IF EXISTS ck_qi_안_번호;
ALTER TABLE quotation_items ADD CONSTRAINT ck_qi_안_번호
  CHECK (안_번호 BETWEEN 1 AND 9);

ALTER TABLE quotation_items DROP CONSTRAINT IF EXISTS ck_qi_식사_컬럼;
ALTER TABLE quotation_items ADD CONSTRAINT ck_qi_식사_컬럼
  CHECK (식사_컬럼 IS NULL OR 식사_컬럼 IN ('조','중','석','X'));

ALTER TABLE quotation_items DROP CONSTRAINT IF EXISTS ck_qi_일차;
ALTER TABLE quotation_items ADD CONSTRAINT ck_qi_일차
  CHECK (일차 IS NULL OR 일차 BETWEEN 1 AND 30);

ALTER TABLE quotation_items DROP CONSTRAINT IF EXISTS ck_qi_수량_단가_음수;
ALTER TABLE quotation_items ADD CONSTRAINT ck_qi_수량_단가_음수
  CHECK (수량 >= 0 AND 단가 >= 0);

COMMENT ON TABLE quotation_items IS '견적 품목 정규화 (4사업부 공통 / 국내여행 일정표 동시 노출)';
COMMENT ON COLUMN quotation_items.일정_표시 IS '국내여행 일정표 짧은 표기 (예: "9.81파크 제주(레이싱)")';
COMMENT ON COLUMN quotation_items.품목명 IS '견적서 정확 표기 (예: "9.81파크 레이싱2회+스포츠랩")';
COMMENT ON COLUMN quotation_items.금액 IS 'GENERATED ALWAYS AS (수량*단가) STORED — 자동 계산 / 직접 UPDATE 불가';

-- ============================================================================
-- SECTION 3. 인덱스 4종
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_qi_quotation_안
  ON quotation_items(quotation_id, 안_번호, 정렬순서);

CREATE INDEX IF NOT EXISTS idx_qi_product
  ON quotation_items(product_id) WHERE product_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_qi_itinerary
  ON quotation_items(quotation_id, 안_번호, 일차, 시간)
  WHERE 일정표_표시 = TRUE;

CREATE INDEX IF NOT EXISTS idx_qi_quote_visible
  ON quotation_items(quotation_id, 안_번호, 정렬순서)
  WHERE 견적서_표시 = TRUE;

-- ============================================================================
-- SECTION 4. updated_at 트리거
-- ============================================================================

DROP TRIGGER IF EXISTS trg_qi_updated ON quotation_items;
CREATE TRIGGER trg_qi_updated BEFORE UPDATE ON quotation_items
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================================
-- SECTION 5. RLS 정책 (sql/021 admin_permissions 정합)
-- ============================================================================

ALTER TABLE quotation_items ENABLE ROW LEVEL SECURITY;

-- 5-1) admin all (owner / fn_current_is_admin)
DROP POLICY IF EXISTS qi_admin_all ON quotation_items;
CREATE POLICY qi_admin_all ON quotation_items
  FOR ALL TO anon, authenticated
  USING (fn_current_is_admin())
  WITH CHECK (fn_current_is_admin());

-- 5-2) authenticated (manager·viewer) SELECT — 견적관리 영역 권한 ≥ viewer
DROP POLICY IF EXISTS qi_auth_select ON quotation_items;
CREATE POLICY qi_auth_select ON quotation_items
  FOR SELECT TO authenticated
  USING (
    fn_current_is_admin()
    OR EXISTS (
      SELECT 1 FROM users u
      WHERE u.이메일 = auth.email()
        AND u.활성 = TRUE
        AND u.권한 IN ('owner','manager','viewer')
    )
  );

-- 5-3) manager INSERT/UPDATE/DELETE — 견적관리 권한 매트릭스 (fn_get_permission fallback)
DROP POLICY IF EXISTS qi_manager_write ON quotation_items;
CREATE POLICY qi_manager_write ON quotation_items
  FOR ALL TO authenticated
  USING (
    fn_current_is_admin()
    OR EXISTS (
      SELECT 1 FROM users u
      WHERE u.이메일 = auth.email()
        AND u.활성 = TRUE
        AND u.권한 IN ('owner','manager')
    )
  )
  WITH CHECK (
    fn_current_is_admin()
    OR EXISTS (
      SELECT 1 FROM users u
      WHERE u.이메일 = auth.email()
        AND u.활성 = TRUE
        AND u.권한 IN ('owner','manager')
    )
  );

-- ============================================================================
-- SECTION 6. RPC 7종
-- ============================================================================

-- 6-1) rpc_list_quotation_items — 안별 조회
CREATE OR REPLACE FUNCTION rpc_list_quotation_items(
  _quotation_id UUID,
  _안_번호 INT DEFAULT 1
)
RETURNS TABLE (
  r_id UUID,
  r_정렬순서 INT,
  r_카테고리_대분류 TEXT,
  r_카테고리_소분류 TEXT,
  r_품목명 TEXT,
  r_일정_표시 TEXT,
  r_일차 INT,
  r_시간 TEXT,
  r_식사_컬럼 TEXT,
  r_수량 NUMERIC,
  r_단위 TEXT,
  r_단가 NUMERIC,
  r_금액 NUMERIC,
  r_판매가 NUMERIC,
  r_비고 TEXT,
  r_product_id UUID,
  r_일정표_표시 BOOLEAN,
  r_견적서_표시 BOOLEAN
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    qi.id,
    qi.정렬순서,
    qi.카테고리_대분류::TEXT,
    qi.카테고리_소분류::TEXT,
    qi.품목명::TEXT,
    qi.일정_표시::TEXT,
    qi.일차,
    qi.시간::TEXT,
    qi.식사_컬럼::TEXT,
    qi.수량,
    qi.단위::TEXT,
    qi.단가,
    qi.금액,
    qi.판매가,
    qi.비고,
    qi.product_id,
    qi.일정표_표시,
    qi.견적서_표시
  FROM quotation_items qi
  WHERE qi.quotation_id = _quotation_id
    AND qi.안_번호 = _안_번호
  ORDER BY qi.정렬순서, qi.created_at;
END;
$$;

-- 6-2) rpc_upsert_quotation_item — 단건 추가·수정
CREATE OR REPLACE FUNCTION rpc_upsert_quotation_item(_payload JSONB)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id UUID;
  v_quotation_id UUID;
BEGIN
  v_id := NULLIF(_payload->>'id','')::UUID;
  v_quotation_id := (_payload->>'quotation_id')::UUID;

  IF v_quotation_id IS NULL THEN
    RAISE EXCEPTION 'quotation_id 필수';
  END IF;

  IF v_id IS NULL THEN
    -- INSERT
    INSERT INTO quotation_items (
      quotation_id, 안_번호, 정렬순서,
      카테고리_대분류, 카테고리_소분류,
      품목명, 일정_표시,
      일차, 시간, 식사_컬럼,
      수량, 단위, 단가, 판매가,
      비고, product_id,
      일정표_표시, 견적서_표시
    ) VALUES (
      v_quotation_id,
      COALESCE((_payload->>'안_번호')::INT, 1),
      COALESCE((_payload->>'정렬순서')::INT, 0),
      _payload->>'카테고리_대분류',
      _payload->>'카테고리_소분류',
      _payload->>'품목명',
      _payload->>'일정_표시',
      NULLIF(_payload->>'일차','')::INT,
      NULLIF(_payload->>'시간','')::TIME,
      NULLIF(_payload->>'식사_컬럼',''),
      COALESCE((_payload->>'수량')::NUMERIC, 1),
      _payload->>'단위',
      COALESCE((_payload->>'단가')::NUMERIC, 0),
      NULLIF(_payload->>'판매가','')::NUMERIC,
      _payload->>'비고',
      NULLIF(_payload->>'product_id','')::UUID,
      COALESCE((_payload->>'일정표_표시')::BOOLEAN, FALSE),
      COALESCE((_payload->>'견적서_표시')::BOOLEAN, TRUE)
    )
    RETURNING id INTO v_id;
  ELSE
    -- UPDATE
    UPDATE quotation_items SET
      안_번호 = COALESCE((_payload->>'안_번호')::INT, 안_번호),
      정렬순서 = COALESCE((_payload->>'정렬순서')::INT, 정렬순서),
      카테고리_대분류 = _payload->>'카테고리_대분류',
      카테고리_소분류 = _payload->>'카테고리_소분류',
      품목명 = COALESCE(_payload->>'품목명', 품목명),
      일정_표시 = _payload->>'일정_표시',
      일차 = NULLIF(_payload->>'일차','')::INT,
      시간 = NULLIF(_payload->>'시간','')::TIME,
      식사_컬럼 = NULLIF(_payload->>'식사_컬럼',''),
      수량 = COALESCE((_payload->>'수량')::NUMERIC, 수량),
      단위 = _payload->>'단위',
      단가 = COALESCE((_payload->>'단가')::NUMERIC, 단가),
      판매가 = NULLIF(_payload->>'판매가','')::NUMERIC,
      비고 = _payload->>'비고',
      product_id = NULLIF(_payload->>'product_id','')::UUID,
      일정표_표시 = COALESCE((_payload->>'일정표_표시')::BOOLEAN, 일정표_표시),
      견적서_표시 = COALESCE((_payload->>'견적서_표시')::BOOLEAN, 견적서_표시),
      updated_at = now()
    WHERE id = v_id
    RETURNING id INTO v_id;
  END IF;

  RETURN v_id;
END;
$$;

-- 6-3) rpc_delete_quotation_item
CREATE OR REPLACE FUNCTION rpc_delete_quotation_item(_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM quotation_items WHERE id = _id;
  RETURN FOUND;
END;
$$;

-- 6-4) rpc_clone_proposal — 1차 → 2차 안 복제
CREATE OR REPLACE FUNCTION rpc_clone_proposal(
  _quotation_id UUID,
  _src_안 INT,
  _dst_안 INT
)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INT;
BEGIN
  IF _src_안 = _dst_안 THEN
    RAISE EXCEPTION '원본과 대상 안 번호가 동일';
  END IF;

  -- 대상 안 기존 항목 삭제
  DELETE FROM quotation_items
  WHERE quotation_id = _quotation_id AND 안_번호 = _dst_안;

  -- 복제
  INSERT INTO quotation_items (
    quotation_id, 안_번호, 정렬순서,
    카테고리_대분류, 카테고리_소분류,
    품목명, 일정_표시,
    일차, 시간, 식사_컬럼,
    수량, 단위, 단가, 판매가,
    비고, product_id,
    일정표_표시, 견적서_표시
  )
  SELECT
    quotation_id, _dst_안, 정렬순서,
    카테고리_대분류, 카테고리_소분류,
    품목명, 일정_표시,
    일차, 시간, 식사_컬럼,
    수량, 단위, 단가, 판매가,
    비고, product_id,
    일정표_표시, 견적서_표시
  FROM quotation_items
  WHERE quotation_id = _quotation_id AND 안_번호 = _src_안;

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$;

-- 6-5) rpc_get_itinerary — 일정표 (국내여행)
CREATE OR REPLACE FUNCTION rpc_get_itinerary(
  _quotation_id UUID,
  _안_번호 INT DEFAULT 1
)
RETURNS TABLE (
  r_일차 INT,
  r_시간 TEXT,
  r_관광_일정 TEXT,
  r_식사 TEXT,
  r_정렬순서 INT
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  SELECT
    qi.일차,
    TO_CHAR(qi.시간, 'HH24:MI')::TEXT,
    COALESCE(NULLIF(qi.일정_표시,''), qi.품목명)::TEXT,
    qi.식사_컬럼::TEXT,
    qi.정렬순서
  FROM quotation_items qi
  WHERE qi.quotation_id = _quotation_id
    AND qi.안_번호 = _안_번호
    AND qi.일정표_표시 = TRUE
  ORDER BY qi.일차 NULLS LAST, qi.시간 NULLS LAST, qi.정렬순서;
END;
$$;

-- 6-6) rpc_get_quotation_summary — 사업부별 합계
CREATE OR REPLACE FUNCTION rpc_get_quotation_summary(
  _quotation_id UUID,
  _안_번호 INT DEFAULT 1
)
RETURNS TABLE (
  r_사업부 TEXT,
  r_소계 NUMERIC,
  r_대행료율 NUMERIC,
  r_대행료 NUMERIC,
  r_부가세 NUMERIC,
  r_합계 NUMERIC,
  r_인원_총 INT,
  r_1인_상품요금 NUMERIC
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_사업부 VARCHAR;
  v_대행료율 NUMERIC;
  v_대행료_표기 BOOLEAN;
  v_vat_표기 BOOLEAN;
  v_인원_성인 INT;
  v_인원_아동 INT;
  v_소계 NUMERIC;
  v_대행료 NUMERIC;
  v_부가세 NUMERIC;
  v_합계 NUMERIC;
  v_인원_총 INT;
  v_1인 NUMERIC;
BEGIN
  SELECT q.사업부, q.대행료율, q.대행료_표기, q.vat_표기, q.인원_성인, q.인원_아동
  INTO v_사업부, v_대행료율, v_대행료_표기, v_vat_표기, v_인원_성인, v_인원_아동
  FROM quotations q WHERE q.id = _quotation_id;

  SELECT COALESCE(SUM(qi.금액), 0) INTO v_소계
  FROM quotation_items qi
  WHERE qi.quotation_id = _quotation_id
    AND qi.안_번호 = _안_번호
    AND qi.견적서_표시 = TRUE;

  v_대행료 := CASE WHEN v_대행료_표기 THEN ROUND(v_소계 * COALESCE(v_대행료율,0) / 100, 0) ELSE 0 END;
  v_부가세 := CASE WHEN v_vat_표기 THEN ROUND((v_소계 + v_대행료) * 0.1, 0) ELSE 0 END;
  v_합계 := v_소계 + v_대행료 + v_부가세;
  v_인원_총 := COALESCE(v_인원_성인,0) + COALESCE(v_인원_아동,0);
  v_1인 := CASE WHEN v_인원_총 > 0 THEN ROUND(v_합계 / v_인원_총, 0) ELSE NULL END;

  RETURN QUERY SELECT
    v_사업부::TEXT, v_소계, v_대행료율, v_대행료, v_부가세, v_합계, v_인원_총, v_1인;
END;
$$;

-- 6-7) rpc_recalc_amounts — quotations.견적금액 재계산 (안=1 기본)
CREATE OR REPLACE FUNCTION rpc_recalc_amounts(_quotation_id UUID)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_합계 NUMERIC;
BEGIN
  SELECT r_합계 INTO v_합계
  FROM rpc_get_quotation_summary(_quotation_id, 1);

  UPDATE quotations
  SET 견적금액 = COALESCE(v_합계, 0)::BIGINT,
      updated_at = now()
  WHERE id = _quotation_id;

  RETURN COALESCE(v_합계, 0)::BIGINT;
END;
$$;

-- ============================================================================
-- SECTION 7. GRANT (anon·authenticated)
-- ============================================================================

GRANT EXECUTE ON FUNCTION rpc_list_quotation_items(UUID, INT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_upsert_quotation_item(JSONB) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_delete_quotation_item(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_clone_proposal(UUID, INT, INT) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_get_itinerary(UUID, INT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_get_quotation_summary(UUID, INT) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION rpc_recalc_amounts(UUID) TO authenticated;

GRANT SELECT, INSERT, UPDATE, DELETE ON quotation_items TO authenticated;
GRANT SELECT ON quotation_items TO anon;

COMMIT;

-- ============================================================================
-- 검증 쿼리 (적용 후 수동 실행)
-- ============================================================================
-- SELECT column_name FROM information_schema.columns WHERE table_name='quotation_items' ORDER BY ordinal_position;
-- SELECT column_name FROM information_schema.columns WHERE table_name='quotations' AND column_name IN ('안_번호','인원_성인','인원_아동','박일수','비고_PDF노출');
-- SELECT proname FROM pg_proc WHERE proname IN ('rpc_list_quotation_items','rpc_upsert_quotation_item','rpc_delete_quotation_item','rpc_clone_proposal','rpc_get_itinerary','rpc_get_quotation_summary','rpc_recalc_amounts');
-- SELECT * FROM pg_policies WHERE tablename='quotation_items';
