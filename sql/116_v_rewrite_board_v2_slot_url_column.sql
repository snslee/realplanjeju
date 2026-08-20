-- 116_v_rewrite_board_v2_slot_url_column.sql
-- 2026-08-20 대표 승인 · v_rewrite_board v2
--
-- [문제] 구판은 원본 URL을 2단으로만 찾았다:
--          COALESCE(초안.리라이트_원본url, 콘텐츠방향에서 정규식으로 긁은 '원본 https://…')
--        즉 mk_blog_slots.리라이트_원본url 은 화면이 보지 않는 죽은 컬럼이었다.
--        2026-08-20에 그 컬럼만 UPDATE 하고 「교체 완료」로 판정했다가, 편성판이 옛 URL(미진입 글)을
--        그대로 그리는 것을 대표가 먼저 발견했다. 화면을 안 열었으면 못 잡는다.
--
-- [수리] 원본 URL을 3단으로: 초안 → 슬롯 컬럼 → 콘텐츠방향 정규식
--        · s CTE 에 sl."리라이트_원본url" AS "슬롯_컬럼url" 추가
--        · j 의 "원본_url" COALESCE 와 q 조인 키를 동일하게 3단으로
--        순위(q)는 손대지 않는다 — 실측(mk_blog_publish_log) 우선이 맞고
--        슬롯의 리라이트_현재순위는 편성 시점 박제값이라 끌어올리면 판정이 뒤집힌다.
--
-- [검증] 뷰 행수 67 = 리라이트 슬롯 67(누락·중복 0)
--        원본_url 67/67(100%) · 2026-08-21~22 pending 순위 빈칸 0건
--        라이브 편성판 8줄 전부 순위 표시 확인(「-」·「미진입」 0)
--
-- [롤백] 아래 COALESCE 3단에서 s."슬롯_컬럼url" 만 제거하면 구판과 동일하다.

CREATE OR REPLACE VIEW v_rewrite_board AS
 WITH s AS (
         SELECT sl.id AS "슬롯_id", sl."발행일", sl."채널", sl."핵심키워드",
            sl."상태" AS "슬롯상태",
            CASE WHEN sl."채널"::text ~~ '%네이버%'::text THEN '네이버'::text ELSE '티스토리'::text END AS "지면",
            "left"(sl."채널"::text, 2) AS "채널군",
            NULLIF((regexp_match(COALESCE(sl."콘텐츠방향", ''::text), '착수일 실측 ([0-9]+)위'::text))[1], ''::text)::integer AS "슬롯_순위",
            sl."리라이트_원본url" AS "슬롯_컬럼url",              -- ★v2 신설
            (regexp_match(COALESCE(sl."콘텐츠방향", ''::text), '원본 (https?://[^\s]+)'::text))[1] AS "슬롯_원본url"
           FROM mk_blog_slots sl
          WHERE sl."슬롯유형"::text = '리라이트'::text
        ), d AS (
         SELECT DISTINCT ON (x."슬롯_id") x."슬롯_id", x.id AS "초안_id", x."상태" AS "초안상태", x."제목",
            x."리라이트_원본url", x."발행_url", x."반영전_순위", x."리라이트_착수일", x."리라이트_반영일",
            x."리라이트_회차", x."자가검증_점수", x."자가검증_결과"
           FROM mk_blog_drafts x
          WHERE x."슬롯유형" = '리라이트'::text AND COALESCE(x."상태", ''::text) <> 'rejected'::text AND x."슬롯_id" IS NOT NULL
          ORDER BY x."슬롯_id", x."수정일" DESC
        ), fx AS (
         SELECT d."슬롯_id", count(*) AS "보완_전체",
            count(*) FILTER (WHERE (e.value ->> '상태'::text) <> '완료'::text) AS "보완_대기"
           FROM d CROSS JOIN LATERAL jsonb_array_elements(COALESCE(d."자가검증_결과" -> '라이브보완'::text, '[]'::jsonb)) e(value)
          GROUP BY d."슬롯_id"
        ), q AS (
         SELECT fn_normalize_blog_url(p."외부_url") AS nurl, max(p."현재순위"::integer) AS "현재순위"
           FROM mk_blog_publish_log p WHERE p."현재순위" IS NOT NULL GROUP BY (fn_normalize_blog_url(p."외부_url"))
        ), j AS (
         SELECT s."슬롯_id", s."발행일", s."채널", s."핵심키워드", s."슬롯상태", s."지면", s."채널군",
            d."초안_id", d."초안상태", d."제목", d."발행_url", d."반영전_순위", d."리라이트_착수일",
            d."리라이트_반영일", d."리라이트_회차", d."자가검증_점수",
            COALESCE(fx."보완_전체", 0::bigint) AS "보완_전체",
            COALESCE(fx."보완_대기", 0::bigint) AS "보완_대기",
            COALESCE(d."리라이트_원본url", s."슬롯_컬럼url", s."슬롯_원본url") AS "원본_url",   -- ★v2 3단
            COALESCE(q."현재순위", d."반영전_순위", s."슬롯_순위") AS "순위"
           FROM s
             LEFT JOIN d ON d."슬롯_id" = s."슬롯_id"
             LEFT JOIN fx ON fx."슬롯_id" = s."슬롯_id"
             LEFT JOIN q ON q.nurl = fn_normalize_blog_url(COALESCE(d."리라이트_원본url", s."슬롯_컬럼url", s."슬롯_원본url"))
        )
 SELECT "발행일",
    ((to_char("발행일"::timestamp with time zone, 'MM/DD'::text) || '('::text) ||
        CASE EXTRACT(dow FROM "발행일")::integer WHEN 0 THEN '일'::text WHEN 1 THEN '월'::text WHEN 2 THEN '화'::text
            WHEN 3 THEN '수'::text WHEN 4 THEN '목'::text WHEN 5 THEN '금'::text ELSE '토'::text END) || ')'::text AS "요일",
    "지면", "채널군", "채널", "핵심키워드",
        CASE WHEN "슬롯상태"::text = 'halted'::text THEN '—'::text
            ELSE ("채널군" || '-'::text) || row_number() OVER (PARTITION BY "발행일", "지면", "채널군", ("슬롯상태"::text = 'halted'::text) ORDER BY "슬롯_id") END AS "순번",
        CASE WHEN "슬롯상태"::text = 'halted'::text THEN '보류'::text
            WHEN EXTRACT(dow FROM "발행일")::integer = 5 AND "지면" = '네이버'::text THEN '정상'::text
            WHEN EXTRACT(dow FROM "발행일")::integer = 6 AND "지면" = '티스토리'::text THEN '정상'::text
            ELSE '⚠️요일오배정'::text END AS "요일정합",
    "순위", "반영전_순위", "리라이트_회차" AS "회차", "슬롯_id", "초안_id", "초안상태", "제목",
    "자가검증_점수" AS "게이트점수", "원본_url", "발행_url", "보완_전체", "보완_대기",
    "리라이트_착수일" AS "착수일",
        CASE WHEN "리라이트_착수일" IS NULL THEN NULL::integer
            ELSE (now() AT TIME ZONE 'Asia/Seoul'::text)::date - "리라이트_착수일" END AS "경과일",
    "리라이트_반영일" AS "반영일", "슬롯상태",
        CASE WHEN "리라이트_반영일" IS NOT NULL THEN '✅ 반영 완료'::text
            WHEN "슬롯상태"::text = 'halted'::text THEN '⏸️ 보류'::text
            WHEN "순위" >= 1 AND "순위" <= 3 THEN '🔒 잠금(1~3위)'::text
            WHEN "초안_id" IS NULL THEN '🟠 초안 없음'::text
            WHEN "리라이트_착수일" IS NOT NULL AND ((now() AT TIME ZONE 'Asia/Seoul'::text)::date - "리라이트_착수일") > 3 THEN '🔴 지연'::text
            WHEN "초안상태" = 'draft'::text THEN '🟡 초안 작성중'::text
            WHEN "초안상태" = 'approved'::text AND "보완_대기" > 0 THEN '🔵 반영 대기'::text
            WHEN "초안상태" = 'approved'::text THEN '🟢 검수 완료·반영 대기'::text
            ELSE '🟡 진행중'::text END AS "배지",
        CASE WHEN "리라이트_반영일" IS NOT NULL THEN ('D+7 결과 대기 ('::text || to_char(("리라이트_반영일" + 7)::timestamp with time zone, 'MM/DD'::text)) || ')'::text
            WHEN "슬롯상태"::text = 'halted'::text THEN '보류 사유 확인'::text
            WHEN "순위" >= 1 AND "순위" <= 3 THEN '★대상 아님 — 편성 취소하고 교체'::text
            WHEN "초안_id" IS NULL THEN ('클로드에게 「'::text || "채널"::text) || ' 리라이트 진행」'::text
            WHEN "초안상태" = 'draft'::text THEN '초안 읽고 승인'::text
            WHEN "지면" = '네이버'::text THEN '대표님이 네이버에 반영'::text ||
                CASE WHEN "보완_대기" > 0 THEN (' (보완 '::text || "보완_대기") || '건)'::text ELSE ''::text END
            ELSE '클로드가 티스토리 반영'::text ||
                CASE WHEN "보완_대기" > 0 THEN (' (보완 '::text || "보완_대기") || '건)'::text ELSE ''::text END END AS "할일",
        CASE WHEN "지면" = '네이버'::text THEN '대표(네이버)'::text ELSE '클로드(티스토리)'::text END AS "담당"
   FROM j;
