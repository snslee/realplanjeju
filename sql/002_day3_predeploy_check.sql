-- ============================================================
-- 리얼플랜제주 Day 3 사전 조사 SQL (5종)
-- 작성일: 2026-04-25
-- 목적: 코드 작성 전 DB 현재 상태 정확 파악 (DB 우선 조사 원칙)
-- 사용법: Supabase Dashboard → SQL Editor → 5개 블록 순차 실행
-- ============================================================


-- ▶ 블록 1. 김현숙 부장 admin_users 등록 상태 확인 (가장 중요·최우선)
-- 출근 후 첫 로그인 전 반드시 PASS 확인 필요
SELECT
  email,
  display_name,
  role,
  is_active,
  created_at,
  last_login_at
FROM admin_users
ORDER BY created_at;

-- 기대 결과: 2행 (이동환·김현숙)
-- 실패 케이스:
--   ① 김현숙 row 없음        → 블록 1-A 실행 필요
--   ② is_active = false       → 블록 1-B 실행 필요
--   ③ role <> 'admin'         → 블록 1-C 실행 필요


-- ▶ 블록 1-A. (김현숙 row 없을 때만) 김현숙 부장 INSERT
-- ※ 실제 이메일·실명을 다시 확인 후 실행
-- INSERT INTO admin_users (email, display_name, role, is_active)
-- VALUES ('realplan01@naver.com', '김현숙', 'admin', true);


-- ▶ 블록 1-B. (is_active=false 일 때만) 활성화
-- UPDATE admin_users SET is_active = true WHERE email = 'realplan01@naver.com';


-- ▶ 블록 1-C. (role 다를 때만) 권한 보정
-- UPDATE admin_users SET role = 'admin' WHERE email = 'realplan01@naver.com';


-- ============================================================


-- ▶ 블록 2. 현재 테이블 9개 정상 존재 확인 (DB v1.1 적용 검증)
SELECT
  table_name,
  (SELECT COUNT(*) FROM information_schema.columns
     WHERE table_schema='public' AND table_name=t.table_name) AS col_count
FROM information_schema.tables t
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE'
ORDER BY table_name;

-- 기대 결과: 9행 (admin_users, inquiries, inquiry_history, files, notes, ...)


-- ============================================================


-- ▶ 블록 3. 현재 RPC 5개 정상 존재 확인 + 시그니처 파악
-- Day 3 코드는 이 함수를 호출하므로 시그니처 정확히 알아야 함
SELECT
  p.proname AS function_name,
  pg_get_function_arguments(p.oid) AS arguments,
  pg_get_function_result(p.oid)    AS return_type
FROM pg_proc p
JOIN pg_namespace n ON p.pronamespace = n.oid
WHERE n.nspname = 'public'
  AND p.prokind = 'f'
ORDER BY p.proname;

-- 기대 결과: 5행 (submit_inquiry 외 4개)
-- 만약 list_inquiries · dashboard_kpis 같은 함수가 없다면
-- → Day 3 작업 중 새로 만들어야 하므로 설계 단계에 반영


-- ============================================================


-- ▶ 블록 4. inquiries 테이블 컬럼 정확 확인 (Day 3 매핑용)
SELECT
  column_name,
  data_type,
  is_nullable,
  column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'inquiries'
ORDER BY ordinal_position;

-- 기대 결과: 15컬럼 (사업부·상태·접수번호·회사명·이름·전화·이메일·메모·담당자·기간·태그 등)


-- ============================================================


-- ▶ 블록 5. 현재 데이터 샘플 (Day 3 화면 검증용)
-- 메모리상 TOUR-2026-001 한 건 성공 접수 기록 있음
SELECT
  inquiry_no,
  business_unit,
  status,
  company_name,
  contact_name,
  contact_phone,
  assigned_to,
  created_at
FROM inquiries
ORDER BY created_at DESC
LIMIT 10;

-- 기대 결과: 최소 1행 (TOUR-2026-001)
-- 0행이면 Day 3 화면 검증 어려움 → 테스트 데이터 1~2건 추가 권장
