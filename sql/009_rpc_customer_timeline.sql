-- ============================================================================
-- 009_rpc_customer_timeline.sql
-- 작성일: 2026-04-25 (Day 4-3)
-- 목적: 문의 상세 [타임라인] 탭 — 4 소스 UNION 시간순 통합
-- 배경:
--   admin.html 문의 상세 페이지에서 "이 고객이 언제 무엇을 했는가"를
--   한 화면 시간순으로 보여주는 RPC. consultation_notes (메모),
--   status_history (상태 변경), quotations (견적), contracts (계약)
--   4개 테이블을 UNION ALL 로 합치고 event_at DESC 로 정렬.
-- 정책 베이스 (Day 4-3 사전 점검 결정):
--   - 시간순 통합 (4 소스 한 줄 표시)
--   - 페이지당 30건 (_limit DEFAULT 30, _offset DEFAULT 0)
--   - 정렬: event_at DESC (최신 먼저)
--   - SECURITY DEFINER + fn_current_is_admin() 검증 (결정 #14 원칙)
--   - #variable_conflict use_column 디렉티브 강제 (결정 #20 학습)
-- 주의:
--   Phase 2a/2b 가동 전이라 현재 quotations·contracts 는 빈 상태.
--   데이터가 들어오면 자동으로 UNION 결과에 합류 (admin.html 코드 변경 0).
-- 적용 방법: Supabase SQL Editor 에 전체 복사 → Run
-- ============================================================================

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
  -- 권한 검증 (admin.html 외 호출 차단)
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  -- 입력값 가드
  IF _customer_id IS NULL THEN
    RAISE EXCEPTION 'customer_id is required';
  END IF;

  IF _limit IS NULL OR _limit <= 0 OR _limit > 200 THEN
    _limit := 30;
  END IF;

  IF _offset IS NULL OR _offset < 0 THEN
    _offset := 0;
  END IF;

  -- 전체 건수 (4 소스 합산) — 페이지네이션 [더보기] 판단용
  SELECT
    (SELECT COUNT(*) FROM consultation_notes n WHERE n.customer_id = _customer_id) +
    (SELECT COUNT(*) FROM status_history     s WHERE s.customer_id = _customer_id) +
    (SELECT COUNT(*) FROM quotations         q WHERE q.customer_id = _customer_id) +
    (SELECT COUNT(*) FROM contracts          c WHERE c.customer_id = _customer_id)
  INTO _total;

  -- 4 소스 UNION ALL → event_at DESC → LIMIT/OFFSET
  RETURN QUERY
  WITH unified AS (
    -- 1) 상담 메모 (consultation_notes)
    SELECT
      n.id                                                       AS event_id,
      'note'::text                                               AS event_type,
      n.created_at                                               AS event_at,
      n."작성자"::text                                            AS 작성자,
      (CASE
         WHEN length(coalesce(n."메모", '')) <= 30 THEN coalesce(n."메모", '')
         ELSE substr(n."메모", 1, 30) || '...'
       END)::text                                                AS 제목,
      coalesce(n."메모", '')::text                                AS 상세,
      jsonb_build_object(
        '버전', n."버전",
        '사업부', n."사업부",
        'updated_at', n.updated_at
      )                                                          AS meta
    FROM public.consultation_notes n
    WHERE n.customer_id = _customer_id

    UNION ALL

    -- 2) 상태 변경 이력 (status_history)
    SELECT
      s.id                                                       AS event_id,
      'status'::text                                             AS event_type,
      s.created_at                                               AS event_at,
      s."변경자"::text                                            AS 작성자,
      (coalesce(s."이전상태", '(시작)') || ' → ' || s."다음상태")::text  AS 제목,
      coalesce(s."변경사유", '')::text                             AS 상세,
      jsonb_build_object(
        '이전상태', s."이전상태",
        '다음상태', s."다음상태",
        'ip_address', s.ip_address::text
      )                                                          AS meta
    FROM public.status_history s
    WHERE s.customer_id = _customer_id

    UNION ALL

    -- 3) 견적서 (quotations) — Phase 2a 사전, 발송일시 우선 정렬
    SELECT
      q.id                                                       AS event_id,
      'quotation'::text                                          AS event_type,
      coalesce(q."발송일시", q.created_at)                        AS event_at,
      q."작성자"::text                                            AS 작성자,
      ('견적 ' || coalesce(q."상태", '작성중') || ': ' ||
       q."견적번호" || ' / ' ||
       to_char(q."견적금액", 'FM999,999,999') || '원')::text       AS 제목,
      ('수정차수 ' || q."수정차수" || '차 / 발송 ' ||
       CASE WHEN q."발송여부" THEN '완료' ELSE '미발송' END ||
       CASE WHEN q.유효기간 IS NOT NULL
            THEN ' / 유효 ' || to_char(q.유효기간, 'YYYY-MM-DD')
            ELSE '' END)::text                                   AS 상세,
      jsonb_build_object(
        '견적번호', q."견적번호",
        '수정차수', q."수정차수",
        '상태', q."상태",
        '견적금액', q."견적금액"
      )                                                          AS meta
    FROM public.quotations q
    WHERE q.customer_id = _customer_id

    UNION ALL

    -- 4) 계약서 (contracts) — Phase 2b 사전, 발송일시 우선 정렬
    SELECT
      c.id                                                       AS event_id,
      'contract'::text                                           AS event_type,
      coalesce(c."발송일시", c.created_at)                        AS event_at,
      c."작성자"::text                                            AS 작성자,
      ('계약 ' || coalesce(c."상태", '작성중') || ': ' ||
       c."계약번호" || ' / ' ||
       to_char(c."계약금액", 'FM999,999,999') || '원')::text       AS 제목,
      ('서명 ' || coalesce(c."서명상태", '미서명') ||
       ' / ' || to_char(c."계약기간_시작", 'YYYY-MM-DD') ||
       ' ~ ' || to_char(c."계약기간_종료", 'YYYY-MM-DD'))::text    AS 상세,
      jsonb_build_object(
        '계약번호', c."계약번호",
        '서명상태', c."서명상태",
        '상태', c."상태",
        '계약금액', c."계약금액"
      )                                                          AS meta
    FROM public.contracts c
    WHERE c.customer_id = _customer_id
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

-- V1. 함수 등록 확인
-- SELECT
--   p.proname,
--   p.prosecdef AS security_definer,
--   pg_get_function_arguments(p.oid) AS args,
--   pg_get_function_result(p.oid)    AS returns
-- FROM pg_proc p
-- JOIN pg_namespace n ON n.oid = p.pronamespace
-- WHERE n.nspname = 'public' AND p.proname = 'rpc_customer_timeline';

-- V2. GRANT 확인
-- SELECT routine_name, grantee, privilege_type
-- FROM information_schema.routine_privileges
-- WHERE routine_schema = 'public' AND routine_name = 'rpc_customer_timeline'
-- ORDER BY grantee;

-- V3. 실호출 (TOUR-2026-001 가져온 후)
-- SELECT * FROM public.rpc_customer_timeline(
--   (SELECT id FROM public.customers WHERE 접수번호 = 'TOUR-2026-001'),
--   30, 0
-- );

-- V4. 페이지네이션 (있으면 2페이지)
-- SELECT * FROM public.rpc_customer_timeline(
--   (SELECT id FROM public.customers WHERE 접수번호 = 'EVENT-2026-001'),
--   30, 30
-- );

-- ============================================================================
-- 끝.
-- ============================================================================
