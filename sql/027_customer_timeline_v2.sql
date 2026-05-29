-- ========================================================================
-- sql/027 rpc_customer_timeline v2 (6번째 이벤트 = 공문 추가)
-- 작성: 2026-05-01 / 26차 회기
-- 기존 sql/009 (5이벤트) → 6이벤트로 확장
--   1) note (consultation_notes)
--   2) status (status_history)
--   3) quotation (quotations)
--   4) contract (contracts)
--   5) field_change (customer_field_history)
--   6) official_doc (official_documents) ← 신규
-- 의존: sql/026 (official_documents 테이블) 적용 후 실행
-- ========================================================================

CREATE OR REPLACE FUNCTION public.rpc_customer_timeline(
  _customer_id uuid,
  _limit integer DEFAULT 30,
  _offset integer DEFAULT 0
)
  RETURNS TABLE(
    event_id uuid,
    event_type text,
    event_at timestamptz,
    "작성자" text,
    "제목" text,
    "상세" text,
    meta jsonb,
    total_count bigint
  )
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'public'
AS $function$
#variable_conflict use_column
DECLARE
  _total bigint;
BEGIN
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  IF _customer_id IS NULL THEN
    RAISE EXCEPTION 'customer_id is required';
  END IF;

  IF _limit IS NULL OR _limit <= 0 OR _limit > 200 THEN _limit := 30; END IF;
  IF _offset IS NULL OR _offset < 0 THEN _offset := 0; END IF;

  -- 6 이벤트 합계 (note + status + quotation + contract + field_change + official_doc)
  SELECT
    (SELECT COUNT(*) FROM consultation_notes      n WHERE n.customer_id = _customer_id) +
    (SELECT COUNT(*) FROM status_history          s WHERE s.customer_id = _customer_id) +
    (SELECT COUNT(*) FROM quotations              q WHERE q.customer_id = _customer_id) +
    (SELECT COUNT(*) FROM contracts               c WHERE c.customer_id = _customer_id) +
    (SELECT COUNT(*) FROM customer_field_history  f WHERE f.customer_id = _customer_id) +
    (SELECT COUNT(*) FROM official_documents      o WHERE o.customer_id = _customer_id)
  INTO _total;

  RETURN QUERY
  WITH unified AS (
    -- 1) 상담 메모
    SELECT
      n.id AS event_id,
      'note'::text AS event_type,
      n.created_at AS event_at,
      n."작성자"::text AS 작성자,
      (CASE
         WHEN length(coalesce(n."메모", '')) <= 30 THEN coalesce(n."메모", '')
         ELSE substr(n."메모", 1, 30) || '...'
       END)::text AS 제목,
      coalesce(n."메모", '')::text AS 상세,
      jsonb_build_object('버전', n."버전", '사업부', n."사업부", 'updated_at', n.updated_at) AS meta
    FROM public.consultation_notes n
    WHERE n.customer_id = _customer_id

    UNION ALL

    -- 2) 상태 변경
    SELECT
      s.id AS event_id,
      'status'::text AS event_type,
      s.created_at AS event_at,
      s."변경자"::text AS 작성자,
      (coalesce(s."이전상태", '(시작)') || ' → ' || s."다음상태")::text AS 제목,
      coalesce(s."변경사유", '')::text AS 상세,
      jsonb_build_object(
        '이전상태', s."이전상태",
        '다음상태', s."다음상태",
        'ip_address', s.ip_address::text
      ) AS meta
    FROM public.status_history s
    WHERE s.customer_id = _customer_id

    UNION ALL

    -- 3) 견적
    SELECT
      q.id AS event_id,
      'quotation'::text AS event_type,
      coalesce(q."발송일시", q.created_at) AS event_at,
      q."작성자"::text AS 작성자,
      ('견적 ' || coalesce(q."상태", '작성중') || ': ' || q."견적번호" || ' / ' ||
       to_char(q."견적금액", 'FM999,999,999') || '원')::text AS 제목,
      ('수정차수 ' || q."수정차수" || '차 / 발송 ' ||
       CASE WHEN q."발송여부" THEN '완료' ELSE '미발송' END ||
       CASE WHEN q.유효기간 IS NOT NULL
            THEN ' / 유효 ' || to_char(q.유효기간, 'YYYY-MM-DD')
            ELSE '' END)::text AS 상세,
      jsonb_build_object(
        '견적번호', q."견적번호",
        '수정차수', q."수정차수",
        '상태', q."상태",
        '견적금액', q."견적금액"
      ) AS meta
    FROM public.quotations q
    WHERE q.customer_id = _customer_id

    UNION ALL

    -- 4) 계약
    SELECT
      c.id AS event_id,
      'contract'::text AS event_type,
      coalesce(c."발송일시", c.created_at) AS event_at,
      c."작성자"::text AS 작성자,
      ('계약 ' || coalesce(c."상태", '작성중') || ': ' || c."계약번호" || ' / ' ||
       to_char(c."계약금액", 'FM999,999,999') || '원')::text AS 제목,
      ('서명 ' || coalesce(c."서명상태", '미서명') ||
       ' / ' || to_char(c."계약기간_시작", 'YYYY-MM-DD') ||
       ' ~ ' || to_char(c."계약기간_종료", 'YYYY-MM-DD'))::text AS 상세,
      jsonb_build_object(
        '계약번호', c."계약번호",
        '서명상태', c."서명상태",
        '상태', c."상태",
        '계약금액', c."계약금액"
      ) AS meta
    FROM public.contracts c
    WHERE c.customer_id = _customer_id

    UNION ALL

    -- 5) 필드 변경 이력
    SELECT
      f.id AS event_id,
      'field_change'::text AS event_type,
      f.created_at AS event_at,
      f."변경자"::text AS 작성자,
      (f."변경필드" || ' 변경: ' ||
       coalesce(nullif(left(coalesce(f."이전값", '(없음)'), 20), ''), '(없음)') ||
       ' → ' ||
       coalesce(nullif(left(coalesce(f."새값", '(없음)'), 20), ''), '(없음)'))::text AS 제목,
      ('이전값: ' || coalesce(f."이전값", '(없음)') || E'\n' ||
       '새값: '   || coalesce(f."새값",   '(없음)'))::text AS 상세,
      jsonb_build_object(
        '변경필드', f."변경필드",
        '이전값', f."이전값",
        '새값', f."새값",
        'ip_address', f.ip_address::text
      ) AS meta
    FROM public.customer_field_history f
    WHERE f.customer_id = _customer_id

    UNION ALL

    -- 6) 공문 (sql/026 신규 / 26차)
    SELECT
      o.id AS event_id,
      'official_doc'::text AS event_type,
      coalesce(o."발송일시", o.created_at) AS event_at,
      o."작성자"::text AS 작성자,
      (o."공문종류" || ' ' || coalesce(o."상태", '작성중') || ': ' ||
       coalesce(o."계약번호", '미발급') || ' / ' || coalesce(o."계약명", '용역명 미정'))::text AS 제목,
      ('사업부: ' || o."사업부" ||
       CASE WHEN o."발주처" IS NOT NULL THEN ' / 발주처: ' || o."발주처" ELSE '' END ||
       CASE WHEN o."계약금액" IS NOT NULL
            THEN ' / 계약금액: ' || to_char(o."계약금액", 'FM999,999,999') || '원'
            ELSE '' END)::text AS 상세,
      jsonb_build_object(
        '공문종류', o."공문종류",
        '사업부', o."사업부",
        '계약명', o."계약명",
        '계약번호', o."계약번호",
        '발주처', o."발주처",
        '상태', o."상태",
        '템플릿버전', o."템플릿버전"
      ) AS meta
    FROM public.official_documents o
    WHERE o.customer_id = _customer_id
  )
  SELECT
    u.event_id,
    u.event_type,
    u.event_at,
    u.작성자,
    u.제목,
    u.상세,
    u.meta,
    _total AS total_count
  FROM unified u
  ORDER BY u.event_at DESC
  LIMIT _limit OFFSET _offset;
END;
$function$;

GRANT EXECUTE ON FUNCTION public.rpc_customer_timeline(uuid,integer,integer) TO authenticated;

-- ========================================================================
-- 검증 쿼리 (라이브 적용 후)
-- ========================================================================
-- SELECT * FROM public.rpc_customer_timeline(
--   (SELECT id FROM public.customers LIMIT 1)::uuid, 30, 0
-- );
