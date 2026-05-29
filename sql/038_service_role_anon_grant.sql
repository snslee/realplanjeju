-- ============================================================================
-- sql/038 — service_role + anon GRANT 일괄 부여 (V77 hotfix)
-- 33차 종료 + v2.20 옵션 C 후속 / 2026-05-03
-- ============================================================================
-- 원인: Supabase 새 sb_secret_* 41글자 키 도입
--       → SUPABASE_SERVICE_ROLE_KEY 환경변수가 JWT 아닌 단축 시크릿 키
--       → PostgREST가 service_role로 인식 못함 → anon fallback
--       → 42501 permission denied for table contracts
-- 영향: send-contract Edge Function v3 contracts.SELECT 차단 (V77 발송 실패 원인)
-- 해결: service_role + anon 모두에 명시 GRANT
--       (RLS는 admin_all_* 정책으로 row 보호 유지 / 권한 상승 위험 0)
-- 검증: pg_net.http_post로 send-contract 직접 호출 → 200 OK + Naver SMTP 250 OK
--       → contracts.상태='발송완료' / 발송_횟수=1 / Naver mail_response 250 2.0.0 OK
-- ============================================================================

-- 핵심 5 테이블 (send-contract EF가 직접 SELECT)
GRANT SELECT, INSERT, UPDATE, DELETE ON public.contracts          TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.customers          TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.contract_templates TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.quotations         TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.file_attachments   TO service_role, anon;

-- 추가 13 테이블 (sql/036 패턴 / 일괄 정합)
GRANT SELECT, INSERT, UPDATE, DELETE ON public.consultation_notes      TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.status_history          TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.users                   TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.portfolio               TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.admin_access_log        TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inquiry_assignees       TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.customer_field_history  TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.product_catalog         TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vd_categories           TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vd_vendors              TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vd_contacts             TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.admin_permissions       TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.admin_permission_log    TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.official_documents      TO service_role, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.customer_contacts       TO service_role, anon;

-- 시퀀스 권한 (INSERT default 외 시퀀스 사용 대비)
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO service_role, anon;
