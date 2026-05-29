-- sql/058c — F축 시스템 개선 제안 (49-1차 / 2026-05-21)
-- 6축 확장 (CHECK 갱신) + 5 룰 신규 + SUGGEST 심각도 추가
-- 라이브 적용 완료 (Supabase iodfqlkeiwxyuojwcozv)

-- 1) hr_audit_rule.감사축 CHECK 갱신 — F축 추가
ALTER TABLE public.hr_audit_rule DROP CONSTRAINT hr_audit_rule_감사축_check;
ALTER TABLE public.hr_audit_rule ADD CONSTRAINT hr_audit_rule_감사축_check
  CHECK (감사축 IN ('A_EF헬스','B_DB무결성','C_3축동기','D_결재흐름','E_보안시크릿','F_시스템개선'));

-- 2) hr_audit_log.감사축 CHECK 갱신
ALTER TABLE public.hr_audit_log DROP CONSTRAINT hr_audit_log_감사축_check;
ALTER TABLE public.hr_audit_log ADD CONSTRAINT hr_audit_log_감사축_check
  CHECK (감사축 IN ('A_EF헬스','B_DB무결성','C_3축동기','D_결재흐름','E_보안시크릿','F_시스템개선'));

-- 3) hr_audit_log.심각도 CHECK 갱신 — SUGGEST 추가
ALTER TABLE public.hr_audit_log DROP CONSTRAINT hr_audit_log_심각도_check;
ALTER TABLE public.hr_audit_log ADD CONSTRAINT hr_audit_log_심각도_check
  CHECK (심각도 IN ('P1','P2','P3','INFO','SUGGEST'));

-- 4) F축 5 룰 시드
INSERT INTO public.hr_audit_rule (룰_코드, 감사축, 룰_이름, 설명, 점검_방법, 임계치, 심각도) VALUES
('F_DEAD_RPC','F_시스템개선','RPC 함수 인벤토리','RPC 함수 모니터링 (advisor 통합 후 dead 판별)','sql_count','{"sql":"SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid WHERE n.nspname=''public'' AND p.proname LIKE ''rpc_%''","threshold":999999}'::jsonb,'P3'),
('F_UNUSED_TABLE','F_시스템개선','0행·90일 미사용 테이블','rows 0 AND 90일↑ 변경 없는 테이블','sql_count','{"sql":"SELECT count(*) FROM (SELECT n_live_tup FROM pg_stat_user_tables WHERE schemaname=''public'' AND n_live_tup=0 AND coalesce(last_autoanalyze, last_analyze, ''2000-01-01''::timestamptz) < now() - interval ''90 days'') x","threshold":1}'::jsonb,'P3'),
('F_EF_VERSION_OLD','F_시스템개선','60일↑ 미수정 EF','placeholder (50차 Mgmt API 연동)','sql_count','{"sql":"SELECT 0","threshold":1}'::jsonb,'P3'),
('F_DB_INDEX_MISSING','F_시스템개선','외래키 인덱스 누락','Supabase performance advisor','advisor_check','{"type":"performance"}'::jsonb,'P3'),
('F_AUDIT_SELF_HEALTH','F_시스템개선','감사 시스템 자체 점검','24h 내 hr_audit_log 적재 0 = 정지','sql_count','{"sql":"SELECT CASE WHEN (SELECT count(*) FROM hr_audit_log WHERE 발생시각 > now() - interval ''24 hours'') > 0 THEN 0 ELSE 1 END","threshold":1}'::jsonb,'P1')
ON CONFLICT (룰_코드) DO NOTHING;

-- 5) 24h 요약 뷰 갱신 (F축 포함)
DROP VIEW IF EXISTS public.v_hr_audit_24h_summary;
CREATE OR REPLACE VIEW public.v_hr_audit_24h_summary AS
SELECT 감사축,
  count(*) FILTER (WHERE 상태 = '정상') AS 정상_건수,
  count(*) FILTER (WHERE 상태 = '경고') AS 경고_건수,
  count(*) FILTER (WHERE 상태 = '오류') AS 오류_건수,
  max(발생시각) AS 마지막_점검
FROM public.hr_audit_log
WHERE 발생시각 > now() - INTERVAL '24 hours'
GROUP BY 감사축
ORDER BY 감사축;

GRANT SELECT ON public.v_hr_audit_24h_summary TO authenticated, service_role;
NOTIFY pgrst, 'reload schema';
