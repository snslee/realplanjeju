-- ============================================================
-- 004_fix_dashboard_kpis_v2.sql
-- 작성일: 2026-04-25
-- 목적: rpc_dashboard_kpis가 deleted_at IS NULL 조건을 체크하지 않아
--       soft-deleted 데이터가 KPI 카운트에 포함되는 일관성 문제 해결
-- 학습: rpc_list_customers는 deleted_at IS NULL 조건 있음. KPI 함수도 동일하게 맞춤.
-- ============================================================

CREATE OR REPLACE FUNCTION public.rpc_dashboard_kpis()
RETURNS json
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
SELECT json_build_object(
  'new_count', (
    SELECT count(*) FROM public.customers
    WHERE deleted_at IS NULL
      AND "고객상태" IN ('신규문의','접수')
  ),
  'unresponsive_count', (
    SELECT count(*) FROM public.customers
    WHERE deleted_at IS NULL
      AND "고객상태" IN ('신규문의','접수')
      AND "마지막접촉일시" IS NULL
      AND now() - "신청일시" > INTERVAL '24 hours'
  ),
  'in_progress_count', (
    SELECT count(*) FROM public.customers
    WHERE deleted_at IS NULL
      AND "고객상태" IN ('확인','상담중','견적발송','계약대기')
  ),
  'completed_month', (
    SELECT count(*) FROM public.customers
    WHERE deleted_at IS NULL
      AND "고객상태" = '계약완료'
      AND "신청일시" >= date_trunc('month', now())
  ),
  'dropout_rate_3m', (
    WITH base AS (
      SELECT "고객상태" FROM public.customers
      WHERE deleted_at IS NULL
        AND "신청일시" >= now() - INTERVAL '90 days'
    )
    SELECT COALESCE(
      ROUND(100.0 * COUNT(*) FILTER (WHERE "고객상태" = '이탈')::numeric
        / NULLIF(COUNT(*), 0), 1),
      0
    )
    FROM base
  ),
  'top_business_unit', (
    SELECT "사업부" FROM public.customers
    WHERE deleted_at IS NULL
      AND "신청일시" >= date_trunc('month', now())
    GROUP BY "사업부" ORDER BY count(*) DESC LIMIT 1
  )
);
$function$;
