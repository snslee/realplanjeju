-- ============================================================================
-- 012_phase2a_quotations_extend.sql
-- Phase 2a: quotations 테이블 확장 + RPC 4종 + 채번 로직
-- 작성일: 2026-04-26 (v7 갱신)
-- 작성자: Claude (개발사업부 AI 컨설턴트)
-- 승인자: 이동환 대표 (결정 #34 v7 / 18대 확정값)
-- v7 변경: 사업부별 계좌 / 결제 조건 4종 / is_government 토글 / VAT는 v6 옵션 그대로
-- 의존성: sql/001~011 (Phase 1 + admin.html v1.9.2)
-- 적용 순서: 본 파일(012) → sql/013 (product_catalog) → 검증 5단계
-- ============================================================================

BEGIN;

-- ============================================================================
-- SECTION 1. quotations 테이블 ALTER (15컬럼 추가)
-- ============================================================================

ALTER TABLE quotations
  ADD COLUMN IF NOT EXISTS parent_quotation_id UUID REFERENCES quotations(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS 사업부 VARCHAR(20),
  ADD COLUMN IF NOT EXISTS 제목 VARCHAR(200),
  ADD COLUMN IF NOT EXISTS 수신_회사명 VARCHAR(100),
  ADD COLUMN IF NOT EXISTS 수신_부서 VARCHAR(80),
  ADD COLUMN IF NOT EXISTS 수신_담당자 VARCHAR(50),
  ADD COLUMN IF NOT EXISTS 수신_직위 VARCHAR(40),
  ADD COLUMN IF NOT EXISTS 대행료율 NUMERIC(4,2) DEFAULT 7.5,
  ADD COLUMN IF NOT EXISTS 대행료_표기 BOOLEAN DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS vat_표기 BOOLEAN DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS 절사_단위 VARCHAR(10) DEFAULT '없음',
  ADD COLUMN IF NOT EXISTS 판매가_컬럼 BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS 비고 TEXT,
  ADD COLUMN IF NOT EXISTS 첨부_옵션 JSONB DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS 발송_실패_사유 TEXT,
  ADD COLUMN IF NOT EXISTS is_government BOOLEAN DEFAULT FALSE;
-- is_government: 관공서·학교·공기업 거래 (ON 시 결제 조건 자동 후불 100%)

-- 사업부 CHECK
ALTER TABLE quotations DROP CONSTRAINT IF EXISTS ck_quotations_사업부;
ALTER TABLE quotations ADD CONSTRAINT ck_quotations_사업부
  CHECK (사업부 IS NULL OR 사업부 IN ('국내여행','행사이벤트','온라인마케팅','마케팅교육'));

-- 절사 단위 CHECK
ALTER TABLE quotations DROP CONSTRAINT IF EXISTS ck_quotations_절사단위;
ALTER TABLE quotations ADD CONSTRAINT ck_quotations_절사단위
  CHECK (절사_단위 IN ('없음','천','만'));

-- 대행료율 CHECK (5~10 범위)
ALTER TABLE quotations DROP CONSTRAINT IF EXISTS ck_quotations_대행료율;
ALTER TABLE quotations ADD CONSTRAINT ck_quotations_대행료율
  CHECK (대행료율 IS NULL OR (대행료율 >= 0 AND 대행료율 <= 30));

-- ============================================================================
-- SECTION 2. 상태 CHECK 7종으로 확장 (5종 → 7종)
-- ============================================================================

ALTER TABLE quotations DROP CONSTRAINT IF EXISTS quotations_상태_check;
ALTER TABLE quotations DROP CONSTRAINT IF EXISTS ck_quotations_상태;
ALTER TABLE quotations ADD CONSTRAINT ck_quotations_상태
  CHECK (상태 IN ('작성중','발송완료','재발송','무효화','수락','거절','만료'));

-- ============================================================================
-- SECTION 3. 인덱스 4종
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_quotations_parent
  ON quotations(parent_quotation_id);
CREATE INDEX IF NOT EXISTS idx_quotations_사업부_year
  ON quotations(사업부, created_at);
CREATE INDEX IF NOT EXISTS idx_quotations_상태
  ON quotations(상태);
CREATE INDEX IF NOT EXISTS idx_quotations_발송일시_desc
  ON quotations(발송일시 DESC);

-- ============================================================================
-- SECTION 4. RPC #1 — rpc_create_quotation (advisory lock 채번)
-- ============================================================================

CREATE OR REPLACE FUNCTION rpc_create_quotation(
  _customer_id UUID,
  _사업부 VARCHAR,
  _제목 VARCHAR,
  _수신 JSONB,
  _items JSONB,
  _options JSONB,
  _parent_id UUID DEFAULT NULL
)
RETURNS TABLE(
  id UUID,
  견적번호 VARCHAR,
  수정차수 INTEGER,
  견적금액 BIGINT,
  사업부 VARCHAR,
  상태 VARCHAR,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  _prefix TEXT;
  _year INT;
  _next_no INT;
  _new_no TEXT;
  _new_id UUID;
  _new_version INT;
  _견적금액 BIGINT;
  _작성자 TEXT;
  _lock_key BIGINT;
BEGIN
  -- 권한 검증
  IF NOT fn_current_is_admin() THEN
    RAISE EXCEPTION '관리자만 견적을 작성할 수 있습니다';
  END IF;

  -- 입력 검증
  IF _사업부 NOT IN ('국내여행','행사이벤트','온라인마케팅','마케팅교육') THEN
    RAISE EXCEPTION '사업부는 4종 중 하나여야 합니다';
  END IF;

  -- 사업부 → prefix 매핑
  _prefix := CASE _사업부
    WHEN '국내여행' THEN 'TOUR'
    WHEN '행사이벤트' THEN 'EVENT'
    WHEN '온라인마케팅' THEN 'MKT'
    WHEN '마케팅교육' THEN 'EDU'
  END;

  _year := EXTRACT(YEAR FROM now())::INT;
  _작성자 := COALESCE(auth.jwt() ->> 'email', 'system');

  -- 견적금액 = 본문 항목 합계 (소계만 계산. 대행료·VAT·절사는 PDF에서)
  SELECT COALESCE(SUM((item->>'금액')::BIGINT), 0)
    INTO _견적금액
    FROM jsonb_array_elements(COALESCE(_items, '[]'::jsonb)) AS item;

  -- advisory lock 키 = hash(사업부 + 연도)
  _lock_key := hashtext(_prefix || '_' || _year::TEXT);
  PERFORM pg_advisory_xact_lock(_lock_key);

  -- 채번: 해당 사업부 + 연도 MAX + 1
  SELECT COALESCE(MAX(
    CASE WHEN q.견적번호 ~ ('^Q-' || _prefix || '-' || _year || '-([0-9]+)') THEN
      (regexp_match(q.견적번호, ('^Q-' || _prefix || '-' || _year || '-([0-9]+)')))[1]::INT
    ELSE 0 END
  ), 0) + 1
  INTO _next_no
  FROM quotations q
  WHERE q.사업부 = _사업부
    AND EXTRACT(YEAR FROM q.created_at) = _year
    AND q.parent_quotation_id IS NULL;  -- 신규 채번은 부모 견적만 카운트

  _new_no := 'Q-' || _prefix || '-' || _year || '-' || LPAD(_next_no::TEXT, 3, '0');

  -- 재견적인 경우: parent의 견적번호에 -vN 부착
  IF _parent_id IS NOT NULL THEN
    SELECT 견적번호, 수정차수
      INTO _new_no, _new_version
      FROM quotations
      WHERE id = _parent_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION '부모 견적을 찾을 수 없습니다: %', _parent_id;
    END IF;
    -- 같은 parent 아래 max version + 1
    SELECT COALESCE(MAX(수정차수), 1) + 1
      INTO _new_version
      FROM quotations
      WHERE parent_quotation_id = _parent_id OR id = _parent_id;
    -- 견적번호 = parent 견적번호 (수정차수만 다름)
  ELSE
    _new_version := 1;
  END IF;

  -- INSERT
  INSERT INTO quotations(
    customer_id, 견적번호, 수정차수, 견적금액, 유효기간, 결제조건,
    세부항목, 상태, 작성자,
    parent_quotation_id, 사업부, 제목,
    수신_회사명, 수신_부서, 수신_담당자, 수신_직위,
    대행료율, 대행료_표기, vat_표기, 절사_단위, 판매가_컬럼,
    비고, 첨부_옵션, is_government
  )
  VALUES (
    _customer_id, _new_no, _new_version, _견적금액,
    (now() + INTERVAL '30 days')::DATE,
    COALESCE(_options ->> '결제조건', NULL),
    _items, '작성중', _작성자,
    _parent_id, _사업부, _제목,
    _수신 ->> '회사명', _수신 ->> '부서', _수신 ->> '담당자', _수신 ->> '직위',
    COALESCE((_options ->> '대행료율')::NUMERIC, 7.5),
    COALESCE((_options ->> '대행료_표기')::BOOLEAN, TRUE),
    COALESCE((_options ->> 'vat_표기')::BOOLEAN, TRUE),
    COALESCE(_options ->> '절사_단위', '없음'),
    COALESCE((_options ->> '판매가_컬럼')::BOOLEAN, FALSE),
    _options ->> '비고',
    COALESCE(_options -> '첨부', '{}'::jsonb),
    COALESCE((_options ->> 'is_government')::BOOLEAN, FALSE)
  )
  RETURNING quotations.id INTO _new_id;

  -- 결과 반환
  RETURN QUERY
    SELECT q.id, q.견적번호, q.수정차수, q.견적금액, q.사업부, q.상태, q.created_at
      FROM quotations q
      WHERE q.id = _new_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_create_quotation(UUID, VARCHAR, VARCHAR, JSONB, JSONB, JSONB, UUID)
  TO anon, authenticated;

-- ============================================================================
-- SECTION 5. RPC #2 — rpc_send_quotation (발송 + 상태 자동 전이)
-- ============================================================================

CREATE OR REPLACE FUNCTION rpc_send_quotation(
  _quotation_id UUID,
  _수신자이메일 VARCHAR,
  _attachments JSONB DEFAULT '[]'::jsonb
)
RETURNS TABLE(
  id UUID,
  견적번호 VARCHAR,
  상태 VARCHAR,
  발송일시 TIMESTAMPTZ,
  customer_id UUID,
  고객상태_after VARCHAR
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  _customer_id UUID;
  _현재상태 VARCHAR;
BEGIN
  IF NOT fn_current_is_admin() THEN
    RAISE EXCEPTION '관리자만 견적을 발송할 수 있습니다';
  END IF;

  IF _수신자이메일 IS NULL OR _수신자이메일 = '' THEN
    RAISE EXCEPTION '수신자 이메일이 필요합니다';
  END IF;

  -- 견적 존재 확인
  SELECT q.customer_id, q.상태 INTO _customer_id, _현재상태
    FROM quotations q WHERE q.id = _quotation_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION '견적을 찾을 수 없습니다';
  END IF;

  -- 무효화 견적은 발송 불가
  IF _현재상태 = '무효화' THEN
    RAISE EXCEPTION '무효화된 견적은 발송할 수 없습니다';
  END IF;

  -- 견적 발송 처리
  UPDATE quotations
    SET 상태 = CASE WHEN 상태 = '발송완료' THEN '재발송' ELSE '발송완료' END,
        발송여부 = TRUE,
        발송일시 = now(),
        수신자이메일 = _수신자이메일,
        첨부_옵션 = jsonb_set(COALESCE(첨부_옵션, '{}'::jsonb), '{발송_첨부}', _attachments)
    WHERE id = _quotation_id;

  -- 고객상태 자동 전이 (현재 상태가 견적발송 이전 단계인 경우만)
  UPDATE customers
    SET 고객상태 = '견적발송'
    WHERE id = _customer_id
      AND 고객상태 IN ('신규문의','접수','확인','상담중');

  RETURN QUERY
    SELECT q.id, q.견적번호, q.상태, q.발송일시, q.customer_id, c.고객상태
      FROM quotations q
      JOIN customers c ON c.id = q.customer_id
      WHERE q.id = _quotation_id;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_send_quotation(UUID, VARCHAR, JSONB)
  TO anon, authenticated;

-- ============================================================================
-- SECTION 6. RPC #3 — rpc_list_quotations (고객별 목록 + 버전 트리)
-- ============================================================================

CREATE OR REPLACE FUNCTION rpc_list_quotations(
  _customer_id UUID
)
RETURNS TABLE(
  id UUID,
  견적번호 VARCHAR,
  수정차수 INTEGER,
  parent_quotation_id UUID,
  사업부 VARCHAR,
  제목 VARCHAR,
  견적금액 BIGINT,
  상태 VARCHAR,
  발송일시 TIMESTAMPTZ,
  created_at TIMESTAMPTZ,
  작성자 VARCHAR
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
BEGIN
  IF NOT fn_current_is_admin() THEN
    RAISE EXCEPTION '관리자만 견적을 조회할 수 있습니다';
  END IF;

  RETURN QUERY
    SELECT
      q.id, q.견적번호, q.수정차수, q.parent_quotation_id,
      q.사업부, q.제목, q.견적금액, q.상태,
      q.발송일시, q.created_at, q.작성자
    FROM quotations q
    WHERE q.customer_id = _customer_id
    ORDER BY
      COALESCE(q.parent_quotation_id, q.id) DESC,
      q.수정차수 ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_list_quotations(UUID)
  TO anon, authenticated;

-- ============================================================================
-- SECTION 7. RPC #4 — rpc_get_quotation (단건 상세)
-- ============================================================================

CREATE OR REPLACE FUNCTION rpc_get_quotation(
  _quotation_id UUID
)
RETURNS SETOF quotations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT fn_current_is_admin() THEN
    RAISE EXCEPTION '관리자만 견적을 조회할 수 있습니다';
  END IF;

  RETURN QUERY
    SELECT * FROM quotations WHERE id = _quotation_id LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION rpc_get_quotation(UUID)
  TO anon, authenticated;

-- ============================================================================
-- SECTION 8. 검증 쿼리 (적용 후 5단계 검증용)
-- ============================================================================

-- 1. 추가 컬럼 15개 확인
-- SELECT column_name FROM information_schema.columns
--   WHERE table_name='quotations' ORDER BY ordinal_position;

-- 2. CHECK 제약 4개 확인
-- SELECT conname FROM pg_constraint WHERE conrelid='quotations'::regclass AND contype='c';

-- 3. RPC 4종 시그니처 확인
-- SELECT proname, pg_get_function_identity_arguments(oid)
--   FROM pg_proc WHERE proname LIKE 'rpc_%quotation%';

-- 4. RPC GRANT 확인
-- SELECT grantee, privilege_type FROM information_schema.routine_privileges
--   WHERE routine_name LIKE 'rpc_%quotation%';

-- 5. 테스트 채번 (실제로는 안전한 더미 customer_id 필요)
-- SELECT * FROM rpc_create_quotation(
--   '00000000-0000-0000-0000-000000000000'::uuid,
--   '국내여행', '테스트 견적', '{}'::jsonb, '[]'::jsonb, '{}'::jsonb, NULL
-- );

COMMIT;

-- ============================================================================
-- 적용 후 다음 작업: sql/013_product_catalog.sql
-- ============================================================================
