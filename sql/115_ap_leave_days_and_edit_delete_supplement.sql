-- 115: 휴가 결재 보완 (2026-06-18) — 김현숙 휴가 10건 인사 적재 + 지출결의 기준 수정/삭제 보완
-- ① ap_결재.휴가일수 컬럼 ② rpc_ap_submit 휴가일수 ③ rpc_ap_update 휴가/인장 필드+승인휴가 수정허용
-- ④ rpc_ap_delete 휴가·출장 상태무관 삭제 ⑤ admin.html EF admin-hr-leave-patch(휴가일수 입력/표시·삭제버튼·승인휴가수정·인사목록 일수/행클릭)
ALTER TABLE ap_결재 ADD COLUMN IF NOT EXISTS 휴가일수 numeric;
-- rpc_ap_submit/update/delete 전문 = apply_migration ap_leave_days_and_rpc_edit_delete_supplement
-- 김현숙 휴가 10건(유형 휴가/상태 승인/기안자 d73378a1/승인자 e211d8c9): 2023-01-26~31(4)·06-08(1)·11-28(1)·
--  2024-07-29~31+09-03~04(5)·12-20(1)·2025-03-17(1)·04-03반차(0.5)·08-22+25(2)·12-26+29~31(4)·2026-03-11(1) 합계 20.5일
