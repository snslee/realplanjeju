-- sql/119_ap_attach_v2_customer_link.sql
-- 결재 첨부 v2 + 고객 연결 정상화 (2026-08-31 대표 승인 17건)
-- 배경: ap_결재 13건 전건 첨부 0건 / docs 버킷 approvals/ 실물 0개 / 지출결의 고객연결 0건
--  B-1 수정 모드에 첨부칸 미노출(admin.html) · B-2 rpc_ap_update 첨부 미처리
--  B-3 승인 후 수정 전면차단 · B-4 docs MIME 화이트리스트가 HWP·HEIC 거부
--  C-1 고객 select 266건 검색 불가 · C-2 자동등록이 동의_개인정보=true 하드코딩
--  C-3 고객 해제 불가(coalesce) · C-4 원장 미동기화 · C-5 고객360 결재 미노출
--  D-1 고객 파일탭 견적서 재사용 불가 · D-2 acc_증빙 이원화
-- 롤백: DROP FUNCTION rpc_ap_attach_add / rpc_ap_attach_remove / rpc_ap_customer_files
--       + _ap_resolve_customer·rpc_ap_update·rpc_ap_form_master 를 이전 정의로 복원
--       + storage.buckets docs.allowed_mime_types 를 8종으로 원복

-- [C-2] 자동 고객등록 폐지 — 지출결의에서 customers 신규 생성 금지
CREATE OR REPLACE FUNCTION public._ap_resolve_customer(p jsonb)
 RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  -- 2026-08-31: 고객DB 오염·개인정보 동의 미취득 방지. 고객은 [고객] 탭에서만 생성한다.
  return nullif(p->>'고객_id','')::uuid;
end $function$;

-- [C-3][C-4] 고객 해제·변경 허용 + 회계 원장 동기화 (본문은 실제 적용본과 동일)
-- (rpc_ap_update 전문은 2026-08-31 마이그레이션 ap_attach_and_customer_link_v1 참조)

-- [B-2][D-2] 첨부 추가 — 전 상태 허용·누적·회계 증빙 동기화·텔레그램 알림
-- [B-7] 첨부 삭제 — owner 전용·사유 필수
-- [D-1] 고객 파일 조회 — file_attachments → 결재 첨부 후보

-- [B-4] docs 버킷 MIME 8종 → 24종 (HWP·HWPX·HEIC·GIF·BMP·TIFF·ZIP·PPT 추가)
UPDATE storage.buckets SET allowed_mime_types = array[
 'application/pdf','application/msword',
 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
 'application/vnd.ms-excel',
 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
 'application/vnd.ms-powerpoint',
 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
 'application/x-hwp','application/haansofthwp','application/vnd.hancom.hwp',
 'application/vnd.hancom.hwpx','application/hwp+zip',
 'application/zip','application/x-zip-compressed',
 'image/png','image/jpeg','image/webp','image/gif','image/bmp','image/tiff','image/heic','image/heif',
 'text/csv','text/plain'
] WHERE id='docs';
