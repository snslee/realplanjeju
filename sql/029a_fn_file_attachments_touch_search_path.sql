-- ============================================================================
-- 029a_fn_file_attachments_touch_search_path.sql
-- 작성일: 2026-05-01 (29차 search_path 핫픽스)
-- 목적: fn_file_attachments_touch search_path 안전 강화
-- WARN: function_search_path_mutable
-- 의존: sql/029 (file_attachments)
-- 라이브 적용: Supabase migration 20260501072900 (2026-05-01)
-- D드라이브 복원: 2026-05-03 (30차 회기 / Supabase에서 추출)
-- ============================================================================

-- 029a: fn_file_attachments_touch search_path 안전 강화
-- WARN: function_search_path_mutable
CREATE OR REPLACE FUNCTION public.fn_file_attachments_touch()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;
