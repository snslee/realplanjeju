-- ============================================================================
-- 029_file_attachments_and_company_info.sql
-- 작성일: 2026-05-01 (Phase A / 전자계약·결제·파일탭 통합 설계서 v1.0)
-- 목적:
--   1) customers 사업자정보 컬럼 4종 추가 (「갑」 자동 채움)
--   2) file_attachments 테이블 신설 (Tier 1·2·3 19개 폴더 지원)
--   3) RLS 정책 4종 (권한 컬럼 기반 동적)
--   4) RPC 4종 (list / get_auto_attach / upsert / delete)
--   5) Storage Bucket 4종 + Storage RLS 정책
-- 의존:
--   - sql/001 (customers / quotations / contracts)
--   - sql/020 v2 (fn_is_role)
--   - sql/028 (customer_contacts 패턴 정합)
-- 정합:
--   - 통합 설계서 v1.0 §3·§4 (Tier 1 7개 즉시 / Tier 2·3 17개 확장 보존)
--   - 운영지침 v2.0.2 §6·§9·§10·§11 (데이터주권·과잉설계X·확장보존)
--   - feedback_postgres_identifier_folding (소문자 정합)
--   - feedback_db_field_mapping (한글 컬럼 직접 접근)
-- 적용: Supabase SQL Editor → 전체 복사 → Run
-- 안전: IF NOT EXISTS · CREATE OR REPLACE · DROP POLICY IF EXISTS (무중단)
-- ============================================================================


-- ============================================================================
-- ▶ 블록 1. customers 「갑」 사업자정보 컬럼 4종 추가
-- ============================================================================
ALTER TABLE public.customers
  ADD COLUMN IF NOT EXISTS 사업자번호      varchar(15),
  ADD COLUMN IF NOT EXISTS 법인등록번호    varchar(20),
  ADD COLUMN IF NOT EXISTS 회사주소        text,
  ADD COLUMN IF NOT EXISTS 사업자유형      varchar(20)
    CHECK (사업자유형 IS NULL OR 사업자유형 IN ('법인','개인','면세사업자','간이과세자','비영리'));

COMMENT ON COLUMN public.customers.사업자번호      IS '「갑」 자동 채움 / 형식: 000-00-00000';
COMMENT ON COLUMN public.customers.법인등록번호    IS '「갑」 자동 채움 (선택)';
COMMENT ON COLUMN public.customers.회사주소        IS '「갑」 자동 채움 / 본점 주소';
COMMENT ON COLUMN public.customers.사업자유형      IS '법인·개인·면세사업자·간이과세자·비영리';

CREATE INDEX IF NOT EXISTS idx_customers_사업자번호 ON public.customers(사업자번호) WHERE 사업자번호 IS NOT NULL;


-- ============================================================================
-- ▶ 블록 2. file_attachments 테이블 (Tier 1·2·3 19개 폴더 지원)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.file_attachments (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id        uuid NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,

  -- 카테고리 (Tier 1 7개 + Tier 2 5개 + Tier 3 7개 = 19개)
  카테고리           varchar(30) NOT NULL
                      CHECK (카테고리 IN (
                        -- Tier 1 (핵심 / 즉시 도입)
                        '사업자사본','제안서_업체제공','사업_운영사진',
                        '계약서_체결본','공문_발송본','견적서_확정본','세금계산서_증빙',
                        -- Tier 2 (사업부별 필수)
                        'NDA_비밀유지','계약_부속서류','보험_자격증명',
                        '결과보고서_산출물','공공기관_입찰자료',
                        -- Tier 3 (선택·고급)
                        '포트폴리오_제공본','클라이언트_자료','현장_답사자료',
                        '명함_연락처','고객_피드백_후기','리스크_이슈기록','회의_미팅자료'
                      )),

  -- 사업부 자동 매핑 (customers.사업부 default)
  사업부_자동매핑    varchar(20)
                      CHECK (사업부_자동매핑 IS NULL OR 사업부_자동매핑 IN ('국내여행','행사이벤트','온라인마케팅','마케팅교육')),

  -- 파일 메타
  파일명             varchar(200) NOT NULL,
  표시명             varchar(200),
  storage_path       text NOT NULL,
  mime_타입          varchar(100),
  파일크기           bigint NOT NULL DEFAULT 0,
  태그               text[],

  -- 자동 첨부 토글 (5종 발송 종류)
  자동첨부_계약      boolean NOT NULL DEFAULT false,
  자동첨부_공문      boolean NOT NULL DEFAULT false,
  자동첨부_견적      boolean NOT NULL DEFAULT false,
  자동첨부_보고      boolean NOT NULL DEFAULT false,
  자동첨부_정산      boolean NOT NULL DEFAULT false,

  -- OCR (Phase 2 useB API용 / 현재 NULL 허용)
  ocr_추출데이터     jsonb,

  -- 보존·권한
  보존기간_년        integer
                      CHECK (보존기간_년 IS NULL OR 보존기간_년 BETWEEN 1 AND 99),
  권한               varchar(20) NOT NULL DEFAULT 'all'
                      CHECK (권한 IN ('all','manager_plus','owner_only')),

  업로더             varchar(50),
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.file_attachments                IS '고객 파일 탭 (Tier 1·2·3 / 통합 설계서 v1.0 §3)';
COMMENT ON COLUMN public.file_attachments.카테고리        IS '19종 폴더 (Tier 1 7 + Tier 2 5 + Tier 3 7)';
COMMENT ON COLUMN public.file_attachments.사업부_자동매핑 IS 'customers.사업부 자동 (사업부별 필터링용)';
COMMENT ON COLUMN public.file_attachments.storage_path    IS 'Supabase Storage 경로 (assets/biz_certs/photos/docs)';
COMMENT ON COLUMN public.file_attachments.권한            IS 'all=전권한 / manager_plus=manager+owner / owner_only=owner만';

-- 인덱스
CREATE INDEX IF NOT EXISTS idx_file_attachments_customer  ON public.file_attachments(customer_id);
CREATE INDEX IF NOT EXISTS idx_file_attachments_카테고리  ON public.file_attachments(customer_id, 카테고리);
CREATE INDEX IF NOT EXISTS idx_file_attachments_사업부    ON public.file_attachments(사업부_자동매핑) WHERE 사업부_자동매핑 IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_file_attachments_시간      ON public.file_attachments(created_at DESC);

-- updated_at 트리거
CREATE OR REPLACE FUNCTION public.fn_file_attachments_touch()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_file_attachments_touch ON public.file_attachments;
CREATE TRIGGER trg_file_attachments_touch
BEFORE UPDATE ON public.file_attachments
FOR EACH ROW EXECUTE FUNCTION public.fn_file_attachments_touch();


-- ============================================================================
-- ▶ 블록 3. RLS 정책 4종 (권한 컬럼 기반 동적 + sql/020 v2 fn_is_role 정합)
-- ============================================================================
ALTER TABLE public.file_attachments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "fa_select_by_권한" ON public.file_attachments;
DROP POLICY IF EXISTS "fa_insert_authenticated" ON public.file_attachments;
DROP POLICY IF EXISTS "fa_update_manager_plus" ON public.file_attachments;
DROP POLICY IF EXISTS "fa_delete_owner" ON public.file_attachments;

-- SELECT: 권한 컬럼에 따라 동적
CREATE POLICY "fa_select_by_권한" ON public.file_attachments
  FOR SELECT TO authenticated
  USING (
    (권한 = 'all'         AND public.fn_is_role(ARRAY['owner','manager','viewer']))
    OR (권한 = 'manager_plus' AND public.fn_is_role(ARRAY['owner','manager']))
    OR (권한 = 'owner_only'   AND public.fn_is_role(ARRAY['owner']))
  );

-- INSERT: manager+ (viewer는 업로드 불가)
CREATE POLICY "fa_insert_authenticated" ON public.file_attachments
  FOR INSERT TO authenticated
  WITH CHECK (public.fn_is_role(ARRAY['owner','manager']));

-- UPDATE: 메타데이터 변경(태그·표시명·자동첨부 토글) manager+
CREATE POLICY "fa_update_manager_plus" ON public.file_attachments
  FOR UPDATE TO authenticated
  USING      (public.fn_is_role(ARRAY['owner','manager']))
  WITH CHECK (public.fn_is_role(ARRAY['owner','manager']));

-- DELETE: owner만
CREATE POLICY "fa_delete_owner" ON public.file_attachments
  FOR DELETE TO authenticated
  USING (public.fn_is_role(ARRAY['owner']));


-- ============================================================================
-- ▶ 블록 4. RPC (1) rpc_list_files_by_customer — 카테고리별 그룹화 목록
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_list_files_by_customer(_customer_id uuid)
RETURNS TABLE(
  r_id uuid,
  r_customer_id uuid,
  r_카테고리 varchar,
  r_사업부_자동매핑 varchar,
  r_파일명 varchar,
  r_표시명 varchar,
  r_storage_path text,
  r_mime_타입 varchar,
  r_파일크기 bigint,
  r_태그 text[],
  r_자동첨부_계약 boolean,
  r_자동첨부_공문 boolean,
  r_자동첨부_견적 boolean,
  r_자동첨부_보고 boolean,
  r_자동첨부_정산 boolean,
  r_보존기간_년 integer,
  r_권한 varchar,
  r_업로더 varchar,
  r_created_at timestamptz,
  r_updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  RETURN QUERY
  SELECT f.id, f.customer_id, f.카테고리, f.사업부_자동매핑,
         f.파일명, f.표시명, f.storage_path, f.mime_타입, f.파일크기, f.태그,
         f.자동첨부_계약, f.자동첨부_공문, f.자동첨부_견적, f.자동첨부_보고, f.자동첨부_정산,
         f.보존기간_년, f.권한, f.업로더,
         f.created_at, f.updated_at
  FROM public.file_attachments f
  WHERE f.customer_id = _customer_id
    -- RLS 권한 정합 (안전 이중 체크)
    AND (
      (f.권한 = 'all'          AND public.fn_is_role(ARRAY['owner','manager','viewer']))
      OR (f.권한 = 'manager_plus' AND public.fn_is_role(ARRAY['owner','manager']))
      OR (f.권한 = 'owner_only'   AND public.fn_is_role(ARRAY['owner']))
    )
  ORDER BY f.카테고리 ASC, f.created_at DESC;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_list_files_by_customer(uuid) TO authenticated, service_role;


-- ============================================================================
-- ▶ 블록 5. RPC (2) rpc_get_auto_attach_files — 발송 종류별 자동 첨부 파일
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_get_auto_attach_files(_customer_id uuid, _발송종류 text)
RETURNS TABLE(
  r_id uuid,
  r_카테고리 varchar,
  r_파일명 varchar,
  r_storage_path text,
  r_mime_타입 varchar,
  r_파일크기 bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- 발송종류: '계약'·'공문'·'견적'·'보고'·'정산' 중 하나
  IF _발송종류 NOT IN ('계약','공문','견적','보고','정산') THEN
    RAISE EXCEPTION '발송종류 invalid: %', _발송종류;
  END IF;

  RETURN QUERY
  SELECT f.id, f.카테고리, f.파일명, f.storage_path, f.mime_타입, f.파일크기
  FROM public.file_attachments f
  WHERE f.customer_id = _customer_id
    AND CASE _발송종류
          WHEN '계약' THEN f.자동첨부_계약
          WHEN '공문' THEN f.자동첨부_공문
          WHEN '견적' THEN f.자동첨부_견적
          WHEN '보고' THEN f.자동첨부_보고
          WHEN '정산' THEN f.자동첨부_정산
        END = true
    AND (
      (f.권한 = 'all'          AND public.fn_is_role(ARRAY['owner','manager','viewer']))
      OR (f.권한 = 'manager_plus' AND public.fn_is_role(ARRAY['owner','manager']))
      OR (f.권한 = 'owner_only'   AND public.fn_is_role(ARRAY['owner']))
    )
  ORDER BY f.카테고리 ASC, f.created_at DESC;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_get_auto_attach_files(uuid, text) TO authenticated, service_role;


-- ============================================================================
-- ▶ 블록 6. RPC (3) rpc_upsert_file_attachment — INSERT/UPDATE
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_upsert_file_attachment(_payload jsonb)
RETURNS TABLE(r_id uuid, r_카테고리 varchar, r_파일명 varchar, r_action text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _id uuid;
  _action text;
  _cid uuid;
  _category varchar(30);
  _사업부 varchar(20);
BEGIN
  _cid := (_payload->>'customer_id')::uuid;
  _category := _payload->>'카테고리';

  -- 카테고리별 default 자동첨부 매트릭스 (통합 설계서 §3-5)
  IF _payload IS NULL OR _category IS NULL THEN
    RAISE EXCEPTION 'customer_id·카테고리 필수';
  END IF;

  -- customers.사업부 자동 채움 (사업부_자동매핑 미지정 시)
  IF _payload->>'사업부_자동매핑' IS NULL THEN
    SELECT c.사업부 INTO _사업부 FROM public.customers c WHERE c.id = _cid;
  ELSE
    _사업부 := _payload->>'사업부_자동매핑';
  END IF;

  IF _payload ? 'id' AND (_payload->>'id') IS NOT NULL AND (_payload->>'id') <> '' THEN
    -- UPDATE
    _id := (_payload->>'id')::uuid;
    UPDATE public.file_attachments SET
      카테고리           = COALESCE(_category, 카테고리),
      사업부_자동매핑    = COALESCE(_사업부, 사업부_자동매핑),
      파일명             = COALESCE(_payload->>'파일명', 파일명),
      표시명             = _payload->>'표시명',
      storage_path       = COALESCE(_payload->>'storage_path', storage_path),
      mime_타입          = _payload->>'mime_타입',
      파일크기           = COALESCE((_payload->>'파일크기')::bigint, 파일크기),
      태그               = CASE WHEN _payload ? '태그'
                                THEN ARRAY(SELECT jsonb_array_elements_text(_payload->'태그'))
                                ELSE 태그 END,
      자동첨부_계약      = COALESCE((_payload->>'자동첨부_계약')::boolean, 자동첨부_계약),
      자동첨부_공문      = COALESCE((_payload->>'자동첨부_공문')::boolean, 자동첨부_공문),
      자동첨부_견적      = COALESCE((_payload->>'자동첨부_견적')::boolean, 자동첨부_견적),
      자동첨부_보고      = COALESCE((_payload->>'자동첨부_보고')::boolean, 자동첨부_보고),
      자동첨부_정산      = COALESCE((_payload->>'자동첨부_정산')::boolean, 자동첨부_정산),
      ocr_추출데이터     = COALESCE(_payload->'ocr_추출데이터', ocr_추출데이터),
      보존기간_년        = COALESCE((_payload->>'보존기간_년')::integer, 보존기간_년),
      권한               = COALESCE(_payload->>'권한', 권한),
      업로더             = COALESCE(_payload->>'업로더', 업로더),
      updated_at         = now()
    WHERE id = _id;
    _action := 'update';
  ELSE
    -- INSERT (default 자동첨부 매트릭스는 클라이언트 책임 / payload에 포함)
    INSERT INTO public.file_attachments (
      customer_id, 카테고리, 사업부_자동매핑,
      파일명, 표시명, storage_path, mime_타입, 파일크기, 태그,
      자동첨부_계약, 자동첨부_공문, 자동첨부_견적, 자동첨부_보고, 자동첨부_정산,
      ocr_추출데이터, 보존기간_년, 권한, 업로더
    ) VALUES (
      _cid, _category, _사업부,
      _payload->>'파일명',
      _payload->>'표시명',
      _payload->>'storage_path',
      _payload->>'mime_타입',
      COALESCE((_payload->>'파일크기')::bigint, 0),
      CASE WHEN _payload ? '태그'
           THEN ARRAY(SELECT jsonb_array_elements_text(_payload->'태그'))
           ELSE NULL END,
      COALESCE((_payload->>'자동첨부_계약')::boolean, false),
      COALESCE((_payload->>'자동첨부_공문')::boolean, false),
      COALESCE((_payload->>'자동첨부_견적')::boolean, false),
      COALESCE((_payload->>'자동첨부_보고')::boolean, false),
      COALESCE((_payload->>'자동첨부_정산')::boolean, false),
      _payload->'ocr_추출데이터',
      (_payload->>'보존기간_년')::integer,
      COALESCE(_payload->>'권한', 'all'),
      _payload->>'업로더'
    ) RETURNING id INTO _id;
    _action := 'insert';
  END IF;

  RETURN QUERY SELECT f.id, f.카테고리, f.파일명, _action
    FROM public.file_attachments f WHERE f.id = _id;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_file_attachment(jsonb) TO authenticated, service_role;


-- ============================================================================
-- ▶ 블록 7. RPC (4) rpc_delete_file_attachment — 삭제 (owner만)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.rpc_delete_file_attachment(_id uuid)
RETURNS TABLE(r_id uuid, r_deleted boolean, r_storage_path text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _exists boolean;
  _path text;
BEGIN
  SELECT EXISTS(SELECT 1 FROM public.file_attachments WHERE id = _id),
         (SELECT storage_path FROM public.file_attachments WHERE id = _id)
    INTO _exists, _path;

  IF NOT _exists THEN
    RETURN QUERY SELECT _id, false, NULL::text;
    RETURN;
  END IF;

  -- 권한 체크 (RLS 보강)
  IF NOT public.fn_is_role(ARRAY['owner']) THEN
    RAISE EXCEPTION 'owner 권한 필요';
  END IF;

  DELETE FROM public.file_attachments WHERE id = _id;
  RETURN QUERY SELECT _id, true, _path;
  -- 클라이언트는 r_storage_path를 받아 Supabase Storage에서 별도 삭제 호출
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_delete_file_attachment(uuid) TO authenticated, service_role;


-- ============================================================================
-- ▶ 블록 8. Storage Bucket 4종 (선언적 / 콘솔에서도 동일 효과)
--    대표님 콘솔 작업 권장 (RLS 정책은 본 SQL에서 일괄 처리)
-- ============================================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  ('assets',     'assets',     false, 10485760,  ARRAY['image/png','image/jpeg','application/pdf']),
  ('biz_certs',  'biz_certs',  false, 10485760,  ARRAY['application/pdf','image/png','image/jpeg']),
  ('photos',     'photos',     false, 52428800,  ARRAY['image/png','image/jpeg','image/webp','video/mp4']),
  ('docs',       'docs',       false, 52428800,  ARRAY['application/pdf','application/msword',
                                                       'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
                                                       'application/vnd.ms-excel',
                                                       'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
ON CONFLICT (id) DO UPDATE SET
  public = EXCLUDED.public,
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;


-- ============================================================================
-- ▶ 블록 9. Storage RLS 정책 (4 Bucket / 인증자 기반)
-- ============================================================================

-- assets (회사 정적 자산 / manager+ 업로드·삭제 / 모든 인증자 SELECT)
DROP POLICY IF EXISTS "stg_assets_select" ON storage.objects;
DROP POLICY IF EXISTS "stg_assets_insert" ON storage.objects;
DROP POLICY IF EXISTS "stg_assets_update" ON storage.objects;
DROP POLICY IF EXISTS "stg_assets_delete" ON storage.objects;

CREATE POLICY "stg_assets_select" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'assets' AND public.fn_is_role(ARRAY['owner','manager','viewer']));

CREATE POLICY "stg_assets_insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'assets' AND public.fn_is_role(ARRAY['owner','manager']));

CREATE POLICY "stg_assets_update" ON storage.objects
  FOR UPDATE TO authenticated
  USING      (bucket_id = 'assets' AND public.fn_is_role(ARRAY['owner','manager']))
  WITH CHECK (bucket_id = 'assets' AND public.fn_is_role(ARRAY['owner','manager']));

CREATE POLICY "stg_assets_delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'assets' AND public.fn_is_role(ARRAY['owner']));


-- biz_certs (고객 사업자등록증 / manager+ / 민감)
DROP POLICY IF EXISTS "stg_biz_select" ON storage.objects;
DROP POLICY IF EXISTS "stg_biz_insert" ON storage.objects;
DROP POLICY IF EXISTS "stg_biz_update" ON storage.objects;
DROP POLICY IF EXISTS "stg_biz_delete" ON storage.objects;

CREATE POLICY "stg_biz_select" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'biz_certs' AND public.fn_is_role(ARRAY['owner','manager']));

CREATE POLICY "stg_biz_insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'biz_certs' AND public.fn_is_role(ARRAY['owner','manager']));

CREATE POLICY "stg_biz_update" ON storage.objects
  FOR UPDATE TO authenticated
  USING      (bucket_id = 'biz_certs' AND public.fn_is_role(ARRAY['owner','manager']))
  WITH CHECK (bucket_id = 'biz_certs' AND public.fn_is_role(ARRAY['owner','manager']));

CREATE POLICY "stg_biz_delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'biz_certs' AND public.fn_is_role(ARRAY['owner']));


-- photos (운영사진 / 모든 인증자 / 마케팅 활용)
DROP POLICY IF EXISTS "stg_photos_select" ON storage.objects;
DROP POLICY IF EXISTS "stg_photos_insert" ON storage.objects;
DROP POLICY IF EXISTS "stg_photos_update" ON storage.objects;
DROP POLICY IF EXISTS "stg_photos_delete" ON storage.objects;

CREATE POLICY "stg_photos_select" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'photos' AND public.fn_is_role(ARRAY['owner','manager','viewer']));

CREATE POLICY "stg_photos_insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'photos' AND public.fn_is_role(ARRAY['owner','manager']));

CREATE POLICY "stg_photos_update" ON storage.objects
  FOR UPDATE TO authenticated
  USING      (bucket_id = 'photos' AND public.fn_is_role(ARRAY['owner','manager']))
  WITH CHECK (bucket_id = 'photos' AND public.fn_is_role(ARRAY['owner','manager']));

CREATE POLICY "stg_photos_delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'photos' AND public.fn_is_role(ARRAY['owner']));


-- docs (제안서·계약서·공문·세금계산서 PDF / manager+ 일반 / 세금계산서는 file_attachments 권한 컬럼)
DROP POLICY IF EXISTS "stg_docs_select" ON storage.objects;
DROP POLICY IF EXISTS "stg_docs_insert" ON storage.objects;
DROP POLICY IF EXISTS "stg_docs_update" ON storage.objects;
DROP POLICY IF EXISTS "stg_docs_delete" ON storage.objects;

CREATE POLICY "stg_docs_select" ON storage.objects
  FOR SELECT TO authenticated
  USING (bucket_id = 'docs' AND public.fn_is_role(ARRAY['owner','manager','viewer']));

CREATE POLICY "stg_docs_insert" ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'docs' AND public.fn_is_role(ARRAY['owner','manager']));

CREATE POLICY "stg_docs_update" ON storage.objects
  FOR UPDATE TO authenticated
  USING      (bucket_id = 'docs' AND public.fn_is_role(ARRAY['owner','manager']))
  WITH CHECK (bucket_id = 'docs' AND public.fn_is_role(ARRAY['owner','manager']));

CREATE POLICY "stg_docs_delete" ON storage.objects
  FOR DELETE TO authenticated
  USING (bucket_id = 'docs' AND public.fn_is_role(ARRAY['owner']));


-- ============================================================================
-- ✅ sql/029 완료
-- 검증 쿼리:
--   1) SELECT column_name FROM information_schema.columns
--      WHERE table_name='customers' AND column_name IN ('사업자번호','법인등록번호','회사주소','사업자유형');
--   2) SELECT count(*) FROM information_schema.tables WHERE table_name='file_attachments';
--   3) SELECT count(*) FROM pg_policies WHERE tablename='file_attachments';  -- 4
--   4) SELECT count(*) FROM pg_proc WHERE proname LIKE 'rpc_%file%';  -- 3 (list/upsert/delete) + rpc_get_auto_attach_files = 4
--   5) SELECT id, file_size_limit FROM storage.buckets WHERE id IN ('assets','biz_certs','photos','docs');
-- ============================================================================
