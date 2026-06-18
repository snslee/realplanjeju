-- 114: rpc_due_for_d_n_check 큐 starvation 2종 수정 (2026-06-18)
-- 버그1: due 조건 'rank IS NULL' → 미진입 글 영구 재요청. '측정일 IS NULL'로 변경=1회 측정.
-- 버그2: 티스토리(EF가 skip)가 due 점유 → '채널 NOT LIKE %티스토리%' 제외.
-- 결과: due_d7 30(반 무효) → 18(실네이버). 정규 22시 실행에서 일괄 측정.
CREATE OR REPLACE FUNCTION public.rpc_due_for_d_n_check(_d integer)
 RETURNS TABLE(r_id uuid, "r_채널" character varying, "r_외부_url" text, "r_핵심키워드" character varying, "r_발행일" date)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  RETURN QUERY
  SELECT p.id::uuid, p.채널::varchar, p.외부_url::text,
         COALESCE(p.핵심키워드, s.핵심키워드)::varchar, p.발행일::date
  FROM public.mk_blog_publish_log p
  LEFT JOIN public.mk_blog_slots s ON s.id = p.매칭_슬롯_id
  WHERE p.발행일 <= (CURRENT_DATE - (_d - 2) * INTERVAL '1 day')
    AND p.외부_url NOT LIKE '%<![CDATA[%'
    AND p.채널 NOT LIKE '%티스토리%'
    AND COALESCE(p.핵심키워드, s.핵심키워드) IS NOT NULL
    AND (
      (_d = 7  AND p.d_plus_7_측정일  IS NULL) OR
      (_d = 14 AND p.d_plus_14_측정일 IS NULL) OR
      (_d = 30 AND p.d_plus_30_측정일 IS NULL) OR
      (_d = 90 AND p.d_plus_90_측정일 IS NULL)
    )
  ORDER BY p.발행일 ASC
  LIMIT 30;
END; $function$;
