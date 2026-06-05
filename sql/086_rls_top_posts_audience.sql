-- 086_rls_top_posts_audience.sql (2026-06-05)
-- 키워드 인사이트 빈칸 복구: mk_top_posts / mk_audience_stats 읽기 정책 누락 보강
-- 미러: mk_keyword_pool kp_auth_read(authenticated:r) + kp_srv_all(service_role:*)

DROP POLICY IF EXISTS tp_auth_read ON mk_top_posts;
DROP POLICY IF EXISTS tp_srv_all ON mk_top_posts;
CREATE POLICY tp_auth_read ON mk_top_posts FOR SELECT TO authenticated USING (true);
CREATE POLICY tp_srv_all  ON mk_top_posts FOR ALL    TO service_role USING (true) WITH CHECK (true);

DROP POLICY IF EXISTS au_auth_read ON mk_audience_stats;
DROP POLICY IF EXISTS au_srv_all ON mk_audience_stats;
CREATE POLICY au_auth_read ON mk_audience_stats FOR SELECT TO authenticated USING (true);
CREATE POLICY au_srv_all  ON mk_audience_stats FOR ALL    TO service_role USING (true) WITH CHECK (true);

NOTIFY pgrst, 'reload schema';
