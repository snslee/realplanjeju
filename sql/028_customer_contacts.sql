-- ============================================================
-- sql/028_customer_contacts.sql
-- v2.15.0 묶음 27 옵션 Y — 고객 추가 담당자 (보조)
-- 적용일: 2026-05-01 (27차 회기)
--
-- 설계 정합 (옵션 Y):
--   - Primary 담당자 = customers.담당자명·연락처·이메일 (그대로 유지)
--   - 추가 담당자  = customer_contacts (보조 N명 / 선택)
--   - is_primary 컬럼 X (Primary는 customers에 영구 고정)
--   - display_order 추가 (vendor_contacts에 없는 개선점)
--
-- 작업:
--   1) customer_contacts 테이블 생성
--   2) 인덱스 3 + 트리거 1 (updated_at 자동)
--   3) RLS 활성화 + 정책 4 (sql/020_v2 정합 / fn_is_role)
--   4) RPC 3종:
--      - rpc_list_customer_contacts(_customer_id)
--      - rpc_upsert_customer_contact(_payload jsonb)
--      - rpc_delete_customer_contact(_id)
-- ============================================================

-- ────────────────────────────────────────
-- 1. customer_contacts 테이블
-- ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.customer_contacts (
  id              uuid         PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id     uuid         NOT NULL REFERENCES public.customers(id) ON DELETE CASCADE,
  담당자명        varchar(50)  NOT NULL,
  직급            varchar(30),
  부서            varchar(50),
  전화            varchar(20),
  휴대폰          varchar(20),
  이메일          varchar(100),
  메모            text,
  display_order   smallint     NOT NULL DEFAULT 0,
  created_at      timestamptz  NOT NULL DEFAULT now(),
  updated_at      timestamptz  NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.customer_contacts          IS '고객 추가(보조) 담당자 — Primary는 customers 테이블 직접 컬럼';
COMMENT ON COLUMN public.customer_contacts.customer_id    IS 'customers.id FK / CASCADE';
COMMENT ON COLUMN public.customer_contacts.display_order  IS '정렬 순서 (낮을수록 위)';

-- 인덱스
CREATE INDEX IF NOT EXISTS idx_cust_contacts_customer ON public.customer_contacts(customer_id);
CREATE INDEX IF NOT EXISTS idx_cust_contacts_order    ON public.customer_contacts(customer_id, display_order, created_at);
CREATE INDEX IF NOT EXISTS idx_cust_contacts_email    ON public.customer_contacts(이메일);

-- updated_at 트리거
CREATE OR REPLACE FUNCTION public.fn_customer_contacts_touch()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_customer_contacts_touch ON public.customer_contacts;
CREATE TRIGGER trg_customer_contacts_touch
BEFORE UPDATE ON public.customer_contacts
FOR EACH ROW EXECUTE FUNCTION public.fn_customer_contacts_touch();


-- ────────────────────────────────────────
-- 2. RLS 활성화 + 정책 (sql/020_v2 / fn_is_role 정합)
-- ────────────────────────────────────────
ALTER TABLE public.customer_contacts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "admin_select_customer_contacts" ON public.customer_contacts;
DROP POLICY IF EXISTS "admin_insert_customer_contacts" ON public.customer_contacts;
DROP POLICY IF EXISTS "admin_update_customer_contacts" ON public.customer_contacts;
DROP POLICY IF EXISTS "admin_delete_customer_contacts" ON public.customer_contacts;

CREATE POLICY "admin_select_customer_contacts" ON public.customer_contacts
  FOR SELECT TO authenticated
  USING (public.fn_is_role(ARRAY['owner','manager','viewer']));

CREATE POLICY "admin_insert_customer_contacts" ON public.customer_contacts
  FOR INSERT TO authenticated
  WITH CHECK (public.fn_is_role(ARRAY['owner','manager']));

CREATE POLICY "admin_update_customer_contacts" ON public.customer_contacts
  FOR UPDATE TO authenticated
  USING      (public.fn_is_role(ARRAY['owner','manager']))
  WITH CHECK (public.fn_is_role(ARRAY['owner','manager']));

CREATE POLICY "admin_delete_customer_contacts" ON public.customer_contacts
  FOR DELETE TO authenticated
  USING (public.fn_is_role(ARRAY['owner']));


-- ────────────────────────────────────────
-- 3. RPC (1) rpc_list_customer_contacts — 추가 담당자 목록
-- ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_list_customer_contacts(_customer_id uuid)
RETURNS TABLE(
  r_id uuid,
  r_customer_id uuid,
  r_담당자명 varchar,
  r_직급 varchar,
  r_부서 varchar,
  r_전화 varchar,
  r_휴대폰 varchar,
  r_이메일 varchar,
  r_메모 text,
  r_display_order smallint,
  r_created_at timestamptz,
  r_updated_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  RETURN QUERY
  SELECT c.id, c.customer_id, c.담당자명, c.직급, c.부서,
    c.전화, c.휴대폰, c.이메일, c.메모, c.display_order,
    c.created_at, c.updated_at
  FROM public.customer_contacts c
  WHERE c.customer_id = _customer_id
  ORDER BY c.display_order ASC, c.created_at ASC;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_list_customer_contacts(uuid) TO authenticated, service_role;


-- ────────────────────────────────────────
-- 4. RPC (2) rpc_upsert_customer_contact — INSERT/UPDATE
-- ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_upsert_customer_contact(_payload jsonb)
RETURNS TABLE(r_id uuid, r_담당자명 varchar, r_action text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _id uuid;
  _action text;
  _cid uuid;
  _order smallint;
BEGIN
  _cid := (_payload->>'customer_id')::uuid;
  _order := COALESCE((_payload->>'display_order')::smallint, 0);

  IF _payload ? 'id' AND (_payload->>'id') IS NOT NULL AND (_payload->>'id') <> '' THEN
    -- UPDATE
    _id := (_payload->>'id')::uuid;
    UPDATE public.customer_contacts SET
      담당자명     = COALESCE(_payload->>'담당자명', 담당자명),
      직급         = _payload->>'직급',
      부서         = _payload->>'부서',
      전화         = _payload->>'전화',
      휴대폰       = _payload->>'휴대폰',
      이메일       = _payload->>'이메일',
      메모         = _payload->>'메모',
      display_order = _order,
      updated_at   = now()
    WHERE id = _id;
    _action := 'update';
  ELSE
    -- INSERT
    INSERT INTO public.customer_contacts (
      customer_id, 담당자명, 직급, 부서, 전화, 휴대폰, 이메일, 메모, display_order
    ) VALUES (
      _cid,
      _payload->>'담당자명',
      _payload->>'직급',
      _payload->>'부서',
      _payload->>'전화',
      _payload->>'휴대폰',
      _payload->>'이메일',
      _payload->>'메모',
      _order
    ) RETURNING id INTO _id;
    _action := 'insert';
  END IF;

  RETURN QUERY SELECT c.id, c.담당자명, _action FROM public.customer_contacts c WHERE c.id = _id;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_customer_contact(jsonb) TO authenticated, service_role;


-- ────────────────────────────────────────
-- 5. RPC (3) rpc_delete_customer_contact — 삭제
-- ────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_delete_customer_contact(_id uuid)
RETURNS TABLE(r_id uuid, r_deleted boolean)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  _exists boolean;
BEGIN
  SELECT EXISTS(SELECT 1 FROM public.customer_contacts WHERE id = _id) INTO _exists;
  IF NOT _exists THEN
    RETURN QUERY SELECT _id, false;
    RETURN;
  END IF;

  DELETE FROM public.customer_contacts WHERE id = _id;
  RETURN QUERY SELECT _id, true;
END $$;

GRANT EXECUTE ON FUNCTION public.rpc_delete_customer_contact(uuid) TO authenticated, service_role;


-- ============================================================
-- ✅ sql/028 완료
-- ============================================================
