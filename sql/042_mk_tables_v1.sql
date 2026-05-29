-- =====================================================
-- sql/042_mk_tables_v1.sql
-- 마케팅 풀오토 v1 — mk_* 4테이블 + RLS + 인덱스
-- 메모리 정합: project_marketing_separation (admin core 분리)
-- 작성: 2026-05-06 / 40차
-- =====================================================

-- ───────────────────────────────────────────────
-- 1. mk_blog_slots — 블로그 슬롯 (스케줄DB 미러)
-- ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.mk_blog_slots (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  발행일 DATE NOT NULL,
  채널 VARCHAR(20) NOT NULL CHECK (채널 IN ('블A네이버','블A티스토리','블B네이버','블B티스토리','블C네이버','블C티스토리')),
  슬롯유형 VARCHAR(20) NOT NULL CHECK (슬롯유형 IN ('정보성','예고','B2B선제','B2B임박')),
  핵심키워드 TEXT NOT NULL,
  콘텐츠방향 TEXT,
  최종제목 TEXT,
  본문_네이버 TEXT,
  본문_티스토리 TEXT,
  이미지프롬프트 JSONB DEFAULT '[]'::jsonb,
  자가검증_결과 JSONB DEFAULT '{}'::jsonb,
  상태 VARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (상태 IN ('pending','in_progress','completed','halted')),
  노션페이지id TEXT,
  티스토리포스트id TEXT,
  docx_경로 TEXT,
  실행로그 JSONB DEFAULT '[]'::jsonb,
  생성일 TIMESTAMPTZ DEFAULT NOW(),
  수정일 TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_mk_blog_slots_발행일 ON public.mk_blog_slots(발행일);
CREATE INDEX IF NOT EXISTS idx_mk_blog_slots_상태 ON public.mk_blog_slots(상태);
CREATE INDEX IF NOT EXISTS idx_mk_blog_slots_채널 ON public.mk_blog_slots(채널);

COMMENT ON TABLE public.mk_blog_slots IS '마케팅 블로그 풀오토 v1 — 슬롯 단위 STAGE 0~7 추적 / 메모리 project_marketing_fullauto_v1';

-- ───────────────────────────────────────────────
-- 2. mk_keywords — 연관키워드DB
-- ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.mk_keywords (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  카테고리 VARCHAR(30) NOT NULL,
  키워드 VARCHAR(100) NOT NULL,
  검색량 INTEGER,
  경쟁도 VARCHAR(10) CHECK (경쟁도 IN ('낮음','중간','높음')),
  시즌 VARCHAR(10) CHECK (시즌 IN ('봄','여름','가을','겨울','연중')),
  검증일 DATE DEFAULT CURRENT_DATE,
  활성 BOOLEAN DEFAULT TRUE,
  생성일 TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (카테고리, 키워드)
);

CREATE INDEX IF NOT EXISTS idx_mk_keywords_카테고리 ON public.mk_keywords(카테고리);
CREATE INDEX IF NOT EXISTS idx_mk_keywords_활성 ON public.mk_keywords(활성);

COMMENT ON TABLE public.mk_keywords IS '연관키워드DB — 네이버 검색광고 API 검증값';

-- ───────────────────────────────────────────────
-- 3. mk_portfolio — 포트폴리오DB (F6 매칭용)
-- ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.mk_portfolio (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  사례명 TEXT NOT NULL,
  사업부 VARCHAR(30) NOT NULL,
  연도 INTEGER,
  URL TEXT,
  키워드 TEXT[],
  실적수치 JSONB DEFAULT '{}'::jsonb,
  활성 BOOLEAN DEFAULT TRUE,
  생성일 TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_mk_portfolio_사업부 ON public.mk_portfolio(사업부);
CREATE INDEX IF NOT EXISTS idx_mk_portfolio_활성 ON public.mk_portfolio(활성);
CREATE INDEX IF NOT EXISTS idx_mk_portfolio_키워드_gin ON public.mk_portfolio USING GIN (키워드);

COMMENT ON TABLE public.mk_portfolio IS '포트폴리오DB — F6 사례 매칭 (스킬 v7.7) / URL 자체 단독·정량';

-- ───────────────────────────────────────────────
-- 4. mk_api_logs — API 호출 모니터링
-- ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.mk_api_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  호출시각 TIMESTAMPTZ DEFAULT NOW(),
  api_종류 VARCHAR(30) NOT NULL CHECK (api_종류 IN ('naver_search_ad','naver_search','gsc','anthropic','notion','tistory','smtp')),
  슬롯id UUID REFERENCES public.mk_blog_slots(id) ON DELETE SET NULL,
  요청_요약 TEXT,
  응답_상태 INTEGER,
  응답_요약 JSONB DEFAULT '{}'::jsonb,
  비용_usd NUMERIC(10,4) DEFAULT 0,
  에러 TEXT
);

CREATE INDEX IF NOT EXISTS idx_mk_api_logs_호출시각 ON public.mk_api_logs(호출시각 DESC);
CREATE INDEX IF NOT EXISTS idx_mk_api_logs_api_종류 ON public.mk_api_logs(api_종류);
CREATE INDEX IF NOT EXISTS idx_mk_api_logs_슬롯id ON public.mk_api_logs(슬롯id);

COMMENT ON TABLE public.mk_api_logs IS 'API 호출 로그 + 비용 모니터링 ($50 한도 추적)';

-- ───────────────────────────────────────────────
-- 5. RLS — service_role 전용 (EF 직접 호출) + authenticated read-only
-- ───────────────────────────────────────────────
ALTER TABLE public.mk_blog_slots ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mk_keywords ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mk_portfolio ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mk_api_logs ENABLE ROW LEVEL SECURITY;

-- mk_blog_slots
DROP POLICY IF EXISTS mk_blog_slots_service_all ON public.mk_blog_slots;
CREATE POLICY mk_blog_slots_service_all ON public.mk_blog_slots
  FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS mk_blog_slots_auth_read ON public.mk_blog_slots;
CREATE POLICY mk_blog_slots_auth_read ON public.mk_blog_slots
  FOR SELECT TO authenticated USING (TRUE);

-- mk_keywords
DROP POLICY IF EXISTS mk_keywords_service_all ON public.mk_keywords;
CREATE POLICY mk_keywords_service_all ON public.mk_keywords
  FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS mk_keywords_auth_read ON public.mk_keywords;
CREATE POLICY mk_keywords_auth_read ON public.mk_keywords
  FOR SELECT TO authenticated USING (TRUE);

-- mk_portfolio
DROP POLICY IF EXISTS mk_portfolio_service_all ON public.mk_portfolio;
CREATE POLICY mk_portfolio_service_all ON public.mk_portfolio
  FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS mk_portfolio_auth_read ON public.mk_portfolio;
CREATE POLICY mk_portfolio_auth_read ON public.mk_portfolio
  FOR SELECT TO authenticated USING (TRUE);

-- mk_api_logs (admin core read only / write = service_role)
DROP POLICY IF EXISTS mk_api_logs_service_all ON public.mk_api_logs;
CREATE POLICY mk_api_logs_service_all ON public.mk_api_logs
  FOR ALL TO service_role USING (TRUE) WITH CHECK (TRUE);

DROP POLICY IF EXISTS mk_api_logs_auth_read ON public.mk_api_logs;
CREATE POLICY mk_api_logs_auth_read ON public.mk_api_logs
  FOR SELECT TO authenticated USING (TRUE);

-- ───────────────────────────────────────────────
-- 6. GRANT
-- ───────────────────────────────────────────────
GRANT ALL ON public.mk_blog_slots TO service_role;
GRANT ALL ON public.mk_keywords TO service_role;
GRANT ALL ON public.mk_portfolio TO service_role;
GRANT ALL ON public.mk_api_logs TO service_role;

GRANT SELECT ON public.mk_blog_slots TO authenticated;
GRANT SELECT ON public.mk_keywords TO authenticated;
GRANT SELECT ON public.mk_portfolio TO authenticated;
GRANT SELECT ON public.mk_api_logs TO authenticated;

-- ───────────────────────────────────────────────
-- 7. 트리거 — 수정일 자동 갱신
-- ───────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_mk_blog_slots_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.수정일 = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_mk_blog_slots_updated_at ON public.mk_blog_slots;
CREATE TRIGGER trg_mk_blog_slots_updated_at
  BEFORE UPDATE ON public.mk_blog_slots
  FOR EACH ROW EXECUTE FUNCTION public.fn_mk_blog_slots_updated_at();

-- =====================================================
-- 끝 — sql/042 _mk_tables_v1
-- 검증: 4테이블 / 9 인덱스 / 8 RLS 정책 / 8 GRANT / 1 트리거
-- =====================================================
