-- ============================================================================
-- sql/045 — rpc_create_quotation 채번 retry-on-conflict 패치 (P0 hotfix)
-- ============================================================================
-- 작성일: 2026-05-06 (v1.3 정합)
-- 목적:
--   1. 모바일/PC 견적번호 duplicate key 오류 근본 차단
--   2. 동시성 race condition 방어 (advisory_lock + retry 5회)
--   3. PandaDoc retry-on-conflict 패턴 차용 (롤모델 매트릭스 §2)
-- 변경:
--   - rpc_create_quotation INSERT 부분을 BEGIN..EXCEPTION unique_violation
--     → MAX+1 재계산 → 재시도 (최대 5회) 루프로 감쌈
--   - 정상 케이스 동작 100% 동일 (예외 발생 시만 retry)
-- 회귀:
--   - admin.html / 기존 RPC 호출부 변경 불요
--   - 시그니처·반환 동일
-- ============================================================================

CREATE OR REPLACE FUNCTION rpc_create_quotation(
  _customer_id UUID,
  _사업부 VARCHAR,
  _제목 VARCHAR,
  _수신 JSONB DEFAULT '{}'::jsonb,
  _items JSONB DEFAULT '[]'::jsonb,
  _options JSONB DEFAULT '{}'::jsonb,
  _parent_id UUID DEFAULT NULL
)
RETURNS TABLE(
  id UUID,
  견적번호 VARCHAR,
  수정차수 INT,
  견적금액 BIGINT,
  사업부 VARCHAR,
  상태 VARCHAR,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  _new_id UUID;
  _new_no VARCHAR;
  _new_version INT;
  _next_no INT;
  _견적금액 BIGINT;
  _작성자 VARCHAR;
  _prefix VARCHAR;
  _year INT;
  _lock_key BIGINT;
  _retry_count INT := 0;
  _max_retry INT := 5;
  _success BOOLEAN := FALSE;
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

  -- 견적금액 = 본문 항목 합계
  SELECT COALESCE(SUM((item->>'금액')::BIGINT), 0)
    INTO _견적금액
    FROM jsonb_array_elements(COALESCE(_items, '[]'::jsonb)) AS item;

  -- advisory lock 키 = hash(사업부 + 연도)
  _lock_key := hashtext(_prefix || '_' || _year::TEXT);
  PERFORM pg_advisory_xact_lock(_lock_key);

  -- ========================================================================
  -- 재견적 분기 (parent 견적번호 상속)
  -- ========================================================================
  IF _parent_id IS NOT NULL THEN
    SELECT q.견적번호, COALESCE(MAX(qx.수정차수), 1) + 1
      INTO _new_no, _new_version
      FROM quotations q
      LEFT JOIN quotations qx ON qx.parent_quotation_id = _parent_id OR qx.id = _parent_id
      WHERE q.id = _parent_id
      GROUP BY q.견적번호;
    IF NOT FOUND THEN
      RAISE EXCEPTION '부모 견적을 찾을 수 없습니다: %', _parent_id;
    END IF;

    -- 재견적은 동일 견적번호 + 다른 수정차수이므로 INSERT (unique 제약 검토 필요)
    INSERT INTO quotations(
      customer_id, 견적번호, 수정차수, 견적금액, 유효기간, 결제조건,
      세부항목, 상태, 작성자, parent_quotation_id, 사업부, 제목,
      수신_회사명, 수신_부서, 수신_담당자, 수신_직위,
      대행료율, 대행료_표기, vat_표기, 절사_단위, 판매가_컬럼,
      비고, 첨부_옵션, is_government
    )
    VALUES (
      _customer_id, _new_no, _new_version, _견적금액,
      (now() + INTERVAL '30 days')::DATE,
      COALESCE(_options ->> '결제조건', NULL),
      _items, '작성중', _작성자, _parent_id, _사업부, _제목,
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
  ELSE
    -- ======================================================================
    -- 신규 채번 + retry-on-conflict (최대 5회)
    -- ======================================================================
    WHILE _retry_count < _max_retry AND NOT _success LOOP
      -- 채번: 해당 사업부 + 연도 MAX + 1 (parent_quotation_id IS NULL 만)
      SELECT COALESCE(MAX(
        CASE WHEN q.견적번호 ~ ('^Q-' || _prefix || '-' || _year || '-([0-9]+)$') THEN
          (regexp_match(q.견적번호, ('^Q-' || _prefix || '-' || _year || '-([0-9]+)$')))[1]::INT
        ELSE 0 END
      ), 0) + 1 + _retry_count
      INTO _next_no
      FROM quotations q
      WHERE q.사업부 = _사업부
        AND EXTRACT(YEAR FROM q.created_at) = _year
        AND q.parent_quotation_id IS NULL;

      _new_no := 'Q-' || _prefix || '-' || _year || '-' || LPAD(_next_no::TEXT, 3, '0');
      _new_version := 1;

      BEGIN
        INSERT INTO quotations(
          customer_id, 견적번호, 수정차수, 견적금액, 유효기간, 결제조건,
          세부항목, 상태, 작성자, parent_quotation_id, 사업부, 제목,
          수신_회사명, 수신_부서, 수신_담당자, 수신_직위,
          대행료율, 대행료_표기, vat_표기, 절사_단위, 판매가_컬럼,
          비고, 첨부_옵션, is_government
        )
        VALUES (
          _customer_id, _new_no, _new_version, _견적금액,
          (now() + INTERVAL '30 days')::DATE,
          COALESCE(_options ->> '결제조건', NULL),
          _items, '작성중', _작성자, NULL, _사업부, _제목,
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
        _success := TRUE;
      EXCEPTION
        WHEN unique_violation THEN
          _retry_count := _retry_count + 1;
          IF _retry_count >= _max_retry THEN
            RAISE EXCEPTION '견적번호 채번 % 회 재시도 후에도 실패 (사업부=%, 연도=%, 마지막 시도=%)',
              _max_retry, _사업부, _year, _new_no;
          END IF;
          -- 다음 루프에서 _next_no + 1 시도
      END;
    END LOOP;
  END IF;

  -- 결과 반환
  RETURN QUERY
    SELECT q.id, q.견적번호, q.수정차수, q.견적금액, q.사업부, q.상태, q.created_at
      FROM quotations q
      WHERE q.id = _new_id;
END;
$$;

-- GRANT (기존 정합)
GRANT EXECUTE ON FUNCTION rpc_create_quotation(UUID, VARCHAR, VARCHAR, JSONB, JSONB, JSONB, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION rpc_create_quotation(UUID, VARCHAR, VARCHAR, JSONB, JSONB, JSONB, UUID) TO service_role;

-- ============================================================================
-- 검증 쿼리 (라이브 적용 후)
-- ============================================================================
-- (1) 정상 동작 확인
-- SELECT * FROM rpc_create_quotation(
--   _customer_id := (SELECT id FROM customers LIMIT 1),
--   _사업부 := '국내여행',
--   _제목 := 'sql/045 retry 검증',
--   _items := '[]'::jsonb
-- );
--
-- (2) duplicate 강제 재현 (테스트 후 ROLLBACK)
-- BEGIN;
-- INSERT INTO quotations(customer_id, 견적번호, 수정차수, 사업부, 제목, 작성자, 견적금액)
--   VALUES ((SELECT id FROM customers LIMIT 1), 'Q-TOUR-2026-099', 1, '국내여행', '강제충돌', 'test', 0);
-- -- 이 상태에서 RPC 호출 → 099 충돌 → 100으로 retry → 성공
-- SELECT * FROM rpc_create_quotation(...);
-- ROLLBACK;
-- ============================================================================
