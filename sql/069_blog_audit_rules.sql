-- sql/069 — 블로그 시스템 감사룰 3종 신설 (62차 / 2026-05-29)
-- 설계: 27_블로그시스템_완성설계도_v1.0 §3.3

INSERT INTO public.hr_audit_rule
  (룰_코드, 감사축, 룰_이름, 설명, 점검_방법, 임계치, 심각도, 활성)
VALUES
  ('G_ALGO_STALE',   'G_블로그헌법', '알고리즘DB 업데이트 지연',  '블로그 알고리즘DB 마지막 업데이트 35일 초과 시 경고', 'manual_check', '{"days":35}'::jsonb,  'P2', true),
  ('G_KEYWORD_STALE','G_블로그헌법', '연관키워드DB 갱신 지연',     'mk_keywords 마지막 INSERT 100일 초과 시 경고',        'sql_count',    '{"days":100}'::jsonb, 'P3', true),
  ('G_DRAFT_PENDING','G_블로그헌법', '초안 미처리 장기 대기',       'mk_blog_drafts draft 상태 7일 초과 건수 경고',        'sql_count',    '{"days":7}'::jsonb,   'P2', true)
ON CONFLICT (룰_코드) DO UPDATE SET
  룰_이름   = EXCLUDED.룰_이름,
  설명      = EXCLUDED.설명,
  심각도    = EXCLUDED.심각도,
  활성      = EXCLUDED.활성,
  updated_at = NOW();
-- 검증: SELECT 룰_코드, 감사축, 심각도 FROM hr_audit_rule WHERE 룰_코드 LIKE 'G_%STALE%' OR 룰_코드='G_DRAFT_PENDING';
