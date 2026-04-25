-- ============================================================================
-- 006_rpc_notes.sql
-- 작성일: 2026-04-25 (Day 4-2)
-- 목적: 문의 상세 [메모 탭] consultation_notes 댓글형 누적 RPC 3종 추가
-- 배경:
--   consultation_notes 테이블에 GRANT SELECT/INSERT/UPDATE 없음 (anon/authenticated
--   에 REFERENCES·TRIGGER·TRUNCATE만 존재). 결정 #14 원칙 (Day 4-1 확립): 모든
--   read/write는 SECURITY DEFINER RPC 경유 강제. 직접 sb.from(...) 패턴 금지.
-- 정책 베이스 (D-3 결정값):
--   - 댓글형 누적 (시간 역순)
--   - 삭제 불가
--   - 본인 작성 + 2분 이내만 수정 가능
--   - 작성자/시각 자동 (auth.jwt.email + now())
--   - 사업부 자동 채움 (customers.사업부 가져옴)
--   - 메모 최대 길이 2000자
-- 적용 방법: Supabase SQL Editor에 전체 복사 → Run
-- ============================================================================

-- ============================================================================
-- 1. rpc_list_notes(_customer_id uuid)
-- ============================================================================
-- 목록 조회. 시간 역순(최신 위). can_edit 플래그 서버 판단(시계 오차 차단).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_list_notes(_customer_id uuid)
RETURNS TABLE (
  note_id     uuid,
  customer_id uuid,
  사업부      varchar,
  메모        text,
  작성자      varchar,
  버전        integer,
  created_at  timestamptz,
  updated_at  timestamptz,
  is_mine     boolean,
  can_edit    boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _email text;
BEGIN
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  _email := lower(auth.jwt()->>'email');

  RETURN QUERY
  SELECT
    n.id            AS note_id,
    n.customer_id,
    n."사업부",
    n."메모",
    n."작성자",
    n."버전",
    n.created_at,
    n.updated_at,
    (lower(n."작성자") = _email)                                  AS is_mine,
    (lower(n."작성자") = _email
     AND (now() - n.updated_at) <= interval '2 minutes')          AS can_edit
  FROM public.consultation_notes n
  WHERE n.customer_id = _customer_id
  ORDER BY n.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_list_notes(uuid) TO anon, authenticated;


-- ============================================================================
-- 2. rpc_add_note(_customer_id uuid, _메모 text)
-- ============================================================================
-- 메모 추가. 사업부 자동 채움. 작성자 = auth.jwt.email.
-- 메모 길이 검증(1~2000자), customer_id 존재 검증.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_add_note(_customer_id uuid, _메모 text)
RETURNS TABLE (
  note_id     uuid,
  customer_id uuid,
  사업부      varchar,
  메모        text,
  작성자      varchar,
  버전        integer,
  created_at  timestamptz,
  updated_at  timestamptz,
  is_mine     boolean,
  can_edit    boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _email      text;
  _사업부     varchar;
  _new_id     uuid;
  _new_row    public.consultation_notes;
BEGIN
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  IF _메모 IS NULL OR length(btrim(_메모)) = 0 THEN
    RAISE EXCEPTION 'empty note not allowed';
  END IF;

  IF length(_메모) > 2000 THEN
    RAISE EXCEPTION 'note too long (max 2000 chars)';
  END IF;

  -- 사업부 자동 채움
  SELECT c."사업부" INTO _사업부
  FROM public.customers c
  WHERE c.id = _customer_id AND c.deleted_at IS NULL;

  IF _사업부 IS NULL THEN
    RAISE EXCEPTION 'customer not found: %', _customer_id;
  END IF;

  _email := lower(auth.jwt()->>'email');

  INSERT INTO public.consultation_notes
    (customer_id, "사업부", "메모", "작성자", "버전")
  VALUES
    (_customer_id, _사업부, _메모, _email, 1)
  RETURNING * INTO _new_row;

  RETURN QUERY
  SELECT
    _new_row.id,
    _new_row.customer_id,
    _new_row."사업부",
    _new_row."메모",
    _new_row."작성자",
    _new_row."버전",
    _new_row.created_at,
    _new_row.updated_at,
    true   AS is_mine,
    true   AS can_edit;  -- 방금 작성 → 무조건 편집 가능
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_add_note(uuid, text) TO anon, authenticated;


-- ============================================================================
-- 3. rpc_update_note(_note_id uuid, _메모 text)
-- ============================================================================
-- 본인 작성 + 2분 이내 메모만 수정 가능. 버전 +1. updated_at 자동(트리거).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.rpc_update_note(_note_id uuid, _메모 text)
RETURNS TABLE (
  note_id     uuid,
  customer_id uuid,
  사업부      varchar,
  메모        text,
  작성자      varchar,
  버전        integer,
  created_at  timestamptz,
  updated_at  timestamptz,
  is_mine     boolean,
  can_edit    boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  _email      text;
  _existing   public.consultation_notes;
  _updated    public.consultation_notes;
BEGIN
  IF NOT public.fn_current_is_admin() THEN
    RAISE EXCEPTION 'permission denied (admin only)';
  END IF;

  IF _메모 IS NULL OR length(btrim(_메모)) = 0 THEN
    RAISE EXCEPTION 'empty note not allowed';
  END IF;

  IF length(_메모) > 2000 THEN
    RAISE EXCEPTION 'note too long (max 2000 chars)';
  END IF;

  _email := lower(auth.jwt()->>'email');

  SELECT * INTO _existing FROM public.consultation_notes WHERE id = _note_id;

  IF _existing.id IS NULL THEN
    RAISE EXCEPTION 'note not found: %', _note_id;
  END IF;

  IF lower(_existing."작성자") <> _email THEN
    RAISE EXCEPTION 'cannot edit other user note';
  END IF;

  IF (now() - _existing.updated_at) > interval '2 minutes' THEN
    RAISE EXCEPTION 'edit window expired (2 minutes)';
  END IF;

  UPDATE public.consultation_notes
  SET "메모"   = _메모,
      "버전"   = COALESCE("버전", 1) + 1
  WHERE id = _note_id
  RETURNING * INTO _updated;

  RETURN QUERY
  SELECT
    _updated.id,
    _updated.customer_id,
    _updated."사업부",
    _updated."메모",
    _updated."작성자",
    _updated."버전",
    _updated.created_at,
    _updated.updated_at,
    true                                                     AS is_mine,
    ((now() - _updated.updated_at) <= interval '2 minutes')  AS can_edit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_update_note(uuid, text) TO anon, authenticated;


-- ============================================================================
-- 검증 쿼리 (postgres role · admin 검증 통과 필요)
-- ============================================================================
-- SELECT * FROM rpc_list_notes('TOUR-2026-001 customer_id 자리');
-- SELECT * FROM rpc_add_note('TOUR-2026-001 customer_id 자리', '첫 메모 테스트');
-- SELECT * FROM rpc_update_note('방금 받은 note_id', '메모 수정 테스트');

-- ============================================================================
-- 함수 + GRANT 점검
-- ============================================================================
-- SELECT p.proname, pg_get_function_identity_arguments(p.oid),
--        p.prosecdef AS sd, array_agg(a.rolname) FILTER (WHERE a.rolname IS NOT NULL)
-- FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid
-- LEFT JOIN aclexplode(p.proacl) ax ON true
-- LEFT JOIN pg_roles a ON a.oid = ax.grantee
-- WHERE n.nspname='public' AND p.proname IN ('rpc_list_notes','rpc_add_note','rpc_update_note')
-- GROUP BY p.proname, p.oid;
