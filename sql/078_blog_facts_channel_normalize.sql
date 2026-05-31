-- 078_blog_facts_channel_normalize.sql
-- 2026-05-31 / 74차 후속 — mk_blog_facts 적용채널 표기 단일화
-- 블A→블로그A, 블B→블로그B, 블C→블로그C (text[] 배열 내 요소 치환)
-- 영향: 6건 (블A 2 + 블B 4). 스킬 채널 필터 누락 방지.
-- NULL 채널 69건 = 카테고리 '경영' 기술정보 → 블로그 채널 불요(정상), 미변경.
-- stale 27건 = 실제 정보 갱신 필요 → 자동 변경 안 함(보고만).

UPDATE mk_blog_facts
SET 적용채널 = array_replace(
                 array_replace(
                   array_replace(적용채널, '블A', '블로그A'),
                 '블B', '블로그B'),
               '블C', '블로그C')
WHERE 적용채널 && ARRAY['블A','블B','블C'];

-- 검증: 0이어야 정상
-- SELECT count(*) FROM mk_blog_facts WHERE 적용채널 && ARRAY['블A','블B','블C'];
