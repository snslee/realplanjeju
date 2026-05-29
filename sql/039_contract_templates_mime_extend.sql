-- sql/039: contract-templates bucket allowed_mime_types 확장 (38차 P2)
-- 작성일: 2026-05-04
-- 사유: overlay 자산 통합 (PDF + JSON 좌표 + TTF 폰트) — EF v4 fetch 정합
-- 영향: 기존 standards/ 4 PDF 무영향 / blanks/·coordinates/·fonts/ 폴더 신규 활성화

UPDATE storage.buckets
SET allowed_mime_types = ARRAY[
  'application/pdf',
  'application/json',
  'font/ttf',
  'font/otf',
  'application/octet-stream'
]
WHERE name = 'contract-templates';

-- 검증:
-- SELECT name, allowed_mime_types FROM storage.buckets WHERE name='contract-templates';
