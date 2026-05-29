-- sql/067 — Dead RPC 정리 (61차 / 2026-05-29)
-- 대상: admin.html + 전체 EF 소스 0참조 확인 후 DROP
-- §3 객관적 비평: 각 함수 폐기 근거 명시

-- 1. rpc_blog_daily_digest — rpc_blog_yesterday_performance 로 대체 (blog-daily-digest v3)
DROP FUNCTION IF EXISTS public.rpc_blog_daily_digest();

-- 2. rpc_blog_constitution_check — 설계 단계 함수, 실제 배포 후 미사용
DROP FUNCTION IF EXISTS public.rpc_blog_constitution_check();

-- 3. rpc_blog_monthly_performance — admin/EF 0참조 (월별 성과 뷰 v_blog_naver_monthly 등으로 대체)
DROP FUNCTION IF EXISTS public.rpc_blog_monthly_performance(date, text);

-- 4. rpc_hitl_pending_list — agent.html HITL 탭 미구현 (61차 admin v1.1 이후 재검토)
DROP FUNCTION IF EXISTS public.rpc_hitl_pending_list();

-- 5. rpc_audit_ef_insert_fail — 52차 mk_metrics 진단용 1회성 함수, 이후 미사용
DROP FUNCTION IF EXISTS public.rpc_audit_ef_insert_fail();

-- 6. fn_call_mk_blog_fullauto — mk-blog-fullauto 폐기(410 Gone, 51-2차) 이후 pg_cron에서도 미사용
DROP FUNCTION IF EXISTS public.fn_call_mk_blog_fullauto(uuid, text);

-- 7. rpc_send_delivery — 납품확인서 발송 기능 미구현 (admin.html 0참조)
DROP FUNCTION IF EXISTS public.rpc_send_delivery(uuid, text);

-- 8. rpc_send_statement — 거래명세서 발송 기능 미구현 (admin.html 0참조)
DROP FUNCTION IF EXISTS public.rpc_send_statement(uuid, text);

-- 9. rpc_set_assignee — inquiry_assignees 테이블 0행·미사용 (화이트리스트 보존 대상)
DROP FUNCTION IF EXISTS public.rpc_set_assignee(uuid, text, boolean);

-- 10. rpc_sync_rank_to_log — blog-rank-d-n-tracker v2 내부화로 미사용
DROP FUNCTION IF EXISTS public.rpc_sync_rank_to_log();

-- 11. rpc_get_auto_attach_files — send-quotation/send-contract EF 0참조 (파일첨부 기능 미완)
DROP FUNCTION IF EXISTS public.rpc_get_auto_attach_files(uuid, text);

-- 검증 쿼리
SELECT proname FROM pg_proc
WHERE pronamespace = 'public'::regnamespace
  AND proname IN (
    'rpc_blog_daily_digest','rpc_blog_constitution_check','rpc_blog_monthly_performance',
    'rpc_hitl_pending_list','rpc_audit_ef_insert_fail','fn_call_mk_blog_fullauto',
    'rpc_send_delivery','rpc_send_statement','rpc_set_assignee',
    'rpc_sync_rank_to_log','rpc_get_auto_attach_files'
  );
-- 결과 0행 = 전체 삭제 완료