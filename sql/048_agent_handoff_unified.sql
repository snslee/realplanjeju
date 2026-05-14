-- ============================================================
-- sql/048 — hr_audit_handoff 테이블 신설 + 에이전트 통합
-- ============================================================
-- 작성: 2026-05-14 / 44차 회기
-- 출처: 4축 운영룰 v1.0 차기 회기 안건 #2 + 23_에이전트시스템_v1.0.md §3
-- 정합: 회사 맞춤형 (한글 컬럼) / agent_ prefix 미적용 (43차 표준 hr_* 유지)
-- 18원칙: §6 데이터 주권 / §9 과잉 X (단일 테이블) / §11 확장 보존
-- ============================================================

-- 1) 테이블 신설 (43차 차기 안건 + 에이전트 통합)
CREATE TABLE IF NOT EXISTS public.hr_audit_handoff (
  id              BIGSERIAL PRIMARY KEY,
  -- 인수인계 영역 (43차 4축 룰 R-5 정합)
  회기번호         INT,
  핸드오프유형     TEXT,         -- handoff·daily·weekly·monthly
  요약            TEXT,
  -- 에이전트 영역 (44차 v1.0 신규 4컬럼)
  에이전트ID       TEXT,         -- rp_agent_eval_v1·rp_agent_guard_v1·rp_agent_collector_v1
  대상유형         TEXT,         -- 블로그·견적·계약·SNS
  대상ID          TEXT,         -- 외부 PK (quotation_id 등)
  점수            NUMERIC(3,1) CHECK (점수 >= 0 AND 점수 <= 10),
  항목별점수       JSONB,
  사유            TEXT,
  평가루브릭       TEXT,         -- blog_v1·quotation_v23·contract_v25·sns_v1
  HITL상태        TEXT DEFAULT 'pending'
                  CHECK (HITL상태 IN ('pending','approved','rejected','auto_pass','blocked')),
  -- 공통
  실행시각         TIMESTAMPTZ DEFAULT now(),
  처리자          UUID REFERENCES auth.users(id),
  처리시각         TIMESTAMPTZ,
  메타            JSONB
);

-- 2) 인덱스 (조회 성능)
CREATE INDEX IF NOT EXISTS idx_hah_에이전트ID
  ON public.hr_audit_handoff(에이전트ID);
CREATE INDEX IF NOT EXISTS idx_hah_HITL상태
  ON public.hr_audit_handoff(HITL상태) WHERE HITL상태 = 'pending';
CREATE INDEX IF NOT EXISTS idx_hah_실행시각
  ON public.hr_audit_handoff(실행시각 DESC);
CREATE INDEX IF NOT EXISTS idx_hah_대상
  ON public.hr_audit_handoff(대상유형, 대상ID);

-- 3) RLS (Guard 정책 일부 포함)
ALTER TABLE public.hr_audit_handoff ENABLE ROW LEVEL SECURITY;

-- owner = 전체 R/W (43차 표준 public.users 정합)
DROP POLICY IF EXISTS p_hah_owner_all ON public.hr_audit_handoff;
CREATE POLICY p_hah_owner_all ON public.hr_audit_handoff
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid() AND u.권한 = 'owner' AND u.활성 = true
    )
  );

-- manager = R only
DROP POLICY IF EXISTS p_hah_manager_read ON public.hr_audit_handoff;
CREATE POLICY p_hah_manager_read ON public.hr_audit_handoff
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.users u
      WHERE u.id = auth.uid() AND u.권한 = 'manager' AND u.활성 = true
    )
  );

-- service_role = 전체 (EF 호출)
DROP POLICY IF EXISTS p_hah_service ON public.hr_audit_handoff;
CREATE POLICY p_hah_service ON public.hr_audit_handoff
  FOR ALL TO service_role USING (true);

-- 4) GRANT (43차 표준 = service_role + anon 모두)
GRANT SELECT, INSERT, UPDATE ON public.hr_audit_handoff TO service_role;
GRANT SELECT ON public.hr_audit_handoff TO anon, authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.hr_audit_handoff_id_seq TO service_role, authenticated;

-- 5) 비용 가드 (월 한도 트리거 — 사고 방지)
CREATE OR REPLACE FUNCTION public.rpc_check_agent_budget()
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_월_호출수 INT;
BEGIN
  SELECT COUNT(*) INTO v_월_호출수
  FROM public.hr_audit_handoff
  WHERE 에이전트ID IS NOT NULL
    AND 실행시각 >= date_trunc('month', now());
  -- 월 10,000 호출 = 약 $100 한도 (Haiku 기준 보수적)
  RETURN v_월_호출수 < 10000;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_check_agent_budget() TO service_role, anon, authenticated;

-- 6) HITL 큐 조회 RPC (Runbook 일일 점검용)
CREATE OR REPLACE FUNCTION public.rpc_hitl_pending_list()
RETURNS TABLE (
  id BIGINT,
  에이전트ID TEXT,
  대상유형 TEXT,
  대상ID TEXT,
  점수 NUMERIC,
  사유 TEXT,
  실행시각 TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
AS $$
  SELECT id, 에이전트ID, 대상유형, 대상ID, 점수, 사유, 실행시각
  FROM public.hr_audit_handoff
  WHERE HITL상태 = 'pending'
  ORDER BY 실행시각 DESC
  LIMIT 100;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_hitl_pending_list() TO service_role, authenticated;

-- 7) 코멘트 (문서화 §7)
COMMENT ON TABLE public.hr_audit_handoff IS
  '인수인계(43차) + 에이전트 채점·차단·핸드오프 통합 로그 / 44차 sql/048 v1.0';
COMMENT ON COLUMN public.hr_audit_handoff.에이전트ID IS
  '카탈로그 24번 참조: rp_agent_eval_v1·rp_agent_guard_v1·rp_agent_collector_v1';

-- ============================================================
-- 검증 쿼리 (배포 후 실행)
-- ============================================================
-- SELECT * FROM public.rpc_hitl_pending_list();   -- 빈 결과 = PASS
-- SELECT public.rpc_check_agent_budget();         -- TRUE = PASS
-- SELECT COUNT(*) FROM public.hr_audit_