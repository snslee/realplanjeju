-- ============================================================================
-- sql/043 — P5 v1.1 신규 3테이블 (A/B 테스트 + 성과 + CRM 연결)
-- ============================================================================
-- 작성일: 2026-05-06 (v1.3 §5 정합)
-- 목적:
--   1. mk_ab_tests: 제목·썸네일 A/B + 승자 자동 게시 (Buffer Insights 패턴)
--   2. mk_metrics: 채널별 조회·전환·비용·키워드 순위 (HubSpot Reports 패턴)
--   3. mk_lead_sources: 마케팅 → CRM 리드 추적 (UTM·GA4 / HubSpot Lead Sources 패턴)
-- 의존:
--   - sql/042 (mk_blog_slots·mk_keywords·mk_portfolio·mk_api_logs 라이브)
-- 회귀:
--   - 기존 mk_* 테이블 변경 X
--   - 기존 EF mk-blog-fullauto 동작 영향 X
-- ============================================================================

-- ============================================================================
-- 1. mk_ab_tests — 제목·썸네일 A/B 테스트
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.mk_ab_tests (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  슬롯_id         uuid REFERENCES public.mk_blog_slots(id) ON DELETE CASCADE,
  변형_그룹       varchar(20) NOT NULL CHECK (변형_그룹 IN ('A', 'B', 'C')),
  변형_종류       varchar(20) NOT NULL CHECK (변형_종류 IN ('제목', '썸네일', '후크', '본문')),
  변형_내용       text NOT NULL,
  채널            varchar(30),
  발행_시각       timestamptz,
  노출_수         int DEFAULT 0,
  클릭_수         int DEFAULT 0,
  CTR             numeric(5,2),
  체류_평균_초    int DEFAULT 0,
  스크롤_70_pct   numeric(5,2),
  전환_수         int DEFAULT 0,
  승자_여부       boolean DEFAULT false,
  분석_시각       timestamptz,
  비고            text,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_mk_ab_slot ON public.mk_ab_tests(슬롯_id);
CREATE INDEX IF NOT EXISTS idx_mk_ab_winner ON public.mk_ab_tests(승자_여부) WHERE 승자_여부 = true;
CREATE INDEX IF NOT EXISTS idx_mk_ab_published ON public.mk_ab_tests(발행_시각) WHERE 발행_시각 IS NOT NULL;

-- ============================================================================
-- 2. mk_metrics — 일별 누적 성과 지표
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.mk_metrics (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  슬롯_id         uuid REFERENCES public.mk_blog_slots(id) ON DELETE CASCADE,
  채널            varchar(30) NOT NULL,
  외부_url        text,
  측정_일자       date NOT NULL,
  조회_수         int DEFAULT 0,
  좋아요_수       int DEFAULT 0,
  댓글_수         int DEFAULT 0,
  공유_수         int DEFAULT 0,
  키워드_순위     int,
  유입_검색량     int DEFAULT 0,
  유입_검색어     text[],
  체류_평균_초    int DEFAULT 0,
  이탈률_pct      numeric(5,2),
  전환_수         int DEFAULT 0,
  비용_원         int DEFAULT 0,
  ROI_pct         numeric(7,2),
  created_at      timestamptz DEFAULT now(),
  UNIQUE(슬롯_id, 채널, 측정_일자)
);

CREATE INDEX IF NOT EXISTS idx_mk_metrics_slot ON public.mk_metrics(슬롯_id);
CREATE INDEX IF NOT EXISTS idx_mk_metrics_date ON public.mk_metrics(측정_일자 DESC);
CREATE INDEX IF NOT EXISTS idx_mk_metrics_channel ON public.mk_metrics(채널, 측정_일자 DESC);

-- ============================================================================
-- 3. mk_lead_sources — 마케팅 → CRM 리드 추적 (UTM·GA4)
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.mk_lead_sources (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id     uuid REFERENCES public.customers(id) ON DELETE SET NULL,
  슬롯_id         uuid REFERENCES public.mk_blog_slots(id) ON DELETE SET NULL,
  utm_source      varchar(60),
  utm_medium      varchar(60),
  utm_campaign    varchar(120),
  utm_content     varchar(120),
  utm_term        varchar(120),
  유입_채널       varchar(30),
  유입_url        text,
  랜딩_페이지     text,
  세션_id         varchar(100),
  ga4_client_id   varchar(60),
  접속_시각       timestamptz NOT NULL DEFAULT now(),
  문의_여부       boolean DEFAULT false,
  문의_시각       timestamptz,
  견적_id         uuid,
  계약_여부       boolean DEFAULT false,
  매출_원         bigint DEFAULT 0,
  사업부          varchar(20),
  비고            text,
  created_at      timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_mk_lead_customer ON public.mk_lead_sources(customer_id) WHERE customer_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_mk_lead_slot ON public.mk_lead_sources(슬롯_id) WHERE 슬롯_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_mk_lead_utm ON public.mk_lead_sources(utm_source, utm_medium, utm_campaign);
CREATE INDEX IF NOT EXISTS idx_mk_lead_접속 ON public.mk_lead_sources(접속_시각 DESC);

-- ============================================================================
-- RLS 정책 (mk_ prefix 표준 정합)
-- ============================================================================

ALTER TABLE public.mk_ab_tests ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mk_metrics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.mk_lead_sources ENABLE ROW LEVEL SECURITY;

-- mk_ab_tests
CREATE POLICY mk_ab_tests_admin_all ON public.mk_ab_tests
  FOR ALL TO authenticated
  USING (fn_current_is_admin())
  WITH CHECK (fn_current_is_admin());

CREATE POLICY mk_ab_tests_service_all ON public.mk_ab_tests
  FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- mk_metrics
CREATE POLICY mk_metrics_admin_select ON public.mk_metrics
  FOR SELECT TO authenticated
  USING (fn_current_is_admin());

CREATE POLICY mk_metrics_service_all ON public.mk_metrics
  FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- mk_lead_sources
CREATE POLICY mk_lead_admin_select ON public.mk_lead_sources
  FOR SELECT TO authenticated
  USING (fn_current_is_admin());

CREATE POLICY mk_lead_service_all ON public.mk_lead_sources
  FOR ALL TO service_role
  USING (true) WITH CHECK (true);

-- anon 차단
REVOKE ALL ON public.mk_ab_tests FROM anon;
REVOKE ALL ON public.mk_metrics FROM anon;
REVOKE ALL ON public.mk_lead_sources FROM anon;

-- authenticated GRANT
GRANT SELECT ON public.mk_ab_tests TO authenticated;
GRANT INSERT, UPDATE ON public.mk_ab_tests TO authenticated;
GRANT SELECT ON public.mk_metrics TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.mk_lead_sources TO authenticated;

-- service_role 풀 권한
GRANT ALL ON public.mk_ab_tests TO service_role;
GRANT ALL ON public.mk_metrics TO service_role;
GRANT ALL ON public.mk_lead_sources TO service_role;

-- ============================================================================
-- 트리거 — updated_at 자동 갱신
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_mk_v11_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_mk_ab_tests_touch ON public.mk_ab_tests;
CREATE TRIGGER trg_mk_ab_tests_touch
  BEFORE UPDATE ON public.mk_ab_tests
  FOR EACH ROW EXECUTE FUNCTION fn_mk_v11_touch_updated_at();

-- ============================================================================
-- 검증 쿼리 (라이브 적용 후)
-- ============================================================================
-- (1) 3테이블 생성 확인
-- SELECT table_name FROM information_schema.tables
--   WHERE table_schema='public' AND table_name IN ('mk_ab_tests','mk_metrics','mk_lead_sources');
--
-- (2) RLS 정책 확인
-- SELECT tablename, policyname FROM pg_policies
--   WHERE tablename IN ('mk_ab_tests','mk_metrics','mk_lead_sources');
--
-- (3) GRANT 매트릭스 확인
-- SELECT grantee, privilege_type FROM information_schema.role_table_grants
--   WHERE table_name IN ('mk_ab_tests','mk_metrics','mk_lead_sources');
-- ============================================================================
