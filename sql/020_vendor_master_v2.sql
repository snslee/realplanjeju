-- ============================================================================
-- 020_vendor_master_v2.sql
-- 작성일: 2026-04-29 (Phase 2 v2.9-C / P1-2c-1a 거래처 마스터 / 게이트 충돌 정합)
-- 목적:
--   사업부별 외주·공급처 마스터 (vd_vendors) + 카테고리 (vd_categories)
--   + 다중 담당자 (vd_contacts) + RPC 4종 + RLS (users 단일 소스 정합).
-- v1 → v2 변경:
--   - sql/018·019(폐기) 의존 제거 — admin_users·fn_current_role 미사용.
--   - users 테이블 직접 조회 (한글 컬럼: 이메일·권한·활성) — 실 라이브 단일 소스.
--   - 권한 명칭 'admin/manager' → 'owner/manager' (실 데이터 정합).
-- 의존:
--   - public.users (한글 컬럼: 이메일·이름·권한·활성)
--   - sql/020a (rpc_check_admin·rpc_touch_admin_login — 라이브 적용 완료)
-- 정합:
--   - 마스터 v1.2 §12-3 (5단계 라벨 표준) / §12-6 (DB 한글 컬럼 표준)
--   - 통합 설계서 v1.1 P3·P4·P5 (vendor_id FK 보존)
--   - 운영지침 §3 (객관적 비평) / §9 (과잉 설계 금지) / §10 (현 상황 우선) / §11 (확장 보존)
--   - feedback_db_field_mapping (한글 컬럼 직접 접근 / 영문 추론 금지)
--   - feedback_postgres_returns_table (r_ prefix + ::TEXT cast)
-- 적용: Supabase SQL Editor → 전체 복사 → Run
-- 안전: IF NOT EXISTS · CREATE OR REPLACE · DROP POLICY IF EXISTS (무중단)
-- ============================================================================


-- ============================================================================
-- ▶ 블록 0. 권한 헬퍼 함수 (users 테이블 기반 / fn_current_role 대체)
--   - fn_is_role(_roles text[]): 현재 인증자의 권한이 인자 배열에 포함되면 true
--   - fn_is_active_user(): 현재 인증자가 users.활성 = true 면 true
-- ============================================================================
CREATE OR REPLACE FUNCTION public.fn_is_role(_roles text[])
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users u
     WHERE LOWER(u.이메일) = LOWER(COALESCE(auth.jwt() ->> 'email', ''))
       AND u.활성 = true
       AND u.권한 = ANY(_roles)
  );
$$;

GRANT EXECUTE ON FUNCTION public.fn_is_role(text[]) TO anon, authenticated;

CREATE OR REPLACE FUNCTION public.fn_is_active_user()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.users u
     WHERE LOWER(u.이메일) = LOWER(COALESCE(auth.jwt() ->> 'email', ''))
       AND u.활성 = true
  );
$$;

GRANT EXECUTE ON FUNCTION public.fn_is_active_user() TO anon, authenticated;


-- ============================================================================
-- ▶ 블록 1. vd_categories — 외주·공급 카테고리 (9종 시드)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.vd_categories (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  코드            varchar(20)  UNIQUE NOT NULL,
  카테고리명      varchar(50)  NOT NULL,
  설명            varchar(200),
  순서            integer      NOT NULL DEFAULT 100,
  is_active       boolean      NOT NULL DEFAULT true,
  created_at      timestamptz  NOT NULL DEFAULT now(),
  updated_at      timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.vd_categories IS '외주·공급 카테고리 — 거래처 분류 표준 (통합 v1.1 정합)';
COMMENT ON COLUMN public.vd_categories.코드 IS '영문 코드 (FLIGHT·HOTEL 등 / API·EF 매핑용)';

INSERT INTO public.vd_categories (코드, 카테고리명, 설명, 순서) VALUES
  ('FLIGHT',    '항공권',         '국내·국제 항공권 발권사 / KATA 미가입 시 위탁 발권',    10),
  ('HOTEL',     '호텔·리조트',    '단체 숙박 / 리조트 / 펜션 / 게스트하우스',                 20),
  ('TRANSPORT', '차량·이동',      '렌터카·관광버스·기사·의전 차량',                            30),
  ('LECTURER',  '강사·교수',      '교육·컨설팅 외부 강사 / 마케팅 전문가',                   40),
  ('DESIGN',    '디자인',          '그래픽·웹·로고·브랜딩',                                       50),
  ('PRINT',     '인쇄·홍보물',    '책자·현수막·배너·기념품',                                     60),
  ('MEDIA',     '영상·사진',      '행사 영상·드론·사진·편집',                                    70),
  ('FNB',       '식음료·케이터링', '단체 식사·도시락·다과·커피',                                  80),
  ('ETC',       '기타',            '기타 외주·공급 (분류 미정)',                                  99)
ON CONFLICT (코드) DO NOTHING;


-- ============================================================================
-- ▶ 블록 2. vd_vendors — 거래처 마스터
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.vd_vendors (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  거래처명        varchar(150) NOT NULL,
  사업자번호      varchar(20)  UNIQUE,
  대표자          varchar(50),
  업태            varchar(50),
  종목            varchar(100),
  카테고리_id     uuid         REFERENCES public.vd_categories(id) ON DELETE SET NULL,
  사업부분류      varchar(20)
                  CHECK (사업부분류 IS NULL OR 사업부분류 IN
                  ('국내여행','행사이벤트','온라인마케팅','마케팅교육','공통')),
                  -- 4사업부 정정 (sql/021b): 경영지원은 내부 백오피스 → vd_vendors 외부 거래처에 부적절
  전화            varchar(30),
  이메일          varchar(100),
  팩스            varchar(30),
  주소            varchar(200),
  계좌_은행       varchar(30),
  계좌_번호       varchar(50),
  계좌_예금주     varchar(50),
  세금계산서_이메일 varchar(100),
  결제조건        varchar(200),
  태그            text[],
  메모            text,
  is_active       boolean      NOT NULL DEFAULT true,
  created_at      timestamptz  NOT NULL DEFAULT now(),
  created_by      uuid         REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at      timestamptz  NOT NULL DEFAULT now(),
  deleted_at      timestamptz
);

COMMENT ON TABLE  public.vd_vendors IS '거래처·외주·공급처 마스터 (P3 여행·P4 입찰·P5 마케팅 공통 / 통합 v1.1 §4 정합)';
COMMENT ON COLUMN public.vd_vendors.사업자번호 IS 'xxx-xx-xxxxx (정규식 검증은 클라이언트 / 미래 국세청 진위 API 보존)';
COMMENT ON COLUMN public.vd_vendors.사업부분류 IS '외부 4사업부 + 공통 (경영지원은 내부 백오피스 / 운영지침 v2.0.2 §1 / sql/021b 정정)';

CREATE INDEX IF NOT EXISTS idx_vd_vendors_active     ON public.vd_vendors(is_active) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_vd_vendors_category   ON public.vd_vendors(카테고리_id);
CREATE INDEX IF NOT EXISTS idx_vd_vendors_부서       ON public.vd_vendors(사업부분류);
CREATE INDEX IF NOT EXISTS idx_vd_vendors_search     ON public.vd_vendors(거래처명);


-- ============================================================================
-- ▶ 블록 3. vd_contacts — 거래처 다중 담당자
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.vd_contacts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  vendor_id       uuid         NOT NULL REFERENCES public.vd_vendors(id) ON DELETE CASCADE,
  담당자명        varchar(50)  NOT NULL,
  직급            varchar(50),
  부서            varchar(50),
  전화            varchar(30),
  휴대폰          varchar(30),
  이메일          varchar(100),
  is_primary      boolean      NOT NULL DEFAULT false,
  메모            text,
  created_at      timestamptz  NOT NULL DEFAULT now(),
  updated_at      timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.vd_contacts IS '거래처별 다중 담당자 (대표 1 + 보조 N)';

CREATE INDEX IF NOT EXISTS idx_vd_contacts_vendor   ON public.vd_contacts(vendor_id);
CREATE INDEX IF NOT EXISTS idx_vd_contacts_primary  ON public.vd_contacts(vendor_id) WHERE is_primary = true;


-- ============================================================================
-- ▶ 블록 4. updated_at 트리거
-- ============================================================================
DROP TRIGGER IF EXISTS trg_vd_vendors_updated     ON public.vd_vendors;
CREATE TRIGGER trg_vd_vendors_updated
  BEFORE UPDATE ON public.vd_vendors
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS trg_vd_categories_updated  ON public.vd_categories;
CREATE TRIGGER trg_vd_categories_updated
  BEFORE UPDATE ON public.vd_categories
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

DROP TRIGGER IF EXISTS trg_vd_contacts_updated    ON public.vd_contacts;
CREATE TRIGGER trg_vd_contacts_updated
  BEFORE UPDATE ON public.vd_contacts
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();


-- ============================================================================
-- ▶ 블록 5. RLS 활성화 + 정책 (users 단일 소스 / owner·manager·viewer 정합)
--   SELECT  : owner / manager / viewer 모두 통과 (활성 사용자)
--   INSERT  : owner / manager
--   UPDATE  : owner / manager
--   DELETE  : owner 단독
-- ============================================================================
ALTER TABLE public.vd_vendors    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vd_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vd_contacts   ENABLE ROW LEVEL SECURITY;

-- vd_vendors
DROP POLICY IF EXISTS "admin_select_vd_vendors"  ON public.vd_vendors;
DROP POLICY IF EXISTS "admin_insert_vd_vendors"  ON public.vd_vendors;
DROP POLICY IF EXISTS "admin_update_vd_vendors"  ON public.vd_vendors;
DROP POLICY IF EXISTS "admin_delete_vd_vendors"  ON public.vd_vendors;

CREATE POLICY "admin_select_vd_vendors" ON public.vd_vendors
  FOR SELECT TO authenticated
  USING (public.fn_is_role(ARRAY['owner','manager','viewer']));

CREATE POLICY "admin_insert_vd_vendors" ON public.vd_vendors
  FOR INSERT TO authenticated
  WITH CHECK (public.fn_is_role(ARRAY['owner','manager']));

CREATE POLICY "admin_update_vd_vendors" ON public.vd_vendors
  FOR UPDATE TO authenticated
  USING      (public.fn_is_role(ARRAY['owner','manager']))
  WITH CHECK (public.fn_is_role(ARRAY['owner','manager']));

CREATE POLICY "admin_delete_vd_vendors" ON public.vd_vendors
  FOR DELETE TO authenticated
  USING (public.fn_is_role(ARRAY['owner']));

-- vd_categories
DROP POLICY IF EXISTS "admin_select_vd_categories" ON public.vd_categories;
DROP POLICY IF EXISTS "admin_modify_vd_categories" ON public.vd_categories;

CREATE POLICY "admin_select_vd_categories" ON public.vd_categories
  FOR SELECT TO authenticated
  USING (public.fn_is_role(ARRAY['owner','manager','viewer']));

CREATE POLICY "admin_modify_vd_categories" ON public.vd_categories
  FOR ALL TO authenticated
  USING      (public.fn_is_role(ARRAY['owner']))
  WITH CHECK (public.fn_is_role(ARRAY['owner']));

-- vd_contacts
DROP POLICY IF EXISTS "admin_select_vd_contacts" ON public.vd_contacts;
DROP POLICY IF EXISTS "admin_insert_vd_contacts" ON public.vd_contacts;
DROP POLICY IF EXISTS "admin_update_vd_contacts" ON public.vd_contacts;
DROP POLICY IF EXISTS "admin_delete_vd_contacts" ON public.vd_contacts;

CREATE POLICY "admin_select_vd_contacts" ON public.vd_contacts
  FOR SELECT TO authenticated
  USING (public.fn_is_role(ARRAY['owner','manager','viewer']));

CREATE POLICY "admin_insert_vd_contacts" ON public.vd_contacts
  FOR INSERT TO authenticated
  WITH CHECK (public.fn_is_role(ARRAY['owner','manager']));

CREATE POLICY "admin_update_vd_contacts" ON public.vd_contacts
  FOR UPDATE TO authenticated
  USING      (public.fn_is_role(ARRAY['owner','manager']))
  WITH CHECK (public.fn_is_role(ARRAY['owner','manager']));

CREATE POLICY "admin_delete_vd_contacts" ON public.vd_contacts
  FOR DELETE TO authenticated
  USING (public.fn_is_role(ARRAY['owner']));


-- ============================================================================
-- ▶ 블록 6. RPC 4종 (users 단일 소스 / RETURNS TABLE r_ prefix + ::TEXT cast)
-- ============================================================================

-- 6-1. rpc_list_vendors — 검색·필터·페이지네이션
DROP FUNCTION IF EXISTS public.rpc_list_vendors(text, varchar, uuid, boolean, integer, integer);
CREATE OR REPLACE FUNCTION public.rpc_list_vendors(
  _search       text     DEFAULT NULL,
  _부서         varchar  DEFAULT NULL,
  _category_id  uuid     DEFAULT NULL,
  _active_only  boolean  DEFAULT true,
  _limit        integer  DEFAULT 50,
  _offset       integer  DEFAULT 0
)
RETURNS TABLE (
  r_id             uuid,
  r_거래처명       text,
  r_사업자번호     text,
  r_대표자         text,
  r_카테고리명     text,
  r_사업부분류     text,
  r_전화           text,
  r_이메일         text,
  r_is_active      boolean,
  r_담당자_count   integer,
  r_created_at     timestamptz,
  r_total_count    bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_total bigint;
BEGIN
  IF NOT public.fn_is_role(ARRAY['owner','manager','viewer']) THEN
    RAISE EXCEPTION 'permission denied (owner/manager/viewer only)';
  END IF;

  SELECT count(*) INTO v_total
    FROM public.vd_vendors v
   WHERE v.deleted_at IS NULL
     AND (NOT _active_only OR v.is_active = true)
     AND (_부서 IS NULL OR v.사업부분류 = _부서)
     AND (_category_id IS NULL OR v.카테고리_id = _category_id)
     AND (_search IS NULL OR _search = ''
           OR v.거래처명 ILIKE '%'||_search||'%'
           OR v.대표자   ILIKE '%'||_search||'%'
           OR v.전화     ILIKE '%'||_search||'%'
           OR v.이메일   ILIKE '%'||_search||'%'
           OR v.사업자번호 ILIKE '%'||_search||'%');

  RETURN QUERY
  SELECT
    v.id::uuid                                                        AS r_id,
    v.거래처명::text                                                  AS r_거래처명,
    v.사업자번호::text                                                AS r_사업자번호,
    v.대표자::text                                                    AS r_대표자,
    c.카테고리명::text                                                AS r_카테고리명,
    v.사업부분류::text                                                AS r_사업부분류,
    v.전화::text                                                      AS r_전화,
    v.이메일::text                                                    AS r_이메일,
    v.is_active::boolean                                              AS r_is_active,
    (SELECT count(*)::integer FROM public.vd_contacts ct
       WHERE ct.vendor_id = v.id)                                      AS r_담당자_count,
    v.created_at::timestamptz                                         AS r_created_at,
    v_total::bigint                                                   AS r_total_count
  FROM public.vd_vendors v
  LEFT JOIN public.vd_categories c ON c.id = v.카테고리_id
  WHERE v.deleted_at IS NULL
    AND (NOT _active_only OR v.is_active = true)
    AND (_부서 IS NULL OR v.사업부분류 = _부서)
    AND (_category_id IS NULL OR v.카테고리_id = _category_id)
    AND (_search IS NULL OR _search = ''
          OR v.거래처명 ILIKE '%'||_search||'%'
          OR v.대표자   ILIKE '%'||_search||'%'
          OR v.전화     ILIKE '%'||_search||'%'
          OR v.이메일   ILIKE '%'||_search||'%'
          OR v.사업자번호 ILIKE '%'||_search||'%')
  ORDER BY v.is_active DESC, v.거래처명 ASC
  LIMIT _limit OFFSET _offset;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_list_vendors(text, varchar, uuid, boolean, integer, integer)
  TO authenticated;


-- 6-2. rpc_get_vendor — 상세 + 담당자 (JSON)
DROP FUNCTION IF EXISTS public.rpc_get_vendor(uuid);
CREATE OR REPLACE FUNCTION public.rpc_get_vendor(_id uuid)
RETURNS TABLE (
  r_vendor    jsonb,
  r_contacts  jsonb,
  r_category  jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.fn_is_role(ARRAY['owner','manager','viewer']) THEN
    RAISE EXCEPTION 'permission denied (owner/manager/viewer only)';
  END IF;

  RETURN QUERY
  SELECT
    to_jsonb(v.*)                                                          AS r_vendor,
    COALESCE(
      (SELECT jsonb_agg(to_jsonb(ct.*) ORDER BY ct.is_primary DESC, ct.created_at ASC)
         FROM public.vd_contacts ct WHERE ct.vendor_id = v.id),
      '[]'::jsonb
    )                                                                       AS r_contacts,
    to_jsonb(c.*)                                                          AS r_category
  FROM public.vd_vendors v
  LEFT JOIN public.vd_categories c ON c.id = v.카테고리_id
  WHERE v.id = _id AND v.deleted_at IS NULL
  LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_get_vendor(uuid) TO authenticated;


-- 6-3. rpc_upsert_vendor — 신규 등록 또는 수정
DROP FUNCTION IF EXISTS public.rpc_upsert_vendor(jsonb);
CREATE OR REPLACE FUNCTION public.rpc_upsert_vendor(_payload jsonb)
RETURNS TABLE (
  r_id        uuid,
  r_거래처명  text,
  r_action    text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id      uuid;
  v_action  text;
BEGIN
  IF NOT public.fn_is_role(ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'permission denied (owner/manager only)';
  END IF;

  v_id := (_payload->>'id')::uuid;

  IF v_id IS NULL THEN
    IF (_payload->>'사업자번호') IS NOT NULL AND (_payload->>'사업자번호') <> '' THEN
      IF EXISTS (SELECT 1 FROM public.vd_vendors WHERE 사업자번호 = (_payload->>'사업자번호')) THEN
        RAISE EXCEPTION '이미 등록된 사업자번호입니다: %', (_payload->>'사업자번호');
      END IF;
    END IF;

    INSERT INTO public.vd_vendors (
      거래처명, 사업자번호, 대표자, 업태, 종목, 카테고리_id, 사업부분류,
      전화, 이메일, 팩스, 주소,
      계좌_은행, 계좌_번호, 계좌_예금주, 세금계산서_이메일, 결제조건,
      태그, 메모, is_active, created_by
    ) VALUES (
      _payload->>'거래처명',
      NULLIF(_payload->>'사업자번호',''),
      _payload->>'대표자',
      _payload->>'업태',
      _payload->>'종목',
      NULLIF(_payload->>'카테고리_id','')::uuid,
      _payload->>'사업부분류',
      _payload->>'전화',
      _payload->>'이메일',
      _payload->>'팩스',
      _payload->>'주소',
      _payload->>'계좌_은행',
      _payload->>'계좌_번호',
      _payload->>'계좌_예금주',
      _payload->>'세금계산서_이메일',
      _payload->>'결제조건',
      CASE WHEN jsonb_typeof(_payload->'태그')='array'
           THEN ARRAY(SELECT jsonb_array_elements_text(_payload->'태그')) END,
      _payload->>'메모',
      COALESCE((_payload->>'is_active')::boolean, true),
      auth.uid()
    )
    RETURNING id INTO v_id;
    v_action := 'inserted';
  ELSE
    UPDATE public.vd_vendors SET
      거래처명          = COALESCE(_payload->>'거래처명', 거래처명),
      사업자번호        = NULLIF(_payload->>'사업자번호',''),
      대표자            = _payload->>'대표자',
      업태              = _payload->>'업태',
      종목              = _payload->>'종목',
      카테고리_id       = NULLIF(_payload->>'카테고리_id','')::uuid,
      사업부분류        = _payload->>'사업부분류',
      전화              = _payload->>'전화',
      이메일            = _payload->>'이메일',
      팩스              = _payload->>'팩스',
      주소              = _payload->>'주소',
      계좌_은행         = _payload->>'계좌_은행',
      계좌_번호         = _payload->>'계좌_번호',
      계좌_예금주       = _payload->>'계좌_예금주',
      세금계산서_이메일 = _payload->>'세금계산서_이메일',
      결제조건          = _payload->>'결제조건',
      태그              = CASE WHEN jsonb_typeof(_payload->'태그')='array'
                               THEN ARRAY(SELECT jsonb_array_elements_text(_payload->'태그')) ELSE 태그 END,
      메모              = _payload->>'메모',
      is_active         = COALESCE((_payload->>'is_active')::boolean, is_active)
    WHERE id = v_id AND deleted_at IS NULL;
    v_action := 'updated';
  END IF;

  RETURN QUERY
  SELECT v.id::uuid, v.거래처명::text, v_action::text
    FROM public.vd_vendors v WHERE v.id = v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_vendor(jsonb) TO authenticated;


-- 6-4. rpc_toggle_vendor_active
DROP FUNCTION IF EXISTS public.rpc_toggle_vendor_active(uuid, boolean);
CREATE OR REPLACE FUNCTION public.rpc_toggle_vendor_active(_id uuid, _active boolean)
RETURNS TABLE (
  r_id         uuid,
  r_거래처명   text,
  r_is_active  boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.fn_is_role(ARRAY['owner','manager']) THEN
    RAISE EXCEPTION 'permission denied (owner/manager only)';
  END IF;

  UPDATE public.vd_vendors
     SET is_active = _active
   WHERE id = _id AND deleted_at IS NULL;

  RETURN QUERY
  SELECT v.id::uuid, v.거래처명::text, v.is_active::boolean
    FROM public.vd_vendors v WHERE v.id = _id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_toggle_vendor_active(uuid, boolean) TO authenticated;


-- ============================================================================
-- 검증 쿼리 (적용 후 실행 권장)
-- ============================================================================
-- 1) 권한 헬퍼
-- SELECT public.fn_is_role(ARRAY['owner']);            -- true 기대 (대표 본인)
-- SELECT public.fn_is_active_user();                    -- true 기대

-- 2) 테이블 3개
-- SELECT table_name FROM information_schema.tables
--  WHERE table_schema='public' AND table_name LIKE 'vd_%' ORDER BY table_name;

-- 3) 시드 9종
-- SELECT 코드, 카테고리명 FROM vd_categories ORDER BY 순서;

-- 4) RPC 4종
-- SELECT proname FROM pg_proc WHERE proname LIKE '%vendor%';

-- 5) RLS 정책
-- SELECT tablename, policyname FROM pg_policies WHERE tablename LIKE 'vd_%' ORDER BY tablename;

-- 6) 본인 호출 (owner 통과)
-- SELECT * FROM public.rpc_list_vendors(NULL, NULL, NULL, true, 10, 0);

-- ============================================================================
-- 다음 단계: admin.html 영역 B (사이드바 활성화 + 목록·상세 UI) — 다음 회기
-- ============================================================================
