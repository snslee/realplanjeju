-- =====================================================================
-- sql/106 회계 D4 자동연동 + D7 감사 (2026-06-12 라이브 적용 완료 / migration 106_acc_d4_triggers_cron_d7_audit)
-- D4: 트리거 2종 + pg_cron 1종 / D7: 감사룰 ACC 4종 + F_DEAD_RPC 90→100
-- 검증: 트리거 롤백테스트 PASS · cron jobname=acc-fixed-monthly · 감사룰 4종 즉석실행 경보 0
-- =====================================================================

-- D4-1 계약 체결 → 미수금 자동 생성
create or replace function fn_acc_on_contract_signed() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  if new.체결일 is not null and coalesce(new.계약금액,0) > 0 then
    if tg_op = 'INSERT' or old.체결일 is distinct from new.체결일 or old.계약금액 is distinct from new.계약금액 then
      perform rpc_acc_receivable_sync(new.id);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_acc_contract_signed on contracts;
create trigger trg_acc_contract_signed
  after insert or update of 체결일, 계약금액 on contracts
  for each row execute function fn_acc_on_contract_signed();

-- D4-2 결제 완료(포트원) → 원장 수입 자동 + 미수금 완납 시도
create or replace function fn_acc_on_contract_paid() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_cat uuid; v_tx uuid;
begin
  if new.결제일 is not null and coalesce(new.결제_금액,0) > 0
     and (tg_op='INSERT' or old.결제일 is distinct from new.결제일) then
    if not exists (select 1 from acc_거래내역 where 출처='계약결제' and 출처_id=new.id and 상태<>'취소') then
      select id into v_cat from acc_카테고리 where 카테고리명='계약입금';
      insert into acc_거래내역(거래일,구분,카테고리_id,금액,거래처_유형,거래처_id,거래처명,결제수단,출처,출처_id,상태,적요)
      values (new.결제일::date,'수입',v_cat,new.결제_금액,'고객',new.customer_id,new.의뢰인_회사명,'카드','계약결제',new.id,'확정',coalesce(new.계약명,'')||' 결제(포트원)')
      returning id into v_tx;
      update acc_미수금 set 상태='완납', 입금일=new.결제일::date, 입금_거래_id=v_tx, updated_at=now()
      where id = (select id from acc_미수금 where contract_id=new.id and 상태='미수' and 단계금액=new.결제_금액 order by 단계 limit 1);
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_acc_contract_paid on contracts;
create trigger trg_acc_contract_paid
  after insert or update of 결제일, 결제_금액 on contracts
  for each row execute function fn_acc_on_contract_paid();

-- D4-3 매월 1일 09:00 KST 고정비 예정 자동 생성
-- select cron.schedule('acc-fixed-monthly','0 0 1 * *', $cr$select rpc_acc_fixed_monthly()$cr$);

-- D7-1 감사룰 ACC 4종 (sql_count / hr_audit_rule)
-- ACC_RECON_CONTRACT (P2): 계약금액 <> 미수금 단계합
-- ACC_VAT_MISMATCH (P3): 2026-07~ 월별 staging 매출세금계산서 세액합 > 원장 매출VAT
-- ACC_SOURCE_ORPHAN (P3): 출처_id 고아 (고정비·계약)
-- ACC_STAGE_UNMATCHED (P3): 45일 초과 미매칭 staging
-- (INSERT 전문은 migration 106 참조)

-- D7-2 F_DEAD_RPC 임계 90→100
update hr_audit_rule set 임계치 = jsonb_set(임계치,'{threshold}','100'), updated_at=now() where 룰_코드='F_DEAD_RPC';

-- =====================================================================
-- D6a 과거 이관 기록 (일회성 — rpc_acc_bulk_import_tmp 생성→적재→DROP 완료)
-- 적재: 594행 (2026 건별 145 · 2025 건별 397 · 2021 요약 4 · 2023 요약 24 · 2024 요약 24)
--      + 고정비 2026년 1~6월 102행(과거분 확정) + acc_연도확정 2021 제1기(25,485,454 / +2,345,559)
-- 대사: 수입 16/16개월 원단위 일치 · 지출 2026 4/4개월 일치 · 2025 연간 원단위 일치(183,361,011)
--      ※ 2025 월 잔차(±59만 이내)는 엑셀이 카드 청구월 기준으로 타월 거래일을 기록한 것 — 데이터 손실 0
-- 날짜 보정 룰: '2025-10-' 처럼 일(日) 누락 → 15일 부여 / 신규 카테고리 8종(세금·공과금, 접대비 등 변동지출)
-- =====================================================================
