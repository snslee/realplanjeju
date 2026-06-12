-- sql/110: 결재 첨부 (2026-06-12) — admin v2.30 연동 / 정본=supabase_migrations 110_ap_attachments
-- ap_결재.첨부 jsonb + rpc_ap_submit v3 — 본문은 마이그레이션 110_ap_attachments 참조
-- applied: 20260612062657 110_ap_attachments
-- sql/110: 결재 첨부 (2026-06-12)
alter table ap_결재 add column if not exists "첨부" jsonb not null default '[]'::jsonb;
comment on column ap_결재."첨부" is '[{path,name,size}] — Storage docs 버킷 approvals/ 경로';

create or replace function public.rpc_ap_submit(p jsonb)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_id uuid; v_approver uuid; v_att jsonb;
begin
  if (p->>'유형') is null or (p->>'제목') is null then raise exception '유형·제목 필수'; end if;
  if (p->>'유형') in ('지출결의','경비정산') and coalesce((p->>'금액')::numeric,0) <= 0 then
    raise exception '지출결의·경비정산은 금액 필수';
  end if;
  if (p->>'유형') in ('휴가','출장') and ((p->>'휴가시작일') is null or (p->>'휴가종료일') is null) then
    raise exception '휴가·출장은 기간 필수';
  end if;
  v_att := coalesce(p->'첨부','[]'::jsonb);
  if jsonb_typeof(v_att) <> 'array' then v_att := '[]'::jsonb; end if;
  select id into v_approver from users where 권한='owner' and 활성 limit 1;
  insert into ap_결재 (유형,제목,내용,금액,사업부,카테고리_id,거래처_유형,거래처명,결제수단,출금계좌_id,지급기한,인장종류,휴가시작일,휴가종료일,기안자,승인자,비고,"첨부")
  values (p->>'유형', p->>'제목', p->>'내용', nullif(p->>'금액','')::numeric, nullif(p->>'사업부',''),
    nullif(p->>'카테고리_id','')::uuid, coalesce(nullif(p->>'거래처_유형',''),'기타'), p->>'거래처명',
    nullif(p->>'결제수단',''), nullif(p->>'출금계좌_id','')::uuid, nullif(p->>'지급기한','')::date,
    nullif(p->>'인장종류',''), nullif(p->>'휴가시작일','')::date, nullif(p->>'휴가종료일','')::date,
    auth.uid(), v_approver, p->>'비고', v_att)
  returning id into v_id;
  insert into mk_notification_queue (이벤트_코드, 메시지, 우선순위, 발송_예정시각)
  values ('AP_SUBMIT', '📝 결재 기안: ['||(p->>'유형')||'] '||(p->>'제목')||coalesce(' / '||to_char(nullif(p->>'금액','')::numeric,'FM999,999,999')||'원','')||coalesce(' / '||(p->>'휴가시작일')||'~'||(p->>'휴가종료일'),'')||case when jsonb_array_length(v_att)>0 then ' / 첨부 '||jsonb_array_length(v_att)||'건' else '' end, 'P2', now());
  return v_id;
end $function$;