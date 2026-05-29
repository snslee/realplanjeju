-- ============================================================================
-- 021_admin_permissions_matrix.sql
-- 작성일: 2026-04-29 (Phase 2 v2.9-D·E·F / 권한 모델 v2.1 / 19차 회기 묶음 3 #1)
-- 목적:
--   영역×레벨 권한 매트릭스 (admin_permissions 오버라이드 + 권한별 기본값 fallback)
--   + 감사 로그 (admin_permission_log 별도 테이블 / §9 단일 책임)
--   + 헬퍼 함수 2종 + RPC 7종 + RLS.
-- 의존:
--   - public.users (한글 컬럼: 이메일·이름·권한·활성)
--   - sql/020 v2 (fn_is_role / fn_is_active_user) — 라이브 적용 완료
--   - sql/020a (rpc_check_admin / rpc_touch_admin_login) — 라이브 적용 완료
-- 7영역 코드: dashboard / customers / approvals / vendors / hr / accounting / admin_management
-- 3레벨: none / read / write
-- 기본 매트릭스:
--   - owner    : 전 영역 write
--   - manager  : dashboard·customers·approvals·vendors=write / hr=read / accounting=none / admin_management=none
--   - viewer   : dashboard·customers·approvals·vendors=read / hr·accounting·admin_management=none
-- 안전장치 5중:
--   1) 자기 자신 권한 변경 차단
--   2) 다른 owner 권한 변경 차단 (owner 2명 보호)
--   3) 자기 자신 활성/비활성 차단
--   4) 마지막 active owner 보호 (admin_management none 변경·비활성 차단)
--   5) 변경 로그 의무 (admin_permission_log)
-- 정합:
--   - 마스터 v1.2 §12-3·§12-6 (라벨·DB 한글 컬럼)
--   - 운영지침 v2.0.2 §3·§9·§10·§11·§13·§14·§16
--   - feedback_db_first_research / feedback_postgres_returns_table / feedback_db_field_mapping
--   - feedback_pre_work_plan_report v2 (선보고 + 게이트 + 묶음)
-- 적용: Supabase SQL Editor → 전체 복사 → Run
-- 안전: IF NOT EXISTS · CREATE OR REPLACE · DROP POLICY IF EXISTS (무중단)
-- ============================================================================


-- ============================================================================
-- ▶ 블록 1. admin_permissions — 영역별 권한 오버라이드
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.admin_permissions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  영역         varchar(30) NOT NULL
                  CHECK (영역 IN ('dashboard','customers','approvals','vendors','hr','accounting','admin_management')),
  레벨         varchar(10) NOT NULL DEFAULT 'none'
                  CHECK (레벨 IN ('none','read','write')),
  granted_at   timestamptz NOT NULL DEFAULT now(),
  granted_by   uuid REFERENCES public.users(id) ON DELETE SET NULL,
  메모         text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE(user_id, 영역)
);

COMMENT ON TABLE  public.admin_permissions IS '영역별 권한 오버라이드 (row 없으면 권한별 기본 매트릭스 적용 / 19차 v2.1)';
COMMENT ON COLUMN public.admin_permissions.영역 IS '7영역: dashboard·customers·approvals·vendors·hr·accounting·admin_management';
COMMENT ON COLUMN public.admin_permissions.레벨 IS '3레벨: none(비표시) / read(조회) / write(편집)';

CREATE INDEX IF NOT EXISTS idx_admin_permissions_user ON public.admin_permissions(user_id);
CREATE INDEX IF NOT EXISTS idx_admin_permissions_영역 ON public.admin_permissions(영역);


-- ============================================================================
-- ▶ 블록 2. admin_permission_log — 권한 변경 감사 로그 (단일 책임)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.admin_permission_log (
  id              bigserial PRIMARY KEY,
  대상_user_id    uuid REFERENCES public.users(id) ON DELETE SET NULL,
  대상_이메일     text NOT NULL,
  변경자_이메일   text NOT NULL,
  액션            text NOT NULL
                    CHECK (액션 IN ('permission_set','permission_bulk_set','user_activate','user_deactivate')),
  영역            text,
  이전레벨        text,
  새레벨          text,
  메모            text,
  created_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.admin_permission_log IS '관리자 권한 변경 감사 로그 (login은 admin_access_log 별도 / §9 단일 책임)';

CREATE INDEX IF NOT EXISTS idx_admin_permission_log_대상 ON public.admin_permission_log(대상_user_id);
CREATE INDEX IF NOT EXISTS idx_admin_permission_log_시간 ON public.admin_permission_log(created_at DESC);


-- ============================================================================
-- ▶ 블록 3. updated_at 트리거
-- ============================================================================
DROP TRIGGER IF EXISTS trg_admin_permissions_updated ON public.admin_permissions;
CREATE TRIGGER trg_admin_permissions_updated
  BEFORE UPDATE ON public.admin_permissions
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


-- ============================================================================
-- ▶ 블록 4. 헬퍼 함수 2종
-- ============================================================================

-- 4-1. fn_get_permission(_email, _영역) → text (none/read/write)
--   1차: admin_permissions에서 user_id + 영역 조회
--   2차: 없으면 권한별 기본 매트릭스 적용
CREATE OR REPLACE FUNCTION public.fn_get_permission(_email text, _영역 text)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id uuid;
  v_role    text;
  v_active  boolean;
  v_level   text;
BEGIN
  SELECT u.id, u.권한, u.활성
    INTO v_user_id, v_role, v_active
    FROM public.users u
   WHERE LOWER(u.이메일) = LOWER(_email)
   LIMIT 1;

  -- 사용자 없거나 비활성 → none
  IF v_user_id IS NULL OR v_active IS NOT TRUE THEN
    RETURN 'none';
  END IF;

  -- 1차: 오버라이드 조회
  SELECT p.레벨 INTO v_level
    FROM public.admin_permissions p
   WHERE p.user_id = v_user_id AND p.영역 = _영역
   LIMIT 1;

  IF v_level IS NOT NULL THEN
    RETURN v_level;
  END IF;

  -- 2차: 권한별 기본 매트릭스
  IF v_role = 'owner' THEN
    RETURN 'write';
  ELSIF v_role = 'manager' THEN
    IF _영역 IN ('dashboard','customers','approvals','vendors') THEN
      RETURN 'write';
    ELSIF _영역 = 'hr' THEN
      RETURN 'read';
    ELSE
      RETURN 'none';
    END IF;
  ELSIF v_role = 'viewer' THEN
    IF _영역 IN ('dashboard','customers','approvals','vendors') THEN
      RETURN 'read';
    ELSE
      RETURN 'none';
    END IF;
  END IF;

  RETURN 'none';
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_get_permission(text, text) TO anon, authenticated;


-- 4-2. fn_can_access(_영역, _required) → boolean
--   레벨 우선순위: write > read > none
CREATE OR REPLACE FUNCTION public.fn_can_access(_영역 text, _required text DEFAULT 'read')
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email   text;
  v_level   text;
  v_user    integer;
  v_req     integer;
BEGIN
  v_email := COALESCE(auth.jwt() ->> 'email', '');
  IF v_email = '' THEN RETURN false; END IF;

  v_level := public.fn_get_permission(v_email, _영역);

  v_user := CASE v_level    WHEN 'write' THEN 2 WHEN 'read' THEN 1 ELSE 0 END;
  v_req  := CASE _required  WHEN 'write' THEN 2 WHEN 'read' THEN 1 ELSE 0 END;

  RETURN v_user >= v_req;
END;
$$;

GRANT EXECUTE ON FUNCTION public.fn_can_access(text, text) TO anon, authenticated;


-- ============================================================================
-- ▶ 블록 5. RLS 활성화 + 정책 (admin_permissions / admin_permission_log)
--   SELECT  : owner 전체 / 본인 row는 viewer/manager도 (UI 사이드바용)
--   INSERT·UPDATE·DELETE : owner 단독
-- ============================================================================
ALTER TABLE public.admin_permissions    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_permission_log ENABLE ROW LEVEL SECURITY;

-- admin_permissions
DROP POLICY IF EXISTS "ap_select_self_or_owner" ON public.admin_permissions;
DROP POLICY IF EXISTS "ap_modify_owner"          ON public.admin_permissions;

CREATE POLICY "ap_select_self_or_owner" ON public.admin_permissions
  FOR SELECT TO authenticated
  USING (
    public.fn_is_role(ARRAY['owner'])
    OR user_id = (
      SELECT u.id FROM public.users u
       WHERE LOWER(u.이메일) = LOWER(COALESCE(auth.jwt()->>'email',''))
       LIMIT 1
    )
  );

CREATE POLICY "ap_modify_owner" ON public.admin_permissions
  FOR ALL TO authenticated
  USING      (public.fn_is_role(ARRAY['owner']))
  WITH CHECK (public.fn_is_role(ARRAY['owner']));

-- admin_permission_log
DROP POLICY IF EXISTS "apl_select_owner" ON public.admin_permission_log;
DROP POLICY IF EXISTS "apl_modify_none"  ON public.admin_permission_log;

CREATE POLICY "apl_select_owner" ON public.admin_permission_log
  FOR SELECT TO authenticated
  USING (public.fn_is_role(ARRAY['owner']));

-- INSERT는 RPC(SECURITY DEFINER)에서만 / 직접 INSERT 차단
CREATE POLICY "apl_modify_none" ON public.admin_permission_log
  FOR ALL TO authenticated
  USING      (false)
  WITH CHECK (false);


-- ============================================================================
-- ▶ 블록 6. RPC 7종 (RETURNS TABLE r_ prefix + ::TEXT cast 표준)
-- ============================================================================

-- 6-1. rpc_get_my_permissions — 본인 7영역 (사이드바·UI 토글용)
DROP FUNCTION IF EXISTS public.rpc_get_my_permissions();
CREATE OR REPLACE FUNCTION public.rpc_get_my_permissions()
RETURNS TABLE (
  r_영역    text,
  r_레벨    text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email text;
  v_areas text[] := ARRAY['dashboard','customers','approvals','vendors','hr','accounting','admin_management'];
  v_area  text;
BEGIN
  v_email := COALESCE(auth.jwt()->>'email','');
  IF v_email = '' THEN
    RAISE EXCEPTION 'permission denied (no auth)';
  END IF;

  FOREACH v_area IN ARRAY v_areas LOOP
    r_영역 := v_area::text;
    r_레벨 := public.fn_get_permission(v_email, v_area)::text;
    RETURN NEXT;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_get_my_permissions() TO authenticated;


-- 6-2. rpc_get_user_permissions(_user_id) — 특정 사용자 7영역 (모달용 / owner만)
DROP FUNCTION IF EXISTS public.rpc_get_user_permissions(uuid);
CREATE OR REPLACE FUNCTION public.rpc_get_user_permissions(_user_id uuid)
RETURNS TABLE (
  r_영역      text,
  r_레벨      text,
  r_is_override boolean,
  r_메모      text,
  r_granted_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_email     text;
  v_role      text;
  v_active    boolean;
  v_areas     text[] := ARRAY['dashboard','customers','approvals','vendors','hr','accounting','admin_management'];
  v_area      text;
  v_level     text;
  v_override  boolean;
  v_memo      text;
  v_granted   timestamptz;
BEGIN
  IF NOT public.fn_is_role(ARRAY['owner']) THEN
    RAISE EXCEPTION 'permission denied (owner only)';
  END IF;

  SELECT u.이메일, u.권한, u.활성 INTO v_email, v_role, v_active
    FROM public.users u WHERE u.id = _user_id LIMIT 1;

  IF v_email IS NULL THEN
    RAISE EXCEPTION 'user not found';
  END IF;

  FOREACH v_area IN ARRAY v_areas LOOP
    SELECT p.레벨, p.메모, p.granted_at
      INTO v_level, v_memo, v_granted
      FROM public.admin_permissions p
     WHERE p.user_id = _user_id AND p.영역 = v_area
     LIMIT 1;

    IF v_level IS NOT NULL THEN
      v_override := true;
    ELSE
      v_override := false;
      v_level := public.fn_get_permission(v_email, v_area);
      v_memo := NULL;
      v_granted := NULL;
    END IF;

    r_영역        := v_area::text;
    r_레벨        := v_level::text;
    r_is_override := v_override;
    r_메모        := v_memo::text;
    r_granted_at  := v_granted;
    RETURN NEXT;
  END LOOP;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_get_user_permissions(uuid) TO authenticated;


-- 6-3. rpc_list_admin_users — 영역 G 첫 화면 / 사용자 목록 (owner만)
DROP FUNCTION IF EXISTS public.rpc_list_admin_users();
CREATE OR REPLACE FUNCTION public.rpc_list_admin_users()
RETURNS TABLE (
  r_user_id        uuid,
  r_이메일         text,
  r_이름           text,
  r_권한           text,
  r_활성           boolean,
  r_마지막_로그인  timestamptz,
  r_override_count integer,
  r_created_at     timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.fn_is_role(ARRAY['owner']) THEN
    RAISE EXCEPTION 'permission denied (owner only)';
  END IF;

  RETURN QUERY
  SELECT
    u.id::uuid                                                   AS r_user_id,
    u.이메일::text                                               AS r_이메일,
    u.이름::text                                                 AS r_이름,
    u.권한::text                                                 AS r_권한,
    u.활성::boolean                                              AS r_활성,
    u.마지막_로그인::timestamptz                                 AS r_마지막_로그인,
    (SELECT count(*)::integer FROM public.admin_permissions p
       WHERE p.user_id = u.id)                                    AS r_override_count,
    u.created_at::timestamptz                                    AS r_created_at
  FROM public.users u
  ORDER BY
    CASE u.권한 WHEN 'owner' THEN 1 WHEN 'manager' THEN 2 ELSE 3 END,
    u.이름 ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_list_admin_users() TO authenticated;


-- 6-4. rpc_set_permission — 단일 영역 권한 변경 (owner만 / 안전장치 5중)
DROP FUNCTION IF EXISTS public.rpc_set_permission(uuid, text, text, text);
CREATE OR REPLACE FUNCTION public.rpc_set_permission(
  _user_id uuid,
  _영역    text,
  _레벨    text,
  _메모    text DEFAULT NULL
)
RETURNS TABLE (
  r_user_id    uuid,
  r_영역       text,
  r_이전레벨   text,
  r_새레벨     text,
  r_action     text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_my_email    text;
  v_my_id       uuid;
  v_target      record;
  v_prev_level  text;
  v_action      text;
  v_owner_count integer;
BEGIN
  -- owner 권한 확인
  IF NOT public.fn_is_role(ARRAY['owner']) THEN
    RAISE EXCEPTION 'permission denied (owner only)';
  END IF;

  v_my_email := LOWER(COALESCE(auth.jwt()->>'email',''));
  SELECT id INTO v_my_id FROM public.users WHERE LOWER(이메일) = v_my_email LIMIT 1;

  -- 안전장치 1: 자기 자신 차단
  IF _user_id = v_my_id THEN
    RAISE EXCEPTION '자기 자신의 권한은 변경할 수 없습니다';
  END IF;

  -- 대상 사용자 조회
  SELECT * INTO v_target FROM public.users WHERE id = _user_id LIMIT 1;
  IF v_target.id IS NULL THEN
    RAISE EXCEPTION 'user not found';
  END IF;

  -- 안전장치 2: 다른 owner 차단
  IF v_target.권한 = 'owner' THEN
    RAISE EXCEPTION '다른 owner의 권한은 변경할 수 없습니다 (공동대표 보호)';
  END IF;

  -- 입력 검증
  IF _영역 NOT IN ('dashboard','customers','approvals','vendors','hr','accounting','admin_management') THEN
    RAISE EXCEPTION '영역 코드 오류: %', _영역;
  END IF;
  IF _레벨 NOT IN ('none','read','write') THEN
    RAISE EXCEPTION '레벨 코드 오류: %', _레벨;
  END IF;

  -- 이전 레벨 (오버라이드 우선 / 없으면 기본값)
  v_prev_level := public.fn_get_permission(v_target.이메일, _영역);

  -- UPSERT
  INSERT INTO public.admin_permissions (user_id, 영역, 레벨, granted_by, 메모)
  VALUES (_user_id, _영역, _레벨, v_my_id, _메모)
  ON CONFLICT (user_id, 영역) DO UPDATE
    SET 레벨       = EXCLUDED.레벨,
        granted_by = EXCLUDED.granted_by,
        granted_at = now(),
        메모       = EXCLUDED.메모,
        updated_at = now();

  v_action := 'permission_set';

  -- 감사 로그
  INSERT INTO public.admin_permission_log (대상_user_id, 대상_이메일, 변경자_이메일, 액션, 영역, 이전레벨, 새레벨, 메모)
  VALUES (_user_id, v_target.이메일, v_my_email, v_action, _영역, v_prev_level, _레벨, _메모);

  RETURN QUERY
  SELECT _user_id::uuid, _영역::text, v_prev_level::text, _레벨::text, v_action::text;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_set_permission(uuid, text, text, text) TO authenticated;


-- 6-5. rpc_bulk_set_permissions — 7영역 일괄 변경 (모달 저장)
DROP FUNCTION IF EXISTS public.rpc_bulk_set_permissions(uuid, jsonb);
CREATE OR REPLACE FUNCTION public.rpc_bulk_set_permissions(
  _user_id uuid,
  _payload jsonb  -- {"dashboard":"write", "customers":"write", ...}
)
RETURNS TABLE (
  r_user_id   uuid,
  r_영역_count integer,
  r_action    text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_my_email   text;
  v_my_id      uuid;
  v_target     record;
  v_areas      text[] := ARRAY['dashboard','customers','approvals','vendors','hr','accounting','admin_management'];
  v_area       text;
  v_new_level  text;
  v_prev_level text;
  v_count      integer := 0;
BEGIN
  IF NOT public.fn_is_role(ARRAY['owner']) THEN
    RAISE EXCEPTION 'permission denied (owner only)';
  END IF;

  v_my_email := LOWER(COALESCE(auth.jwt()->>'email',''));
  SELECT id INTO v_my_id FROM public.users WHERE LOWER(이메일) = v_my_email LIMIT 1;

  IF _user_id = v_my_id THEN
    RAISE EXCEPTION '자기 자신의 권한은 변경할 수 없습니다';
  END IF;

  SELECT * INTO v_target FROM public.users WHERE id = _user_id LIMIT 1;
  IF v_target.id IS NULL THEN
    RAISE EXCEPTION 'user not found';
  END IF;

  IF v_target.권한 = 'owner' THEN
    RAISE EXCEPTION '다른 owner의 권한은 변경할 수 없습니다 (공동대표 보호)';
  END IF;

  FOREACH v_area IN ARRAY v_areas LOOP
    v_new_level := _payload->>v_area;
    IF v_new_level IS NULL THEN CONTINUE; END IF;
    IF v_new_level NOT IN ('none','read','write') THEN
      RAISE EXCEPTION '레벨 코드 오류 (%): %', v_area, v_new_level;
    END IF;

    v_prev_level := public.fn_get_permission(v_target.이메일, v_area);

    -- 변경 없으면 skip
    IF v_prev_level = v_new_level THEN CONTINUE; END IF;

    INSERT INTO public.admin_permissions (user_id, 영역, 레벨, granted_by)
    VALUES (_user_id, v_area, v_new_level, v_my_id)
    ON CONFLICT (user_id, 영역) DO UPDATE
      SET 레벨       = EXCLUDED.레벨,
          granted_by = EXCLUDED.granted_by,
          granted_at = now(),
          updated_at = now();

    INSERT INTO public.admin_permission_log (대상_user_id, 대상_이메일, 변경자_이메일, 액션, 영역, 이전레벨, 새레벨)
    VALUES (_user_id, v_target.이메일, v_my_email, 'permission_bulk_set', v_area, v_prev_level, v_new_level);

    v_count := v_count + 1;
  END LOOP;

  RETURN QUERY
  SELECT _user_id::uuid, v_count::integer, 'permission_bulk_set'::text;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_bulk_set_permissions(uuid, jsonb) TO authenticated;


-- 6-6. rpc_toggle_user_active — 활성/비활성 (owner만 / 자기 자신 + 마지막 owner 차단)
DROP FUNCTION IF EXISTS public.rpc_toggle_user_active(uuid, boolean);
CREATE OR REPLACE FUNCTION public.rpc_toggle_user_active(
  _user_id uuid,
  _active  boolean
)
RETURNS TABLE (
  r_user_id  uuid,
  r_이메일   text,
  r_활성     boolean,
  r_action   text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_my_email    text;
  v_my_id       uuid;
  v_target      record;
  v_owner_count integer;
  v_action      text;
BEGIN
  IF NOT public.fn_is_role(ARRAY['owner']) THEN
    RAISE EXCEPTION 'permission denied (owner only)';
  END IF;

  v_my_email := LOWER(COALESCE(auth.jwt()->>'email',''));
  SELECT id INTO v_my_id FROM public.users WHERE LOWER(이메일) = v_my_email LIMIT 1;

  IF _user_id = v_my_id THEN
    RAISE EXCEPTION '자기 자신은 비활성화할 수 없습니다';
  END IF;

  SELECT * INTO v_target FROM public.users WHERE id = _user_id LIMIT 1;
  IF v_target.id IS NULL THEN
    RAISE EXCEPTION 'user not found';
  END IF;

  -- 안전장치 4: 마지막 active owner 보호
  IF v_target.권한 = 'owner' AND _active = false THEN
    SELECT count(*)::integer INTO v_owner_count
      FROM public.users WHERE 권한 = 'owner' AND 활성 = true;
    IF v_owner_count <= 1 THEN
      RAISE EXCEPTION '마지막 active owner는 비활성화할 수 없습니다';
    END IF;
  END IF;

  UPDATE public.users SET 활성 = _active, updated_at = now()
   WHERE id = _user_id;

  v_action := CASE WHEN _active THEN 'user_activate' ELSE 'user_deactivate' END;

  INSERT INTO public.admin_permission_log (대상_user_id, 대상_이메일, 변경자_이메일, 액션, 새레벨)
  VALUES (_user_id, v_target.이메일, v_my_email, v_action, _active::text);

  RETURN QUERY
  SELECT _user_id::uuid, v_target.이메일::text, _active::boolean, v_action::text;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_toggle_user_active(uuid, boolean) TO authenticated;


-- 6-7. rpc_list_permission_log — 감사 로그 조회 (owner만 / 페이지네이션)
DROP FUNCTION IF EXISTS public.rpc_list_permission_log(integer, integer);
CREATE OR REPLACE FUNCTION public.rpc_list_permission_log(
  _limit  integer DEFAULT 50,
  _offset integer DEFAULT 0
)
RETURNS TABLE (
  r_id            bigint,
  r_대상_이메일   text,
  r_변경자_이메일 text,
  r_액션          text,
  r_영역          text,
  r_이전레벨      text,
  r_새레벨        text,
  r_메모          text,
  r_created_at    timestamptz,
  r_total_count   bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total bigint;
BEGIN
  IF NOT public.fn_is_role(ARRAY['owner']) THEN
    RAISE EXCEPTION 'permission denied (owner only)';
  END IF;

  SELECT count(*) INTO v_total FROM public.admin_permission_log;

  RETURN QUERY
  SELECT
    l.id::bigint,
    l.대상_이메일::text,
    l.변경자_이메일::text,
    l.액션::text,
    l.영역::text,
    l.이전레벨::text,
    l.새레벨::text,
    l.메모::text,
    l.created_at::timestamptz,
    v_total::bigint
  FROM public.admin_permission_log l
  ORDER BY l.created_at DESC
  LIMIT _limit OFFSET _offset;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_list_permission_log(integer, integer) TO authenticated;


-- ============================================================================
-- 검증 쿼리 (적용 후 실행 권장)
-- ============================================================================
-- 1) 테이블 2개
-- SELECT table_name FROM information_schema.tables
--  WHERE table_schema='public' AND table_name LIKE 'admin_permission%' ORDER BY table_name;

-- 2) 함수 2개 + RPC 7개
-- SELECT proname FROM pg_proc WHERE proname IN
--   ('fn_get_permission','fn_can_access',
--    'rpc_get_my_permissions','rpc_get_user_permissions','rpc_list_admin_users',
--    'rpc_set_permission','rpc_bulk_set_permissions','rpc_toggle_user_active','rpc_list_permission_log')
-- ORDER BY proname;

-- 3) RLS 정책
-- SELECT tablename, policyname FROM pg_policies WHERE tablename LIKE 'admin_permission%' ORDER BY tablename;

-- 4) 본인 7영역 (owner = 전부 write 기대)
-- SELECT * FROM public.rpc_get_my_permissions();

-- 5) 김현숙(manager) 7영역 (default 매트릭스 기대)
-- SELECT * FROM public.rpc_get_user_permissions(
--   (SELECT id FROM public.users WHERE 이메일='gomsook6805@gmail.com')
-- );

-- 6) 사용자 목록
-- SELECT * FROM public.rpc_list_admin_users();

-- ============================================================================
-- 다음 단계: admin.html v2.9-D·E·F (acceptSession fix + 사이드바 7영역 + 영역 G UI)
-- ============================================================================
