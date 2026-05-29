-- sql/035 — contracts 테이블 authenticated SELECT/INSERT/UPDATE/DELETE GRANT
-- 33차-6 hotfix / 2026-05-03
-- 원인: sql/030 contracts 테이블 생성 시 RLS 정책만 부여 / authenticated GRANT 누락
--       → admin.html ecLoad의 c.from('contracts').select() 호출이 GRANT 단에서 403 차단
-- 해결: authenticated에 CRUD GRANT 부여 / RLS는 admin_all_contracts 정책으로 한 번 더 필터

GRANT SELECT, INSERT, UPDATE, DELETE ON public.contracts TO authenticated;

COMMENT ON TABLE public.contracts IS
  'sql/030 + sql/035: RLS admin_all_contracts (fn_current_is_admin) + authenticated CRUD GRANT';
