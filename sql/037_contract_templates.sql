-- ============================================================================
-- sql/037 — contract_templates (회사 전사 표준 별첨 템플릿)
-- 33차 종료 / v2.20 옵션 C — file_attachments 본래 설계 보존 + 별도 테이블 신설
-- ============================================================================
-- 목적: 4사업부 표준 계약서 PDF (별첨)을 회사 전사 단일 row로 보관
-- 의존: sql/030 (contracts) + fn_current_is_admin (sql/021)
-- 정합: §9 과잉 X (file_attachments customer_id NOT NULL 본래 설계 보존)
--       §11 확장 보존 (견적·공문·보고 별첨 통합 시 동일 패턴)
-- 적용: Supabase SQL Editor → 전체 복사 → Run (3 묶음 순차)
-- ============================================================================

-- ▶ 블록 A — contract_templates 테이블
CREATE TABLE IF NOT EXISTS public.contract_templates (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  사업부          varchar(20) NOT NULL
                    CHECK (사업부 IN ('행사이벤트','온라인마케팅','국내여행','마케팅교육')),
  카테고리        varchar(30) NOT NULL DEFAULT '계약서_표준'
                    CHECK (카테고리 IN ('계약서_표준','약관_별첨','부속서류','기타')),
  파일명          varchar(200) NOT NULL,
  표시명          varchar(200),
  storage_path    text NOT NULL,
  mime_타입       varchar(100) DEFAULT 'application/pdf',
  파일크기        bigint NOT NULL DEFAULT 0,

  -- 자동 첨부 토글 (5종 발송)
  자동첨부_계약   boolean NOT NULL DEFAULT true,
  자동첨부_공문   boolean NOT NULL DEFAULT false,
  자동첨부_견적   boolean NOT NULL DEFAULT false,
  자동첨부_보고   boolean NOT NULL DEFAULT false,
  자동첨부_정산   boolean NOT NULL DEFAULT false,

  활성            boolean NOT NULL DEFAULT true,
  비고            text,

  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.contract_templates                IS 'v2.20 옵션 C — 사업부별 전사 표준 별첨 (file_attachments 본래 설계 보존)';
COMMENT ON COLUMN public.contract_templates.사업부          IS '행사이벤트·온라인마케팅·국내여행·마케팅교육 (CHECK enum)';
COMMENT ON COLUMN public.contract_templates.storage_path    IS 'Supabase Storage 경로 (bucket: contract-templates)';

CREATE INDEX IF NOT EXISTS idx_contract_templates_사업부 ON public.contract_templates(사업부) WHERE 활성 = true;
CREATE INDEX IF NOT EXISTS idx_contract_templates_자동첨부_계약 ON public.contract_templates(자동첨부_계약, 사업부) WHERE 자동첨부_계약 = true AND 활성 = true;

ALTER TABLE public.contract_templates ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS contract_templates_select_all ON public.contract_templates;
CREATE POLICY contract_templates_select_all
  ON public.contract_templates FOR SELECT
  TO authenticated USING (true);

DROP POLICY IF EXISTS contract_templates_admin_write ON public.contract_templates;
CREATE POLICY contract_templates_admin_write
  ON public.contract_templates FOR ALL
  TO authenticated
  USING (public.fn_current_is_admin())
  WITH CHECK (public.fn_current_is_admin());

GRANT SELECT, INSERT, UPDATE, DELETE ON public.contract_templates TO authenticated;

CREATE OR REPLACE FUNCTION public.fn_contract_templates_touch()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_contract_templates_touch ON public.contract_templates;
CREATE TRIGGER trg_contract_templates_touch
  BEFORE UPDATE ON public.contract_templates
  FOR EACH ROW EXECUTE FUNCTION public.fn_contract_templates_touch();


-- ▶ 블록 B — Storage bucket 신설 + RLS
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('contract-templates', 'contract-templates', false, 10485760, ARRAY['application/pdf'])
ON CONFLICT (id) DO UPDATE SET
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "contract_templates_select_all" ON storage.objects;
CREATE POLICY "contract_templates_select_all"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (bucket_id = 'contract-templates');

DROP POLICY IF EXISTS "contract_templates_admin_write" ON storage.objects;
CREATE POLICY "contract_templates_admin_write"
  ON storage.objects FOR ALL
  TO authenticated
  USING (bucket_id = 'contract-templates' AND public.fn_current_is_admin())
  WITH CHECK (bucket_id = 'contract-templates' AND public.fn_current_is_admin());


-- ▶ 블록 C — 4 row INSERT (4사업부 매핑)
-- ⚠ Supabase Storage 파일명 검증: 한글 X / 영문·숫자·_·. 만 허용 → storage_path 영문 정합
INSERT INTO public.contract_templates
  (사업부, 카테고리, 파일명, 표시명, storage_path, 파일크기, 자동첨부_계약, 활성, 비고)
VALUES
  ('행사이벤트',   '계약서_표준', '01_event_v25.pdf',     '행사대행 계약서 v2.5 (표준약관·세부조항)',         'standards/01_event_v25.pdf',     134252, true, true, 'v2.5 최종완성본 / 3페이지 / 2026-05-03 LibreOffice 변환'),
  ('온라인마케팅', '계약서_표준', '02_marketing_v25.pdf', '마케팅 대행업무 계약서 v2.5 (표준약관·세부조항)',  'standards/02_marketing_v25.pdf', 120836, true, true, 'v2.5 최종완성본 / 3페이지 / 2026-05-03 LibreOffice 변환'),
  ('국내여행',     '계약서_표준', '03_tour_v25.pdf',      '국내여행 계약서 v2.5 (여행자용 표준약관 별첨 포함)','standards/03_tour_v25.pdf',      190194, true, true, 'v2.5 최종완성본 / 5페이지 (표준약관 별첨 포함) / 2026-05-03 LibreOffice 변환'),
  ('마케팅교육',   '계약서_표준', '04_education_v25.pdf', '마케팅 교육·컨설팅 계약서 v2.5 (표준약관·세부조항)','standards/04_education_v25.pdf', 139880, true, true, 'v2.5 최종완성본 / 4페이지 / 2026-05-03 LibreOffice 변환')
ON CONFLICT DO NOTHING;
