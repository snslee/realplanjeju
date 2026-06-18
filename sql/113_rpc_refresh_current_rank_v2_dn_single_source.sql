-- 113: rpc_refresh_current_rank v2.1 — 현재순위/진입판정 단일소스 교체 + 라벨 정규화
-- 배경(2026-06-18): 텔레그램 D+30 판정과 admin 현재순위/진입판정 4건중 3건 불일치.
-- 근본원인: 구 v1이 mk_metrics naver_search 평균_순위(5/26 멈춘 합성 placeholder=1.00, 노출·클릭·검색어 NULL)를
--   현재순위로 사용 → 실제 타깃키워드 61위인데 화면은 1위로 거짓 표시.
-- 조치: 텔레그램과 동일 소스인 D+N 실측 타깃키워드 순위를 단일소스로 사용.
--   D+N 미측정 글만 GSC 실측 평균순위(30일 신선도 게이트) 폴백. naver_search placeholder 완전 미사용.
-- 라벨: D+N 트래커(rpc_update_d_n_rank)·admin jmap/필터와 동일한 공백없는 버킷으로 통일
--   '✅1~5위'/'⚠️6~10위'/'🔶11~30위'/'❌미진입'/'측정중'. 현재순위 컬럼은 숫자 유지.
-- 결과: 텔레그램 4건 100% 일치. 분포 측정중57·❌미진입45·🔶11~30위16·⚠️6~10위10·✅1~5위10(138건).
-- cron job40(refresh-current-rank-daily, 22:40 KST)이 매일 호출.

CREATE OR REPLACE FUNCTION public.rpc_refresh_current_rank()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE n int;
BEGIN
  WITH dn AS (
    SELECT p.id, x.측정일, x.rank
    FROM mk_blog_publish_log p
    CROSS JOIN LATERAL (VALUES
      (p.d_plus_7_측정일,  p.d_plus_7_rank),
      (p.d_plus_14_측정일, p.d_plus_14_rank),
      (p.d_plus_30_측정일, p.d_plus_30_rank),
      (p.d_plus_90_측정일, p.d_plus_90_rank)
    ) AS x(측정일, rank)
    WHERE x.측정일 IS NOT NULL
  ),
  meas_any AS (
    SELECT id, true AS 측정됨,
      (SELECT rank FROM dn d2 WHERE d2.id = d1.id AND d2.rank IS NOT NULL
       ORDER BY 측정일 DESC LIMIT 1) AS r
    FROM dn d1 GROUP BY id
  ),
  gsc AS (
    SELECT DISTINCT ON (외부_url) 외부_url, round(평균_순위)::int AS r
    FROM mk_metrics
    WHERE 데이터_소스 = 'gsc' AND 평균_순위 IS NOT NULL
      AND 측정_일자 >= current_date - 30
    ORDER BY 외부_url, 측정_일자 DESC
  ),
  src AS (
    SELECT p.id,
      COALESCE(m.측정됨,false) AS dn_측정됨,
      CASE WHEN m.id IS NOT NULL THEN m.r ELSE g.r END AS r,
      (m.id IS NULL AND g.외부_url IS NULL) AS 측정중
    FROM mk_blog_publish_log p
    LEFT JOIN meas_any m ON m.id = p.id
    LEFT JOIN gsc g ON g.외부_url = p.외부_url
    WHERE p.외부_url IS NOT NULL
  )
  UPDATE mk_blog_publish_log p SET
    현재순위 = s.r,
    진입판정 = CASE
      WHEN s.측정중               THEN '측정중'
      WHEN s.r IS NULL OR s.r > 30 THEN '❌미진입'
      WHEN s.r <= 5              THEN '✅1~5위'
      WHEN s.r <= 10             THEN '⚠️6~10위'
      ELSE                            '🔶11~30위'
    END
  FROM src s WHERE p.id = s.id;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END$function$;
