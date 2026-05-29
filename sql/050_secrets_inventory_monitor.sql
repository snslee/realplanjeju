-- 050 / Track A+D 번들 / B-2 secrets-monitor 인프라
-- 시크릿 인벤토리 + 60일 전 만료 알림 / 2026-05-20

-- 1. secrets_inventory 테이블
CREATE TABLE IF NOT EXISTS public.secrets_inventory (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  시크릿_이름 TEXT NOT NULL UNIQUE,
  분류 TEXT NOT NULL CHECK (분류 IN ('회사용', '투자용', '기타', 'Vault')),
  용도 TEXT,
  발급일 DATE,
  만료일 DATE,
  갱신주기_일 INT,
  위치_D드라이브 TEXT,
  위치_Vault TEXT,
  활성 BOOLEAN DEFAULT TRUE,
  마지막_점검일 TIMESTAMPTZ,
  비고 TEXT,
  생성일시 TIMESTAMPTZ DEFAULT NOW(),
  수정일시 TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_secrets_만료일 ON public.secrets_inventory(만료일) WHERE 활성 = TRUE;
CREATE INDEX IF NOT EXISTS idx_secrets_분류 ON public.secrets_inventory(분류) WHERE 활성 = TRUE;

ALTER TABLE public.secrets_inventory ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_secrets_owner_all ON public.secrets_inventory;
CREATE POLICY p_secrets_owner_all ON public.secrets_inventory
  FOR ALL TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.users
      WHERE id = auth.uid() AND 권한 IN ('owner', 'manager')
    )
  );

GRANT ALL ON public.secrets_inventory TO service_role;
GRANT SELECT, INSERT, UPDATE ON public.secrets_inventory TO authenticated;

-- 2. 알림 로그 테이블 (중복 발송 방지)
CREATE TABLE IF NOT EXISTS public.secrets_alert_log (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  시크릿_이름 TEXT NOT NULL,
  알림_종류 TEXT NOT NULL CHECK (알림_종류 IN ('60d_warning', '30d_warning', '7d_critical', 'expired')),
  발송_일자 DATE NOT NULL,
  수신자_이메일 TEXT,
  결과 TEXT,
  생성일시 TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (시크릿_이름, 알림_종류, 발송_일자)
);

ALTER TABLE public.secrets_alert_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_secrets_alert_owner ON public.secrets_alert_log;
CREATE POLICY p_secrets_alert_owner ON public.secrets_alert_log
  FOR SELECT TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.users WHERE id = auth.uid() AND 권한 IN ('owner', 'manager'))
  );

GRANT ALL ON public.secrets_alert_log TO service_role;
GRANT SELECT ON public.secrets_alert_log TO authenticated;

-- 3. RPC: 만료 임박 시크릿 조회
CREATE OR REPLACE FUNCTION public.rpc_secrets_expiring(_days INT DEFAULT 60)
RETURNS TABLE (
  r_시크릿_이름 TEXT,
  r_분류 TEXT,
  r_용도 TEXT,
  r_만료일 DATE,
  r_남은_일수 INT,
  r_위치_D드라이브 TEXT,
  r_갱신주기_일 INT
) AS $$
  SELECT
    시크릿_이름::TEXT,
    분류::TEXT,
    용도::TEXT,
    만료일,
    (만료일 - CURRENT_DATE)::INT AS 남은_일수,
    위치_D드라이브::TEXT,
    갱신주기_일
  FROM public.secrets_inventory
  WHERE 활성 = TRUE
    AND 만료일 IS NOT NULL
    AND 만료일 - CURRENT_DATE <= _days
    AND 만료일 - CURRENT_DATE >= 0
  ORDER BY 만료일 ASC;
$$ LANGUAGE SQL SECURITY DEFINER SET search_path = public;

GRANT EXECUTE ON FUNCTION public.rpc_secrets_expiring TO authenticated, service_role;

-- 4. 시드 데이터 (18 시크릿 / 인벤토리 .md 기반)
INSERT INTO public.secrets_inventory (시크릿_이름, 분류, 용도, 발급일, 만료일, 갱신주기_일, 위치_D드라이브, 위치_Vault, 비고)
VALUES
  ('github_pat (구)', '회사용', 'realplanjeju 리포 (구 PAT)', '2026-05-05', '2026-06-04', 30, 'github_pat.txt', NULL, '401 폐기 추정 / 60일 보관 후 폐기'),
  ('github_pat_2026-05-17', '회사용', 'realplan-quant-system 리포', '2026-05-17', '2026-08-15', 90, 'github_pat_2026-05-17.txt', NULL, '신 fine-grained PAT'),
  ('realplan_anthropic_api_key', 'Vault', 'Claude API ($50 한도)', '2026-05-06', NULL, NULL, NULL, 'realplan_anthropic_api_key', 'Pay-as-you-go'),
  ('realplan_notion_token', 'Vault', '노션 프라이빗 통합', '2026-05-06', NULL, 90, '3종 API.txt(별도)', 'realplan_notion_token', '권장 90일 갱신'),
  ('realplan_naver_search_client_id', 'Vault', '네이버 검색 API ClientID', '2026-04-27', NULL, 365, '3종 API.txt', 'realplan_naver_search_client_id', '연 1회 갱신'),
  ('realplan_naver_search_client_secret', 'Vault', '네이버 검색 API Secret', '2026-04-27', NULL, 365, '3종 API.txt', 'realplan_naver_search_client_secret', '연 1회 갱신'),
  ('realplan_naver_ad_api_key', 'Vault', '네이버 검색광고 API', '2026-05-06', NULL, 365, '3종 API.txt', 'realplan_naver_ad_api_key', NULL),
  ('realplan_naver_ad_customer_id', 'Vault', '네이버 검색광고 Customer', '2026-05-06', NULL, NULL, '3종 API.txt', 'realplan_naver_ad_customer_id', NULL),
  ('realplan_naver_ad_secret_key', 'Vault', '네이버 검색광고 Secret', '2026-05-06', NULL, 365, '3종 API.txt', 'realplan_naver_ad_secret_key', NULL),
  ('realplan_gsc_oauth_client_id', 'Vault', 'GSC OAuth Client ID', '2026-05-04', NULL, NULL, '3종 API.txt', 'realplan_gsc_oauth_client_id', '교체일 2026-05-04'),
  ('realplan_gsc_oauth_client_secret', 'Vault', 'GSC OAuth Secret', '2026-05-04', NULL, NULL, '3종 API.txt', 'realplan_gsc_oauth_client_secret', NULL),
  ('realplan_gsc_oauth_refresh_token', 'Vault', 'GSC Refresh Token (영구)', '2026-05-04', NULL, NULL, '3종 API.txt', 'realplan_gsc_oauth_refresh_token', NULL),
  ('realplan_cron_internal_secret', 'Vault', 'pg_cron 내부 인증', '2026-05-06', NULL, 180, NULL, 'realplan_cron_internal_secret', '6개월 권장 갱신'),
  ('SUPABASE_ACCESS_TOKEN', '회사용', 'Supabase 관리 토큰', '2026-05-17', NULL, 180, 'SUPABASE_ACCESS_TOKEN.txt', NULL, NULL),
  ('AWS 자격증명', '회사용', 'AWS 자격증명', '2026-05-15', NULL, 365, 'AWS.txt', NULL, NULL),
  ('realplan-proxy.pem', '회사용', '프록시 인증서', '2026-05-15', NULL, 365, 'realplan-proxy.pem', NULL, NULL),
  ('GCP service account (GSC)', '회사용', 'GCP 서비스 계정', '2026-04-27', NULL, NULL, 'realplanjeju-be96ef11394f.json', NULL, '무기한'),
  ('Backup-codes 구글', '기타', 'Google 2FA 백업 코드', NULL, NULL, NULL, 'Backup-codes-snslee82 구글.txt', NULL, '매우 민감 / Vault 등록 X')
ON CONFLICT (시크릿_이름) DO NOTHING;

NOTIFY pgrst, 'reload schema';
