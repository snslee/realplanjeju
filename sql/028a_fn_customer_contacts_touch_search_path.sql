-- ============================================================================
-- 028a_fn_customer_contacts_touch_search_path.sql
-- 작성일: 2026-05-01 (28차 누적 search_path 핫픽스)
-- 목적: fn_customer_contacts_touch search_path 안전 강화
-- WARN: function_search_path_mutable
-- 의존: sql/028 (customer_contacts)
-- 라이브 적용: Supabase migration 20260501073246 (2026-05-01)
-- D드라이브 복원: 2026-05-03 (30차 회기 / Supabase에서 추출)
-- ============================================================================

-- 028a: fn_customer_contacts_touch search_path 안전 강화 (28차 누적 핫픽스)
-- WARN: function_search_path_mutable
CREATE OR REPLACE FUNCTION public.fn_customer_contacts_touch()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;
