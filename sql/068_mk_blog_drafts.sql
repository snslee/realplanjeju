-- sql/068 — mk_blog_drafts 신설 (62차 / 2026-05-29)
-- 목적: 블로그 초안 보관·검토·발행 연계 테이블
-- 설계: 27_블로그시스템_완성설계도_v1.0_2026-05-29.md §4.1

-- ▶ 1. 테이블 생성
CREATE TABLE IF NOT EXISTS public.mk_blog_drafts (
  id                UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  슬롯_id           UUID REFERENCES public.mk_blog_slots(id) ON DELETE SET NULL,
  채널              TEXT NOT NULL
                      CHECK (채널 IN (
                        '블A네이버','블A티스토리',
                        '블B네이버','블B티스토리',
                        '블C네이버','블C티스토리'
                      )),
  핵심키워드         TEXT,
  제목              TEXT,
  본문_네이버        TEXT,
  본문_티스토리      TEXT,
  자가검증_점수      NUMERIC(4,1),          -- 19.0 만점
  자가검증_결과      JSONB,                 -- 7항목 상세 {"F1":true,...}
  상태              TEXT NOT NULL DEFAULT 'draft'
                      CHECK (상태 IN ('draft','approved','published','rejected')),
  스킬_버전          TEXT,                  -- 'v7.8' 등
  알고리즘_버전      TEXT,                  -- 'v1.1' 등
  생성_방식          TEXT DEFAULT 'skill'
                      CHECK (생성_방식 IN ('skill','manual')),
  노션_페이지_id     TEXT,
  발행_url           TEXT,
  거절_사유          TEXT,
  생성일            TIMESTAMPTZ DEFAULT NOW(),
  수정일            TIMESTAMPTZ DEFAULT NOW(),
  승인일            TIMESTAMPTZ,
  발행일            TIMESTAMPTZ
);

-- ▶ 2. 인덱스
CREATE INDEX IF NOT EXISTS idx_mk_blog_drafts_채널
  ON public.mk_blog_drafts (채널);

CREATE INDEX IF NOT EXISTS idx_mk_blog_drafts_상태
  ON public.mk_blog_drafts (상태);

CREATE INDEX IF NOT EXISTS idx_mk_blog_drafts_생성일
  ON public.mk_blog_drafts (생성일 DESC);

CREATE INDEX IF NOT EXISTS idx_mk_blog_drafts_슬롯_id
  ON public.mk_blog_drafts (슬롯_id)
  WHERE 슬롯_id IS NOT NULL;

-- ▶ 3. 수정일 자동 갱신 트리거
CREATE OR REPLACE FUNCTION public.fn_mk_blog_drafts_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.수정일 = NOW();
  -- 상태 변경 시 시각 자동 기록
  IF NEW.상태 = 'approved' AND OLD.상태 != 'approved' THEN
    NEW.승인일 = NOW();
  END IF;
  IF NEW.상태 = 'published' AND OLD.상태 != 'published' THEN
    NEW.발행일 = NOW();
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER trg_mk_blog_drafts_updated_at
  BEFORE UPDATE ON public.mk_blog_drafts
  FOR EACH ROW EXECUTE FUNCTION public.fn_mk_blog_drafts_updated_at();

-- ▶ 4. RLS 활성화
ALTER TABLE public.mk_blog_drafts ENABLE ROW LEVEL SECURITY;

-- service_role: 전체 허용 (EF 내부 호출)
CREATE POLICY "service_role 전체 허용"
  ON public.mk_blog_drafts
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- authenticated: SELECT + UPDATE (본문 수정·승인)
CREATE POLICY "authenticated 읽기쓰기"
  ON public.mk_blog_drafts
  FOR ALL
  TO authenticated
  USING (true)
  WITH CHECK (true);

-- anon: SELECT only (admin blog.html anon_key 접근)
CREATE POLICY "anon 읽기"
  ON public.mk_blog_drafts
  FOR SELECT
  TO anon
  USING (true);

-- ▶ 5. GRANT
GRANT SELECT, INSERT, UPDATE ON public.mk_blog_drafts TO authenticated, anon, service_role;
GRANT USAGE ON SEQUENCE public.mk_blog_drafts_id_seq TO authenticated, service_role;

-- ▶ 6. PostgREST 스키마 캐시 갱신 (PGRST204 방지)
NOTIFY pgrst, 'reload schema';

-- ▶ 7. 검증 쿼리
SELECT
  c.column_name,
  c.data_type,
  c.column_default,
  c.is_nullable
FROM information_schema.columns c
WHERE c.table_name = 'mk_blog_drafts'
  AND c.table_schema = 'public'
ORDER BY c.ordinal_position;
-- 기대: 17개 컬럼 반환
