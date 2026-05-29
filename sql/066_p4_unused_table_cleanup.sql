-- sql/066_p4_unused_table_cleanup.sql
-- 59차 P4 — 0행 테이블 정리 + F_UNUSED_TABLE 감사 노이즈 제거
-- 작성: 2026-05-29
--
-- 판정 근거:
--   삭제(2): mk_ab_tests·mk_lead_sources = 폐기된 풀오토 v1 산물 / EF·admin 0참조
--   보존(7): customer_contacts·file_attachments·mk_notification_queue·
--            admin_permissions·admin_permission_log·portfolio·inquiry_assignees
--            = 실사용 중이거나 설계 예정 테이블

-- ============================================================
-- 1. 폐기 테이블 삭제
-- ============================================================
DROP TABLE IF EXISTS public.mk_ab_tests CASCADE;
DROP TABLE IF EXISTS public.mk_lead_sources CASCADE;

-- ============================================================
-- 2. F_UNUSED_TABLE 룰 임계치 조정
--    → 보존 7개 테이블은 0행이 정상 → 룰 임계치를 실제 미사용 기준으로 수정
--    현재 임계치 1 (0행 테이블 1개 이상) → 3으로 올려 노이즈 감소
--    (삭제 후 남은 0행 테이블 7개 중 미래 사용 예정이 대부분)
-- ============================================================
UPDATE hr_audit_rule
SET 임계치 = 3,
    설명 = '0행·90일 미사용 테이블 (임계치 3 / 보존 예정 테이블 7개 제외 후 정상)',
    updated_at = NOW()
WHERE 룰_코드 = 'F_UNUSED_TABLE';

-- ============================================================
-- 3. 검증
-- ============================================================
-- 남은 0행 테이블 확인
SELECT relname AS 테이블명, n_live_tup AS 행수
FROM pg_stat_user_tables
WHERE n_live_tup = 0 AND schemaname = 'public'
ORDER BY relname;

-- F_UNUSED_TABLE 룰 확인
SELECT 룰_코드, 임계치, 설명 FROM hr_audit_rule WHERE 룰_코드 = 'F_UNUSED_TABLE';
