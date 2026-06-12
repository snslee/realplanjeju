-- ===== migration 20260612023719 (105a_acc_tables) =====
-- sql/105a 회계 모듈 테이블 7종 (회계 통합설계서 v1.0 §2)
create table if not exists acc_카테고리 (
  id uuid primary key default gen_random_uuid(),
  카테고리명 text unique not null,
  유형 text not null check (유형 in ('수입','고정비','변동지출')),
  정렬 int default 0,
  활성 boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists acc_계좌 (
  id uuid primary key default gen_random_uuid(),
  은행 text not null,
  계좌번호 text unique not null,
  별칭 text,
  용도 text,
  사업부 text check (사업부 in ('국내여행','행사이벤트','온라인마케팅','마케팅교육','본사공통')),
  활성 boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists acc_거래내역 (
  id uuid primary key default gen_random_uuid(),
  거래일 date not null,
  구분 text not null check (구분 in ('수입','지출')),
  카테고리_id uuid references acc_카테고리(id),
  사업부 text check (사업부 in ('국내여행','행사이벤트','온라인마케팅','마케팅교육','본사공통')),
  금액 numeric not null check (금액 >= 0),
  공급가액 numeric,
  부가세 numeric,
  거래처_유형 text check (거래처_유형 in ('고객','매입처','직원','기타')),
  거래처_id uuid,
  거래처명 text,
  결제수단 text check (결제수단 in ('계좌이체','카드','현금','기타')),
  계좌_id uuid references acc_계좌(id),
  출처 text not null default '수동' check (출처 in ('수동','계약결제','계약입금','고정비','통장','카드','세금계산서','결재','급여','과거이관')),
  출처_id uuid,
  상태 text not null default '확정' check (상태 in ('예정','확정','취소')),
  신뢰등급 text not null default '확정' check (신뢰등급 in ('확정','관리용')),
  적요 text,
  비고 text,
  증빙_파일_id uuid references file_attachments(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_acc_tx_거래일 on acc_거래내역(거래일);
create index if not exists idx_acc_tx_출처 on acc_거래내역(출처, 출처_id);
create index if not exists idx_acc_tx_거래처 on acc_거래내역(거래처_id);
create index if not exists idx_acc_tx_사업부 on acc_거래내역(사업부, 거래일);

create table if not exists acc_고정비 (
  id uuid primary key default gen_random_uuid(),
  항목명 text not null,
  카테고리_id uuid references acc_카테고리(id),
  결제일 int check (결제일 between 1 and 31),
  출금계좌_id uuid references acc_계좌(id),
  상대계좌 text,
  월금액 numeric not null,
  변동여부 boolean not null default false,
  시작월 date not null default '2026-01-01',
  종료월 date,
  활성 boolean not null default true,
  비고 text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists acc_미수금 (
  id uuid primary key default gen_random_uuid(),
  contract_id uuid references contracts(id),
  거래처_유형 text check (거래처_유형 in ('고객','매입처','직원','기타')),
  거래처_id uuid,
  거래처명 text,
  사업부 text check (사업부 in ('국내여행','행사이벤트','온라인마케팅','마케팅교육','본사공통')),
  계약금액 numeric,
  단계 int not null check (단계 in (1,2)),
  단계금액 numeric not null,
  예정일 date,
  입금일 date,
  입금_거래_id uuid references acc_거래내역(id),
  상태 text not null default '미수' check (상태 in ('미수','완납','취소')),
  비고 text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (contract_id, 단계)
);

create table if not exists acc_원천거래 (
  id uuid primary key default gen_random_uuid(),
  원천 text not null check (원천 in ('농협통장','농협카드','BC카드','세금계산서매출','세금계산서매입')),
  중복키 text unique not null,
  원본 jsonb not null,
  거래일 date,
  금액 numeric,
  상대명 text,
  상대사업자번호 text,
  계좌_id uuid references acc_계좌(id),
  매칭_거래_id uuid references acc_거래내역(id),
  매칭상태 text not null default '미매칭' check (매칭상태 in ('미매칭','자동','수동','제외')),
  업로드채널 text not null default 'admin' check (업로드채널 in ('admin','텔레그램','팝빌')),
  created_at timestamptz not null default now()
);
create index if not exists idx_acc_stage_매칭 on acc_원천거래(매칭상태, 거래일);

create table if not exists acc_연도확정 (
  id uuid primary key default gen_random_uuid(),
  연도 int unique not null,
  기수 int,
  매출액 numeric,
  영업손익 numeric,
  당기순손익 numeric,
  출처문서_파일_id uuid references file_attachments(id),
  비고 text,
  created_at timestamptz not null default now()
);

-- ===== migration 20260612023742 (105b_acc_rls_grant_views) =====
-- sql/105b RLS(owner 단독) + GRANT + 뷰 4종
do $$
declare t text;
begin
  foreach t in array array['acc_카테고리','acc_계좌','acc_거래내역','acc_고정비','acc_미수금','acc_원천거래','acc_연도확정'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists acc_owner_all on %I', t);
    execute format($p$create policy acc_owner_all on %I for all to authenticated
      using (fn_is_role(array['owner'])) with check (fn_is_role(array['owner']))$p$, t);
    execute format('grant all on %I to service_role', t);
    execute format('grant select, insert, update, delete on %I to authenticated', t);
  end loop;
end $$;

create or replace view v_acc_월별손익 as
select date_trunc('month', t.거래일)::date as 월,
  sum(t.금액) filter (where t.구분='수입') as 수입합계,
  sum(t.금액) filter (where t.구분='지출' and c.유형='고정비') as 고정비합계,
  sum(t.금액) filter (where t.구분='지출' and coalesce(c.유형,'변동지출')='변동지출') as 변동지출합계,
  coalesce(sum(t.금액) filter (where t.구분='수입'),0) - coalesce(sum(t.금액) filter (where t.구분='지출'),0) as 순이익,
  count(*) as 건수
from acc_거래내역 t left join acc_카테고리 c on c.id = t.카테고리_id
where t.상태 <> '취소'
group by 1;

create or replace view v_acc_부가세 as
select date_trunc('month', 거래일)::date as 월,
  coalesce(sum(부가세) filter (where 구분='수입'),0) as 매출_vat,
  coalesce(sum(부가세) filter (where 구분='지출'),0) as 매입_vat,
  coalesce(sum(부가세) filter (where 구분='수입'),0) - coalesce(sum(부가세) filter (where 구분='지출'),0) as 납부예정_vat
from acc_거래내역 where 상태 <> '취소'
group by 1;

create or replace view v_acc_미수금잔액 as
select r.contract_id, max(r.거래처명) as 거래처명, max(r.사업부) as 사업부, max(r.계약금액) as 계약금액,
  sum(r.단계금액) filter (where r.상태='완납') as 입금합계,
  sum(r.단계금액) filter (where r.상태='미수') as 미수잔액,
  count(*) filter (where r.상태='미수') as 미수단계수
from acc_미수금 r where r.상태 <> '취소'
group by r.contract_id;

create or replace view v_acc_연도대사 as
select coalesce(l1.연도, l2.연도) as 연도,
  l1.매출액 as 공식_매출액, l1.당기순손익 as 공식_당기손익,
  l2.매출 as 관리_매출, l2.지출 as 관리_지출, l2.순이익 as 관리_순이익,
  l1.매출액 - l2.매출 as 매출_대사차이
from acc_연도확정 l1
full outer join (
  select extract(year from 거래일)::int as 연도,
    sum(금액) filter (where 구분='수입') as 매출,
    sum(금액) filter (where 구분='지출') as 지출,
    coalesce(sum(금액) filter (where 구분='수입'),0) - coalesce(sum(금액) filter (where 구분='지출'),0) as 순이익
  from acc_거래내역 where 상태 <> '취소' group by 1
) l2 on l2.연도 = l1.연도;

grant select on v_acc_월별손익, v_acc_부가세, v_acc_미수금잔액, v_acc_연도대사 to authenticated, service_role;

-- ===== migration 20260612023826 (105c_acc_rpc_6) =====
-- sql/105c RPC 6종 (SECURITY DEFINER)
create or replace function rpc_acc_insert_tx(p jsonb) returns uuid
language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if (p->>'거래일') is null or (p->>'구분') is null or (p->>'금액') is null then
    raise exception '필수값 누락: 거래일·구분·금액';
  end if;
  insert into acc_거래내역 (거래일, 구분, 카테고리_id, 사업부, 금액, 공급가액, 부가세,
    거래처_유형, 거래처_id, 거래처명, 결제수단, 계좌_id, 출처, 출처_id, 상태, 신뢰등급, 적요, 비고)
  values ((p->>'거래일')::date, p->>'구분', nullif(p->>'카테고리_id','')::uuid, p->>'사업부',
    (p->>'금액')::numeric, nullif(p->>'공급가액','')::numeric, nullif(p->>'부가세','')::numeric,
    p->>'거래처_유형', nullif(p->>'거래처_id','')::uuid, p->>'거래처명', p->>'결제수단',
    nullif(p->>'계좌_id','')::uuid, coalesce(p->>'출처','수동'), nullif(p->>'출처_id','')::uuid,
    coalesce(p->>'상태','확정'), coalesce(p->>'신뢰등급','확정'), p->>'적요', p->>'비고')
  returning id into v_id;
  return v_id;
end $$;

create or replace function rpc_acc_bulk_stage(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare r jsonb; v_ins int := 0; v_dup int := 0;
begin
  for r in select * from jsonb_array_elements(p_rows) loop
    begin
      insert into acc_원천거래 (원천, 중복키, 원본, 거래일, 금액, 상대명, 상대사업자번호, 계좌_id, 업로드채널)
      values (r->>'원천', r->>'중복키', coalesce(r->'원본', r), nullif(r->>'거래일','')::date,
        nullif(r->>'금액','')::numeric, r->>'상대명', r->>'상대사업자번호',
        nullif(r->>'계좌_id','')::uuid, coalesce(r->>'업로드채널','admin'));
      v_ins := v_ins + 1;
    exception when unique_violation then
      v_dup := v_dup + 1;
    end;
  end loop;
  return jsonb_build_object('적재', v_ins, '중복제외', v_dup);
end $$;

create or replace function rpc_acc_match(p_mode text default 'auto', p_stage_id uuid default null, p_tx_id uuid default null) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_cnt int := 0; s record;
begin
  if p_mode = 'confirm' then
    update acc_원천거래 set 매칭_거래_id = p_tx_id, 매칭상태 = case when p_tx_id is null then '제외' else '수동' end
    where id = p_stage_id;
    if p_tx_id is not null then
      update acc_거래내역 set 상태='확정', updated_at=now() where id = p_tx_id and 상태='예정';
    end if;
    return jsonb_build_object('수동확정', 1);
  end if;
  for s in select * from acc_원천거래 where 매칭상태='미매칭' and 거래일 is not null and 금액 is not null loop
    update acc_원천거래 st set 매칭_거래_id = t.id, 매칭상태 = '자동'
    from (
      select id from acc_거래내역 t
      where t.상태='예정' and abs(t.금액) = abs(s.금액)
        and t.거래일 between s.거래일 - 3 and s.거래일 + 3
        and not exists (select 1 from acc_원천거래 x where x.매칭_거래_id = t.id)
      order by abs(t.거래일 - s.거래일) limit 1
    ) t
    where st.id = s.id;
    if found then
      update acc_거래내역 set 상태='확정', updated_at=now()
      where id = (select 매칭_거래_id from acc_원천거래 where id = s.id);
      v_cnt := v_cnt + 1;
    end if;
  end loop;
  return jsonb_build_object('자동매칭', v_cnt);
end $$;

create or replace function rpc_acc_receivable_sync(p_contract_id uuid) returns jsonb
language plpgsql security definer set search_path=public as $$
declare c record; v_1 numeric; v_2 numeric;
begin
  select id, customer_id, 계약명, 계약금액, coalesce(계약금비율,50) as 계약금비율, coalesce(잔금비율,50) as 잔금비율, 체결일,
    의뢰인_회사명 into c
  from contracts where id = p_contract_id;
  if c.id is null then raise exception '계약 없음: %', p_contract_id; end if;
  if c.계약금액 is null or c.계약금액 = 0 then return jsonb_build_object('skip','계약금액 0'); end if;
  v_1 := round(c.계약금액 * c.계약금비율 / 100.0);
  v_2 := c.계약금액 - v_1;
  insert into acc_미수금 (contract_id, 거래처_유형, 거래처_id, 거래처명, 계약금액, 단계, 단계금액, 예정일)
  values
    (c.id, '고객', c.customer_id, c.의뢰인_회사명, c.계약금액, 1, v_1, c.체결일),
    (c.id, '고객', c.customer_id, c.의뢰인_회사명, c.계약금액, 2, v_2, null)
  on conflict (contract_id, 단계) do update
    set 계약금액 = excluded.계약금액, 단계금액 = excluded.단계금액, updated_at = now()
    where acc_미수금.상태 = '미수';
  return jsonb_build_object('계약', c.id, '1단계', v_1, '2단계', v_2);
end $$;

create or replace function rpc_acc_fixed_monthly(p_월 date default date_trunc('month', now())::date) returns jsonb
language plpgsql security definer set search_path=public as $$
declare f record; v_cnt int := 0; v_date date;
begin
  for f in select * from acc_고정비 where 활성
    and 시작월 <= p_월 and (종료월 is null or 종료월 >= p_월) loop
    v_date := p_월 + (least(f.결제일, extract(day from (p_월 + interval '1 month - 1 day'))::int) - 1);
    if not exists (select 1 from acc_거래내역 where 출처='고정비' and 출처_id=f.id
        and date_trunc('month',거래일)::date = p_월 and 상태 <> '취소') then
      insert into acc_거래내역 (거래일, 구분, 카테고리_id, 사업부, 금액, 결제수단, 계좌_id, 출처, 출처_id, 상태, 적요)
      values (v_date, '지출', f.카테고리_id, '본사공통', f.월금액, '계좌이체', f.출금계좌_id, '고정비', f.id, '예정', f.항목명);
      v_cnt := v_cnt + 1;
    end if;
  end loop;
  return jsonb_build_object('월', p_월, '생성', v_cnt);
end $$;

create or replace function rpc_acc_export_tax(p_시작 date, p_종료 date) returns jsonb
language plpgsql security definer set search_path=public as $$
begin
  return jsonb_build_object(
    '기간', jsonb_build_array(p_시작, p_종료),
    '매출', (select coalesce(jsonb_agg(to_jsonb(t) - 'created_at' - 'updated_at' order by t.거래일),'[]'::jsonb)
      from acc_거래내역 t where t.구분='수입' and t.상태='확정' and t.거래일 between p_시작 and p_종료),
    '매입경비', (select coalesce(jsonb_agg(to_jsonb(t) - 'created_at' - 'updated_at' order by t.거래일),'[]'::jsonb)
      from acc_거래내역 t where t.구분='지출' and t.상태='확정' and t.거래일 between p_시작 and p_종료),
    '세금계산서', (select coalesce(jsonb_agg(to_jsonb(s) order by s.거래일),'[]'::jsonb)
      from acc_원천거래 s where s.원천 in ('세금계산서매출','세금계산서매입') and s.거래일 between p_시작 and p_종료),
    '카드', (select coalesce(jsonb_agg(to_jsonb(s) order by s.거래일),'[]'::jsonb)
      from acc_원천거래 s where s.원천 in ('농협카드','BC카드') and s.거래일 between p_시작 and p_종료),
    '계좌', (select coalesce(jsonb_agg(to_jsonb(s) order by s.거래일),'[]'::jsonb)
      from acc_원천거래 s where s.원천='농협통장' and s.거래일 between p_시작 and p_종료),
    '급여4대보험', (select coalesce(jsonb_agg(to_jsonb(t) - 'created_at' - 'updated_at' order by t.거래일),'[]'::jsonb)
      from acc_거래내역 t join acc_카테고리 c on c.id=t.카테고리_id
      where c.카테고리명 in ('인건비','4대보험') and t.상태='확정' and t.거래일 between p_시작 and p_종료)
  );
end $$;

grant execute on function rpc_acc_insert_tx(jsonb), rpc_acc_bulk_stage(jsonb),
  rpc_acc_match(text, uuid, uuid), rpc_acc_receivable_sync(uuid),
  rpc_acc_fixed_monthly(date), rpc_acc_export_tax(date, date) to authenticated, service_role;

-- ===== migration 20260612023857 (105d_acc_initial_data) =====
-- sql/105d 초기값: 카테고리 21·계좌 3·고정비 17(로컬 회계관리 2026.xlsx 고정비관리 시트 실측)·연도확정 4(재무제표 실측)
insert into acc_카테고리 (카테고리명, 유형, 정렬) values
 ('매출','수입',1),('계약입금','수입',2),('기타수입','수입',3),
 ('인건비','고정비',10),('임대료','고정비',11),('용역비','고정비',12),('4대보험','고정비',13),
 ('세금','고정비',14),('통신비','고정비',15),('기부금','고정비',16),('대출상환','고정비',17),
 ('수수료','고정비',18),('법인카드대금','고정비',19),
 ('숙박','변동지출',30),('교통버스','변동지출',31),('항공','변동지출',32),('인력비','변동지출',33),
 ('식대','변동지출',34),('촬영외주','변동지출',35),('광고선전','변동지출',36),('기타지출','변동지출',37)
on conflict (카테고리명) do nothing;

insert into acc_계좌 (은행, 계좌번호, 별칭, 용도) values
 ('농협','301-0312-7698-71','농협(대출이자)','확인대기'),
 ('농협','301-0345-1194-81','농협(주거래)','확인대기'),
 ('IBK기업','315-083782-04','기업(법인카드 결제)','법인카드 결제')
on conflict (계좌번호) do nothing;

with c as (select id, 카테고리명 from acc_카테고리)
insert into acc_고정비 (항목명, 카테고리_id, 결제일, 상대계좌, 월금액, 변동여부, 비고)
select v.항목명, c.id, v.결제일, v.상대계좌, v.월금액, v.변동여부, v.비고
from (values
 ('김현숙 급여','인건비',5,'기업은행 01044326805',2897520,false,null),
 ('이동환 급여','인건비',5,'카카오 3333-07-5050463',1777220,false,null),
 ('사무실 임대료','임대료',1,'제주은행 3901051605',440500,false,null),
 ('세무사','용역비',25,'농협 901010-56-096788',165000,false,null),
 ('건강보험료','4대보험',10,null,256080,true,'매월 변동'),
 ('연금보험료','4대보험',10,null,705480,false,null),
 ('산재보험료','4대보험',10,null,23640,false,null),
 ('고용보험료','4대보험',10,null,67310,false,null),
 ('원천세(국세)','세금',10,'기업은행 058-0982-9693-84-1',687720,false,null),
 ('지방소득세','세금',10,'농협 790278-47-798241',68700,false,null),
 ('핸드폰(KT)','통신비',21,null,58480,false,null),
 ('핸드폰(SK)','통신비',21,null,20466,false,null),
 ('인터넷(KT)','통신비',21,null,113520,true,'매월 변동'),
 ('SK브로드밴드','통신비',21,'고객번호: 15772296',55439,false,null),
 ('초록우산','기부금',20,null,50000,false,'기부금'),
 ('농협 대출(이자+원금)','대출상환',16,null,1469573,false,'이자 93,397 + 원금 1,376,176'),
 ('농협 UMS수수료','수수료',10,null,1000,false,null)
) as v(항목명, 카테고리명, 결제일, 상대계좌, 월금액, 변동여부, 비고)
join c on c.카테고리명 = v.카테고리명
where not exists (select 1 from acc_고정비 f where f.항목명 = v.항목명);

insert into acc_연도확정 (연도, 기수, 매출액, 당기순손익, 비고) values
 (2022, 2, 170899020, -7153651, '23년 손익계산서 전기란'),
 (2023, 3, 232491012, -105062074, '23년 손익계산서'),
 (2024, 4, 129271902, 2595462, '24년 손익계산서'),
 (2025, 5, 185800836, -35051038, '손익계산서 전기대비 2026-04-01 발급')
on conflict (연도) do nothing;

-- ===== migration 20260612024417 (105e_acc_views_security_invoker) =====
-- sql/105e 뷰 4종 security_invoker 전환 (RLS 우회 차단 — advisors 시정)
alter view v_acc_월별손익 set (security_invoker = true);
alter view v_acc_부가세 set (security_invoker = true);
alter view v_acc_미수금잔액 set (security_invoker = true);
alter view v_acc_연도대사 set (security_invoker = true);
