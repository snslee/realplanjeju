-- sql/036 — 모든 public 테이블 authenticated CRUD GRANT 일괄 부여
-- 33차-7 hotfix / 2026-05-03
-- 원인: sql/030~032 등 마이그레이션에서 GRANT 누락이 누적 (라이브에서는 RPC 경유로 가려져 있었음)
-- 해결: 일괄 GRANT (RLS는 그대로 활성 / admin_all_* 정책으로 row 보호)
-- 영향: 직접 SELECT/INSERT 시 GRANT 단 통과 / RLS 정책이 row 필터링 (admin만 모든 row)

GRANT SELECT, INSERT, UPDATE, DELETE ON public.customers TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.consultation_notes TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.status_history TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.quotations TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.users TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.portfolio TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.admin_access_log TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inquiry_assignees TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.customer_field_history TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.product_catalog TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vd_categories TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vd_vendors TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vd_contacts TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.admin_permissions TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.admin_permission_log TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.official_documents TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.customer_contacts TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.file_attachments TO authenticated;
