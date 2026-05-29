-- ============================================================
-- 003_fix_list_customers_v2.sql
-- 작성일: 2026-04-25
-- 목적: rpc_list_customers RETURN TABLE ↔ SELECT 결과 mismatch 수정
-- 원인: 기존 RPC가 c.* + GREATEST(...)::INT 등을 SELECT하지만 RETURN TABLE 정의와 컬럼 갯수·타입이 불일치
-- 해결: 동일 시그니처 유지 + RETURN TABLE 명확 정의 + SELECT를 정확히 매칭
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_list_customers(
  _search text DEFAULT NULL,
  _status text[] DEFAULT NULL,
  _business_unit text[] DEFAULT NULL,
  _admin_email text DEFAULT NULL,
  _from_date timestamp with time zone DEFAULT NULL,
  _to_date timestamp with time zone DEFAULT NULL,
  _tags text[] DEFAULT NULL,
  _limit integer DEFAULT 20,
  _offset integer DEFAULT 0
)
RETURNS TABLE(
  id uuid,
  "접수번호" text,
  "회사명" text,
  "담당자명" text,
  "사업부" text,
  "고객상태" text,
  "내부담당자" text,
  "신청일시" timestamp with time zone,
  unresponsive_level text,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  _total bigint;
BEGIN
  -- 권한 체크 (admin만 호출 가능)
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION '권한 없음';
  END IF;

  -- Step 1: 필터 조건에 맞는 전체 건수 계산 (페이지네이션용)
  SELECT count(*) INTO _total
  FROM public.customers c
  WHERE c.deleted_at IS NULL
    AND (_search IS NULL OR (
      c."회사명"   ILIKE '%'||_search||'%'
      OR c."담당자명" ILIKE '%'||_search||'%'
      OR c."연락처"   ILIKE '%'||_search||'%'
      OR c."접수번호" ILIKE '%'||_search||'%'
    ))
    AND (_status         IS NULL OR c."고객상태"   = ANY (_status))
    AND (_business_unit  IS NULL OR c."사업부"    = ANY (_business_unit))
    AND (_admin_email    IS NULL OR c."내부담당자" = _admin_email)
    AND (_from_date      IS NULL OR c."신청일시"  >= _from_date)
    AND (_to_date        IS NULL OR c."신청일시"  <= _to_date)
    AND (_tags           IS NULL OR c."태그"      && _tags);

  -- Step 2: 페이지 데이터 + total_count 반환
  RETURN QUERY
  SELECT
    c.id,
    c."접수번호"::text,
    c."회사명"::text,
    c."담당자명"::text,
    c."사업부"::text,
    c."고객상태"::text,
    c."내부담당자"::text,
    c."신청일시",
    h.unresponsive_level::text,
    _total AS total_count
  FROM public.customers c
  LEFT JOIN public.v_customer_status_hints h ON h.id = c.id
  WHERE c.deleted_at IS NULL
    AND (_search IS NULL OR (
      c."회사명"   ILIKE '%'||_search||'%'
      OR c."담당자명" ILIKE '%'||_search||'%'
      OR c."연락처"   ILIKE '%'||_search||'%'
      OR c."접수번호" ILIKE '%'||_search||'%'
    ))
    AND (_status         IS NULL OR c."고객상태"   = ANY (_status))
    AND (_business_unit  IS NULL OR c."사업부"    = ANY (_business_unit))
    AND (_admin_email    IS NULL OR c."내부담당자" = _admin_email)
    AND (_from_date      IS NULL OR c."신청일시"  >= _from_date)
    AND (_to_date        IS NULL OR c."신청일시"  <= _to_date)
    AND (_tags           IS NULL OR c."태그"      && _tags)
  ORDER BY
    CASE
      WHEN h.unresponsive_level LIKE '%72%' THEN 1
      WHEN h.unresponsive_level LIKE '%48%' THEN 2
      WHEN h.unresponsive_level LIKE '%24%' THEN 3
      ELSE 4
    END,
    c."신청일시" DESC
  LIMIT _limit OFFSET _offset;
END;
$function$;

-- 권한 부여 (anon/authenticated 모두 호출 가능 — 함수 내 fn_current_is_admin이 진짜 차단)
GRANT EXECUTE ON FUNCTION public.rpc_list_customers(text, text[], text[], text, timestamp with time zone, timestamp with time zone, text[], integer, integer) TO anon, authenticated;

-- 검증 1: anon role에서는 권한 없음 에러 발생해야 함 (정상)
-- SELECT * FROM rpc_list_customers(NULL, NULL);
-- 기대: ERROR: 권한 없음

-- 검증 2: admin.html에서 호출 시 데이터 반환되어야 함 (브라우저에서 확인)
