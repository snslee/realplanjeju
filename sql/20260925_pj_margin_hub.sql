-- =====================================================================
-- sql/20260925_pj_margin_hub.sql
-- 리얼플랜제주 회사 시스템 방 · 행사별 실제 마진 계산 허브 (2026-09-24 1~4단계 + 2026-09-25 매칭 번들)
-- 정본 = Supabase iodfqlkeiwxyuojwcozv · 이 파일은 실행 후 기록본(구조 DDL + 데이터 변경 요약)
-- 원가·마진은 내부 전용(owner·manager) — 고객 문서에 쓰지 않는다 (지침 제12조 F)
-- 백업: bak20260924s·t·u·v·w_* / bak20260925a_* (acc_거래내역·pr_지출원장·v_pj_손익)
-- =====================================================================

-- [1] 칸 추가 -----------------------------------------------------------
alter table "pj_프로젝트" add column if not exists "손익제외" boolean default false;
alter table "pj_프로젝트" add column if not exists "손익제외사유" text;
alter table mk_portfolio add column if not exists "프로젝트_id" uuid references "pj_프로젝트"(id);
alter table "acc_거래내역" add column if not exists "프로젝트_id" uuid references "pj_프로젝트"(id);

-- [2] 표 ----------------------------------------------------------------
create table if not exists "pj_연결로그" (
  id bigserial primary key,
  "대상표" text not null, "대상_id" text not null, "칸" text not null,
  "이전값" text, "새값" text, "근거" text,
  "방식" text default '자동(3단계 소급)', at timestamptz default now());
alter table "pj_연결로그" enable row level security;
create policy "pj_연결로그_owner" on "pj_연결로그" for select using (fn_is_role(array['owner','manager']));

create table if not exists "acc_수정계산서_짝" (
  "수정_id" uuid primary key references "acc_원천거래"(id),
  "원본_id" uuid unique references "acc_원천거래"(id),
  "원천" text not null, "상대사업자번호" text, "금액" numeric not null,
  "판정" text not null check ("판정" in ('확실','같은날_여럿중1','원본없음')),
  "후보수" int, "근거" text, created_at timestamptz default now());
alter table "acc_수정계산서_짝" enable row level security;
create policy "짝_읽기_owner_manager" on "acc_수정계산서_짝" for select using (fn_is_role(array['owner','manager']));

create table if not exists "acc_프로젝트배분" (
  id uuid primary key default gen_random_uuid(),
  "거래_id" uuid not null references "acc_거래내역"(id) on delete cascade,
  "프로젝트_id" uuid not null references "pj_프로젝트"(id),
  "금액" numeric not null check ("금액" > 0), "근거" text, created_at timestamptz default now(),
  unique ("거래_id","프로젝트_id"));
alter table "acc_프로젝트배분" enable row level security;
create policy "acc_배분_owner_all" on "acc_프로젝트배분" for all using (fn_is_role(array['owner']));

-- [3] 중복 거부 규칙 ------------------------------------------------------
CREATE UNIQUE INDEX "uq_cu_고객사_사업자번호" ON public."cu_고객사" USING btree (regexp_replace("사업자번호", '\D'::text, ''::text, 'g'::text)) WHERE ((deleted_at IS NULL) AND ("사업자번호" IS NOT NULL) AND (regexp_replace("사업자번호", '\D'::text, ''::text, 'g'::text) <> ''::text));
CREATE UNIQUE INDEX "uq_pj_견적_id" ON public."pj_프로젝트" USING btree ("견적_id") WHERE (("견적_id" IS NOT NULL) AND (deleted_at IS NULL));
CREATE UNIQUE INDEX "uq_mk_portfolio_프로젝트_id" ON public.mk_portfolio USING btree ("프로젝트_id") WHERE ("프로젝트_id" IS NOT NULL);

-- [4] 함수 ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_norm_company(p text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select nullif(
    regexp_replace(
      regexp_replace(coalesce(p,''), '\(주\)|㈜|주식회사|\(사\)|㈔|사단법인|재단법인|\(재\)|㈕|\(복\)|사회복지법인|\(유\)|유한회사|농업회사법인', '', 'g'),
      '[[:space:]()\[\]{}·・.,\-_/]', '', 'g')
  , '')
$function$
;

CREATE OR REPLACE FUNCTION public._ap_project_for_customer(p_cust uuid, "p_사업부" text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_pj uuid; v_n int; c record; v_year int; v_no text; v_state text; v_bu text;
        BU constant text[] := array['국내여행','행사이벤트','온라인마케팅','마케팅교육','본사공통'];
begin
  if p_cust is null then return null; end if;

  select count(*) into v_n from "pj_프로젝트" where "고객_id" = p_cust and deleted_at is null;
  if v_n = 1 then
    select id into v_pj from "pj_프로젝트" where "고객_id" = p_cust and deleted_at is null;
    return v_pj;
  elsif v_n > 1 then
    -- [2026-09-24] 행사가 2건 이상: ①진행 중 1건 ②오늘이 행사 앞 90일~뒤 45일 안에 드는 1건 → 그것. 아니면 null(사람이 고름)
    select min(id::text)::uuid, count(*) into v_pj, v_n from "pj_프로젝트"
     where "고객_id" = p_cust and deleted_at is null and "상태" = '진행';
    if v_n = 1 then return v_pj; end if;
    select min(id::text)::uuid, count(*) into v_pj, v_n from "pj_프로젝트"
     where "고객_id" = p_cust and deleted_at is null
       and current_date between coalesce("시작일", current_date) - 90 and coalesce("종료일", "시작일", current_date) + 45;
    if v_n = 1 then return v_pj; end if;
    return null;
  end if;

  select * into c from customers where id = p_cust and deleted_at is null;
  if c.id is null then return null; end if;
  v_year := coalesce(
    nullif(substring(coalesce(c."접수번호",'') from '(\d{4})'),'')::int,
    extract(year from c."시작일")::int,
    extract(year from current_date)::int);
  v_no := "fn_pj_다음번호"(v_year);
  v_state := case when c."고객상태" in ('종료','이탈') then '완료' else '진행' end;
  v_bu := case when c."사업부" = any(BU) then c."사업부"
               when "p_사업부" = any(BU) then "p_사업부"
               else '본사공통' end;
  insert into "pj_프로젝트"
    ("프로젝트번호","고객_id","프로젝트명","사업부","시작일","종료일","상태","출처","비고")
  values (v_no, p_cust, c."회사명" || coalesce(' ('||c."접수번호"||')',''), v_bu, c."시작일", c."종료일", v_state, '결재자동',
    '접수건에서 자동 생성 — 접수건을 고르면 원가가 여기에 쌓입니다')
  returning id into v_pj;
  return v_pj;
end $function$
;

CREATE OR REPLACE FUNCTION public."fn_acc_배분_합계검사"()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_total numeric; v_sum numeric;
begin
  select abs(금액) into v_total from acc_거래내역 where id = new."거래_id";
  select coalesce(sum("금액"),0) into v_sum from "acc_프로젝트배분" where "거래_id" = new."거래_id";
  if v_sum > v_total then
    raise exception '나눈 금액 합(%)이 원래 거래 금액(%)보다 큽니다', v_sum, v_total;
  end if;
  return null;
end $function$
;
CREATE CONSTRAINT TRIGGER "trg_acc_배분_합계검사" AFTER INSERT OR UPDATE ON public."acc_프로젝트배분" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "fn_acc_배분_합계검사"();

-- [5] 마진표 뷰 ------------------------------------------------------------
create or replace view "v_pj_손익" with (security_invoker = true) as
 WITH pj AS (
         SELECT p.id,
            p."프로젝트번호",
            p."프로젝트명",
            p."사업부",
            p."상태",
            p."고객_id",
            p."손익제외",
            p."손익제외사유",
            c."고객사_id",
            cu."사업자번호",
            COALESCE(p."시작일", c."시작일", to_date(pf."진행월"::text || '-01'::text, 'YYYY-MM-DD'::text)) AS s,
            COALESCE(p."종료일", c."종료일", p."시작일", c."시작일", (to_date(pf."진행월"::text || '-01'::text, 'YYYY-MM-DD'::text) + '1 mon -1 days'::interval)::date) AS e,
            pf.id AS pf_id,
            pf."사례명"
           FROM "pj_프로젝트" p
             LEFT JOIN customers c ON c.id = p."고객_id"
             LEFT JOIN "cu_고객사" cu ON cu.id = c."고객사_id"
             LEFT JOIN mk_portfolio pf ON pf."프로젝트_id" = p.id
          WHERE p.deleted_at IS NULL
        ), inn AS (
         SELECT "acc_거래내역"."프로젝트_id" AS pj,
            sum("acc_거래내역"."금액") AS amt,
            count(*) AS n
           FROM "acc_거래내역"
          WHERE "acc_거래내역"."구분" = '수입'::text AND COALESCE("acc_거래내역"."상태", ''::text) <> '취소'::text AND "acc_거래내역"."프로젝트_id" IS NOT NULL
          GROUP BY "acc_거래내역"."프로젝트_id"
        ), cost AS (
         SELECT COALESCE(a."프로젝트_id", t."프로젝트_id") AS pj,
            sum(x."금액") AS amt,
            count(*) AS n,
            count(*) FILTER (WHERE x."원천" = 'ap'::text) AS n_ap
           FROM "pr_지출원장" x
             LEFT JOIN "ap_결재" a ON x."원천" = 'ap'::text AND a.id::text = x."원천_id"
             LEFT JOIN "acc_거래내역" t ON x."원천" = 'acc'::text AND t.id::text = x."원천_id"
          WHERE NOT COALESCE(x."제외", false)
          GROUP BY (COALESCE(a."프로젝트_id", t."프로젝트_id"))
        ), split AS (
         SELECT b."프로젝트_id" AS pj,
            sum(
                CASE
                    WHEN t."구분" = '수입'::text THEN b."금액"
                    ELSE 0::numeric
                END) AS inn,
            sum(
                CASE
                    WHEN t."구분" = '지출'::text THEN b."금액"
                    ELSE 0::numeric
                END) AS cost
           FROM "acc_프로젝트배분" b
             JOIN "acc_거래내역" t ON t.id = b."거래_id"
          GROUP BY b."프로젝트_id"
        ), bank AS (
         SELECT max("acc_원천거래"."거래일") AS last
           FROM "acc_원천거래"
          WHERE "acc_원천거래"."원천" ~~ '%통장'::text
        ), b1 AS (
         SELECT pj.id,
            pj."프로젝트번호",
            pj."프로젝트명",
            pj."사업부",
            pj."상태",
            pj."고객_id",
            pj."손익제외",
            pj."손익제외사유",
            pj."고객사_id",
            pj."사업자번호",
            pj.s,
            pj.e,
            pj.pf_id,
            pj."사례명",
            COALESCE(i.amt, 0::numeric) + COALESCE(sp.inn, 0::numeric) AS "입금",
            COALESCE(i.n, 0::bigint) AS "입금건",
            COALESCE(k.amt, 0::numeric) + COALESCE(sp.cost, 0::numeric) AS "지출",
            COALESCE(k.n, 0::bigint) AS "지출건",
            COALESCE(k.n_ap, 0::bigint) AS "지출결의건",
                CASE
                    WHEN pj."사업자번호" IS NOT NULL THEN ( SELECT COALESCE(sum(r."금액"), 0::numeric) AS "coalesce"
                       FROM "acc_원천거래" r
                      WHERE r."원천" = '세금계산서매출'::text AND regexp_replace(r."상대사업자번호", '\D'::text, ''::text, 'g'::text) = regexp_replace(pj."사업자번호", '\D'::text, ''::text, 'g'::text) AND r."거래일" >= (pj.s - 60) AND r."거래일" <= (pj.e + 90))
                    ELSE 0::numeric
                END AS "계산서",
            ( SELECT bank.last
                   FROM bank) AS "통장마지막"
           FROM pj
             LEFT JOIN inn i ON i.pj = pj.id
             LEFT JOIN cost k ON k.pj = pj.id
             LEFT JOIN split sp ON sp.pj = pj.id
        ), b2 AS (
         SELECT b1.id,
            b1."프로젝트번호",
            b1."프로젝트명",
            b1."사업부",
            b1."상태",
            b1."고객_id",
            b1."손익제외",
            b1."손익제외사유",
            b1."고객사_id",
            b1."사업자번호",
            b1.s,
            b1.e,
            b1.pf_id,
            b1."사례명",
            b1."입금",
            b1."입금건",
            b1."지출",
            b1."지출건",
            b1."지출결의건",
            b1."계산서",
            b1."통장마지막",
                CASE
                    WHEN b1."입금" > 0::numeric THEN round((b1."입금" - b1."지출") * 100.0 / b1."입금", 1)
                    ELSE NULL::numeric
                END AS "마진율",
            b1."입금" > 0::numeric AS c1,
            b1."계산서" > 0::numeric AS c2,
            b1."지출" > 0::numeric AS c3,
            b1."입금" > 0::numeric AND b1."계산서" > 0::numeric AND (abs(b1."입금" - b1."계산서") <= (b1."입금" * 0.01) OR b1."사업부" = '국내여행'::text AND b1."계산서" < (b1."입금" * 0.2)) AS c4,
            b1.e IS NOT NULL AND (b1.e + 30) <= b1."통장마지막" AS c5
           FROM b1
        ), b3 AS (
         SELECT b2.id,
            b2."프로젝트번호",
            b2."프로젝트명",
            b2."사업부",
            b2."상태",
            b2."고객_id",
            b2."손익제외",
            b2."손익제외사유",
            b2."고객사_id",
            b2."사업자번호",
            b2.s,
            b2.e,
            b2.pf_id,
            b2."사례명",
            b2."입금",
            b2."입금건",
            b2."지출",
            b2."지출건",
            b2."지출결의건",
            b2."계산서",
            b2."통장마지막",
            b2."마진율",
            b2.c1,
            b2.c2,
            b2.c3,
            b2.c4,
            b2.c5,
            b2."마진율" IS NOT NULL AND (b2."마진율" < 0::numeric OR b2."사업부" = '국내여행'::text AND b2."마진율" > 40::numeric OR b2."사업부" <> '국내여행'::text AND b2."마진율" > 60::numeric) AS outlier
           FROM b2
        )
 SELECT id AS "프로젝트_id",
    "프로젝트번호",
    "프로젝트명",
    "사업부",
    s AS "시작일",
    e AS "종료일",
    pf_id AS "실사례_id",
    "사례명",
    "입금"::bigint AS "입금",
    "입금건",
    "지출"::bigint AS "지출",
    "지출건",
    "지출결의건",
    "계산서"::bigint AS "계산서",
    ("입금" - "지출")::bigint AS "마진",
    "마진율",
    c1 AS "①입금",
    c2 AS "②계산서",
    c3 AS "③지출",
    c4 AS "④입금=계산서",
    c5 AS "⑤자료기간",
        CASE
            WHEN "손익제외" THEN '제외(봉사 등)'::text
            WHEN c1 AND c2 AND c3 AND c4 AND c5 AND NOT outlier THEN '확정 가능'::text
            WHEN c1 AND c2 AND c3 AND c4 AND c5 AND outlier THEN '확인 필요(마진율)'::text
            ELSE '잠정'::text
        END AS "판정",
        CASE
            WHEN "손익제외" THEN "손익제외사유"
            ELSE concat_ws(' · '::text,
            CASE
                WHEN NOT c1 THEN '입금 없음'::text
                ELSE NULL::text
            END,
            CASE
                WHEN NOT c2 THEN '계산서 못 찾음'::text
                ELSE NULL::text
            END,
            CASE
                WHEN NOT c3 THEN '지출 없음'::text
                ELSE NULL::text
            END,
            CASE
                WHEN c1 AND c2 AND NOT c4 THEN '입금≠계산서'::text
                ELSE NULL::text
            END,
            CASE
                WHEN "사업부" = '국내여행'::text AND c2 AND "계산서" < ("입금" * 0.2) THEN '수수료만 계산서(여행)'::text
                ELSE NULL::text
            END,
            CASE
                WHEN NOT c5 THEN '통장 자료 기간 밖'::text
                ELSE NULL::text
            END,
            CASE
                WHEN outlier AND "마진율" < 0::numeric THEN '역마진 — 이중계산·빠진 입금 확인'::text
                ELSE NULL::text
            END,
            CASE
                WHEN outlier AND "마진율" >= 0::numeric THEN '마진율 높음 — 빠진 지출 확인'::text
                ELSE NULL::text
            END)
        END AS "확인할것"
   FROM b3;

-- 마진 = 입금(통장·부가세 포함) − pr_지출원장(제외 아닌 것). 5칸: ①입금 ②매출계산서(사업자번호·행사 −60~+90일) ③지출 ④입금=계산서 ±1%(여행은 수수료만 계산서 인정) ⑤행사끝+30일 ≤ 통장 마지막일
-- 이상치: 여행 >40% · 그 외 >60% · <0% → 「확인 필요(마진율)」

-- [6] 2026-09-24 데이터 정리 요약 (행 단위 전부 pj_연결로그에 기록) ------------
-- 1단계: 고객사 중복 4쌍 병합 · 사업자번호 역채움 2 · (−)수정계산서 29쌍 → acc_수정계산서_짝
-- 3단계: 실사례 21건 ↔ 행사 1:1(mk_portfolio.프로젝트_id) · 입금·지출 77행 연결
-- 4단계: 지출결의서 원본 67파일·137항목 전수 대조 → pr_지출원장 이중계산 8행 제외 · 지출결의 3건 이동 · 행사 신설 7
--        · 로타리 5주년(PJ-2026-013) 손익제외(봉사)

-- [7] 2026-09-25 매칭 번들 ① (대표 승인) · 직접 매칭 (대표 지시) -------------
-- 입금 연결: 페이앱 3,900,385·1,744,414·영중소 97,425 → PJ-2025-011 광주과기원
--            페이앱 2,562,080·10,236,734·영중소 44,220·176,680 → PJ-2025-014 오니츠카
--            주식회사씨앤 17,086,500 → PJ-2026-003 KSB (발주처 씨앤)
--            고은채 550,000(버스 차액) → PJ-2026-001 단국대
-- 지출 이동: ㈜고마워토토 768,000 · 모노리스제주파크 748,800 → 대부초에서 오니츠카로 (지출결의서 9/8)
-- 원가 추가: AG커뮤니케이션 440,000 (오니츠카 안전요원, 지출결의서 9/15)
-- 원가 제외: pr_지출원장 133 ㈜위더스제주 2,390,500 (5/19 지출결의서 2,415,000과 같은 돈)
-- 품목 정정: pr_지출원장 123 → 신기초 숙박 (에어시티)
-- 금액 정정: pr_지출원장 170 오니츠카 버스 1,200,000 → 600,000 (지출결의서 원본 · 업체 40만×2일−할인20만)
-- 결과: 적자 행사 0(해경 PJ-2026-011은 통장 자료 기간 밖) · 확정 가능 16건 마진 68,490,600

-- [8] 되돌리기 ------------------------------------------------------------
-- update "acc_거래내역" x set "프로젝트_id"=b."프로젝트_id", "적요"=b."적요" from "bak20260925a_acc_거래내역" b where b.id=x.id;
-- delete from "pr_지출원장" where "원천"='acc' and "원천_id"='78f04972-d156-453d-b4de-8ecb8cf7b747';
-- update "pr_지출원장" x set "금액"=b."금액","단가"=b."단가","제외"=b."제외","제외사유"=b."제외사유","거래처명"=b."거래처명","분류"=b."분류","품목"=b."품목","행사명"=b."행사명","고객_id"=b."고객_id","비고"=b."비고" from "bak20260925a_pr_지출원장" b where b.id=x.id;
-- 9/24분: update acc_거래내역 t set 프로젝트_id=l.이전값::uuid from "pj_연결로그" l where l.대상표='acc_거래내역' and l.칸='프로젝트_id' and t.id::text=l.대상_id; (역순)

-- 배포 통로(fn_sys_deploy_from_stage) 꼬리 검사용 표지: </html>
