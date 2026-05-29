-- 071_mk_blog_algorithm_table.sql
-- 63차 Phase B1 (2026-05-30): 플랫폼별 알고리즘 버전 관리 테이블 신설
-- G_ALGO_STALE 감사룰 연동 (35일 초과 시 P2 경보)

CREATE TABLE IF NOT EXISTS public.mk_blog_algorithm (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  플랫폼 VARCHAR(50) NOT NULL,
  알고리즘_버전 VARCHAR(20),
  업데이트_주기_일 INTEGER DEFAULT 35,
  마지막_업데이트일 DATE,
  마지막_점검일 DATE,
  핵심변경사항 TEXT,
  참고링크 TEXT,
  비고 TEXT,
  활성 BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- UNIQUE 제약 (플랫폼당 1개 row)
ALTER TABLE public.mk_blog_algorithm
  ADD CONSTRAINT mk_blog_algorithm_플랫폼_unique UNIQUE (플랫폼);

-- RLS
ALTER TABLE public.mk_blog_algorithm ENABLE ROW LEVEL SECURITY;

CREATE POLICY "admin_all_mk_blog_algorithm" ON public.mk_blog_algorithm
  USING (public.fn_current_is_admin());

-- updated_at 자동 갱신 트리거
CREATE OR REPLACE FUNCTION public.fn_mk_blog_algorithm_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END;
$$;

CREATE TRIGGER trg_mk_blog_algorithm_updated_at
  BEFORE UPDATE ON public.mk_blog_algorithm
  FOR EACH ROW EXECUTE FUNCTION public.fn_mk_blog_algorithm_updated_at();

-- 초기 6플랫폼 데이터
INSERT INTO public.mk_blog_algorithm (플랫폼, 알고리즘_버전, 마지막_업데이트일, 마지막_점검일, 핵심변경사항) VALUES
  ('네이버블로그', 'v2026.05', '2026-05-01', '2026-05-29', '리뷰어 지수 + 체류시간 가중치 상향 / 이웃 공감 반응 강화'),
  ('티스토리',   'v2026.04', '2026-04-15', '2026-05-29', '구글 SEO 연동 강화 / 2000자 이상 우대 / 태그 5개 최적화'),
  ('인스타그램', 'v2026.05', '2026-05-01', '2026-05-29', '릴스 초반 3초 이탈율 중요 / 저장 수 가중치 상향 / 키워드 해시태그 5개 이내'),
  ('유튜브',    'v2026.05', '2026-05-10', '2026-05-29', 'Shorts 클릭률 + 시청지속시간 알고리즘 업데이트 / 커뮤니티 탭 노출 강화'),
  ('틱톡',     'v2026.05', '2026-05-15', '2026-05-29', '검색 노출 알고리즘 강화 / 키워드 자막 중요 / 7초 이상 체류 우대'),
  ('페이스북',  'v2026.05', '2026-05-20', '2026-05-29', '릴스 노출 강화 / 그룹 콘텐츠 축소 / 외부링크 도달률 감소 유지')
ON CONFLICT (플랫폼) DO NOTHING;
