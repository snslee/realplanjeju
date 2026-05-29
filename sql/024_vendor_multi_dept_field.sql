-- ============================================================
-- sql/024_vendor_multi_dept_field.sql
-- v2.13.4 묶음 4 거래처 (B-1) 사전 마이그레이션
-- 적용일: 2026-04-30 (25차 회기)
--
-- 변경 사항:
-- 1) 사업부분류 (단일 string) → 사업부분류_목록 (ARRAY) — 다중 사업부 적용
-- 2) 카테고리_id (FK) → 거래처_분야 (자유 텍스트 + datalist 추천) — 명칭 변경
-- 3) rpc_list_vendors v2 — 다중 사업부 검색 + 거래처 분야 검색
-- 4) rpc_upsert_vendor v2 — 새 컬럼 처리
--
-- 정합 원칙: §9 과잉 설계 금지 / §11 확장 가능성 보존 / §13 학습 산출물 즉시 반영
-- 기존 컬럼 (사업부분류·카테고리_id)은 deprecated 보존 (다음 회기에 제거)
-- ============================================================

-- ─── (1) 사업부분류_목록 ARRAY 컬럼 추가 ───
ALTER TABLE public.vd_vendors
  ADD COLUMN IF NOT EXISTS 사업부분류_목록 character varying[];

COMMENT ON COLUMN public.vd_vendors.사업부분류_목록 IS
  '사업부 다중 적용 (ARRAY) — 한 거래처가 여러 사업부에서 활용 가능. v2.13.4 신규 / sql/024';

-- 기존 단일 string 데이터 → ARRAY (single-element)
UPDATE public.vd_vendors
SET 사업부분류_목록 = ARRAY[사업부분류]::character varying[]
WHERE 사업부분류 IS NOT NULL AND 사업부분류_목록 IS NULL;

-- CHECK 제약 (모든 element가 5개 값 중 하나)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'vd_vendors_사업부분류_목록_check'
      AND conrelid = 'public.vd_vendors'::regclass
  ) THEN
    ALTER TABLE public.vd_vendors
      ADD CONSTRAINT vd_vendors_사업부분류_목록_check
      CHECK (
        사업부분류_목록 IS NULL OR
        사업부분류_목록 <@ ARRAY['국내여행','행사이벤트','온라인마케팅','마케팅교육','공통']::character varying[]
      );
  END IF;
END $$;

-- ─── (2) 거래처_분야 자유 텍스트 컬럼 추가 ───
ALTER TABLE public.vd_vendors
  ADD COLUMN IF NOT EXISTS 거래처_분야 character varying;

COMMENT ON COLUMN public.vd_vendors.거래처_분야 IS
  '거래처 분야 자유 텍스트 + datalist 추천 (vd_categories 9개 추천 / 자유 입력 가능). v2.13.4 신규 / sql/024';

-- 기존 카테고리_id (FK) → 거래처_분야 (텍스트) 마이그레이션
UPDATE public.vd_vendors v
SET 거래처_분야 = c.카테고리명
FROM public.vd_categories c
WHERE v.카테고리_id = c.id AND v.거래처_분야 IS NULL;


-- ─── (3) rpc_list_vendors v2 — 다중 사업부 + 거래처 분야 검색 ───
CREATE OR REPLACE FUNCTION public.rpc_list_vendors(
  _search text DEFAULT NULL,
  _bu_list character varying[] DEFAULT NULL,   -- 다중 사업부 (ANY 매칭)
  _분야 text DEFAULT NULL,                       -- 거래처 분야 (LIKE 검색)
  _active_only boolean DEFAULT true,
  _limit integer DEFAULT 50,
  _offset integer DEFAULT 0
)
RETURNS TABLE(
  r_id uuid,
  r_거래처명 character varying,
  r_사업자번호 character varying,
  r_대표자 character varying,
  r_사업부분류_목록 character varying[],
  r_거래처_분야 character varying,
  r_전화 character varying,
  r_이메일 character varying,
  r_is_active boolean,
  r_담당자_primary text,
  r_담당자_count integer,
  r_total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  RETURN QUERY
  WITH base AS (
    SELECT v.*
    FROM public.vd_vendors v
    WHERE (NOT _active_only OR v.is_active = true)
      AND v.deleted_at IS NULL
      AND (
        _search IS NULL OR _search = '' OR
        v.거래처명::text ILIKE '%' || _search || '%' OR
        v.사업자번호 ILIKE '%' || _search || '%' OR
        v.대표자 ILIKE '%' || _search || '%' OR
        v.전화 ILIKE '%' || _search || '%' OR
        v.이메일 ILIKE '%' || _search || '%'
      )
      AND (
        _bu_list IS NULL OR
        array_length(_bu_list, 1) IS NULL OR
        v.사업부분류_목록 && _bu_list  -- 교집합 (어느 하나라도 매칭)
      )
      AND (
        _분야 IS NULL OR _분야 = '' OR
        v.거래처_분야 ILIKE '%' || _분야 || '%'
      )
  ),
  cnt AS (SELECT COUNT(*) AS total FROM base)
  SELECT
    b.id,
    b.거래처명,
    b.사업자번호,
    b.대표자,
    b.사업부분류_목록,
    b.거래처_분야,
    b.전화,
    b.이메일,
    b.is_active,
    (SELECT c.담당자명::text FROM public.vd_contacts c WHERE c.vendor_id = b.id AND c.is_primary = true LIMIT 1),
    (SELECT COUNT(*)::integer FROM public.vd_contacts c WHERE c.vendor_id = b.id),
    (SELECT total FROM cnt)
  FROM base b
  ORDER BY b.거래처명 ASC
  LIMIT _limit OFFSET _offset;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_list_vendors(text, character varying[], text, boolean, integer, integer) TO authenticated, service_role;

-- 기존 시그니처 deprecated (호환 유지 — 다음 회기에 제거)
-- rpc_list_vendors(text, character varying, uuid, boolean, integer, integer) — 보존


-- ─── (4) rpc_upsert_vendor v2 — 새 컬럼 처리 ───
CREATE OR REPLACE FUNCTION public.rpc_upsert_vendor(_payload jsonb)
RETURNS TABLE(
  r_id uuid,
  r_거래처명 character varying,
  r_action text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _id uuid;
  _action text;
  _bu_arr character varying[];
BEGIN
  -- 사업부분류_목록 jsonb array → text[] 변환
  IF _payload ? '사업부분류_목록' AND jsonb_typeof(_payload->'사업부분류_목록') = 'array' THEN
    SELECT ARRAY(SELECT jsonb_array_elements_text(_payload->'사업부분류_목록'))::character varying[] INTO _bu_arr;
  ELSE
    _bu_arr := NULL;
  END IF;

  IF _payload ? 'id' AND (_payload->>'id') IS NOT NULL AND (_payload->>'id') <> '' THEN
    -- UPDATE
    _id := (_payload->>'id')::uuid;
    UPDATE public.vd_vendors SET
      거래처명 = COALESCE(_payload->>'거래처명', 거래처명),
      사업자번호 = _payload->>'사업자번호',
      대표자 = _payload->>'대표자',
      업태 = _payload->>'업태',
      종목 = _payload->>'종목',
      사업부분류_목록 = COALESCE(_bu_arr, 사업부분류_목록),
      거래처_분야 = _payload->>'거래처_분야',
      전화 = _payload->>'전화',
      이메일 = _payload->>'이메일',
      팩스 = _payload->>'팩스',
      주소 = _payload->>'주소',
      계좌_은행 = _payload->>'계좌_은행',
      계좌_번호 = _payload->>'계좌_번호',
      계좌_예금주 = _payload->>'계좌_예금주',
      세금계산서_이메일 = _payload->>'세금계산서_이메일',
      결제조건 = _payload->>'결제조건',
      메모 = _payload->>'메모',
      태그 = COALESCE(
        CASE WHEN _payload ? '태그' AND jsonb_typeof(_payload->'태그') = 'array'
          THEN ARRAY(SELECT jsonb_array_elements_text(_payload->'태그'))::text[]
          ELSE NULL END,
        태그
      ),
      updated_at = now()
    WHERE id = _id;
    _action := 'update';
  ELSE
    -- INSERT
    INSERT INTO public.vd_vendors (
      거래처명, 사업자번호, 대표자, 업태, 종목,
      사업부분류_목록, 거래처_분야,
      전화, 이메일, 팩스, 주소,
      계좌_은행, 계좌_번호, 계좌_예금주, 세금계산서_이메일, 결제조건,
      메모, 태그, is_active
    ) VALUES (
      _payload->>'거래처명',
      _payload->>'사업자번호',
      _payload->>'대표자',
      _payload->>'업태',
      _payload->>'종목',
      _bu_arr,
      _payload->>'거래처_분야',
      _payload->>'전화',
      _payload->>'이메일',
      _payload->>'팩스',
      _payload->>'주소',
      _payload->>'계좌_은행',
      _payload->>'계좌_번호',
      _payload->>'계좌_예금주',
      _payload->>'세금계산서_이메일',
      _payload->>'결제조건',
      _payload->>'메모',
      CASE WHEN _payload ? '태그' AND jsonb_typeof(_payload->'태그') = 'array'
        THEN ARRAY(SELECT jsonb_array_elements_text(_payload->'태그'))::text[]
        ELSE NULL END,
      true
    ) RETURNING id INTO _id;
    _action := 'insert';
  END IF;

  RETURN QUERY
  SELECT v.id, v.거래처명, _action FROM public.vd_vendors v WHERE v.id = _id;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_vendor(jsonb) TO authenticated, service_role;


-- ─── (5) rpc_get_vendor v2 — 새 컬럼 반환 ───
CREATE OR REPLACE FUNCTION public.rpc_get_vendor(_id uuid)
RETURNS TABLE(
  r_id uuid,
  r_거래처명 character varying,
  r_사업자번호 character varying,
  r_대표자 character varying,
  r_업태 character varying,
  r_종목 character varying,
  r_사업부분류_목록 character varying[],
  r_거래처_분야 character varying,
  r_전화 character varying,
  r_이메일 character varying,
  r_팩스 character varying,
  r_주소 character varying,
  r_계좌_은행 character varying,
  r_계좌_번호 character varying,
  r_계좌_예금주 character varying,
  r_세금계산서_이메일 character varying,
  r_결제조건 character varying,
  r_태그 text[],
  r_메모 text,
  r_is_active boolean,
  r_created_at timestamptz,
  r_updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  RETURN QUERY
  SELECT v.id, v.거래처명, v.사업자번호, v.대표자, v.업태, v.종목,
    v.사업부분류_목록, v.거래처_분야,
    v.전화, v.이메일, v.팩스, v.주소,
    v.계좌_은행, v.계좌_번호, v.계좌_예금주, v.세금계산서_이메일, v.결제조건,
    v.태그, v.메모, v.is_active, v.created_at, v.updated_at
  FROM public.vd_vendors v
  WHERE v.id = _id AND v.deleted_at IS NULL;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_get_vendor(uuid) TO authenticated, service_role;
