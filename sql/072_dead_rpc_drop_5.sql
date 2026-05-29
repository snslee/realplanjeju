-- sql/072 — Dead RPC 삭제 2차 (66차 / 2026-05-30)
-- 전수 분석: admin.html 51개 + EF 18개 참조 교차검증 후 0참조 확정
-- §3 객관적 비평: 삭제 근거 명시

-- 1. rpc_clone_proposal
--    근거: admin.html + 전체 EF 0참조 / 견적 복제 기능 미구현
DROP FUNCTION IF EXISTS public.rpc_clone_proposal(uuid, integer, integer);

-- 2. rpc_delete_quotation_item
--    근거: admin.html + 전체 EF 0참조 / rpc_upsert_quotation_item으로 삭제 대응 (items 배열 재업)
DROP FUNCTION IF EXISTS public.rpc_delete_quotation_item(uuid);

-- 3. rpc_set_permission
--    근거: 0참조 / rpc_bulk_set_permissions(_user_id, _payload jsonb)로 완전 대체됨
DROP FUNCTION IF EXISTS public.rpc_set_permission(uuid, text, text, text);

-- 4. rpc_send_telegram_smart
--    근거: 0참조 / 이관 마스터플랜 문서에만 언급, 실제 EF는 telegram-notifier EF 직접 호출로 대체
DROP FUNCTION IF EXISTS public.rpc_send_telegram_smart(text, text);

-- 5. rpc_update_official_doc
--    근거: 0참조 / rpc_update_official_doc_with_revision으로 완전 대체
DROP FUNCTION IF EXISTS public.rpc_update_official_doc(uuid, jsonb);

-- 검증: 삭제 후 rpc_ 카운트
SELECT count(*) AS rpc_total_after
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public' AND p.proname LIKE 'rpc_%';
-- 기대값: 64 (69 - 5)
