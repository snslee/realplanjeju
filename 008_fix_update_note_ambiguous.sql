-- ============================================================================
-- 008_fix_update_note_ambiguous.sql
-- 작성일: 2026-04-25 (Day 4-2 v1.5)
-- 목적: rpc_update_note "column reference 버전 is ambiguous" 에러 수정
-- 원인:
--   RETURNS TABLE(..., 버전 integer, ...) OUT 파라미터 이름과 테이블 컬럼명
--   "버전"이 동일 → UPDATE SET 절에서 plpgsql이 어느 것인지 판단 불가.
--   PostgreSQL은 안전을 위해 ambiguous 에러로 차단.
-- 해결:
--   1. 함수 본문 상단에 `#variable_conflict use_column` 디렉티브 추가
--      → 충돌 시 column 우선
--   2. UPDATE 문에 테이블 별칭(cn) 추가 + cn."버전" 명시 qualify
-- 적용: Supabase SQL Editor에 전체 복사 → Run
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
#variable_conflict use_column
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

  -- 테이블 alias(cn) 사용 + cn."버전" 명시 qualify (ambiguous 방지)
  UPDATE public.consultation_notes AS cn
  SET "메모"   = _메모,
      "버전"   = COALESCE(cn."버전", 1) + 1
  WHERE cn.id = _note_id
  RETURNING cn.* INTO _updated;

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
