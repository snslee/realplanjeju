-- sql/059_blog_analytics_phase1.sql
-- 51차 Phase 1 - 블로그 통계·순위·발행 추적 인프라
-- 본문 품질 영향: 0% / PC OFF 무관 / 한글 컬럼 표준 (§16)
-- 2026-05-21 라이브 적용 완료 (Supabase migration: 059_blog_analytics_phase1)

-- ============================================================
-- 1. mk_metrics 컬럼 확장 (GSC + Naver 통합)
-- ============================================================
ALTER TABLE public.mk_metrics
  ADD COLUMN IF NOT EXISTS 노출_수 integer,
  ADD COLUMN IF NOT EXISTS 클릭_수 integer,
  ADD COLUMN IF NOT EXISTS ctr_pct numeric(6,3),
  ADD COLUMN IF NOT EXISTS 평균_순위 numeric(6,2),
  ADD COLUMN IF NOT EXISTS 발행_시각 timestamptz,
  ADD COLUMN IF NOT EXISTS 수집_시각 timestamptz DEFAULT now(),
  ADD COLUMN IF NOT EXISTS 데이터_소스 varchar(32);

COMMENT ON COLUMN public.mk_metrics.데이터_소스 IS 'gsc · naver_datalab · naver_search · tistory_rss · manual';

-- ============================================================
-- 2. mk_rank_tracker — 키워드별 자체 URL 순위 추적
-- ============================================================
CREATE TABLE IF NOT EXISTS public.mk_rank_tracker (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  키워드 varchar(255) NOT NULL,
  채널 varchar(32) NOT NULL,
  측정_일자 date NOT NULL DEFAULT CURRENT_DATE,
  자체_url text,
  순위 integer,
  검색_결과_수 integer,
  검색_엔진 varchar(16) NOT NULL DEFAULT 'naver',
  수집_시각 timestamptz DEFAULT now(),
  CONSTRAINT mk_rank_tracker_unique UNIQUE (키워드, 채널, 측정_일자, 검색_엔진)
);
CREATE INDEX IF NOT EXISTS idx_mk_rank_tracker_채널_일자 ON public.mk_rank_tracker(채널, 측정_일자 DESC);
CREATE INDEX IF NOT EXISTS idx_mk_rank_tracker_키워드 ON public.mk_rank_tracker(키워드);
ALTER TABLE public.mk_rank_tracker ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_mk_rank_tracker_authenticated ON public.mk_rank_tracker;
CREATE POLICY p_mk_rank_tracker_authenticated ON public.mk_rank_tracker
  FOR ALL TO authenticated USING (true) WITH CHECK (true);
GRANT ALL ON public.mk_rank_tracker TO authenticated, service_role, anon;

-- ============================================================
-- 3. mk_blog_publish_log — 11 KST 발행 URL 자동 감지 로그
-- ============================================================
CREATE TABLE IF NOT EXISTS public.mk_blog_publish_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  발행일 date NOT NULL DEFAULT CURRENT_DATE,
  채널 varchar(32) NOT NULL,
  자동감지_시각 timestamptz DEFAULT now(),
  외부_url text NOT NULL,
  rss_제목 text,
  매칭_슬롯_id uuid REFERENCES public.mk_blog_slots(id) ON DELETE SET NULL,
  상태 varchar(16) NOT NULL DEFAULT '감지됨',
  오류_메시지 text,
  CONSTRAINT mk_blog_publish_log_url_unique UNIQUE (외부_url),
  CONSTRAINT mk_blog_publish_log_상태_check CHECK (상태 IN ('감지됨','슬롯매칭','노션반영','완료','실패'))
);
CREATE INDEX IF NOT EXISTS idx_mk_publish_log_발행일 ON public.mk_blog_publish_log(발행일 DESC);
CREATE INDEX IF NOT EXISTS idx_mk_publish_log_채널 ON public.mk_blog_publish_log(채널);
CREATE INDEX IF NOT EXISTS idx_mk_publish_log_상태 ON public.mk_blog_publish_log(상태);
ALTER TABLE public.mk_blog_publish_log ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS p_mk_publish_log_authenticated ON public.mk_blog_publish_log;
CREATE POLICY p_mk_publish_log_authenticated ON public.mk_blog_publish_log
  FOR ALL TO authenticated USING (true) WITH CHECK (true);
GRANT ALL ON public.mk_blog_publish_log TO authenticated, service_role, anon;

-- ============================================================
-- 4. RPC rpc_blog_daily_digest
-- 5. RPC rpc_blog_weekly_winners
-- 6. RPC rpc_upsert_mk_rank
-- (전체 SQL은 Supabase migration 059_blog_analytics_phase1 참조)
-- ============================================================

-- pg_cron 신규 4개 (51차 라이브):
-- jobid 9  blog-publish-detector-11kst   0 2 * * *
-- jobid 10 blog-stats-collector-11kst    5 2 * * *
-- jobid 11 blog-rank-tracker-21kst       0 12 * * *
-- jobid 12 notion-blog-sync-hourly       0 * * * *
-- pg_cron 추가 3개 (Phase 2·3):
-- jobid 13 blog-skill-suggest-weekly-mon 0 0 * * 1
-- jobid 14 blog-daily-digest-21kst       15 12 * * *
-- jobid 15 sitemap-submit-weekly-mon     10 0 * * 1

NOTIFY pgrst, 'reload schema';
