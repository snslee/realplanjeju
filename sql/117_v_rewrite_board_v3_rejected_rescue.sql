-- 117_v_rewrite_board_v3_rejected_rescue.sql
-- 2026-08-21 대표 지시 — 「리라이트 카테고리에 있어야 될 데이터가 초안보관소에 있다」
--
-- 배경
--   초안보관소(loadDrafts)에서 리라이트를 통째로 빼려면, 그 전에 리라이트 탭이
--   반려(rejected) 초안을 받아 줄 수 있어야 한다. 지금은 3중으로 막혀 있다.
--     ① 이 뷰 d절의  상태 <> 'rejected'      → 초안_id 가 null 로 떨어짐
--     ② 편성판 화면쿼리 슬롯상태 ≠ halted     → 슬롯 행 자체가 안 뜸 (marketing.html 에서 수리)
--     ③ v_rewrite_queue 미포함                → 대queue 에도 없음
--   그래서 반려 3건(a888a8c8·e04d452d·810ed6c2)은 초안보관소가 유일한 통로였다.
--   초안보관소에서 빼기 전에 이 뷰가 먼저 받아야 한다.
--
-- v3 변경점 (v2 대비 딱 3곳, 나머지는 v2 원문 그대로)
--   1) d CTE  : AND COALESCE(x."상태",'') <> 'rejected'  삭제
--   2) d CTE  : DISTINCT ON 정렬에 「비반려 우선」 키 추가
--               → 같은 슬롯에 반려 옛 초안 + 살아 있는 새 초안이 있으면 새 초안이 이긴다.
--                 (이 키가 없으면 수정일만으로 골라 반려본이 산 초안을 가릴 수 있다)
--   3) 배지/할일 : 🚫 반려 분기 신설. halted 보다 앞에 둔다 —
--                 반려 3건은 슬롯도 halted 라서 뒤에 두면 「⏸️ 보류」에 먹혀 안 보인다.
--
-- 실측 사전검증 (적용 전 확인 완료)
--   · 반려 3건 라이브보완 0건  → fx CTE 영향 없음
--   · 초안 리라이트_원본url = 슬롯 원본url (3/3 동일) → 원본_url·순위(4·4·999) 불변
--   · 순위 4·999 이므로 「🔒 잠금(1~3위)」 분기에 걸리지 않음

CREATE OR REPLACE VIEW public.v_rewrite_board AS
WITH s AS (
  SELECT sl.id AS "슬롯_id",
         sl."발행일",
         sl."채널",
         sl."핵심키워드",
         sl."상태" AS "슬롯상태",
         CASE WHEN sl."채널"::text LIKE '%네이버%' THEN '네이버' ELSE '티스토리' END AS "지면",
         LEFT(sl."채널"::text, 2) AS "채널군",
         NULLIF((regexp_match(COALESCE(sl."콘텐츠방향",''), '착수일 실측 ([0-9]+)위'))[1], '')::integer AS "슬롯_순위",
         sl."리라이트_원본url" AS "슬롯_컬럼url",
         (regexp_match(COALESCE(sl."콘텐츠방향",''), '원본 (https?://[^\s]+)'))[1] AS "슬롯_원본url"
  FROM mk_blog_slots sl
  WHERE sl."슬롯유형"::text = '리라이트'
), d AS (
  SELECT DISTINCT ON (x."슬롯_id")
         x."슬롯_id",
         x.id AS "초안_id",
         x."상태" AS "초안상태",
         x."제목",
         x."리라이트_원본url",
         x."발행_url",
         x."반영전_순위",
         x."리라이트_착수일",
         x."리라이트_반영일",
         x."리라이트_회차",
         x."자가검증_점수",
         x."자가검증_결과"
  FROM mk_blog_drafts x
  WHERE x."슬롯유형" = '리라이트'
    AND x."슬롯_id" IS NOT NULL
  ORDER BY x."슬롯_id",
           (COALESCE(x."상태",'') = 'rejected') ASC,   -- ★v3 비반려 우선
           x."수정일" DESC
), fx AS (
  SELECT d."슬롯_id",
         count(*) AS "보완_전체",
         count(*) FILTER (WHERE (e.value ->> '상태') <> '완료') AS "보완_대기"
  FROM d
  CROSS JOIN LATERAL jsonb_array_elements(COALESCE(d."자가검증_결과" -> '라이브보완', '[]'::jsonb)) e(value)
  GROUP BY d."슬롯_id"
), q AS (
  SELECT fn_normalize_blog_url(p."외부_url") AS nurl,
         max(p."현재순위"::integer) AS "현재순위"
  FROM mk_blog_publish_log p
  WHERE p."현재순위" IS NOT NULL
  GROUP BY fn_normalize_blog_url(p."외부_url")
), j AS (
  SELECT s."슬롯_id", s."발행일", s."채널", s."핵심키워드", s."슬롯상태", s."지면", s."채널군",
         d."초안_id", d."초안상태", d."제목", d."발행_url", d."반영전_순위",
         d."리라이트_착수일", d."리라이트_반영일", d."리라이트_회차", d."자가검증_점수",
         COALESCE(fx."보완_전체", 0::bigint) AS "보완_전체",
         COALESCE(fx."보완_대기", 0::bigint) AS "보완_대기",
         COALESCE(d."리라이트_원본url", s."슬롯_컬럼url", s."슬롯_원본url") AS "원본_url",
         COALESCE(q."현재순위", d."반영전_순위", s."슬롯_순위") AS "순위"
  FROM s
  LEFT JOIN d  ON d."슬롯_id" = s."슬롯_id"
  LEFT JOIN fx ON fx."슬롯_id" = s."슬롯_id"
  LEFT JOIN q  ON q.nurl = fn_normalize_blog_url(COALESCE(d."리라이트_원본url", s."슬롯_컬럼url", s."슬롯_원본url"))
)
SELECT "발행일",
       to_char("발행일"::timestamptz,'MM/DD') || '(' ||
       CASE EXTRACT(dow FROM "발행일")::integer
         WHEN 0 THEN '일' WHEN 1 THEN '월' WHEN 2 THEN '화' WHEN 3 THEN '수'
         WHEN 4 THEN '목' WHEN 5 THEN '금' ELSE '토' END || ')' AS "요일",
       "지면", "채널군", "채널", "핵심키워드",
       CASE WHEN "슬롯상태"::text = 'halted' THEN '—'
            ELSE "채널군" || '-' || row_number() OVER (
                   PARTITION BY "발행일","지면","채널군",("슬롯상태"::text='halted') ORDER BY "슬롯_id")
       END AS "순번",
       CASE WHEN "슬롯상태"::text = 'halted' THEN '보류'
            WHEN EXTRACT(dow FROM "발행일")::integer = 5 AND "지면" = '네이버'   THEN '정상'
            WHEN EXTRACT(dow FROM "발행일")::integer = 6 AND "지면" = '티스토리' THEN '정상'
            ELSE '⚠️요일오배정' END AS "요일정합",
       "순위", "반영전_순위",
       "리라이트_회차" AS "회차",
       "슬롯_id", "초안_id", "초안상태", "제목",
       "자가검증_점수" AS "게이트점수",
       "원본_url", "발행_url", "보완_전체", "보완_대기",
       "리라이트_착수일" AS "착수일",
       CASE WHEN "리라이트_착수일" IS NULL THEN NULL::integer
            ELSE (now() AT TIME ZONE 'Asia/Seoul')::date - "리라이트_착수일" END AS "경과일",
       "리라이트_반영일" AS "반영일",
       "슬롯상태",
       CASE
         WHEN "리라이트_반영일" IS NOT NULL                     THEN '✅ 반영 완료'
         WHEN "초안상태" = 'rejected'                           THEN '🚫 반려'          -- ★v3
         WHEN "슬롯상태"::text = 'halted'                       THEN '⏸️ 보류'
         WHEN "순위" BETWEEN 1 AND 3                            THEN '🔒 잠금(1~3위)'
         WHEN "초안_id" IS NULL                                 THEN '🟠 초안 없음'
         WHEN "리라이트_착수일" IS NOT NULL
              AND ((now() AT TIME ZONE 'Asia/Seoul')::date - "리라이트_착수일") > 3 THEN '🔴 지연'
         WHEN "초안상태" = 'draft'                              THEN '🟡 초안 작성중'
         WHEN "초안상태" = 'approved' AND "보완_대기" > 0        THEN '🔵 반영 대기'
         WHEN "초안상태" = 'approved'                           THEN '🟢 검수 완료·반영 대기'
         ELSE '🟡 진행중'
       END AS "배지",
       CASE
         WHEN "리라이트_반영일" IS NOT NULL
              THEN 'D+7 결과 대기 (' || to_char(("리라이트_반영일" + 7)::timestamptz,'MM/DD') || ')'
         WHEN "초안상태" = 'rejected'
              THEN '반려 사유 확인 → 재작성 또는 슬롯 폐기'                              -- ★v3
         WHEN "슬롯상태"::text = 'halted'  THEN '보류 사유 확인'
         WHEN "순위" BETWEEN 1 AND 3       THEN '★대상 아님 — 편성 취소하고 교체'
         WHEN "초안_id" IS NULL            THEN '클로드에게 「' || "채널"::text || ' 리라이트 진행」'
         WHEN "초안상태" = 'draft'         THEN '초안 읽고 승인'
         WHEN "지면" = '네이버'
              THEN '대표님이 네이버에 반영' || CASE WHEN "보완_대기" > 0 THEN ' (보완 ' || "보완_대기" || '건)' ELSE '' END
         ELSE '클로드가 티스토리 반영' || CASE WHEN "보완_대기" > 0 THEN ' (보완 ' || "보완_대기" || '건)' ELSE '' END
       END AS "할일",
       CASE WHEN "지면" = '네이버' THEN '대표(네이버)' ELSE '클로드(티스토리)' END AS "담당"
FROM j;
