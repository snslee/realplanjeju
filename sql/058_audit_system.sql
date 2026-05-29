-- =====================================================
-- sql/058 — 통합 감사 시스템 (5축 24h 무인 운영)
-- 운영 지침 v2.0.2 §16 회사 맞춤형 + §19 롤모델 의무 (Google SRE 4 시그널)
-- 49차 회기 / 2026-05-20
-- 라이브 적용: Supabase iodfqlkeiwxyuojwcozv (success)
-- =====================================================

-- 1) hr_audit_rule — 감사 룰 정의 테이블
CREATE TABLE IF NOT EXISTS public.hr_audit_rule (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  룰_코드 TEXT NOT NULL UNIQUE,
  감사축 TEXT NOT NULL CHECK (감사축 IN ('A_EF헬스','B_DB무결성','C_3축동기','D_결재흐름','E_보안시크릿')),
  룰_이름 TEXT NOT NULL,
  설명 TEXT,
  점검_방법 TEXT NOT NULL,
  임계치 JSONB DEFAULT '{}'::jsonb,
  심각도 TEXT DEFAULT 'P2' CHECK (심각도 IN ('P1','P2','P3')),
  활성 BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_hr_audit_rule_축 ON public.hr_audit_rule(감사축);
CREATE INDEX IF NOT EXISTS idx_hr_audit_rule_활성 ON public.hr_audit_rule(활성) WHERE 활성 = true;

-- 2) hr_audit_log — 감사 결과 로그
CREATE TABLE IF NOT EXISTS public.hr_audit_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  발생시각 TIMESTAMPTZ DEFAULT now(),
  감사축 TEXT NOT NULL CHECK (감사축 IN ('A_EF헬스','B_DB무결성','C_3축동기','D_결재흐름','E_보안시크릿')),
  룰_코드 TEXT NOT NULL,
  심각도 TEXT NOT NULL CHECK (심각도 IN ('P1','P2','P3','INFO')),
  상태 TEXT NOT NULL CHECK (상태 IN ('정상','경고','오류')),
  메시지 TEXT NOT NULL,
  세부데이터 JSONB DEFAULT '{}'::jsonb,
  알림_발송됨 BOOLEAN DEFAULT false,
  학습모드 BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_hr_audit_log_발생시각 ON public.hr_audit_log(발생시각 DESC);
CREATE INDEX IF NOT EXISTS idx_hr_audit_log_축 ON public.hr_audit_log(감사축);
CREATE INDEX IF NOT EXISTS idx_hr_audit_log_심각도 ON public.hr_audit_log(심각도) WHERE 심각도 IN ('P1','P2');
CREATE INDEX IF NOT EXISTS idx_hr_audit_log_상태 ON public.hr_audit_log(상태) WHERE 상태 IN ('경고','오류');

-- 3) RLS
ALTER TABLE public.hr_audit_rule ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.hr_audit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS hr_audit_rule_admin ON public.hr_audit_rule;
CREATE POLICY hr_audit_rule_admin ON public.hr_audit_rule
  FOR ALL TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.users WHERE users.id = auth.uid() AND users.권한 IN ('owner','manager'))
  );

DROP POLICY IF EXISTS hr_audit_log_admin ON public.hr_audit_log;
CREATE POLICY hr_audit_log_admin ON public.hr_audit_log
  FOR ALL TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.users WHERE users.id = auth.uid() AND users.권한 IN ('owner','manager'))
  );

GRANT SELECT, INSERT, UPDATE, DELETE ON public.hr_audit_rule TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.hr_audit_log TO service_role;
GRANT SELECT ON public.hr_audit_rule TO authenticated;
GRANT SELECT ON public.hr_audit_log TO authenticated;

-- 4) 기본 룰 13개 시드 INSERT
INSERT INTO public.hr_audit_rule (룰_코드, 감사축, 룰_이름, 설명, 점검_방법, 임계치, 심각도) VALUES
('A_EF_5XX_RATE','A_EF헬스','EF 5xx 응답률','EF 호출 중 5xx 응답 발생','log_query','{"window_hours":1,"threshold":1}'::jsonb,'P2'),
('A_EF_TIMEOUT','A_EF헬스','EF 타임아웃','EF 응답시간 초과','log_query','{"window_hours":1,"threshold":1}'::jsonb,'P1'),
('A_EF_INVOKE_DROP','A_EF헬스','EF 정지 의심 (24h 호출 0)','24시간 동안 호출 0건 = 정지 의심','log_query','{"window_hours":24,"threshold":0,"operator":"=="}'::jsonb,'P1'),
('B_DB_ORPHAN_QUOT','B_DB무결성','고객 없는 견적','customers 없는 quotations 레코드','sql_count','{"sql":"SELECT count(*) FROM quotations q LEFT JOIN customers c ON q.customer_id=c.id WHERE c.id IS NULL"}'::jsonb,'P2'),
('B_DB_ORPHAN_CONT','B_DB무결성','견적 없는 계약','quotations 없는 contracts 레코드','sql_count','{"sql":"SELECT count(*) FROM contracts ct LEFT JOIN quotations q ON ct.quotation_id=q.id WHERE q.id IS NULL"}'::jsonb,'P2'),
('B_DB_RPC_FAIL','B_DB무결성','RPC 호출 실패','24h 내 RPC 실패 ≥ 5건','log_query','{"window_hours":24,"threshold":5}'::jsonb,'P2'),
('C_GITHUB_DRIFT','C_3축동기','GitHub vs D드라이브 drift','admin.html·sql 어긋남','file_check','{"target":"realplanjeju"}'::jsonb,'P2'),
('C_EF_BACKUP_MISSING','C_3축동기','EF D드라이브 백업 누락','17 EF 백업 0건 사고 재발 방지','file_check','{"target":"D:\\자동화\\회사 시스템 및 개발 사업부\\edge_functions"}'::jsonb,'P2'),
('D_QUOT_STUCK','D_결재흐름','견적 7일 정체','draft·sent 상태 7일↑','sql_count','{"sql":"SELECT count(*) FROM quotations WHERE status IN (''draft'',''sent'') AND updated_at < now() - interval ''7 days''"}'::jsonb,'P2'),
('D_CONT_STUCK','D_결재흐름','계약 14일 정체','draft·sent 상태 14일↑','sql_count','{"sql":"SELECT count(*) FROM contracts WHERE status IN (''draft'',''sent'') AND updated_at < now() - interval ''14 days''"}'::jsonb,'P2'),
('D_DOC_STUCK','D_결재흐름','공문 미발송 7일','official_documents 미발송 7일↑','sql_count','{"sql":"SELECT count(*) FROM official_documents WHERE status = ''draft'' AND created_at < now() - interval ''7 days''"}'::jsonb,'P3'),
('E_SECRETS_EXPIRE','E_보안시크릿','시크릿 30일 내 만료','secrets_inventory 만료일 30일↑','sql_count','{"sql":"SELECT count(*) FROM secrets_inventory WHERE 만료일 IS NOT NULL AND 만료일 < now() + interval ''30 days''"}'::jsonb,'P2'),
('E_ADVISOR_WARN','E_보안시크릿','Supabase advisor 경고','보안 advisor warn 발생','advisor_check','{"type":"security"}'::jsonb,'P3')
ON CONFLICT (룰_코드) DO NOTHING;

-- 5) PostgREST schema reload
NOTIFY pgrst, 'reload schema';

COMMENT ON TABLE public.hr_audit_rule IS '49차 sql/058 — 5축 통합 감사 룰 정의 (Google SRE 4 시그널 정합)';
COMMENT ON TABLE public.hr_audit_log IS '49차 sql/058 — 5축 통합 감사 로그 / 학습모드 7일 후 정식 가동';
