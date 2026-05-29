-- ============================================================================
-- 010_field_history_and_update.sql
-- 작성일: 2026-04-25 (Day 4-1B)
-- 목적: 개요 탭 인라인 편집 모드 — 변경 감사 로그 + 인라인 수정 RPC + 타임라인 5번째 소스
-- 정책 베이스 (Day 4-1B 사전 점검 결정):
--   - 잠금 필드 4종: 접수번호·신청일시·동의_개인정보·고객상태 (별도 RPC)
--   - 변경 감사: customer_field_history 신규 테이블 (필드 1개 = row 1개)
--   - 동시 편집: 낙관적 락 (_expected_updated_at 비교)
--   - SECURITY DEFINER + fn_current_is_admin() (결정 #14)
--   - #variable_conflict use_column 디렉티브 (결정 #20)
-- 적용 방법: Supabase SQL Editor 에 전체 복사 → Run (Section 1~4 순차 자동 실행)
-- ============================================================================

-- ============================================================================
-- Section 1. customer_field_history 테이블 (변경 감사 로그)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.customer_field_history (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  customer_id uuid NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  변경필드    varchar(50) NOT NULL,
  이전값      text,
  새값        text,
  변경자      varchar(100) NOT NULL,
  ip_address  inet,
  user_agent  text,
  created_at  timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_field_history_customer ON public.customer_field_history(customer_id);
CREATE INDEX IF NOT EXISTS idx_field_history_date     ON public.customer_field_history(created_at DESC);

-- RLS
ALTER TABLE public.customer_field_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS admin_select_field_history ON public.customer_field_history;
CREATE POLICY admin_select_field_history ON public.customer_field_history
  FOR SELECT TO authenticated
  USING (public.fn_current_is_admin());

-- INSERT는 RPC에서만 (직접 차단)


-- ============================================================================
-- Section 2. rpc_update_customer — 인라인 편집 RPC
-- ============================================================================
-- 입력: _customer_id, _updates jsonb, _expected_updated_at timestamptz
-- 동작:
--   1) admin 검증
--   2) updated_at 일치 확인 (낙관적 락)
--   3) 잠금 필드 4종 변경 거부
--   4) 각 변경 필드별 customer_field_history INSERT
--   5) customers UPDATE
--   6) 새 row 반환
-- 반환: SETOF customers (1 row)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_update_customer(
  _customer_id          uuid,
  _updates              jsonb,
  _expected_updated_at  timestamptz
)
RETURNS SETOF public.customers
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
#variable_conflict use_column
DECLARE
  _email text;
  _current_updated_at timestamptz;
  _key text;
  _new_value text;
  _old_value text;
  _allowed_fields text[] := ARRAY[
    '구분','사업부','회사명','담당자명','연락처','이메일',
    '시작일','종료일','일정조율가능','희망지역','예산','유입경로',
    '요청사항','동의_콘텐츠','동의_마케팅','내부담당자','태그','비고'
  ];
  _locked_fields text[] := ARRAY[
    '접수번호','신청일시','동의_개인정보','고객상태','id',
    'created_at','updated_at','deleted_at','재문의여부','이전접수번호',
    '마지막접촉일시'
  ];
  _set_clauses text[] := ARRAY[]::text[];
  _change_count int := 0;
BEGIN
  -- 1) admin 검증
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  _email := lower(auth.jwt()->>'email');
  IF _email IS NULL OR _email = '' THEN
    RAISE EXCEPTION 'email not found in jwt';
  END IF;

  -- 2) 가드
  IF _customer_id IS NULL THEN
    RAISE EXCEPTION 'customer_id is required';
  END IF;
  IF _updates IS NULL OR jsonb_typeof(_updates) <> 'object' THEN
    RAISE EXCEPTION 'updates must be a json object';
  END IF;

  -- 3) 낙관적 락 — updated_at 일치 확인
  SELECT updated_at INTO _current_updated_at
    FROM public.customers
    WHERE id = _customer_id AND deleted_at IS NULL
    FOR UPDATE;
  IF _current_updated_at IS NULL THEN
    RAISE EXCEPTION 'customer not found or deleted';
  END IF;
  IF _expected_updated_at IS NOT NULL
     AND date_trunc('milliseconds', _current_updated_at)
       <> date_trunc('milliseconds', _expected_updated_at) THEN
    RAISE EXCEPTION 'concurrent edit detected (please reload)';
  END IF;

  -- 4) 변경 필드 검증 + 감사 로그 기록
  FOR _key IN SELECT jsonb_object_keys(_updates) LOOP
    -- 잠금 필드 거부
    IF _key = ANY(_locked_fields) THEN
      RAISE EXCEPTION 'field % is locked', _key;
    END IF;
    IF NOT (_key = ANY(_allowed_fields)) THEN
      RAISE EXCEPTION 'unknown field: %', _key;
    END IF;

    -- 이전값 조회 (text로 캐스팅)
    EXECUTE format(
      'SELECT (%I)::text FROM public.customers WHERE id = $1',
      _key
    ) INTO _old_value USING _customer_id;

    -- 새 값 (jsonb -> text)
    IF jsonb_typeof(_updates -> _key) = 'null' THEN
      _new_value := NULL;
    ELSIF jsonb_typeof(_updates -> _key) = 'array' THEN
      _new_value := (_updates -> _key)::text;  -- 태그 등 배열
    ELSE
      _new_value := _updates ->> _key;
    END IF;

    -- 동일값이면 skip
    IF _old_value IS NOT DISTINCT FROM _new_value THEN
      CONTINUE;
    END IF;

    -- 감사 로그 INSERT
    INSERT INTO public.customer_field_history
      (customer_id, 변경필드, 이전값, 새값, 변경자)
    VALUES
      (_customer_id, _key, _old_value, _new_value, _email);

    _change_count := _change_count + 1;
  END LOOP;

  -- 5) 변경 없으면 그냥 반환
  IF _change_count = 0 THEN
    RETURN QUERY SELECT * FROM public.customers WHERE id = _customer_id;
    RETURN;
  END IF;

  -- 6) 실제 UPDATE — JSONB merge 방식
  UPDATE public.customers c SET
    구분           = COALESCE((_updates ->> '구분')::varchar, c.구분),
    사업부         = COALESCE((_updates ->> '사업부')::varchar, c.사업부),
    회사명         = COALESCE((_updates ->> '회사명')::varchar, c.회사명),
    담당자명       = COALESCE((_updates ->> '담당자명')::varchar, c.담당자명),
    연락처         = COALESCE((_updates ->> '연락처')::varchar, c.연락처),
    이메일         = COALESCE((_updates ->> '이메일')::varchar, c.이메일),
    시작일         = CASE WHEN _updates ? '시작일'   THEN (_updates ->> '시작일')::date   ELSE c.시작일 END,
    종료일         = CASE WHEN _updates ? '종료일'   THEN (_updates ->> '종료일')::date   ELSE c.종료일 END,
    일정조율가능   = CASE WHEN _updates ? '일정조율가능' THEN (_updates ->> '일정조율가능')::boolean ELSE c.일정조율가능 END,
    희망지역       = COALESCE(_updates ->> '희망지역', c.희망지역),
    예산           = COALESCE(_updates ->> '예산', c.예산),
    유입경로       = COALESCE((_updates ->> '유입경로')::varchar, c.유입경로),
    요청사항       = CASE WHEN _updates ? '요청사항' THEN _updates ->> '요청사항' ELSE c.요청사항 END,
    동의_콘텐츠    = CASE WHEN _updates ? '동의_콘텐츠' THEN (_updates ->> '동의_콘텐츠')::boolean ELSE c.동의_콘텐츠 END,
    동의_마케팅    = CASE WHEN _updates ? '동의_마케팅' THEN (_updates ->> '동의_마케팅')::boolean ELSE c.동의_마케팅 END,
    내부담당자     = CASE WHEN _updates ? '내부담당자' THEN (_updates ->> '내부담당자')::varchar ELSE c.내부담당자 END,
    태그           = CASE WHEN _updates ? '태그'
                          THEN ARRAY(SELECT jsonb_array_elements_text(_updates -> '태그'))::text[]
                          ELSE c.태그 END,
    비고           = CASE WHEN _updates ? '비고' THEN _updates ->> '비고' ELSE c.비고 END,
    updated_at     = now()
  WHERE c.id = _customer_id;

  RETURN QUERY SELECT * FROM public.customers WHERE id = _customer_id;
END;
$$;

GRANT EXECUTE ON FUNCTION
  public.rpc_update_customer(uuid, jsonb, timestamptz)
  TO anon, authenticated;


-- ============================================================================
-- Section 3. rpc_customer_timeline — 5번째 소스(customer_field_history) 추가
-- ============================================================================
-- DROP 후 CREATE — UNION ALL 5단계로 확장
-- ============================================================================

DROP FUNCTION IF EXISTS public.rpc_customer_timeline(uuid, int, int);

CREATE OR REPLACE FUNCTION public.rpc_customer_timeline(
  _customer_id uuid,
  _limit       int DEFAULT 30,
  _offset      int DEFAULT 0
)
RETURNS TABLE (
  event_id    uuid,
  event_type  text,
  event_at    timestamptz,
  작성자      text,
  제목        text,
  상세        text,
  meta        jsonb,
  total_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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

  IF _limit IS NULL OR _limit <= 0 OR _limit > 200 THEN
    _limit := 30;
  END IF;
  IF _offset IS NULL OR _offset < 0 THEN
    _offset := 0;
  END IF;

  SELECT
    (SELECT COUNT(*) FROM consultation_notes      n WHERE n.customer_id = _customer_id) +
    (SELECT COUNT(*) FROM status_history          s WHERE s.customer_id = _customer_id) +
    (SELECT COUNT(*) FROM quotations              q WHERE q.customer_id = _customer_id) +
    (SELECT COUNT(*) FROM contracts               c WHERE c.customer_id = _customer_id) +
    (SELECT COUNT(*) FROM customer_field_history  f WHERE f.customer_id = _customer_id)
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

    -- 5) 필드 변경 이력 (Day 4-1B 신규)
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
$$;

GRANT EXECUTE ON FUNCTION
  public.rpc_customer_timeline(uuid, int, int)
  TO anon, authenticated;


-- ============================================================================
-- 검증 쿼리 (적용 후 실행)
-- ============================================================================

-- V1. 신규 테이블·인덱스
-- SELECT tablename FROM pg_tables WHERE schemaname='public' AND tablename='customer_field_history';
-- SELECT indexname FROM pg_indexes WHERE schemaname='public' AND tablename='customer_field_history';

-- V2. RLS 정책
-- SELECT policyname, cmd FROM pg_policies WHERE schemaname='public' AND tablename='customer_field_history';

-- V3. rpc_update_customer 등록 + GRANT
-- SELECT p.proname, p.prosecdef, pg_get_function_arguments(p.oid) FROM pg_proc p
-- JOIN pg_namespace n ON n.oid=p.pronamespace
-- WHERE n.nspname='public' AND p.proname='rpc_update_customer';

-- V4. rpc_customer_timeline 새 시그니처 (확장본)
-- SELECT pg_get_function_arguments(p.oid) FROM pg_proc p
-- JOIN pg_namespace n ON n.oid=p.pronamespace
-- WHERE n.nspname='public' AND p.proname='rpc_customer_timeline';

-- ============================================================================
-- 끝.
-- ============================================================================
