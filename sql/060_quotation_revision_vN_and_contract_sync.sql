-- ============================================================================
-- sql/060 — 견적 재견적(-vN) 정상화 + 계약 금액 동기화 + 서명·결제 잠금
-- ============================================================================
-- 작성일: 2026-08-10
-- 승인: 대표 승인 (2026-08-10 「권장 번들 진행해」)
--
-- 배경(근본원인):
--   sql/001 : 견적번호 varchar(30) UNIQUE          ← 단일 UNIQUE
--   sql/012 : 재견적 = "parent 견적번호에 -vN 부착" (주석)
--             그러나 코드는 -vN 을 붙이지 않고 부모 번호를 그대로 INSERT
--   → UNIQUE 정면충돌. 재견적/복사는 도입 이래 100% 실패(수정차수>1 행 0건).
--   sql/045 : retry 를 신규 채번 분기에만 감쌈. 부모 분기는 예외처리 0
--             → raw duplicate key 가 화면까지 노출 → "채번 충돌" 로 오진
--
-- 변경 3종:
--   1) rpc_next_quotation_no      : 정규식 앵커(-vN 행 오염 차단) + KST 연도
--   2) rpc_create_quotation       : 부모 분기 = base||'-v'||차수 / 루트 평면화
--                                   / advisory lock / retry 5회 / KST 연도
--                                   / 채번 기준을 next_no 와 완전 일치
--   3) rpc_update_quotation_status: 수락 시 루트 계약을 찾아 금액 동기화
--                                   서명·결제 진행 후에는 차단(변경계약 유도)
--
-- 데이터 변경: 0건 (기존 행 무손상)
-- 스키마 변경: 0건 (UNIQUE 제약 그대로 유지)
-- 롤백: sql/060_ROLLBACK.sql (변경 전 함수 원문 3종)
-- ============================================================================


-- ────────────────────────────────────────────────────────────────────────────
-- 1) rpc_next_quotation_no — 미리보기 채번
--    ★변경 전: regexp_replace(견적번호,'^.*-(\d+)$','\1')::int
--              → 'Q-EVENT-2026-014-v2' 에서 추출 실패 → int 캐스팅 에러
--    ★변경 후: 3자리 신규번호 형식만 앵커로 필터 → -vN 행은 애초에 안 들어옴
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_next_quotation_no("_사업부" text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_prefix text; v_year text; v_max int;
BEGIN
  v_prefix := CASE _사업부
    WHEN '국내여행'     THEN 'TOUR'
    WHEN '행사이벤트'   THEN 'EVENT'
    WHEN '온라인마케팅' THEN 'MKT'
    WHEN '마케팅교육'   THEN 'EDU'
    ELSE 'GEN' END;

  -- ★연도는 KST 기준 (UTC 기준이면 1/1 오전 9시 이전에 전년도 번호가 나감)
  v_year := to_char(now() AT TIME ZONE 'Asia/Seoul', 'YYYY');

  SELECT COALESCE(MAX(
           (regexp_match(q.견적번호, '^Q-' || v_prefix || '-' || v_year || '-([0-9]{3})$'))[1]::int
         ), 0)
    INTO v_max
    FROM public.quotations q
   WHERE q.견적번호 ~ ('^Q-' || v_prefix || '-' || v_year || '-[0-9]{3}$');

  RETURN 'Q-' || v_prefix || '-' || v_year || '-' || lpad((v_max + 1)::text, 3, '0');
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.rpc_next_quotation_no(text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_next_quotation_no(text) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────────
-- 2) rpc_create_quotation — 신규 채번 + 재견적(-vN)
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_create_quotation(
  _customer_id UUID,
  "_사업부" VARCHAR,
  "_제목" VARCHAR,
  "_수신" JSONB DEFAULT '{}'::jsonb,
  _items JSONB DEFAULT '[]'::jsonb,
  _options JSONB DEFAULT '{}'::jsonb,
  _parent_id UUID DEFAULT NULL
)
RETURNS TABLE(
  id UUID, "견적번호" VARCHAR, "수정차수" INT, "견적금액" BIGINT,
  "사업부" VARCHAR, "상태" VARCHAR, created_at TIMESTAMPTZ
)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  _new_id UUID; _new_no VARCHAR; _new_version INT;
  _next_no INT; _견적금액 BIGINT; _작성자 VARCHAR;
  _prefix VARCHAR; _year INT;
  _root_id UUID; _base_no TEXT;
  _retry_count INT := 0; _max_retry INT := 5;
  _success BOOLEAN := FALSE;
BEGIN
  IF NOT fn_current_is_admin() THEN
    RAISE EXCEPTION '관리자만 견적을 작성할 수 있습니다';
  END IF;
  IF _사업부 NOT IN ('국내여행','행사이벤트','온라인마케팅','마케팅교육') THEN
    RAISE EXCEPTION '사업부는 4종 중 하나여야 합니다';
  END IF;

  _prefix := CASE _사업부 WHEN '국내여행' THEN 'TOUR' WHEN '행사이벤트' THEN 'EVENT'
    WHEN '온라인마케팅' THEN 'MKT' WHEN '마케팅교육' THEN 'EDU' END;
  _year   := EXTRACT(YEAR FROM (now() AT TIME ZONE 'Asia/Seoul'))::INT;  -- ★KST
  _작성자 := COALESCE(auth.jwt() ->> 'email', 'system');

  SELECT COALESCE(SUM((item->>'금액')::BIGINT), 0) INTO _견적금액
    FROM jsonb_array_elements(COALESCE(_items, '[]'::jsonb)) AS item;

  -- ══════════════════════════════════════════════════════════════════
  -- (가) 재견적 = 같은 건의 N차 견적 → base||'-v'||차수
  -- ══════════════════════════════════════════════════════════════════
  IF _parent_id IS NOT NULL THEN

    -- 루트 평면화: v2의 재견적도 루트(v1)에 매달아 트리를 1단으로 유지
    SELECT COALESCE(q.parent_quotation_id, q.id)
      INTO _root_id
      FROM public.quotations q WHERE q.id = _parent_id;
    IF _root_id IS NULL THEN
      RAISE EXCEPTION '부모 견적을 찾을 수 없습니다: %', _parent_id;
    END IF;

    -- 베이스 번호 = 루트 견적번호에서 -vN 제거 (이중 부착 방지)
    SELECT regexp_replace(q.견적번호::TEXT, '-v[0-9]+$', '')
      INTO _base_no
      FROM public.quotations q WHERE q.id = _root_id;

    PERFORM pg_advisory_xact_lock(hashtext('QREV_' || _root_id::TEXT));

    WHILE _retry_count < _max_retry AND NOT _success LOOP
      SELECT COALESCE(MAX(qx.수정차수), 1) + 1 + _retry_count
        INTO _new_version
        FROM public.quotations qx
       WHERE qx.id = _root_id OR qx.parent_quotation_id = _root_id;

      _new_no := _base_no || '-v' || _new_version::TEXT;

      BEGIN
        INSERT INTO quotations(
          customer_id, 견적번호, 수정차수, 견적금액, 유효기간, 결제조건,
          세부항목, 상태, 작성자, parent_quotation_id, 사업부, 제목,
          수신_회사명, 수신_부서, 수신_담당자, 수신_직위,
          대행료율, 대행료_표기, vat_표기, 절사_단위, 판매가_컬럼,
          비고, 첨부_옵션, is_government
        ) VALUES (
          _customer_id, _new_no, _new_version, _견적금액,
          (now() + INTERVAL '30 days')::DATE,
          COALESCE(_options ->> '결제조건', NULL), _items, '작성중', _작성자,
          _root_id, _사업부, _제목,
          _수신 ->> '회사명', _수신 ->> '부서', _수신 ->> '담당자', _수신 ->> '직위',
          COALESCE((_options ->> '대행료율')::NUMERIC, 7.5),
          COALESCE((_options ->> '대행료_표기')::BOOLEAN, TRUE),
          COALESCE((_options ->> 'vat_표기')::BOOLEAN, TRUE),
          COALESCE(_options ->> '절사_단위', '없음'),
          COALESCE((_options ->> '판매가_컬럼')::BOOLEAN, FALSE),
          _options ->> '비고',
          COALESCE(_options -> '첨부', '{}'::jsonb),
          COALESCE((_options ->> 'is_government')::BOOLEAN, FALSE)
        ) RETURNING quotations.id INTO _new_id;
        _success := TRUE;
      EXCEPTION
        WHEN unique_violation THEN
          _retry_count := _retry_count + 1;
          IF _retry_count >= _max_retry THEN
            RAISE EXCEPTION '재견적 차수 채번 % 회 재시도 후에도 실패 (루트=%, 마지막 시도=%)',
              _max_retry, _base_no, _new_no;
          END IF;
      END;
    END LOOP;

  -- ══════════════════════════════════════════════════════════════════
  -- (나) 신규 견적 → Q-<접두>-<연도>-<3자리>
  --     ★채번 기준을 rpc_next_quotation_no 와 완전 일치시킴
  --       (구버전은 사업부+created_at연도+parent IS NULL 로 서로 달랐음)
  -- ══════════════════════════════════════════════════════════════════
  ELSE
    PERFORM pg_advisory_xact_lock(hashtext(_prefix || '_' || _year::TEXT));

    WHILE _retry_count < _max_retry AND NOT _success LOOP
      SELECT COALESCE(MAX(
               (regexp_match(q.견적번호, '^Q-' || _prefix || '-' || _year || '-([0-9]{3})$'))[1]::INT
             ), 0) + 1 + _retry_count
        INTO _next_no
        FROM quotations q
       WHERE q.견적번호 ~ ('^Q-' || _prefix || '-' || _year || '-[0-9]{3}$');

      _new_no := 'Q-' || _prefix || '-' || _year || '-' || LPAD(_next_no::TEXT, 3, '0');
      _new_version := 1;

      BEGIN
        INSERT INTO quotations(
          customer_id, 견적번호, 수정차수, 견적금액, 유효기간, 결제조건,
          세부항목, 상태, 작성자, parent_quotation_id, 사업부, 제목,
          수신_회사명, 수신_부서, 수신_담당자, 수신_직위,
          대행료율, 대행료_표기, vat_표기, 절사_단위, 판매가_컬럼,
          비고, 첨부_옵션, is_government
        ) VALUES (
          _customer_id, _new_no, _new_version, _견적금액,
          (now() + INTERVAL '30 days')::DATE,
          COALESCE(_options ->> '결제조건', NULL), _items, '작성중', _작성자,
          NULL, _사업부, _제목,
          _수신 ->> '회사명', _수신 ->> '부서', _수신 ->> '담당자', _수신 ->> '직위',
          COALESCE((_options ->> '대행료율')::NUMERIC, 7.5),
          COALESCE((_options ->> '대행료_표기')::BOOLEAN, TRUE),
          COALESCE((_options ->> 'vat_표기')::BOOLEAN, TRUE),
          COALESCE(_options ->> '절사_단위', '없음'),
          COALESCE((_options ->> '판매가_컬럼')::BOOLEAN, FALSE),
          _options ->> '비고',
          COALESCE(_options -> '첨부', '{}'::jsonb),
          COALESCE((_options ->> 'is_government')::BOOLEAN, FALSE)
        ) RETURNING quotations.id INTO _new_id;
        _success := TRUE;
      EXCEPTION
        WHEN unique_violation THEN
          _retry_count := _retry_count + 1;
          IF _retry_count >= _max_retry THEN
            RAISE EXCEPTION '견적번호 채번 % 회 재시도 후에도 실패 (사업부=%, 연도=%, 마지막 시도=%)',
              _max_retry, _사업부, _year, _new_no;
          END IF;
      END;
    END LOOP;
  END IF;

  RETURN QUERY
    SELECT q.id, q.견적번호, q.수정차수, q.견적금액, q.사업부, q.상태, q.created_at
      FROM quotations q WHERE q.id = _new_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.rpc_create_quotation(UUID,VARCHAR,VARCHAR,JSONB,JSONB,JSONB,UUID) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_quotation(UUID,VARCHAR,VARCHAR,JSONB,JSONB,JSONB,UUID) TO authenticated;


-- ────────────────────────────────────────────────────────────────────────────
-- 3) rpc_update_quotation_status — 수락 시 계약 동기화
--    ★변경 전: 계약번호가 이미 있으면 "조용히 건너뜀"
--              → v2 를 수락해도 옛 금액 계약이 그대로 남음 (금액 오류 무경고)
--    ★변경 후: 루트 계약을 찾아 금액·항목·차수 갱신 + status_history 기록
--              단, 서명/결제/체결이 진행된 계약은 차단 → 변경계약(부속합의)
-- ────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_update_quotation_status(
  _quotation_id uuid, _new_status text, _reason text DEFAULT NULL::text)
 RETURNS TABLE(r_quotation_id uuid, "r_견적번호" text, "r_상태_이전" text,
               "r_상태_이후" text, "r_발송_실패_사유" text, r_updated_at timestamptz)
 LANGUAGE plpgsql SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_old_status TEXT; v_qno TEXT; v_reason_field TEXT;
  v_contract_no TEXT;
  v_deposit_rate NUMERIC; v_balance_rate NUMERIC; v_payment_terms TEXT;
  v_root_id UUID; v_root_no TEXT;
  v_c_id UUID; v_c_amt BIGINT; v_c_sig TEXT; v_c_sig2 TEXT;
  v_c_pay TEXT; v_c_stat TEXT;
  v_new_amt BIGINT; v_cust UUID;
BEGIN
  IF NOT public.fn_current_is_admin() THEN RAISE EXCEPTION 'permission denied (admin only)'; END IF;
  IF _new_status NOT IN ('수락','거절','만료','무효화') THEN RAISE EXCEPTION 'invalid status: %', _new_status; END IF;

  SELECT q.상태::TEXT, q.견적번호::TEXT, q.customer_id
    INTO v_old_status, v_qno, v_cust
    FROM public.quotations q WHERE q.id = _quotation_id;
  IF v_qno IS NULL THEN RAISE EXCEPTION 'Quotation not found: %', _quotation_id USING ERRCODE = 'P0002'; END IF;

  v_reason_field := NULL;
  IF _new_status = '거절'   AND _reason IS NOT NULL AND length(trim(_reason)) > 0 THEN v_reason_field := '[거절] '   || _reason;
  ELSIF _new_status = '무효화' AND _reason IS NOT NULL AND length(trim(_reason)) > 0 THEN v_reason_field := '[무효화] ' || _reason; END IF;

  UPDATE public.quotations
     SET 상태 = _new_status,
         발송_실패_사유 = COALESCE(v_reason_field, public.quotations.발송_실패_사유),
         updated_at = now()
   WHERE id = _quotation_id;

  IF _new_status = '수락' THEN
    -- 루트(원 견적) 확정 → 계약번호는 언제나 루트 기준 (v2 라도 같은 계약)
    SELECT COALESCE(q.parent_quotation_id, q.id) INTO v_root_id
      FROM public.quotations q WHERE q.id = _quotation_id;
    SELECT regexp_replace(q.견적번호::TEXT, '-v[0-9]+$', '') INTO v_root_no
      FROM public.quotations q WHERE q.id = v_root_id;

    v_contract_no := 'C-' || SUBSTRING(v_root_no FROM 3);

    SELECT c.id, c.계약금액, c.서명상태::TEXT, c.서명_상태_세부::TEXT, c.결제_상태::TEXT, c.상태::TEXT
      INTO v_c_id, v_c_amt, v_c_sig, v_c_sig2, v_c_pay, v_c_stat
      FROM public.contracts c WHERE c.계약번호 = v_contract_no;

    SELECT q.견적금액 INTO v_new_amt FROM public.quotations q WHERE q.id = _quotation_id;

    IF v_c_id IS NULL THEN
      -- ── 계약 신규 생성 (기존 로직 유지) ──
      SELECT q.결제조건 INTO v_payment_terms FROM public.quotations q WHERE q.id = _quotation_id;
      v_deposit_rate := COALESCE(NULLIF(substring(COALESCE(v_payment_terms,'') from '계약금[^0-9]*([0-9]+)'),'')::numeric, 50);
      v_balance_rate := COALESCE(NULLIF(substring(COALESCE(v_payment_terms,'') from '잔금[^0-9]*([0-9]+)'),'')::numeric, 100 - v_deposit_rate);
      IF (v_deposit_rate + v_balance_rate) <> 100 THEN v_deposit_rate := 50; v_balance_rate := 50; END IF;

      INSERT INTO public.contracts (
        customer_id, quotation_id, 계약번호, 계약금액, 계약명,
        계약기간_시작, 계약기간_종료, 계약금비율, 잔금비율,
        작성자, 상태, provider, 서명상태, 서명_상태_세부, 결제_상태, 발송_횟수,
        행사명, 행사일시, 예상인원_총, 행사품목, 행사내용,
        의뢰인_회사명, 의뢰인_사업자번호, 의뢰인_대표자명, 의뢰인_주소, 의뢰인_연락처, 체결일
      )
      SELECT q.customer_id, q.id, v_contract_no, COALESCE(q.견적금액, 0),
        COALESCE(q.제목,''), c2.시작일, c2.종료일, v_deposit_rate, v_balance_rate,
        COALESCE(auth.email(),'system'), '작성중', 'self', '미서명', 'pending', 'pending', 0,
        q.제목,
        CASE WHEN c2.시작일 IS NOT NULL
             THEN to_char(c2.시작일,'YYYY.MM.DD')
               || CASE WHEN c2.종료일 IS NOT NULL AND c2.종료일 <> c2.시작일
                       THEN ' ~ ' || to_char(c2.종료일,'YYYY.MM.DD') ELSE '' END
             ELSE NULL END,
        CASE WHEN c2.인원_성인 IS NOT NULL OR c2.인원_아동 IS NOT NULL
             THEN COALESCE(c2.인원_성인,0) + COALESCE(c2.인원_아동,0) ELSE NULL END,
        (SELECT string_agg(DISTINCT qi.품목명, ', ') FROM public.quotation_items qi
          WHERE qi.quotation_id = q.id AND COALESCE(qi.품목명,'') <> ''),
        (SELECT string_agg(DISTINCT qi.카테고리_대분류, ', ') FROM public.quotation_items qi
          WHERE qi.quotation_id = q.id AND COALESCE(qi.카테고리_대분류,'') <> ''),
        c2.회사명, c2.사업자번호, c2.대표자명, c2.회사주소, c2.연락처, CURRENT_DATE
      FROM public.quotations q
      JOIN public.customers c2 ON c2.id = q.customer_id
     WHERE q.id = _quotation_id;

    ELSE
      -- ── 기존 계약 있음 ──
      -- ★안전장치: 서명·결제·체결이 진행됐으면 자동 변경 금지
      IF v_c_sig2 IN ('signed_갑','signed_을','completed')
         OR v_c_sig IN ('갑서명','을서명','완료')
         OR v_c_pay <> 'pending'
         OR v_c_stat IN ('체결','해지') THEN
        RAISE EXCEPTION
          '서명·결제가 진행된 계약(%)은 금액을 자동 변경할 수 없습니다. 변경계약(부속합의)으로 처리하세요. [서명=% / 결제=% / 계약상태=%] 요청금액 % → %',
          v_contract_no, v_c_sig2, v_c_pay, v_c_stat, v_c_amt, v_new_amt;
      END IF;

      -- 금액·연결견적·항목 동기화 + 수정차수 +1
      UPDATE public.contracts c
         SET 계약금액   = COALESCE(v_new_amt, c.계약금액),
             quotation_id = _quotation_id,
             계약명     = COALESCE(q.제목, c.계약명),
             행사명     = COALESCE(q.제목, c.행사명),
             행사품목   = COALESCE((SELECT string_agg(DISTINCT qi.품목명, ', ')
                                     FROM public.quotation_items qi
                                    WHERE qi.quotation_id = _quotation_id
                                      AND COALESCE(qi.품목명,'') <> ''), c.행사품목),
             행사내용   = COALESCE((SELECT string_agg(DISTINCT qi.카테고리_대분류, ', ')
                                     FROM public.quotation_items qi
                                    WHERE qi.quotation_id = _quotation_id
                                      AND COALESCE(qi.카테고리_대분류,'') <> ''), c.행사내용),
             수정차수   = c.수정차수 + 1,
             수정사유   = '[' || v_qno || ' 수락 반영] 계약금액 ' ||
                          to_char(COALESCE(v_c_amt,0),'FM999,999,999,999') || ' → ' ||
                          to_char(COALESCE(v_new_amt,0),'FM999,999,999,999'),
             updated_at = now()
        FROM public.quotations q
       WHERE c.id = v_c_id AND q.id = _quotation_id;

      INSERT INTO public.status_history(customer_id, 이전상태, 다음상태, 변경사유, 변경자)
      VALUES (v_cust, LEFT(COALESCE(v_c_stat,'작성중'),10), LEFT(COALESCE(v_c_stat,'작성중'),10),
              '[계약 ' || v_contract_no || ' 금액 동기화] ' || v_qno || ' 수락 → ' ||
              to_char(COALESCE(v_c_amt,0),'FM999,999,999,999') || '원 → ' ||
              to_char(COALESCE(v_new_amt,0),'FM999,999,999,999') || '원',
              COALESCE(auth.email(),'system'));
    END IF;
  END IF;

  RETURN QUERY SELECT q.id, q.견적번호::TEXT, v_old_status, q.상태::TEXT,
                      q.발송_실패_사유::TEXT, q.updated_at
    FROM public.quotations q WHERE q.id = _quotation_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.rpc_update_quotation_status(uuid,text,text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_update_quotation_status(uuid,text,text) TO authenticated;

NOTIFY pgrst, 'reload schema';
