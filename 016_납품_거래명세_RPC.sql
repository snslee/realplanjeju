-- =====================================================================
-- sql/016 — 납품·거래명세 RPC + quotations 컬럼 4종 추가
-- 작성일: 2026-04-28
-- 적용 시점: admin v2.8.0 셸 배포 시 (Day 2 AM 1)
-- 선행 의존: sql/001~015 적용 완료
-- =====================================================================
-- 운영 지침서 v2.0.1 §11 (확장 가능성 보존):
--   - cast 면제 (UUID·TIMESTAMPTZ 타입 직접 반환) — 메모리 'feedback_postgres_returns_table' 표준 준수
--   - r_ prefix + 명시적 타입 보존 (sql/015 v3 표준)
--   - SECURITY DEFINER + GRANT EXECUTE TO anon, authenticated
-- =====================================================================
-- 변경 영향:
--   1. quotations 테이블 4 컬럼 추가 (NULL 허용 / 기존 데이터 영향 없음)
--   2. 신규 RPC 2종: rpc_send_delivery, rpc_send_statement
--   3. 롤백 절차: ALTER TABLE DROP COLUMN + DROP FUNCTION (본 파일 하단 참조)
-- =====================================================================

-- 1) quotations 컬럼 추가 (납품 + 거래명세)
ALTER TABLE quotations
  ADD COLUMN IF NOT EXISTS 납품일시      TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS 거래명세일시  TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS 납품수신자    TEXT,
  ADD COLUMN IF NOT EXISTS 거래명세수신자 TEXT;

COMMENT ON COLUMN quotations.납품일시       IS '납품서 메일 발송 일시 (rpc_send_delivery로 갱신)';
COMMENT ON COLUMN quotations.거래명세일시   IS '거래명세서 메일 발송 일시 (rpc_send_statement로 갱신)';
COMMENT ON COLUMN quotations.납품수신자     IS '납품서 메일 수신자 이메일';
COMMENT ON COLUMN quotations.거래명세수신자 IS '거래명세서 메일 수신자 이메일';

-- 2) rpc_send_delivery — 납품서 발송 시각 기록 (Edge Function send-quotation 후속 호출)
CREATE OR REPLACE FUNCTION rpc_send_delivery(
    _quotation_id   UUID,
    _수신자이메일   TEXT
) RETURNS TABLE (
    r_quotation_id UUID,
    r_납품일시     TIMESTAMPTZ,
    r_납품수신자   TEXT
) AS $$
BEGIN
    UPDATE quotations
       SET 납품일시   = NOW(),
           납품수신자 = _수신자이메일
     WHERE id = _quotation_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'quotations.id=% not found', _quotation_id;
    END IF;

    RETURN QUERY
        SELECT id, 납품일시, 납품수신자
          FROM quotations
         WHERE id = _quotation_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION rpc_send_delivery(UUID, TEXT) TO anon, authenticated;

COMMENT ON FUNCTION rpc_send_delivery IS
    '견적 ID와 수신자 이메일로 납품일시·수신자 기록. Edge Function send-quotation 발송 성공 후 호출.';

-- 3) rpc_send_statement — 거래명세서 발송 시각 기록
CREATE OR REPLACE FUNCTION rpc_send_statement(
    _quotation_id   UUID,
    _수신자이메일   TEXT
) RETURNS TABLE (
    r_quotation_id     UUID,
    r_거래명세일시     TIMESTAMPTZ,
    r_거래명세수신자   TEXT
) AS $$
BEGIN
    UPDATE quotations
       SET 거래명세일시   = NOW(),
           거래명세수신자 = _수신자이메일
     WHERE id = _quotation_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'quotations.id=% not found', _quotation_id;
    END IF;

    RETURN QUERY
        SELECT id, 거래명세일시, 거래명세수신자
          FROM quotations
         WHERE id = _quotation_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

GRANT EXECUTE ON FUNCTION rpc_send_statement(UUID, TEXT) TO anon, authenticated;

COMMENT ON FUNCTION rpc_send_statement IS
    '견적 ID와 수신자 이메일로 거래명세일시·수신자 기록. Edge Function send-quotation 발송 성공 후 호출.';

-- =====================================================================
-- 검증 쿼리 (Supabase SQL Editor에서 실행)
-- =====================================================================
-- (a) 컬럼 추가 확인
-- SELECT column_name, data_type, is_nullable
--   FROM information_schema.columns
--  WHERE table_name = 'quotations'
--    AND column_name IN ('납품일시','거래명세일시','납품수신자','거래명세수신자');
-- 기대값: 4행 (TIMESTAMPTZ 2 + TEXT 2 / 모두 YES nullable)

-- (b) RPC 2종 등록 확인
-- SELECT routine_name, routine_type, security_type
--   FROM information_schema.routines
--  WHERE routine_name IN ('rpc_send_delivery','rpc_send_statement');
-- 기대값: 2행 (FUNCTION / DEFINER)

-- (c) GRANT 확인
-- SELECT grantee, privilege_type
--   FROM information_schema.routine_privileges
--  WHERE routine_name IN ('rpc_send_delivery','rpc_send_statement')
--    AND grantee IN ('anon','authenticated');
-- 기대값: 4행 (각 RPC × anon, authenticated)

-- (d) 호출 검증 — 기존 견적 1건으로 테스트 (실 데이터 영향 → 테스트 후 NULL로 복구)
-- SELECT * FROM rpc_send_delivery(
--     (SELECT id FROM quotations LIMIT 1),
--     'test@realplanjeju.com'
-- );
-- 복구: UPDATE quotations SET 납품일시=NULL, 납품수신자=NULL WHERE 납품수신자='test@realplanjeju.com';

-- =====================================================================
-- 롤백 절차 (필요 시)
-- =====================================================================
-- DROP FUNCTION IF EXISTS rpc_send_delivery(UUID, TEXT);
-- DROP FUNCTION IF EXISTS rpc_send_statement(UUID, TEXT);
-- ALTER TABLE quotations DROP COLUMN IF EXISTS 납품일시;
-- ALTER TABLE quotations DROP COLUMN IF EXISTS 거래명세일시;
-- ALTER TABLE quotations DROP COLUMN IF EXISTS 납품수신자;
-- ALTER TABLE quotations DROP COLUMN IF EXISTS 거래명세수신자;
-- =====================================================================
-- END OF FILE — sql/016
-- =====================================================================
