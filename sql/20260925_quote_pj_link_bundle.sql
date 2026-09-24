-- =====================================================================
-- 2026-09-24~25 회사 시스템 방 — 견적↔행사↔계산서 연결(5단계) + 직접 매칭 + 권장 번들
-- 대표 승인: 9/24 「진행해」(5단계) · 9/25 「권장 번들 진행해」
-- 이 파일은 실행 기록이다. 데이터 행 변경은 요약만 싣고, 스키마·뷰는 전문을 싣는다.
-- 인수인계: claude/SYS_인수인계_20260925_권장번들_완료.md
-- =====================================================================

-- [1] 5단계 (2026-09-24 밤) — 백업 bak20260925a_pj_프로젝트 · _quotations · _견적매출연결 · _customers · _cu_고객사
--  · pj_프로젝트.견적_id 22건 연결 (같은 고객 · 행사 창 안 · 수락 1건) — pj_연결로그 방식 '5단계 견적연결'
--  · quotations: M-TOUR-2025-035 → 수락 · M-TOUR-2025-046 → 발송완료 · M-EVENT-2026-025 → 무효화(Q-EVENT-2026-014-v2 중복)
--  · acc_견적매출연결: 이전 수정본 → 수주본 15행 이동·확정 · 추정/검토→확정 2 · 새 연결 5 (안성·지천 확정, 제주영상·가은초 검토)
--  · customers/cu_고객사 「제 목 : 글로벌 포럼」 숨김

-- [2] 직접 매칭 (2026-09-25) — 백업 bak20260925b_*
--  · PJ-2025-011 광주 ← M-TOUR-2025-069 · 계산서 검토 7 → 확정
--  · 새 행사 PJ-2025-015 한림공고 인공위성 모형 기증식 · PJ-2025-016 신양1리 하추자도 마을축제 3회
--  · acc 6행 프로젝트 연결 (한림 2 · 신양1리 3 · 지천 「2일차 석식」 216,500)
--  · 창녕 계산서(한국생활개선창녕군연합회 2,885,300) → M-TOUR-2025-099 확정 연결
--  · mk_portfolio 2행 프로젝트_id (P5-A 통지)

-- [3] 권장 번들 (2026-09-25) — 백업 bak20260925c_* (viewdef 포함)
alter table pj_프로젝트 add column if not exists "계산서대체" text, add column if not exists "마진확인" text;
comment on column pj_프로젝트."계산서대체" is '세금계산서 대신 인정한 증빙(카드결제·학교 인보이스 등) — 5칸 ② 통과. 2026-09-25 대표 승인(K)';
comment on column pj_프로젝트."마진확인" is '마진율 이상치를 사람이 확인해 정상으로 확정한 메모 — 이상치 판정 해제. 2026-09-25';
--  · 새 행사 PJ-2025-017 제주영웅로타리클럽 부산여행(2025-02) 손익제외 · ap 2행 + acc 4행 연결
--  · 주류비 50,000 ap 비고 「공통비」
--  · 계산서대체: PJ-2025-014 오니츠카(카드결제·페이앱) · PJ-2026-001 단국대(학교 인보이스)
--  · 마진확인: PJ-2025-011 광주 「정상 고마진」
--  · M-EVENT-2026-013 더보상 이전판 → 재발송

-- [4] v_pj_손익 개정 — ② 계산서 = 사업자번호 창 ∪ 견적매출연결(확정, 행사 견적) · 계산서대체 인정 · 마진확인 시 이상치 해제
create or replace view "v_pj_손익" with (security_invoker=true) as
WITH pj AS (
 SELECT p.id, p."프로젝트번호", p."프로젝트명", p."사업부", p."상태", p."고객_id", p."손익제외", p."손익제외사유", c."고객사_id", cu."사업자번호",
  COALESCE(p."시작일", c."시작일", to_date(((pf."진행월")::text || '-01'::text), 'YYYY-MM-DD'::text)) AS s,
  COALESCE(p."종료일", c."종료일", p."시작일", c."시작일", ((to_date(((pf."진행월")::text || '-01'::text), 'YYYY-MM-DD'::text) + '1 mon -1 days'::interval))::date) AS e,
  pf.id AS pf_id, pf."사례명", p."견적_id", p."계산서대체", p."마진확인"
 FROM "pj_프로젝트" p LEFT JOIN customers c ON c.id = p."고객_id" LEFT JOIN "cu_고객사" cu ON cu.id = c."고객사_id" LEFT JOIN mk_portfolio pf ON pf."프로젝트_id" = p.id
 WHERE p.deleted_at IS NULL
), inn AS (
 SELECT "프로젝트_id" AS pj, sum("금액") AS amt, count(*) AS n FROM "acc_거래내역"
 WHERE "구분" = '수입' AND COALESCE("상태", '') <> '취소' AND "프로젝트_id" IS NOT NULL GROUP BY "프로젝트_id"
), cost AS (
 SELECT COALESCE(a."프로젝트_id", t."프로젝트_id") AS pj, sum(x."금액") AS amt, count(*) AS n, count(*) FILTER (WHERE x."원천" = 'ap') AS n_ap
 FROM "pr_지출원장" x LEFT JOIN "ap_결재" a ON x."원천" = 'ap' AND a.id::text = x."원천_id" LEFT JOIN "acc_거래내역" t ON x."원천" = 'acc' AND t.id::text = x."원천_id"
 WHERE NOT COALESCE(x."제외", false) GROUP BY COALESCE(a."프로젝트_id", t."프로젝트_id")
), split AS (
 SELECT b."프로젝트_id" AS pj, sum(CASE WHEN t."구분" = '수입' THEN b."금액" ELSE 0 END) AS inn, sum(CASE WHEN t."구분" = '지출' THEN b."금액" ELSE 0 END) AS cost
 FROM "acc_프로젝트배분" b JOIN "acc_거래내역" t ON t.id = b."거래_id" GROUP BY b."프로젝트_id"
), bank AS (
 SELECT max("거래일") AS last FROM "acc_원천거래" WHERE "원천" ~~ '%통장'
), b1 AS (
 SELECT pj.id, pj."프로젝트번호", pj."프로젝트명", pj."사업부", pj."상태", pj."고객_id", pj."손익제외", pj."손익제외사유", pj."고객사_id", pj."사업자번호", pj.s, pj.e, pj.pf_id, pj."사례명",
  COALESCE(i.amt, 0) + COALESCE(sp.inn, 0) AS "입금", COALESCE(i.n, 0::bigint) AS "입금건",
  COALESCE(k.amt, 0) + COALESCE(sp.cost, 0) AS "지출", COALESCE(k.n, 0::bigint) AS "지출건", COALESCE(k.n_ap, 0::bigint) AS "지출결의건",
  ( SELECT COALESCE(sum(r."금액"), 0) FROM "acc_원천거래" r
    WHERE r."원천" = '세금계산서매출' AND r.id IN (
      SELECT r2.id FROM "acc_원천거래" r2 WHERE pj."사업자번호" IS NOT NULL AND r2."원천" = '세금계산서매출'
        AND regexp_replace(r2."상대사업자번호", '\D', '', 'g') = regexp_replace(pj."사업자번호", '\D', '', 'g') AND r2."거래일" >= pj.s - 60 AND r2."거래일" <= pj.e + 90
      UNION
      SELECT l."원천거래_id" FROM "acc_견적매출연결" l WHERE pj."견적_id" IS NOT NULL AND l.quotation_id = pj."견적_id" AND l."판정" = '확정')) AS "계산서",
  ( SELECT bank.last FROM bank) AS "통장마지막",
  pj."계산서대체", pj."마진확인"
 FROM pj LEFT JOIN inn i ON i.pj = pj.id LEFT JOIN cost k ON k.pj = pj.id LEFT JOIN split sp ON sp.pj = pj.id
), b2 AS (
 SELECT b1.*,
  CASE WHEN b1."입금" > 0 THEN round((b1."입금" - b1."지출") * 100.0 / b1."입금", 1) ELSE NULL::numeric END AS "마진율",
  b1."입금" > 0 AS c1,
  (b1."계산서" > 0 OR b1."계산서대체" IS NOT NULL) AS c2,
  b1."지출" > 0 AS c3,
  ((b1."입금" > 0 AND b1."계산서" > 0 AND (abs(b1."입금" - b1."계산서") <= b1."입금" * 0.01 OR (b1."사업부" = '국내여행' AND b1."계산서" < b1."입금" * 0.2)))
    OR (b1."입금" > 0 AND b1."계산서대체" IS NOT NULL AND b1."계산서" = 0)) AS c4,
  (b1.e IS NOT NULL AND (b1.e + 30) <= b1."통장마지막") AS c5
 FROM b1
), b3 AS (
 SELECT b2.*,
  (b2."마진율" IS NOT NULL AND (b2."마진율" < 0 OR (b2."사업부" = '국내여행' AND b2."마진율" > 40) OR (b2."사업부" <> '국내여행' AND b2."마진율" > 60))) AS outlier_raw
 FROM b2
), b4 AS (
 SELECT b3.*, (b3.outlier_raw AND b3."마진확인" IS NULL) AS outlier FROM b3
)
SELECT id AS "프로젝트_id", "프로젝트번호", "프로젝트명", "사업부", s AS "시작일", e AS "종료일", pf_id AS "실사례_id", "사례명",
 "입금"::bigint AS "입금", "입금건", "지출"::bigint AS "지출", "지출건", "지출결의건", "계산서"::bigint AS "계산서",
 ("입금" - "지출")::bigint AS "마진", "마진율",
 c1 AS "①입금", c2 AS "②계산서", c3 AS "③지출", c4 AS "④입금=계산서", c5 AS "⑤자료기간",
 CASE WHEN "손익제외" THEN '제외(봉사 등)'
      WHEN c1 AND c2 AND c3 AND c4 AND c5 AND NOT outlier THEN '확정 가능'
      WHEN c1 AND c2 AND c3 AND c4 AND c5 AND outlier THEN '확인 필요(마진율)'
      ELSE '잠정' END AS "판정",
 CASE WHEN "손익제외" THEN "손익제외사유"
  ELSE concat_ws(' · ',
   CASE WHEN NOT c1 THEN '입금 없음' END,
   CASE WHEN NOT c2 THEN '계산서 못 찾음' END,
   CASE WHEN "계산서대체" IS NOT NULL AND "계산서" = 0 THEN '계산서 대체 인정: ' || "계산서대체" END,
   CASE WHEN NOT c3 THEN '지출 없음' END,
   CASE WHEN c1 AND c2 AND NOT c4 THEN '입금≠계산서' END,
   CASE WHEN "사업부" = '국내여행' AND "계산서" > 0 AND "계산서" < "입금" * 0.2 THEN '수수료만 계산서(여행)' END,
   CASE WHEN NOT c5 THEN '통장 자료 기간 밖' END,
   CASE WHEN outlier AND "마진율" < 0 THEN '역마진 — 이중계산·빠진 입금 확인' END,
   CASE WHEN outlier AND "마진율" >= 0 THEN '마진율 높음 — 빠진 지출 확인' END,
   CASE WHEN outlier_raw AND "마진확인" IS NOT NULL THEN '마진율 확인됨: ' || "마진확인" END)
 END AS "확인할것",
 "계산서대체", "마진확인"
FROM b4;

-- [5] 결과 (2026-09-25): 확정 가능 21 · 입금 321,500,938 · 마진 83,165,678 / 확인 필요 3(오봉·라이나·선관위) / 잠정 6 / 제외 2(로타리 2)

-- [6] 되돌리기
-- 뷰: select def from "bak20260925c_viewdef";  → create or replace view "v_pj_손익" with (security_invoker=true) as <def>  (새 칸 2개는 뒤에 붙었으므로 drop view 후 재생성)
-- 권장 번들: update pj_프로젝트 p set "계산서대체"=null, "마진확인"=null; update ap_결재 a set 프로젝트_id=b.프로젝트_id, 고객_id=b.고객_id, 비고=b.비고 from "bak20260925c_ap_결재" b where b.id=a.id;
--           update acc_거래내역 t set 프로젝트_id=b.프로젝트_id from "bak20260925c_acc_거래내역" b where b.id=t.id; delete from pj_프로젝트 where 프로젝트번호='PJ-2025-017';
--           update quotations q set 상태=b.상태, 비고=b.비고 from "bak20260925c_quotations" b where b.id=q.id;
-- 직접 매칭: update acc_거래내역 t set 프로젝트_id=b.프로젝트_id from "bak20260925b_acc_거래내역" b where b.id=t.id;
--           update mk_portfolio p set 프로젝트_id=b.프로젝트_id from "bak20260925b_mk_portfolio" b where b.id=p.id; delete from pj_프로젝트 where 프로젝트번호 in ('PJ-2025-015','PJ-2025-016');
--           update pj_프로젝트 set 견적_id=null where 프로젝트번호='PJ-2025-011';
-- 연결표: delete from "acc_견적매출연결" where id not in (select id from "bak20260925a_견적매출연결"); update "acc_견적매출연결" l set quotation_id=b.quotation_id, 판정=b.판정, 근거=b.근거, 연결방식=b.연결방식 from "bak20260925a_견적매출연결" b where b.id=l.id;
-- 5단계 행사↔견적: update pj_프로젝트 p set 견적_id=b.견적_id from "bak20260925a_pj_프로젝트" b where b.id=p.id;
-- 배포 통로 꼬리 검사용 표지 -- </html>
