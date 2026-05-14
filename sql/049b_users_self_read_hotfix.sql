-- 핫픽스 / 45차 / 2026-05-14
-- agent.html 로그인 시 본인 row SELECT 허용
DROP POLICY IF EXISTS p_users_self_read ON public.users;
CREATE POLICY p_users_self_read ON public.users
  FOR SELECT TO authenticated
  USING (id = auth.uid());

NOTIFY pgrst, 'reload schema';
