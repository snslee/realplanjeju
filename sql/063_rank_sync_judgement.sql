-- ============================================================
-- sql/063 — 상위노출 자동화 1차 복구 (URL 추적 + 진입판정)
-- 작성일: 2026-05-28
-- 설계서: v2.1 §13
-- 변경: mk_rank_tracker → mk_blog_publish_log 동기 + D+N + 진입판정 자동
-- 제외: D드라이브 폴더 이동 (대표님 제외 요청)
-- ============================================================

-- 1. URL 정규화 함수 (CDATA·fromRss=true 제거 + lowercase)
CREATE OR REPLACE FUNCTION public.fn_normalize_blog_url(_url text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF _url IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN
    regexp_replace(
      regexp_replace(
        regexp_replace(_url, '<!\[CDATA\[(.*?)\]\]>', '\1', 'g'),
        '\?fromRss=true.*$', '', 'g'
      ),
      '/$', '', 'g'
    );
END;
$$;

-- 2. mk_rank_tracker → mk_blog_publish_log 동기 + D+N 계산
-- 매일 23:00 KST 실행 / 모든 publish_log 글 대상
CREATE OR REPLACE FUNCTION public.rpc_sync_rank_to_log()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  _updated integer := 0;
  _judgement_updated integer := 0;
  _r record;
  _best_d7 integer;
  _best_d14 integer;
  _best_d30 integer;
  _best_d90 integer;
  _judgement text;
BEGIN
  -- 발행일이 있고 정상 매칭된 글만
  FOR _r IN
    SELECT id, 채널, 외부_url, 발행일, 핵심키워드
    FROM public.mk_blog_publish_log
    WHERE 발행일 IS NOT NULL
      AND 외부_url IS NOT NULL
  LOOP
    -- D+7 ±3일 / 최저 순위
    SELECT MIN(순위) INTO _best_d7
    FROM public.mk_rank_tracker rt
    WHERE rt.채널 = _r.채널
      AND public.fn_normalize_blog_url(rt.자체_url) = public.fn_normalize_blog_url(_r.외부_url)
      AND rt.측정_일자 BETWEEN _r.발행일 + INTERVAL '4 days' AND _r.발행일 + INTERVAL '10 days';

    -- D+14 ±3일
    SELECT MIN(순위) INTO _best_d14
    FROM public.mk_rank_tracker rt
    WHERE rt.채널 = _r.채널
      AND public.fn_normalize_blog_url(rt.자체_url) = public.fn_normalize_blog_url(_r.외부_url)
      AND rt.측정_일자 BETWEEN _r.발행일 + INTERVAL '11 days' AND _r.발행일 + INTERVAL '17 days';

    -- D+30 ±3일
    SELECT MIN(순위) INTO _best_d30
    FROM public.mk_rank_tracker rt
    WHERE rt.채널 = _r.채널
      AND public.fn_normalize_blog_url(rt.자체_url) = public.fn_normalize_blog_url(_r.외부_url)
      AND rt.측정_일자 BETWEEN _r.발행일 + INTERVAL '27 days' AND _r.발행일 + INTERVAL '33 days';

    -- D+90 ±5일
    SELECT MIN(순위) INTO _best_d90
    FROM public.mk_rank_tracker rt
    WHERE rt.채널 = _r.채널
      AND public.fn_normalize_blog_url(rt.자체_url) = public.fn_normalize_blog_url(_r.외부_url)
      AND rt.측정_일자 BETWEEN _r.발행일 + INTERVAL '85 days' AND _r.발행일 + INTERVAL '95 days';

    -- 진입판정 (D+30 우선 / 없으면 D+14 / 없으면 D+7)
    _judgement := CASE
      WHEN COALESCE(_best_d30, _best_d14, _best_d7) IS NULL THEN NULL
      WHEN COALESCE(_best_d30, _best_d14, _best_d7) BETWEEN 1 AND 5 THEN '✅1~5위'
      WHEN COALESCE(_best_d30, _best_d14, _best_d7) BETWEEN 6 AND 10 THEN '⚠️6~10위'
      WHEN COALESCE(_best_d30, _best_d14, _best_d7) BETWEEN 11 AND 30 THEN '🔶11~30위'
      ELSE '❌미진입'
    END;

    -- UPDATE
    UPDATE public.mk_blog_publish_log
    SET
      d_plus_7_rank = COALESCE(_best_d7, d_plus_7_rank),
      d_plus_7_측정일 = CASE WHEN _best_d7 IS NOT NULL THEN CURRENT_DATE ELSE d_plus_7_측정일 END,
      d_plus_14_rank = COALESCE(_best_d14, d_plus_14_rank),
      d_plus_14_측정일 = CASE WHEN _best_d14 IS NOT NULL THEN CURRENT_DATE ELSE d_plus_14_측정일 END,
      d_plus_30_rank = COALESCE(_best_d30, d_plus_30_rank),
      d_plus_30_측정일 = CASE WHEN _best_d30 IS NOT NULL THEN CURRENT_DATE ELSE d_plus_30_측정일 END,
      d_plus_90_rank = COALESCE(_best_d90, d_plus_90_rank),
      d_plus_90_측정일 = CASE WHEN _best_d90 IS NOT NULL THEN CURRENT_DATE ELSE d_plus_90_측정일 END,
      진입판정 = COALESCE(_judgement, 진입판정)
    WHERE id = _r.id;

    IF FOUND THEN
      _updated := _updated + 1;
      IF _judgement IS NOT NULL THEN
        _judgement_updated := _judgement_updated + 1;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'updated', _updated,
    'judgement_updated', _judgement_updated,
    'executed_at', now()
  );
END;
$$;

-- 3. pg_cron #25 — 매일 23:00 KST = 14:00 UTC
SELECT cron.schedule(
  'rank-sync-23kst',
  '0 14 * * *',
  $$SELECT public.rpc_sync_rank_to_log();$$
);

-- 4. EF 호출 cron #26 — 매일 23:15 KST = 14:15 UTC (notion-rank-pusher 호출)
SELECT cron.schedule(
  'notion-rank-pusher-2315kst',
  '15 14 * * *',
  $$SELECT net.http_post(
    url := 'https://iodfqlkeiwxyuojwcozv.supabase.co/functions/v1/notion-rank-pusher',
    headers := jsonb_build_object('Content-Type','application/json'),
    body := jsonb_build_object('trigger','pg_cron')
  );$$
);

-- 5. PostgREST 스키마 캐시 갱신
NOTIFY pgrst, 'reload schema';

-- ============================================================
-- 검증 쿼리 (배포 후 실행)
-- SELECT public.rpc_sync_rank_to_log();
-- SELECT COUNT(*), COUNT(*) FILTER (WHERE 진입판정 IS NOT NULL) FROM mk_blog_publish_log;
-- ============================================================
