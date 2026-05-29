-- ========================================================================
-- sql/026 official_documents (공문 4종 통합 / v8 widget 정합)
-- 작성: 2026-05-01 / 26차 회기
-- 정책: 옵션 A (단계별 명칭 통일)
--   - 계약·실행 (착수계·완료계) → 출력 라벨 "용역명"
--   - 보고·정산 (결과보고서·정산결과보고서) → 출력 라벨 "사업명"
--   - DB 컬럼 = 계약명 (1 사업 = 1 마스터 / contracts FK 자동 복사)
-- 적용 범위: 4사업부 (국내여행·행사이벤트·온라인마케팅·마케팅교육·컨설팅)
-- 발신부: 4종 통일 / 팩스 번호 X / 업종 자동 매핑
-- ========================================================================

-- ────────────────────────────────────────
-- 1. 테이블
-- ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.official_documents (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- 관계 (1 고객 → 1 사업 → 1 계약번호 통일 정책)
  customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE RESTRICT,
  contract_id uuid REFERENCES public.contracts(id) ON DELETE SET NULL,
  quotation_id uuid REFERENCES public.quotations(id) ON DELETE SET NULL,

  -- 공문 메타
  공문종류 varchar(20) NOT NULL CHECK (공문종류 IN ('착수계','완료계','결과보고서','정산결과보고서')),
  사업부 varchar(20) NOT NULL CHECK (사업부 IN ('국내여행','행사이벤트','온라인마케팅','마케팅교육·컨설팅')),

  -- 계약 정보 (contracts에서 자동 복사 / 수정 가능)
  계약명 varchar(200) NOT NULL,
  계약번호 varchar(50),
  계약기간_시작 date,
  계약기간_종료 date,
  계약금액 bigint,

  -- 발주처 (수신처)
  발주처 varchar(200),

  -- 발신부 메타 (회사 표준 / 4종 통일)
  발신일자 date NOT NULL DEFAULT CURRENT_DATE,
  발신자_사업자번호 varchar(20) DEFAULT '819-87-02344',
  발신자_업종 varchar(100),
  발신자_주소 varchar(200) DEFAULT '제주특별자치도 제주시 제원1길 5(연동)',
  발신자_연락처 varchar(100) DEFAULT '1577-2296 | realplan01@naver.com',
  발신자_회사명 varchar(50) DEFAULT '리얼플랜제주(주)',
  발신자_대표 varchar(50) DEFAULT '이동환·김현숙',

  -- 자유 편집 본문 (양식별 다른 구조 통합 저장)
  자유편집_본문 jsonb,

  -- 착수계 전용
  제출서류_체크 jsonb DEFAULT '{"착수신고서":false,"용역공정예정표":false,"용역책임자선임계":false,"용역참여인력명단":false,"보안각서":false}'::jsonb,

  -- 완료계 전용 (본문 6항목 / 새 순서: 1.용역명·2.계약번호·3.금액·4.계약일·5.완료기한·6.완료일)
  완료기한 date,
  완료일자 date,
  결과물_목록 jsonb,

  -- 결과보고서 전용
  보고서_요약 text,
  목차_본문 jsonb,
  정산_내역 jsonb,
  첨부이미지_URL text[],

  -- 정산결과보고서 전용
  한글금액_계약 varchar(100),
  한글금액_완료 varchar(100),
  착수일 date,
  세부_정산 jsonb,
  잔액처리 varchar(50),

  -- 공통
  pdf_url text,
  상태 varchar(20) DEFAULT '작성중' CHECK (상태 IN ('작성중','발송완료','수신확인','보관')),
  발송일시 timestamptz,
  템플릿버전 varchar(20) DEFAULT 'v1.0',
  작성자 varchar(100) NOT NULL,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

COMMENT ON TABLE public.official_documents IS '공문 4종 (착수계·완료계·결과보고서·정산결과보고서) / 26차 신규';
COMMENT ON COLUMN public.official_documents.계약명 IS 'DB 키 / PDF 출력 시 양식별 라벨 분기 (계약·실행=용역명 / 보고·정산=사업명)';

-- ────────────────────────────────────────
-- 2. 인덱스
-- ────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_offdoc_customer ON public.official_documents(customer_id);
CREATE INDEX IF NOT EXISTS idx_offdoc_contract ON public.official_documents(contract_id);
CREATE INDEX IF NOT EXISTS idx_offdoc_종류 ON public.official_documents(공문종류);
CREATE INDEX IF NOT EXISTS idx_offdoc_사업부 ON public.official_documents(사업부);
CREATE INDEX IF NOT EXISTS idx_offdoc_상태 ON public.official_documents(상태);
CREATE INDEX IF NOT EXISTS idx_offdoc_발신일자 ON public.official_documents(발신일자 DESC);

-- ────────────────────────────────────────
-- 3. RLS
-- ────────────────────────────────────────
ALTER TABLE public.official_documents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS offdoc_admin_all ON public.official_documents;
CREATE POLICY offdoc_admin_all ON public.official_documents
  FOR ALL TO authenticated
  USING (public.fn_current_is_admin())
  WITH CHECK (public.fn_current_is_admin());

-- ────────────────────────────────────────
-- 4. 트리거: updated_at 자동 갱신
-- ────────────────────────────────────────
DROP TRIGGER IF EXISTS trg_offdoc_updated ON public.official_documents;
CREATE TRIGGER trg_offdoc_updated
  BEFORE UPDATE ON public.official_documents
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ────────────────────────────────────────
-- 5. 사업부 → 업종 자동 매핑 함수 (4사업부 표준)
-- ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_업종_by_사업부(_dept text)
  RETURNS text
  LANGUAGE sql
  IMMUTABLE
AS $$
  SELECT CASE _dept
    WHEN '행사이벤트' THEN '행사기획 및 운영업'
    WHEN '국내여행' THEN '국내여행업 / 일반여행업'
    WHEN '온라인마케팅' THEN '온라인홍보 및 광고대행업'
    WHEN '마케팅교육·컨설팅' THEN '마케팅 대행/교육/컨설팅'
    ELSE NULL
  END;
$$;

COMMENT ON FUNCTION public.fn_업종_by_사업부(text) IS '4사업부 표준 업종 자동 매핑';

-- ────────────────────────────────────────
-- 6. 트리거: 계약 정보 + 업종 자동 채움
-- ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.trg_offdoc_autofill()
  RETURNS trigger
  LANGUAGE plpgsql
AS $$
BEGIN
  -- 업종 자동 매핑 (NULL이면 사업부에서 추출)
  IF NEW.발신자_업종 IS NULL OR NEW.발신자_업종 = '' THEN
    NEW.발신자_업종 := public.fn_업종_by_사업부(NEW.사업부);
  END IF;

  -- 계약 정보 자동 복사 (contract_id 있고 비어있을 때만)
  IF NEW.contract_id IS NOT NULL AND COALESCE(NEW.계약명, '') = '' THEN
    SELECT
      c."계약명",
      c."계약번호",
      c."계약기간_시작",
      c."계약기간_종료",
      c."계약금액"
    INTO
      NEW.계약명,
      NEW.계약번호,
      NEW.계약기간_시작,
      NEW.계약기간_종료,
      NEW.계약금액
    FROM public.contracts c
    WHERE c.id = NEW.contract_id;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_offdoc_before_iu ON public.official_documents;
CREATE TRIGGER trg_offdoc_before_iu
  BEFORE INSERT OR UPDATE ON public.official_documents
  FOR EACH ROW EXECUTE FUNCTION public.trg_offdoc_autofill();

-- ========================================================================
-- RPC 6종
-- ========================================================================

-- ────────────────────────────────────────
-- RPC 1: rpc_create_official_doc
-- ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_create_official_doc(
  _customer_id uuid,
  _contract_id uuid DEFAULT NULL,
  _quotation_id uuid DEFAULT NULL,
  _공문종류 text DEFAULT '착수계',
  _사업부 text DEFAULT NULL,
  _계약명 text DEFAULT NULL,
  _발주처 text DEFAULT NULL,
  _자유편집_본문 jsonb DEFAULT NULL
)
  RETURNS TABLE(r_id uuid, r_계약명 text, r_계약번호 text)
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $$
DECLARE
  _new_id uuid;
  _작성자 text;
BEGIN
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  IF _customer_id IS NULL THEN
    RAISE EXCEPTION 'customer_id is required';
  END IF;

  -- 작성자 = 현재 로그인 사용자
  SELECT u."이름" INTO _작성자
  FROM public.users u
  WHERE u.id = auth.uid();

  INSERT INTO public.official_documents (
    customer_id, contract_id, quotation_id,
    공문종류, 사업부, 계약명, 발주처, 자유편집_본문, 작성자
  )
  VALUES (
    _customer_id, _contract_id, _quotation_id,
    _공문종류, _사업부, COALESCE(_계약명, ''), _발주처, _자유편집_본문, _작성자
  )
  RETURNING id INTO _new_id;

  RETURN QUERY
  SELECT od.id, od."계약명"::text, od."계약번호"::text
  FROM public.official_documents od
  WHERE od.id = _new_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_create_official_doc(uuid,uuid,uuid,text,text,text,text,jsonb) TO authenticated;

-- ────────────────────────────────────────
-- RPC 2: rpc_list_official_docs
-- ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_list_official_docs(
  _customer_id uuid DEFAULT NULL,
  _공문종류 text DEFAULT NULL,
  _상태 text DEFAULT NULL,
  _limit integer DEFAULT 30,
  _offset integer DEFAULT 0
)
  RETURNS TABLE(
    r_id uuid,
    r_공문종류 text,
    r_사업부 text,
    r_계약명 text,
    r_계약번호 text,
    r_발주처 text,
    r_상태 text,
    r_발신일자 date,
    r_발송일시 timestamptz,
    r_작성자 text,
    r_created_at timestamptz,
    r_total_count bigint
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $$
DECLARE
  _total bigint;
BEGIN
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  IF _limit IS NULL OR _limit <= 0 OR _limit > 200 THEN _limit := 30; END IF;
  IF _offset IS NULL OR _offset < 0 THEN _offset := 0; END IF;

  SELECT COUNT(*) INTO _total
  FROM public.official_documents od
  WHERE (_customer_id IS NULL OR od.customer_id = _customer_id)
    AND (_공문종류 IS NULL OR od."공문종류" = _공문종류)
    AND (_상태 IS NULL OR od."상태" = _상태);

  RETURN QUERY
  SELECT
    od.id,
    od."공문종류"::text,
    od."사업부"::text,
    od."계약명"::text,
    od."계약번호"::text,
    od."발주처"::text,
    od."상태"::text,
    od."발신일자",
    od."발송일시",
    od."작성자"::text,
    od.created_at,
    _total
  FROM public.official_documents od
  WHERE (_customer_id IS NULL OR od.customer_id = _customer_id)
    AND (_공문종류 IS NULL OR od."공문종류" = _공문종류)
    AND (_상태 IS NULL OR od."상태" = _상태)
  ORDER BY od.created_at DESC
  LIMIT _limit OFFSET _offset;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_list_official_docs(uuid,text,text,integer,integer) TO authenticated;

-- ────────────────────────────────────────
-- RPC 3: rpc_get_official_doc
-- ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_get_official_doc(_id uuid)
  RETURNS SETOF public.official_documents
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $$
BEGIN
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  RETURN QUERY
  SELECT * FROM public.official_documents WHERE id = _id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_get_official_doc(uuid) TO authenticated;

-- ────────────────────────────────────────
-- RPC 4: rpc_update_official_doc (작성중일 때만)
-- ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_update_official_doc(
  _id uuid,
  _patch jsonb
)
  RETURNS public.official_documents
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $$
DECLARE
  _row public.official_documents;
BEGIN
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  SELECT * INTO _row FROM public.official_documents WHERE id = _id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'official_document not found';
  END IF;

  IF _row."상태" <> '작성중' THEN
    RAISE EXCEPTION 'cannot update non-draft document (current status: %)', _row."상태";
  END IF;

  UPDATE public.official_documents SET
    계약명 = COALESCE(_patch->>'계약명', "계약명"),
    계약번호 = COALESCE(_patch->>'계약번호', "계약번호"),
    계약기간_시작 = COALESCE((_patch->>'계약기간_시작')::date, "계약기간_시작"),
    계약기간_종료 = COALESCE((_patch->>'계약기간_종료')::date, "계약기간_종료"),
    계약금액 = COALESCE((_patch->>'계약금액')::bigint, "계약금액"),
    발주처 = COALESCE(_patch->>'발주처', "발주처"),
    자유편집_본문 = COALESCE(_patch->'자유편집_본문', "자유편집_본문"),
    제출서류_체크 = COALESCE(_patch->'제출서류_체크', "제출서류_체크"),
    완료기한 = COALESCE((_patch->>'완료기한')::date, "완료기한"),
    완료일자 = COALESCE((_patch->>'완료일자')::date, "완료일자"),
    결과물_목록 = COALESCE(_patch->'결과물_목록', "결과물_목록"),
    보고서_요약 = COALESCE(_patch->>'보고서_요약', "보고서_요약"),
    목차_본문 = COALESCE(_patch->'목차_본문', "목차_본문"),
    정산_내역 = COALESCE(_patch->'정산_내역', "정산_내역"),
    한글금액_계약 = COALESCE(_patch->>'한글금액_계약', "한글금액_계약"),
    한글금액_완료 = COALESCE(_patch->>'한글금액_완료', "한글금액_완료"),
    착수일 = COALESCE((_patch->>'착수일')::date, "착수일"),
    세부_정산 = COALESCE(_patch->'세부_정산', "세부_정산"),
    잔액처리 = COALESCE(_patch->>'잔액처리', "잔액처리")
  WHERE id = _id
  RETURNING * INTO _row;

  RETURN _row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_update_official_doc(uuid,jsonb) TO authenticated;

-- ────────────────────────────────────────
-- RPC 5: rpc_send_official_doc (발송 / 상태 변경)
-- ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_send_official_doc(
  _id uuid,
  _pdf_url text DEFAULT NULL
)
  RETURNS public.official_documents
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $$
DECLARE
  _row public.official_documents;
BEGIN
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  UPDATE public.official_documents SET
    상태 = '발송완료',
    발송일시 = now(),
    pdf_url = COALESCE(_pdf_url, pdf_url)
  WHERE id = _id
    AND "상태" = '작성중'
  RETURNING * INTO _row;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'official_document not found or not in draft state';
  END IF;

  RETURN _row;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_send_official_doc(uuid,text) TO authenticated;

-- ────────────────────────────────────────
-- RPC 6: rpc_delete_official_doc (작성중·24h 이내만)
-- ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_delete_official_doc(_id uuid)
  RETURNS boolean
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $$
DECLARE
  _row public.official_documents;
BEGIN
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  SELECT * INTO _row FROM public.official_documents WHERE id = _id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'official_document not found';
  END IF;

  IF _row."상태" <> '작성중' THEN
    RAISE EXCEPTION 'cannot delete non-draft document';
  END IF;

  IF _row.created_at < now() - INTERVAL '24 hours' THEN
    RAISE EXCEPTION 'cannot delete document older than 24 hours';
  END IF;

  DELETE FROM public.official_documents WHERE id = _id;

  RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_delete_official_doc(uuid) TO authenticated;

-- ========================================================================
-- 검증 쿼리 (라이브 적용 후 실행)
-- ========================================================================
-- SELECT COUNT(*) FROM public.official_documents;
-- SELECT * FROM public.fn_업종_by_사업부('마케팅교육·컨설팅');
-- SELECT routine_name FROM information_schema.routines
--   WHERE routine_schema='public' AND routine_name LIKE 'rpc_%official%';
