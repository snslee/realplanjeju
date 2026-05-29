-- ============================================================
-- sql/025_vendor_contacts_crud.sql
-- v2.13.4-α5 묶음 4 Phase 5 — 거래처 담당자 CRUD + Primary 1명 보장
-- 적용일: 2026-04-30 (25차 회기)
--
-- RPC 4종 신규:
-- 1) rpc_list_contacts(_vendor_id) — 담당자 목록 조회
-- 2) rpc_upsert_contact(_payload jsonb) — INSERT/UPDATE
-- 3) rpc_delete_contact(_id) — 삭제
-- 4) rpc_set_primary_contact(_id) — Primary 1명 보장 (다른 contacts is_primary = false)
-- ============================================================

-- ─── (1) rpc_list_contacts — 담당자 목록 조회 ───
CREATE OR REPLACE FUNCTION public.rpc_list_contacts(_vendor_id uuid)
RETURNS TABLE(
  r_id uuid,
  r_vendor_id uuid,
  r_담당자명 character varying,
  r_직급 character varying,
  r_부서 character varying,
  r_전화 character varying,
  r_휴대폰 character varying,
  r_이메일 character varying,
  r_is_primary boolean,
  r_메모 text,
  r_created_at timestamptz,
  r_updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  RETURN QUERY
  SELECT c.id, c.vendor_id, c.담당자명, c.직급, c.부서,
    c.전화, c.휴대폰, c.이메일, c.is_primary, c.메모,
    c.created_at, c.updated_at
  FROM public.vd_contacts c
  WHERE c.vendor_id = _vendor_id
  ORDER BY c.is_primary DESC, c.담당자명 ASC;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_list_contacts(uuid) TO authenticated, service_role;


-- ─── (2) rpc_upsert_contact — INSERT/UPDATE ───
CREATE OR REPLACE FUNCTION public.rpc_upsert_contact(_payload jsonb)
RETURNS TABLE(r_id uuid, r_담당자명 character varying, r_action text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _id uuid;
  _action text;
  _vid uuid;
  _is_primary boolean;
BEGIN
  _vid := (_payload->>'vendor_id')::uuid;
  _is_primary := COALESCE((_payload->>'is_primary')::boolean, false);

  IF _payload ? 'id' AND (_payload->>'id') IS NOT NULL AND (_payload->>'id') <> '' THEN
    -- UPDATE
    _id := (_payload->>'id')::uuid;
    UPDATE public.vd_contacts SET
      담당자명 = COALESCE(_payload->>'담당자명', 담당자명),
      직급 = _payload->>'직급',
      부서 = _payload->>'부서',
      전화 = _payload->>'전화',
      휴대폰 = _payload->>'휴대폰',
      이메일 = _payload->>'이메일',
      메모 = _payload->>'메모',
      is_primary = _is_primary,
      updated_at = now()
    WHERE id = _id;
    _action := 'update';
  ELSE
    -- INSERT
    INSERT INTO public.vd_contacts (
      vendor_id, 담당자명, 직급, 부서, 전화, 휴대폰, 이메일, is_primary, 메모
    ) VALUES (
      _vid,
      _payload->>'담당자명',
      _payload->>'직급',
      _payload->>'부서',
      _payload->>'전화',
      _payload->>'휴대폰',
      _payload->>'이메일',
      _is_primary,
      _payload->>'메모'
    ) RETURNING id INTO _id;
    _action := 'insert';
  END IF;

  -- Primary 1명 보장: is_primary=true로 저장된 경우 같은 vendor의 다른 contacts는 false
  IF _is_primary THEN
    UPDATE public.vd_contacts
    SET is_primary = false, updated_at = now()
    WHERE vendor_id = _vid AND id <> _id AND is_primary = true;
  END IF;

  RETURN QUERY SELECT c.id, c.담당자명, _action FROM public.vd_contacts c WHERE c.id = _id;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_contact(jsonb) TO authenticated, service_role;


-- ─── (3) rpc_delete_contact — 삭제 ───
CREATE OR REPLACE FUNCTION public.rpc_delete_contact(_id uuid)
RETURNS TABLE(r_id uuid, r_deleted boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _vid uuid;
  _was_primary boolean;
  _new_primary uuid;
BEGIN
  -- 삭제 전 vendor_id + is_primary 보존
  SELECT vendor_id, is_primary INTO _vid, _was_primary
  FROM public.vd_contacts WHERE id = _id;

  IF _vid IS NULL THEN
    RETURN QUERY SELECT _id, false;
    RETURN;
  END IF;

  DELETE FROM public.vd_contacts WHERE id = _id;

  -- Primary 삭제 시 같은 vendor의 다른 contact 중 첫 번째를 Primary로 자동 승격
  IF _was_primary THEN
    SELECT id INTO _new_primary
    FROM public.vd_contacts
    WHERE vendor_id = _vid
    ORDER BY created_at ASC LIMIT 1;
    IF _new_primary IS NOT NULL THEN
      UPDATE public.vd_contacts SET is_primary = true, updated_at = now() WHERE id = _new_primary;
    END IF;
  END IF;

  RETURN QUERY SELECT _id, true;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_delete_contact(uuid) TO authenticated, service_role;


-- ─── (4) rpc_set_primary_contact — Primary 1명 보장 ───
CREATE OR REPLACE FUNCTION public.rpc_set_primary_contact(_id uuid)
RETURNS TABLE(r_id uuid, r_vendor_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _vid uuid;
BEGIN
  SELECT vendor_id INTO _vid FROM public.vd_contacts WHERE id = _id;
  IF _vid IS NULL THEN
    RAISE EXCEPTION '담당자 ID 없음: %', _id;
  END IF;

  -- 같은 vendor의 모든 contact를 false로 + 지정 contact만 true
  UPDATE public.vd_contacts
  SET is_primary = (id = _id), updated_at = now()
  WHERE vendor_id = _vid;

  RETURN QUERY SELECT _id, _vid;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_set_primary_contact(uuid) TO authenticated, service_role;
