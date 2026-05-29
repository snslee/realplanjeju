-- sql/034 — admin_access_log 액션 CHECK 제약 제거
-- 33차 후속 hotfix / 2026-05-03
-- 원인: admin.html 9개 logAccess 호출 액션이 기존 6개 CHECK와 불일치 -> 400 에러 양산
-- 해결: CHECK 제거 (자유 텍스트 허용 / §9 과잉 X / §10 현 상황 우선)
-- 영향: 운영 감사 로그 자유 텍스트화 / 향후 액션 종류 확장 자유

ALTER TABLE public.admin_access_log
  DROP CONSTRAINT IF EXISTS admin_access_log_액션_check;

COMMENT ON COLUMN public.admin_access_log.액션 IS
  '운영 감사 로그 액션 / 자유 텍스트 / 표준: 소문자 underscore (예: login_success / customer_detail_view) — 대문자 호환 가능';
