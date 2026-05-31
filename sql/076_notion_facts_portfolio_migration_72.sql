-- 076 노션→Supabase 이관 (72차 / 2026-05-31)
-- 사실정보DB·포트폴리오DB 데이터 이관 + GRANT + 신선도 룰
-- 블로그 자동화 SSoT = Supabase 단일화 (블로그 초안 본문만 노션 잔존, 53차 원칙)
-- 데이터 이관 실행체: edge_functions/notion-facts-migrator (일회성, 노션 databases/query 2022-06-28)
-- 결과: mk_blog_facts 349건 / mk_portfolio 71건(신규 8 포함)

-- ① 신규 테이블 권한 (교훈: 신규 테이블 service_role GRANT 필수)
GRANT ALL    ON TABLE mk_blog_facts TO service_role;
GRANT ALL    ON TABLE mk_blog_facts TO authenticated;
GRANT SELECT ON TABLE mk_blog_facts TO anon;

-- ② 사실DB 신선도 감사 룰 (만료/확인필요 항목 경보)
INSERT INTO hr_audit_rule (룰_코드, 감사축, 룰_이름, 설명, 점검_방법, 임계치, 심각도, 활성)
VALUES ('G_FACT_STALE','G_블로그헌법','사실DB 만료 항목 존재',
 'mk_blog_facts 활성행 중 점검상태=❌만료 또는 만료예정일 경과 시 경고(블로그 본문 인용 사실 신선도)',
 'SELECT count(*) FROM mk_blog_facts WHERE 활성=true AND (점검상태=''❌만료'' OR (만료예정일 IS NOT NULL AND 만료예정일<now()))',
 '{"max":0}'::jsonb,'P3',true)
ON CONFLICT (룰_코드) DO UPDATE SET 설명=EXCLUDED.설명, 점검_방법=EXCLUDED.점검_방법, 활성=true;

-- ③ PostgREST 스키마 캐시 갱신
NOTIFY pgrst, 'reload schema';
