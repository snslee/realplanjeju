-- 087_yesterday_perf_window.sql (2026-06-05)
-- 디지스트 per-post 성과: 성과대상=최근4일 발행(GSC 2~3일 지연 흡수), 지표=최근7일 URL+채널별 최신
CREATE OR REPLACE FUNCTION public.rpc_blog_yesterday_performance()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  _yesterday date := (CURRENT_DATE - INTERVAL '1 day')::date;
  _result jsonb;
BEGIN
  WITH
  발행어제 AS (
    SELECT DISTINCT ON (public.fn_normalize_blog_url(외부_url), 채널)
      채널, public.fn_normalize_blog_url(외부_url) AS 정규화_url
    FROM mk_blog_publish_log
    WHERE 발행일 = _yesterday
    ORDER BY public.fn_normalize_blog_url(외부_url), 채널, 자동감지_시각 ASC
  ),
  성과대상 AS (
    SELECT DISTINCT ON (public.fn_normalize_blog_url(외부_url), 채널)
      채널, public.fn_normalize_blog_url(외부_url) AS 정규화_url, rss_제목, 발행일
    FROM mk_blog_publish_log
    WHERE 발행일 >= _yesterday - 3
    ORDER BY public.fn_normalize_blog_url(외부_url), 채널, 자동감지_시각 ASC
  ),
  성과 AS (
    SELECT DISTINCT ON (public.fn_normalize_blog_url(외부_url), 채널)
      채널, public.fn_normalize_blog_url(외부_url) AS 정규화_url,
      조회_수, 좋아요_수, 댓글_수, 노출_수, 클릭_수, ctr_pct, 평균_순위,
      체류_평균_초, 전환_수, roi_pct, 측정_일자
    FROM mk_metrics
    WHERE 측정_일자 >= CURRENT_DATE - 7 AND 외부_url IS NOT NULL
    ORDER BY public.fn_normalize_blog_url(외부_url), 채널, 측정_일자 DESC
  ),
  카운트 AS (
    SELECT 채널, COUNT(*) AS 발행_건수 FROM 발행어제 GROUP BY 채널
  )
  SELECT jsonb_build_object(
    'yesterday', _yesterday,
    'today', CURRENT_DATE,
    'counts', (SELECT jsonb_object_agg(채널, 발행_건수) FROM 카운트),
    'total', (SELECT COUNT(*) FROM 발행어제),
    'posts', (
      SELECT jsonb_agg(jsonb_build_object(
        '채널', p.채널, '제목', p.rss_제목, 'url', p.정규화_url, '발행일', p.발행일,
        '조회', COALESCE(s.조회_수, 0), '좋아요', COALESCE(s.좋아요_수, 0), '댓글', COALESCE(s.댓글_수, 0),
        '노출', COALESCE(s.노출_수, 0), '클릭', COALESCE(s.클릭_수, 0), 'ctr', COALESCE(s.ctr_pct, 0),
        '순위', COALESCE(s.평균_순위, 0), '체류초', COALESCE(s.체류_평균_초, 0),
        '전환', COALESCE(s.전환_수, 0), 'roi', COALESCE(s.roi_pct, 0),
        'metrics_매칭', CASE WHEN s.정규화_url IS NOT NULL THEN '✅' ELSE '❌' END
      ) ORDER BY p.발행일 DESC, p.채널)
      FROM 성과대상 p
      LEFT JOIN 성과 s ON s.채널 = p.채널 AND s.정규화_url = p.정규화_url
    ),
    'sleeping_giants', (
      SELECT jsonb_agg(jsonb_build_object(
        '제목', LEFT(외부_url, 60), 'url', 외부_url, '채널', 채널,
        '노출', 노출_수, '클릭', 클릭_수, '순위', 평균_순위
      ))
      FROM (
        SELECT * FROM mk_metrics
        WHERE 측정_일자 >= CURRENT_DATE - INTERVAL '7 days'
          AND 노출_수 > 500 AND ctr_pct < 3.0 AND 평균_순위 BETWEEN 5 AND 20
        ORDER BY 노출_수 DESC LIMIT 3
      ) t
    )
  ) INTO _result;
  RETURN _result;
END;
$function$;
