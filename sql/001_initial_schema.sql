-- ==========================================================================
-- 리얼플랜제주 고객DB Phase 1 초기 스키마 v1.0
-- 기반: Supabase DB스키마 v1.0 (2026-04-24) + 통합설계서 v2.0
-- 실행 환경: Supabase SQL Editor (realplanjeju 프로젝트)
-- 실행일: 2026-04-24
-- 순서: 반드시 파일 전체를 한 번에 실행 (의존성 있음)
-- ==========================================================================

-- ==========================================================================
-- 0. UUID 확장 활성화
-- ==========================================================================
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";


-- ==========================================================================
-- 1. customers (고객 기본정보)
-- ==========================================================================
CREATE TABLE IF NOT EXISTS customers (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  접수번호        varchar(20) UNIQUE NOT NULL,
  신청일시        timestamptz DEFAULT now(),
  구분            varchar(10) NOT NULL CHECK (구분 IN ('기업','단체','개인')),
  사업부          varchar(20) NOT NULL CHECK (사업부 IN ('국내여행','행사이벤트','온라인마케팅','마케팅교육')),
  회사명          varchar(100) NOT NULL,
  담당자명        varchar(50) NOT NULL,
  연락처          varchar(20) NOT NULL,
  이메일          varchar(100) NOT NULL,
  시작일          date NOT NULL,
  종료일          date NOT NULL CHECK (종료일 >= 시작일),
  일정조율가능    boolean DEFAULT false,
  희망지역        text NOT NULL,
  예산            text NOT NULL,
  유입경로        varchar(30) NOT NULL,
  요청사항        text,
  동의_개인정보   boolean NOT NULL CHECK (동의_개인정보 = true),
  동의_콘텐츠     boolean DEFAULT false,
  동의_마케팅     boolean DEFAULT false,
  고객상태        varchar(10) DEFAULT '신규문의'
                   CHECK (고객상태 IN ('신규문의','상담중','견적발송','계약완료','실행중','완료','취소')),
  내부담당자      varchar(50),
  재문의여부      boolean DEFAULT false,
  이전접수번호    varchar(20),
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now(),
  deleted_at      timestamptz
);

CREATE INDEX IF NOT EXISTS idx_customers_status ON customers(사업부, 고객상태);
CREATE INDEX IF NOT EXISTS idx_customers_email  ON customers(이메일);
CREATE INDEX IF NOT EXISTS idx_customers_date   ON customers(신청일시 DESC);
CREATE INDEX IF NOT EXISTS idx_customers_phone  ON customers(연락처);


-- ==========================================================================
-- 2. consultation_notes (상담 메모)
-- ==========================================================================
CREATE TABLE IF NOT EXISTS consultation_notes (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  customer_id     uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  사업부          varchar(20) NOT NULL,
  메모            text,
  작성자          varchar(50) NOT NULL,
  버전            integer DEFAULT 1,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_notes_customer ON consultation_notes(customer_id);


-- ==========================================================================
-- 3. status_history (상태 변경 이력 — 감사 로그)
-- ==========================================================================
CREATE TABLE IF NOT EXISTS status_history (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  customer_id     uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  이전상태        varchar(10),
  다음상태        varchar(10) NOT NULL,
  변경자          varchar(50) NOT NULL,
  변경사유        text,
  ip_address      inet,
  user_agent      text,
  created_at      timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_status_customer ON status_history(customer_id);
CREATE INDEX IF NOT EXISTS idx_status_date     ON status_history(created_at DESC);


-- ==========================================================================
-- 4. quotations (견적서 · Phase 2a)
-- ==========================================================================
CREATE TABLE IF NOT EXISTS quotations (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  customer_id     uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  견적번호        varchar(30) UNIQUE NOT NULL,
  수정차수        integer DEFAULT 1,
  견적금액        bigint NOT NULL,
  유효기간        date NOT NULL,
  결제조건        text,
  세부항목        jsonb,
  pdf_url         text,
  발송여부        boolean DEFAULT false,
  발송일시        timestamptz,
  수신자이메일    varchar(100),
  상태            varchar(10) DEFAULT '작성중'
                   CHECK (상태 IN ('작성중','발송완료','수락','거절','만료')),
  작성자          varchar(50) NOT NULL,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_quotations_customer ON quotations(customer_id);


-- ==========================================================================
-- 5. contracts (계약서 · Phase 2b)
-- ==========================================================================
CREATE TABLE IF NOT EXISTS contracts (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  customer_id     uuid NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
  quotation_id    uuid REFERENCES quotations(id) ON DELETE SET NULL,
  계약번호        varchar(30) UNIQUE NOT NULL,
  계약금액        bigint NOT NULL,
  계약기간_시작   date NOT NULL,
  계약기간_종료   date NOT NULL,
  계약금비율      numeric(5,2),
  잔금비율        numeric(5,2),
  환불규정        text,
  pdf_url         text,
  서명상태        varchar(10) DEFAULT '미서명'
                   CHECK (서명상태 IN ('미서명','갑서명','을서명','완료')),
  서명일          date,
  발송일시        timestamptz,
  상태            varchar(10) DEFAULT '작성중'
                   CHECK (상태 IN ('작성중','발송완료','체결','해지')),
  작성자          varchar(50) NOT NULL,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_contracts_customer ON contracts(customer_id);


-- ==========================================================================
-- 6. users (관리자 계정)
-- ==========================================================================
CREATE TABLE IF NOT EXISTS users (
  id              uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  이메일          varchar(100) UNIQUE NOT NULL,
  이름            varchar(50) NOT NULL,
  권한            varchar(20) DEFAULT 'manager'
                   CHECK (권한 IN ('owner','manager','viewer')),
  활성            boolean DEFAULT true,
  마지막_로그인   timestamptz,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);


-- ==========================================================================
-- 7. portfolio (포트폴리오 · Phase 3)
-- ==========================================================================
CREATE TABLE IF NOT EXISTS portfolio (
  id              uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  customer_id     uuid REFERENCES customers(id) ON DELETE SET NULL,
  사업부          varchar(20) NOT NULL,
  프로젝트명      varchar(200) NOT NULL,
  회사명          varchar(100),
  진행일자        date NOT NULL,
  지역            varchar(50) NOT NULL,
  대표이미지_url  text,
  이미지_urls     jsonb,
  설명            text,
  공개여부        boolean DEFAULT false,
  순서            integer DEFAULT 0,
  created_at      timestamptz DEFAULT now(),
  updated_at      timestamptz DEFAULT now()
);


-- ==========================================================================
-- 8. RLS 활성화
-- ==========================================================================
ALTER TABLE customers           ENABLE ROW LEVEL SECURITY;
ALTER TABLE consultation_notes  ENABLE ROW LEVEL SECURITY;
ALTER TABLE status_history      ENABLE ROW LEVEL SECURITY;
ALTER TABLE quotations          ENABLE ROW LEVEL SECURITY;
ALTER TABLE contracts           ENABLE ROW LEVEL SECURITY;
ALTER TABLE users               ENABLE ROW LEVEL SECURITY;
ALTER TABLE portfolio           ENABLE ROW LEVEL SECURITY;


-- ==========================================================================
-- 9. RLS 정책
-- ==========================================================================

-- customers: 익명 INSERT 허용 (고객 폼) · 인증자만 SELECT/UPDATE · owner만 DELETE
CREATE POLICY "anon_insert_customers" ON customers
  FOR INSERT TO anon, authenticated WITH CHECK (true);
CREATE POLICY "authenticated_select_customers" ON customers
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "authenticated_update_customers" ON customers
  FOR UPDATE TO authenticated USING (true) WITH CHECK (true);
CREATE POLICY "owner_delete_customers" ON customers
  FOR DELETE TO authenticated
  USING (EXISTS (SELECT 1 FROM users WHERE id = auth.uid() AND 권한 = 'owner'));

-- consultation_notes: 인증자 전권
CREATE POLICY "authenticated_all_notes" ON consultation_notes
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- status_history: 인증자만 조회 (INSERT는 트리거만)
CREATE POLICY "authenticated_select_history" ON status_history
  FOR SELECT TO authenticated USING (true);

-- quotations: 인증자 전권
CREATE POLICY "authenticated_all_quotations" ON quotations
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- contracts: 인증자 전권
CREATE POLICY "authenticated_all_contracts" ON contracts
  FOR ALL TO authenticated USING (true) WITH CHECK (true);

-- users: 인증자 조회 · owner만 수정
CREATE POLICY "authenticated_select_users" ON users
  FOR SELECT TO authenticated USING (true);
CREATE POLICY "owner_modify_users" ON users
  FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.권한 = 'owner'))
  WITH CHECK (EXISTS (SELECT 1 FROM users u WHERE u.id = auth.uid() AND u.권한 = 'owner'));

-- portfolio: 공개 항목은 익명 조회 · 인증자 전권
CREATE POLICY "public_select_portfolio" ON portfolio
  FOR SELECT TO anon, authenticated USING (공개여부 = true);
CREATE POLICY "authenticated_all_portfolio" ON portfolio
  FOR ALL TO authenticated USING (true) WITH CHECK (true);


-- ==========================================================================
-- 10. 트리거 함수 · updated_at 자동 갱신
-- ==========================================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_customers_updated ON customers;
CREATE TRIGGER trg_customers_updated BEFORE UPDATE ON customers
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

DROP TRIGGER IF EXISTS trg_notes_updated ON consultation_notes;
CREATE TRIGGER trg_notes_updated BEFORE UPDATE ON consultation_notes
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

DROP TRIGGER IF EXISTS trg_quotations_updated ON quotations;
CREATE TRIGGER trg_quotations_updated BEFORE UPDATE ON quotations
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

DROP TRIGGER IF EXISTS trg_contracts_updated ON contracts;
CREATE TRIGGER trg_contracts_updated BEFORE UPDATE ON contracts
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

DROP TRIGGER IF EXISTS trg_users_updated ON users;
CREATE TRIGGER trg_users_updated BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

DROP TRIGGER IF EXISTS trg_portfolio_updated ON portfolio;
CREATE TRIGGER trg_portfolio_updated BEFORE UPDATE ON portfolio
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();


-- ==========================================================================
-- 11. 트리거 함수 · status_history 자동 기록
-- ==========================================================================
CREATE OR REPLACE FUNCTION log_status_change()
RETURNS TRIGGER AS $$
BEGIN
  IF OLD.고객상태 IS DISTINCT FROM NEW.고객상태 THEN
    INSERT INTO status_history (customer_id, 이전상태, 다음상태, 변경자, created_at)
    VALUES (
      NEW.id,
      OLD.고객상태,
      NEW.고객상태,
      COALESCE(auth.email(), 'system'),
      now()
    );
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS trg_status_log ON customers;
CREATE TRIGGER trg_status_log AFTER UPDATE ON customers
  FOR EACH ROW EXECUTE FUNCTION log_status_change();


-- ==========================================================================
-- 12. 신규 Auth 사용자 → public.users 자동 등록
--     이동환(snslee82@gmail.com)은 owner, 나머지는 manager
-- ==========================================================================
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.users (id, 이메일, 이름, 권한)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'name',
             NEW.raw_user_meta_data->>'full_name',
             split_part(NEW.email, '@', 1)),
    CASE
      WHEN NEW.email = 'snslee82@gmail.com'   THEN 'owner'
      WHEN NEW.email = 'gomsook6805@gmail.com' THEN 'manager'
      ELSE 'viewer'
    END
  )
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();


-- ==========================================================================
-- 13. Supabase Storage Bucket 3종
-- ==========================================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES
  ('documents', 'documents', false, 10485760, NULL),
  ('contracts', 'contracts', false, 10485760, NULL),
  ('portfolio', 'portfolio', true,  5242880,
     ARRAY['image/jpeg','image/png','image/webp','image/gif'])
ON CONFLICT (id) DO NOTHING;


-- ==========================================================================
-- 14. Storage 정책
-- ==========================================================================
CREATE POLICY "authenticated_all_documents" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'documents') WITH CHECK (bucket_id = 'documents');

CREATE POLICY "authenticated_all_contracts" ON storage.objects
  FOR ALL TO authenticated
  USING (bucket_id = 'contracts') WITH CHECK (bucket_id = 'contracts');

CREATE POLICY "public_read_portfolio" ON storage.objects
  FOR SELECT TO anon, authenticated USING (bucket_id = 'portfolio');

CREATE POLICY "authenticated_insert_portfolio" ON storage.objects
  FOR INSERT TO authenticated WITH CHECK (bucket_id = 'portfolio');

CREATE POLICY "authenticated_update_portfolio" ON storage.objects
  FOR UPDATE TO authenticated USING (bucket_id = 'portfolio');

CREATE POLICY "authenticated_delete_portfolio" ON storage.objects
  FOR DELETE TO authenticated USING (bucket_id = 'portfolio');


-- ==========================================================================
-- 완료 · 검증 쿼리
-- ==========================================================================
-- 실행 완료 후 아래 쿼리로 확인:
-- SELECT table_name FROM information_schema.tables WHERE table_schema='public' ORDER BY table_name;
-- SELECT id, name, public FROM storage.buckets;
