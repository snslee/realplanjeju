-- 118_v_rewrite_board_v4_rank_source.sql
-- 2026-08-21 대표 지시 「반려건 니 눈으로 확인해서 제안하라」 → 확인 중 순위 오염 발견
--
-- 무엇이 틀려 있었나
--   뷰가 순위를 mk_blog_publish_log 에서 **URL 기준**으로만 가져왔다.
--   publish_log 는 URL 당 1행이고 그 행의 핵심키워드가 슬롯 키워드와 다를 수 있다.
--   실측: 「중학교수학여행」 슬롯(블A네이버)에 같은 URL 의 「가을 수학여행」 순위 999 가
--         붙어, 네이버 SERP 3위인 글이 편성판에 「미진입」으로 떠 있었다.
--         반대로 「팀빌딩 프로그램」은 화면 11위 / SERP 999 / 일반 2위로 세 값이 전부 달랐고,
--         대표 육안 실측은 36위였다(2026-08-21 · naver_manual 로 기록).
--
-- v4 설계 — 없는 진실을 만들지 않는다
--   순위 = COALESCE(대표 육안 실측, 키워드 SERP 실측, URL 실측, 반영전 박제, 슬롯 기재)
--   · 대표 육안(naver_manual)이 최상위 정본이다.
--   · 그다음이 키워드+채널로 붙인 SERP 실측 — URL 기준보다 판정 의도에 맞다.
--   · 대표 실측이 없고 기계 소스끼리 구간(1~3 잠금 / 4~30 대상 / 31~ 대상밖)이 갈리면
--     기계값으로 판정하지 않고 배지를 「순위 확인 필요」로 세운다.
--     어느 엔진이 맞는지는 코드가 정할 수 없다 — 대표께 검색 한 번을 청하는 편이 옳다.
--
-- 신설 컬럼(맨 뒤 — CREATE OR REPLACE 는 중간 삽입 불가)
--   실측_대표 · 실측_serp · 실측_일반 · 실측일 · 순위_출처 · 순위_불일치
-- 신설 배지  대상밖(31위~) · 순위 확인 필요
--   ★ 대상 범위 4~30위는 mk_blog_skill_rules id=47 (v10.8 · 2026-08-04 대표 승인) 정본.
--     구판 뷰에는 31위 이상을 걸러 내는 분기가 아예 없었다.
--
-- 검증(v3 → v4 전수 대조): 67행 유지 · 바뀐 행 20 · 확인 필요 4건

CREATE OR REPLACE VIEW public.v_rewrite_board AS
WITH s AS (
  SELECT sl.id AS "슬롯_id", sl."발행일", sl."채널", sl."핵심키워드", sl."상태" AS "슬롯상태",
         CASE WHEN sl."채널"::text LIKE '%네이버%' THEN '네이버' ELSE '티스토리' END AS "지면",
         LEFT(sl."채널"::text, 2) AS "채널군",
         NULLIF((regexp_match(COALESCE(sl."콘텐츠방향",''), '착수일 실측 ([0-9]+)위'))[1], '')::integer AS "슬롯_순위",
         sl."리라이트_원본url" AS "슬롯_컬럼url",
         (regexp_match(COALESCE(sl."콘텐츠방향",''), '원본 (https?://[^\s]+)'))[1] AS "슬롯_원본url"
  FROM mk_blog_slots sl WHERE sl."슬롯유형"::text = '리라이트'
), d AS (
  SELECT DISTINCT ON (x."슬롯_id") x."슬롯_id", x.id AS "초안_id", x."상태" AS "초안상태", x."제목",
         x."리라이트_원본url", x."발행_url", x."반영전_순위", x."리라이트_착수일",
         x."리라이트_반영일", x."리라이트_회차", x."자가검증_점수", x."자가검증_결과"
  FROM mk_blog_drafts x
  WHERE x."슬롯유형" = '리라이트' AND x."슬롯_id" IS NOT NULL
  ORDER BY x."슬롯_id", (COALESCE(x."상태",'') = 'rejected') ASC, x."수정일" DESC
), fx AS (
  SELECT d."슬롯_id", count(*) AS "보완_전체",
         count(*) FILTER (WHERE (e.value ->> '상태') <> '완료') AS "보완_대기"
  FROM d CROSS JOIN LATERAL jsonb_array_elements(COALESCE(d."자가검증_결과" -> '라이브보완','[]'::jsonb)) e(value)
  GROUP BY d."슬롯_id"
), q AS (
  SELECT fn_normalize_blog_url(p."외부_url") AS nurl, max(p."현재순위"::integer) AS "현재순위"
  FROM mk_blog_publish_log p WHERE p."현재순위" IS NOT NULL
  GROUP BY fn_normalize_blog_url(p."외부_url")
), rk AS (
  SELECT DISTINCT ON (k, ch, eng) k, ch, eng, "순위" AS r, "측정_일자" AS dt
  FROM (SELECT replace("키워드",' ','') AS k, "채널" AS ch, "검색_엔진" AS eng, "순위", "측정_일자"
          FROM mk_rank_tracker WHERE "측정_신뢰" = true AND "순위" IS NOT NULL) t
  ORDER BY k, ch, eng, "측정_일자" DESC
), rkp AS (
  SELECT k, ch,
         max(r) FILTER (WHERE eng = 'naver_manual') AS "실측_대표",
         max(r) FILTER (WHERE eng = 'naver_serp')   AS "실측_serp",
         max(r) FILTER (WHERE eng = 'naver')        AS "실측_일반",
         max(dt) AS "실측일"
  FROM rk GROUP BY k, ch
), j AS (
  SELECT s."슬롯_id", s."발행일", s."채널", s."핵심키워드", s."슬롯상태", s."지면", s."채널군",
         d."초안_id", d."초안상태", d."제목", d."발행_url", d."반영전_순위",
         d."리라이트_착수일", d."리라이트_반영일", d."리라이트_회차", d."자가검증_점수",
         COALESCE(fx."보완_전체",0::bigint) AS "보완_전체",
         COALESCE(fx."보완_대기",0::bigint) AS "보완_대기",
         COALESCE(d."리라이트_원본url", s."슬롯_컬럼url", s."슬롯_원본url") AS "원본_url",
         rkp."실측_대표", rkp."실측_serp", rkp."실측_일반", rkp."실측일", q."현재순위" AS "실측_url",
         COALESCE(rkp."실측_대표", rkp."실측_serp", q."현재순위", d."반영전_순위", s."슬롯_순위") AS "순위",
         CASE WHEN rkp."실측_대표" IS NOT NULL THEN '대표 실측'
              WHEN rkp."실측_serp" IS NOT NULL THEN '키워드 실측(SERP)'
              WHEN q."현재순위" IS NOT NULL     THEN 'URL 실측'
              WHEN d."반영전_순위" IS NOT NULL  THEN '반영전 박제'
              WHEN s."슬롯_순위" IS NOT NULL    THEN '슬롯 기재'
              ELSE NULL END AS "순위_출처",
         (rkp."실측_대표" IS NULL AND
          (SELECT count(DISTINCT CASE WHEN v<=3 THEN 1 WHEN v<=30 THEN 2 ELSE 3 END)
             FROM (VALUES (rkp."실측_serp"),(rkp."실측_일반"),(q."현재순위")) z(v)
            WHERE v IS NOT NULL) > 1) AS "순위_확인필요"
  FROM s
  LEFT JOIN d   ON d."슬롯_id" = s."슬롯_id"
  LEFT JOIN fx  ON fx."슬롯_id" = s."슬롯_id"
  LEFT JOIN q   ON q.nurl = fn_normalize_blog_url(COALESCE(d."리라이트_원본url", s."슬롯_컬럼url", s."슬롯_원본url"))
  LEFT JOIN rkp ON rkp.k = replace(s."핵심키워드"::text,' ','') AND rkp.ch = s."채널"::text
)
SELECT "발행일",
       to_char("발행일"::timestamptz,'MM/DD') || '(' ||
       CASE EXTRACT(dow FROM "발행일")::integer
         WHEN 0 THEN '일' WHEN 1 THEN '월' WHEN 2 THEN '화' WHEN 3 THEN '수'
         WHEN 4 THEN '목' WHEN 5 THEN '금' ELSE '토' END || ')' AS "요일",
       "지면","채널군","채널","핵심키워드",
       CASE WHEN "슬롯상태"::text='halted' THEN '—'
            ELSE "채널군" || '-' || row_number() OVER (PARTITION BY "발행일","지면","채널군",("슬롯상태"::text='halted') ORDER BY "슬롯_id") END AS "순번",
       CASE WHEN "슬롯상태"::text='halted' THEN '보류'
            WHEN EXTRACT(dow FROM "발행일")::integer=5 AND "지면"='네이버'   THEN '정상'
            WHEN EXTRACT(dow FROM "발행일")::integer=6 AND "지면"='티스토리' THEN '정상'
            ELSE '⚠️요일오배정' END AS "요일정합",
       "순위","반영전_순위","리라이트_회차" AS "회차",
       "슬롯_id","초안_id","초안상태","제목","자가검증_점수" AS "게이트점수",
       "원본_url","발행_url","보완_전체","보완_대기",
       "리라이트_착수일" AS "착수일",
       CASE WHEN "리라이트_착수일" IS NULL THEN NULL::integer
            ELSE (now() AT TIME ZONE 'Asia/Seoul')::date - "리라이트_착수일" END AS "경과일",
       "리라이트_반영일" AS "반영일","슬롯상태",
       CASE
         WHEN "리라이트_반영일" IS NOT NULL              THEN '✅ 반영 완료'
         WHEN "초안상태" = 'rejected'                    THEN '🚫 반려'
         WHEN "슬롯상태"::text = 'halted'                THEN '⏸️ 보류'
         WHEN "순위_확인필요"                            THEN '⚠️ 순위 확인 필요'
         WHEN "순위" BETWEEN 1 AND 3                     THEN '🔒 잠금(1~3위)'
         WHEN "순위" > 30                                THEN '🟣 대상밖(31위~)'
         WHEN "초안_id" IS NULL                          THEN '🟠 초안 없음'
         WHEN "리라이트_착수일" IS NOT NULL
              AND ((now() AT TIME ZONE 'Asia/Seoul')::date - "리라이트_착수일") > 3 THEN '🔴 지연'
         WHEN "초안상태" = 'draft'                       THEN '🟡 초안 작성중'
         WHEN "초안상태" = 'approved' AND "보완_대기" > 0 THEN '🔵 반영 대기'
         WHEN "초안상태" = 'approved'                    THEN '🟢 검수 완료·반영 대기'
         ELSE '🟡 진행중' END AS "배지",
       CASE
         WHEN "리라이트_반영일" IS NOT NULL
              THEN 'D+7 결과 대기 (' || to_char(("리라이트_반영일"+7)::timestamptz,'MM/DD') || ')'
         WHEN "초안상태" = 'rejected'      THEN '반려 사유 확인 → 재작성 또는 슬롯 폐기'
         WHEN "슬롯상태"::text = 'halted'  THEN '보류 사유 확인'
         WHEN "순위_확인필요"
              THEN '네이버에서 「' || "핵심키워드"::text || '」 검색해 우리 글 순위 확인 (측정값이 갈립니다)'
         WHEN "순위" BETWEEN 1 AND 3       THEN '★대상 아님(1~3위 잠금) — 편성 취소하고 교체'
         WHEN "순위" > 30                  THEN '★대상 아님(4~30위 밖) — 편성 취소하고 교체'
         WHEN "초안_id" IS NULL            THEN '클로드에게 「' || "채널"::text || ' 리라이트 진행」'
         WHEN "초안상태" = 'draft'         THEN '초안 읽고 승인'
         WHEN "지면" = '네이버'
              THEN '대표님이 네이버에 반영' || CASE WHEN "보완_대기">0 THEN ' (보완 '||"보완_대기"||'건)' ELSE '' END
         ELSE '클로드가 티스토리 반영' || CASE WHEN "보완_대기">0 THEN ' (보완 '||"보완_대기"||'건)' ELSE '' END
       END AS "할일",
       CASE WHEN "지면"='네이버' THEN '대표(네이버)' ELSE '클로드(티스토리)' END AS "담당",
       "실측_대표","실측_serp","실측_일반","실측일","순위_출처","순위_확인필요" AS "순위_불일치"
FROM j;

-- 대표 육안 실측 기록 방법 (2026-08-21 · 팀빌딩 프로그램 36위 사례)
-- insert into mk_rank_tracker("키워드","채널","측정_일자","자체_url","순위","검색_엔진","측정_신뢰")
-- values ('팀빌딩 프로그램','블A네이버', current_date, '<원본url>', 36, 'naver_manual', true);
-- ★ naver_manual 은 절대 삭제 금지 대상(수동 실측 정본).
