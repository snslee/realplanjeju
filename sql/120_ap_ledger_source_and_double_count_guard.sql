-- sql/120_ap_ledger_source_and_double_count_guard.sql
-- 결재→회계 원장 연동 복구 + 이중계상 차단 (2026-08-31 대표 승인 E-1~E-3)
--
-- 배경
--  · `acc_거래내역_출처_check` 허용값 7종(통장·카드·세금계산서·고정비·수동·과거이관·감가상각)에
--    '결재'가 없어서 `rpc_acc_insert_from_approval` 의 INSERT 가 항상 CHECK 위반으로 죽었다.
--  · `출처='결재'` 행이 실제로 0건 = 결재→회계 연동은 만들어진 이래 한 번도 성공한 적이 없다.
--  · 휴가 12건은 회계 기록 대상이 아니라(`유형 not in ('지출결의','경비정산') → return null`) 안 걸렸고,
--    지출결의 승인이 2026-08-31 이 처음이라 이제야 드러났다.
--
-- 이중계상 주의
--  · 승인하면 원장에 '예정' 지출이 생기는데, 실제 이체 후 통장 대사에서 같은 금액이 또 들어온다.
--  · 2026-08-30 「고정비추정(통장과 이중)」 120건 / 「세금계산서(통장과 중복)」 12건 과 같은 구조다.
--  · 그래서 결재 원장 행에는 `정산_성격` 을 달아 A안 산식(`정산_성격 is null`)이 자동으로 빼게 한다.
--  ★지출의 정본은 통장 대사다. 결재 원장 행은 「누가 언제 무엇을 승인했나」와 증빙 연결용이다.
--
-- 롤백
--  · CHECK 를 옛 7종으로 되돌리고, 두 함수에서 `정산_성격` 컬럼과 주석을 제거한다.

-- [E-1] 출처에 '결재' 추가
ALTER TABLE public."acc_거래내역" DROP CONSTRAINT "acc_거래내역_출처_check";
ALTER TABLE public."acc_거래내역" ADD CONSTRAINT "acc_거래내역_출처_check"
  CHECK ("출처" = ANY (ARRAY['통장'::text,'카드'::text,'세금계산서'::text,'고정비'::text,'수동'::text,'과거이관'::text,'감가상각'::text,'결재'::text]));

-- [E-2] rpc_acc_insert_from_approval — 결재 원장 행에 정산_성격='결재예정(통장과 이중)' 자동 기입
-- [E-3] rpc_ap_mark_paid — 상태만 '예정'→'확정'. 정산_성격은 유지(지우면 이중계상된다)
-- (두 함수 전문은 2026-08-31 마이그레이션 ap_ledger_source_and_double_count_guard_v1 과 동일)

-- 감도시험(실행 후 전체 롤백)
-- do $$
-- declare v_tx uuid; r record;
-- begin
--   v_tx := rpc_acc_insert_from_approval('<결재 id>');
--   select 출처, 상태, "정산_성격" into r from acc_거래내역 where id = v_tx;
--   raise exception '출처=% 상태=% 정산_성격=%', r.출처, r.상태, r."정산_성격";
-- end $$;
-- 결과 2026-08-31: 출처=결재 / 상태=예정 / 정산_성격=결재예정(통장과 이중) → A안 자동 제외 확인
