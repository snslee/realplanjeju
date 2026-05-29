-- ============================================================================
-- 007_extend_note_edit_window.sql
-- 작성일: 2026-04-25 (Day 4-2 v1.4)
-- 목적: 메모 수정 가능 시간 2분 → 30분 확장
-- 배경:
--   D-3 결정값 "본인 + 2분 이내 수정"이 운영 현실에 짧음. 통화 중·마무리
--   포함 30분 충분. 결정 #16 (대표님 2026-04-25 승인).
-- 변경 위치 (3곳):
--   1. rpc_list_notes 의 can_edit 계산
--   2. rpc_update_note 의 시간 검증 (RAISE EXCEPTION 조건)
--   3. rpc_update_note 의 RETURN can_edit 계산
-- 적용: Supabase SQL Editor에 전체 복사 → Run (CREATE OR REPLACE 3개)
-- ============================================================================

-- ============================================================================
-- 1. rpc_list_notes — can_edit 30분
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
     AND (now() - n.updated_at) <= interval '30 minutes')         AS can_edit
  FROM public.consultation_notes n
  WHERE n.customer_id = _customer_id
  ORDER BY n.created_at DESC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_list_notes(uuid) TO anon, authenticated;


-- ============================================================================
-- 2. rpc_update_note — 시간 검증 30분 + RETURN can_edit 30분
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

  IF (now() - _existing.updated_at) > interval '30 minutes' THEN
    RAISE EXCEPTION 'edit window expired (30 minutes)';
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
    true                                                       AS is_mine,
    ((now() - _updated.updated_at) <= interval '30 minutes')   AS can_edit;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_update_note(uuid, text) TO anon, authenticated;
