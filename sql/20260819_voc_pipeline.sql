-- 리얼플랜제주 · 2026-08-19 실행 정본
-- 고객DB → 키워드 발굴 자동화(VOC) + 승격 배관 + 문의 귀속 해석기
-- 대표 승인 후 실행 완료분. 롤백용 백업표: mk_bak_20260819_{banned,service,intent,keywords,slots_wsfix}

-- ===== 1. VOC 원장 DDL =====
create table if not exists public.mk_voc_terms (
  id uuid primary key default gen_random_uuid(), 어휘 text not null, 사업부 text,
  등장횟수 integer not null default 1, 접수번호_목록 text[] not null default '{}',
  최초등장 date, 최근등장 date, 예산대 text, 인원대 text, 리드타임_중앙 integer,
  b2b의도어 text, 풀적재 boolean not null default false, 차단사유 text,
  생성일 timestamptz not null default now(), 수정일 timestamptz not null default now(),
  unique (어휘, 사업부));

-- ===== 2. 함수 정본 =====
CREATE OR REPLACE FUNCTION public.fn_cta_utm_autotag()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
declare
  v_q text; v_new text; v_n int; v_rw boolean; v_base text; v_kw text; v_cur text; v_url text; v_blc boolean;
begin
  if NEW."슬롯_id" is null then return NEW; end if;

  v_rw  := coalesce(NEW."슬롯유형",'') = '리라이트';
  v_blc := coalesce(NEW."채널",'') like '블C%';
  v_q   := '?utm_source=blog&utm_medium=' || NEW."채널" || '&utm_content=';

  -- ★2026-08-19 신설 — 블C 는 CTA 착지를 홈B(marketing) 로 강제한다.
  --   [사고] 블C 초안 147건 중 86건의 CTA 가 홈A(realplanjeju.com) 로 가고 있었다.
  --          마케팅 대행·교육 글을 읽고 눌렀는데 여행사 첫화면이 뜨니 전환이 될 리 없다.
  --          실제로 온라인마케팅 사업부 폼 문의는 3개월간 0건이었고,
  --          홈A 폼에는 「온라인마케팅」 선택지 자체가 없다(홈B 에만 있다).
  --   ★치환은 URL 이라 복합어 파손 위험이 없다 — 'https://realplanjeju.com/' 는
  --     'https://marketing.realplanjeju.com/' 의 부분문자열이 아니다(marketing. 이 앞에 붙는다).
  if v_blc then
    if NEW."본문_네이버" is not null then
      NEW."본문_네이버" := replace(NEW."본문_네이버", 'https://realplanjeju.com/', 'https://marketing.realplanjeju.com/');
    end if;
    if NEW."본문_티스토리" is not null then
      NEW."본문_티스토리" := replace(NEW."본문_티스토리", 'https://realplanjeju.com/', 'https://marketing.realplanjeju.com/');
    end if;
  end if;

  if v_rw then
    v_base := coalesce(NEW."원본_슬롯_id"::text, NEW."품질지표"->>'리라이트_원본_슬롯_id');
    if v_base is null then
      v_url := nullif(coalesce(NEW."리라이트_원본url",''),'');
      if v_url is null then
        select nullif(s."리라이트_원본url",'') into v_url from mk_blog_slots s where s.id = NEW."슬롯_id";
      end if;
      if v_url is not null then
        select o."슬롯_id"::text into v_base from mk_blog_drafts o
         where fn_normalize_blog_url(o."발행_url") = fn_normalize_blog_url(v_url)
           and coalesce(o."슬롯유형",'') <> '리라이트' and o."슬롯_id" is not null
         order by o."발행일" desc limit 1;
        if v_base is null then
          select l."매칭_슬롯_id"::text into v_base from mk_blog_publish_log l
           where fn_normalize_blog_url(l."외부_url") = fn_normalize_blog_url(v_url)
             and l."매칭_슬롯_id" is not null limit 1;
        end if;
      end if;
    end if;
    if v_base is null then
      select s2."핵심키워드" into v_kw from mk_blog_slots s2 where s2.id = NEW."슬롯_id";
      select s3.id::text into v_base from mk_blog_slots s3
       where s3."채널" = NEW."채널" and s3."핵심키워드" = coalesce(NEW."핵심키워드", v_kw)
         and coalesce(s3."슬롯유형",'') <> '리라이트'
       order by s3."발행일" desc limit 1;
    end if;
    v_base := coalesce(v_base, NEW."슬롯_id"::text);
    NEW."원본_슬롯_id" := v_base::uuid;
    if TG_OP = 'INSERT' or NEW."리라이트_회차" is null then
      select count(*) into v_n from mk_blog_drafts z
       where z."원본_슬롯_id" = v_base::uuid and z.id <> NEW.id
         and coalesce(z."상태",'') <> 'rejected';
      v_n := v_n + 2;
      NEW."리라이트_회차" := v_n;
    else
      v_n := NEW."리라이트_회차";
    end if;
    v_new := v_base || '_r' || v_n;
  else
    v_base := NEW."슬롯_id"::text;
    v_new  := v_base;
  end if;

  if NEW."본문_네이버" is not null then
    if position('utm_content' in NEW."본문_네이버") > 0 then
      v_cur := substring(NEW."본문_네이버" from 'utm_content=([0-9a-fA-F-]{36}(?:_r[0-9]+)?)');
      if v_rw and v_cur is not null and v_cur <> v_new then
        NEW."본문_네이버" := replace(NEW."본문_네이버",'utm_content='||v_cur,'utm_content='||v_new);
      end if;
    else
      if position('https://marketing.realplanjeju.com/' in NEW."본문_네이버") > 0 then
        NEW."본문_네이버" := replace(NEW."본문_네이버",'https://marketing.realplanjeju.com/','https://marketing.realplanjeju.com/' || v_q || v_new);
      elsif position('https://realplanjeju.com/' in NEW."본문_네이버") > 0 then
        NEW."본문_네이버" := replace(NEW."본문_네이버",'https://realplanjeju.com/','https://realplanjeju.com/' || v_q || v_new);
      end if;
    end if;
  end if;

  if NEW."본문_티스토리" is not null then
    if position('utm_content' in NEW."본문_티스토리") > 0 then
      v_cur := substring(NEW."본문_티스토리" from 'utm_content=([0-9a-fA-F-]{36}(?:_r[0-9]+)?)');
      if v_rw and v_cur is not null and v_cur <> v_new then
        NEW."본문_티스토리" := replace(NEW."본문_티스토리",'utm_content='||v_cur,'utm_content='||v_new);
      end if;
    else
      if position('https://marketing.realplanjeju.com/' in NEW."본문_티스토리") > 0 then
        NEW."본문_티스토리" := replace(NEW."본문_티스토리",'https://marketing.realplanjeju.com/','https://marketing.realplanjeju.com/' || v_q || v_new);
      elsif position('https://realplanjeju.com/' in NEW."본문_티스토리") > 0 then
        NEW."본문_티스토리" := replace(NEW."본문_티스토리",'https://realplanjeju.com/','https://realplanjeju.com/' || v_q || v_new);
      end if;
    end if;
  end if;

  return NEW;
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_utm_content_to_slot(p_content text)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- ★2026-08-19 신설 — utm_content 형식 5종을 슬롯 uuid 하나로 되돌린다.
--   [사유] 문의 23건 중 글까지 추적된 건이 1건뿐이었고, 그 1건조차 콘텐츠제목이 NULL이었다.
--          utm_content 실측 형식이 5종으로 갈려 있어 뷰의 단순 조인이 대부분 실패했다.
--   ①uuid(+_rN)  87건 ← 현행 트리거 정본
--   ②hex8_날짜   16건 ← uuid 앞 8자리만 남은 구형
--   ③문자열_날짜 66건 ← agency_20260730 · S2_20260727 (슬롯 대장에 없는 값)
--   ④S1/B/C      22건 ← 축약 표기
--   ⑤uuid#contact 11건 ← ★정본 uuid인데 앵커가 붙어 조인이 깨졌다
--   ★①⑤는 문자열 손질로, ②는 prefix 매칭으로, ③④는 초안 본문 역검색으로 되돌린다.
--   ★해석 불가면 NULL 을 준다. 억지 매칭은 하지 않는다(틀린 귀속이 미귀속보다 나쁘다).
declare v text; v_id uuid; v_hex text;
begin
  if p_content is null or btrim(p_content) = '' then return null; end if;
  -- ⑤ 앵커·쿼리 꼬리 제거 → ① 리라이트 회차 접미 제거
  v := split_part(split_part(btrim(p_content), '#', 1), '?', 1);
  v := regexp_replace(v, '_r[0-9]+$', '');

  -- ① 완전한 uuid
  if v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    select s.id into v_id from mk_blog_slots s where s.id = v::uuid;
    if v_id is not null then return v_id; end if;
    return v::uuid;   -- 슬롯 대장에 없어도 uuid 자체는 돌려준다(유튜브 슬롯일 수 있다)
  end if;

  -- ② hex8_날짜 → uuid 앞 8자리 prefix 매칭 (중복이면 포기)
  v_hex := (regexp_match(v, '^([0-9a-f]{8})_[0-9]{8}$'))[1];
  if v_hex is not null then
    select s.id into v_id from mk_blog_slots s where s.id::text like v_hex || '%' limit 2;
    if (select count(*) from mk_blog_slots s where s.id::text like v_hex || '%') = 1 then
      return v_id;
    end if;
    return null;
  end if;

  -- ③④ 초안 본문 역검색 — 그 utm_content 를 실제로 담고 있는 초안의 슬롯을 쓴다
  select d."슬롯_id" into v_id
    from mk_blog_drafts d
   where d."슬롯_id" is not null
     and (coalesce(d."본문_네이버",'') like '%utm_content=' || v || '%'
       or coalesce(d."본문_티스토리",'') like '%utm_content=' || v || '%')
   order by d."생성일" desc
   limit 1;
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.fn_utm_content_to_slot(p_content text, p_medium text)
 RETURNS uuid
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- ★2026-08-19 — 채널 힌트판. 1인자판과 같은 규칙이되 ③④ 역검색에서 utm_medium 채널을 먼저 고른다.
--   [사유] agency_20260730 이 네이버·티스토리 두 초안 본문에 모두 들어 있어
--          최신순 역검색이 티스토리를 잡았는데 실제 유입 리퍼러는 blog.naver.com 이었다.
--          채널이 틀린 귀속은 「어느 채널이 매출을 만드나」 판단을 통째로 뒤집는다.
declare v text; v_id uuid; v_hex text; v_ch text;
begin
  if p_content is null or btrim(p_content) = '' then return null; end if;
  v := split_part(split_part(btrim(p_content), '#', 1), '?', 1);
  v := regexp_replace(v, '_r[0-9]+$', '');

  -- 채널 힌트 정규화: 「블A네이버」 원본형과 「naver/tistory」 정규화형을 모두 받는다
  v_ch := case
    when p_medium is null then null
    when p_medium ~* '(티스토리|tistory)' then 'tistory'
    when p_medium ~* '(네이버|naver)' then 'naver'
    else null end;

  if v ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return v::uuid;
  end if;

  v_hex := (regexp_match(v, '^([0-9a-f]{8})_[0-9]{8}$'))[1];
  if v_hex is not null then
    if (select count(*) from mk_blog_slots s where s.id::text like v_hex || '%') = 1 then
      select s.id into v_id from mk_blog_slots s where s.id::text like v_hex || '%';
      return v_id;
    end if;
    return null;
  end if;

  -- ③④ 역검색 — 채널 힌트가 있으면 그 채널 초안을 먼저, 없으면 최신순
  select d."슬롯_id" into v_id
    from mk_blog_drafts d
   where d."슬롯_id" is not null
     and (coalesce(d."본문_네이버",'') like '%utm_content=' || v || '%'
       or coalesce(d."본문_티스토리",'') like '%utm_content=' || v || '%')
   order by
     case when v_ch = 'naver'   and d."채널" ilike '%네이버%'   then 0
          when v_ch = 'tistory' and d."채널" ilike '%티스토리%' then 0
          else 1 end,
     d."생성일" desc
   limit 1;
  return v_id;
end $function$
;

CREATE OR REPLACE FUNCTION public.rpc_kw_promote(p_dryrun boolean DEFAULT true, p_limit integer DEFAULT 20, p_min_score numeric DEFAULT 30, p_min_inflow integer DEFAULT 3)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- ★2026-08-19 신설 — 키워드풀 → 운영키워드 승격기.
--   [사고] mk_keyword_pool 29,576건 중 활성 243건(0.8%), 출처 '유입미커버' 291건 중 활성 0건.
--          원인은 파이프가 끊긴 게 아니라 **활성=true 로 만드는 코드가 DB 에 아예 없었다**는 것.
--   [설계] 5박자 — ①수요점수 ②유입실적(매출근거 대리) ③차단어 ④서비스마스터 ⑤B2B의도어
--   ★⑤가 핵심. ①②만 쓰면 「그린란드 여행」·「올림픽공원 핑크뮬리」 같은 B2C 정보검색이
--     유입 8~9회로 상위에 올라온다(2026-08-19 실측 — 상위 22건 중 우리 밭 1건뿐).
--   ★검색량은 게이트에 넣지 않는다. 「제주도 워크샵 숙소」는 검색량 50 인데
--     클릭 17·노출 374·문의 3건을 만든 최고 매출 키워드다. 100↑ 기준은 1등을 잘라낸다.
--   ★mk_keywords.정규키워드 는 generated column 이라 insert 목록에서 뺀다.
declare v_rows jsonb; v_n int := 0; v_ins int := 0;
begin
  create temp table if not exists _pick_tmp (id uuid, 키워드 text, 채널 text, 검색량 int, 수요점수 numeric, 유입 int, 카테고리 text, b2b의도어 text) on commit drop;
  delete from _pick_tmp;

  insert into _pick_tmp
  select p.id, p.키워드, p.채널, p.검색량, p.수요점수, coalesce(p.유입횟수,0),
         coalesce(p.정규화카테고리,'여행'),
         (select string_agg(i.의도어, ', ') from mk_b2b_intent_map i
           where i.활성 and p.키워드 like '%'||i.의도어||'%'
             and (i.제외_패턴 is null or p.키워드 !~* i.제외_패턴))
  from mk_keyword_pool p
  where not p.활성
    and p.수요점수 >= p_min_score
    and coalesce(p.유입횟수,0) >= p_min_inflow
    and not exists (select 1 from mk_banned_keywords b where b.활성 and p.키워드 ~* b.키워드패턴)
    and not exists (select 1 from mk_service_master sm, jsonb_array_elements_text(sm.금지키워드) g
          where sm.활성 and p.키워드 like '%'||g||'%'
            and case when p.채널 like '블A%' then sm.분류='블A'
                     when p.채널 like '블B%' then sm.분류='블B'
                     else sm.분류 like '블C%' end)
    and coalesce(p.g15_판정,'') <> '차단'
    and not exists (select 1 from mk_keywords m
          where replace(lower(m.키워드),' ','') = replace(lower(p.키워드),' ',''))
    and exists (select 1 from mk_b2b_intent_map i
          where i.활성 and p.키워드 like '%'||i.의도어||'%'
            and (i.제외_패턴 is null or p.키워드 !~* i.제외_패턴));

  delete from _pick_tmp where id not in (select id from _pick_tmp order by 유입 desc, 수요점수 desc limit p_limit);

  if not p_dryrun then
    insert into mk_keywords (카테고리, 키워드, 검색량, 활성, 사업정합등급)
    select 카테고리, 키워드, 검색량, true, 'B승격' from _pick_tmp;
    get diagnostics v_ins = row_count;
    update mk_keyword_pool p set 활성 = true, 검증일 = current_date
      from _pick_tmp t where p.id = t.id;
  end if;

  select jsonb_agg(jsonb_build_object('키워드',키워드,'채널',채널,'검색량',검색량,'수요점수',수요점수,'유입',유입,'b2b의도어',b2b의도어) order by 유입 desc), count(*)
    into v_rows, v_n from _pick_tmp;

  return jsonb_build_object('ok',true,'dryrun',p_dryrun,'후보건수',coalesce(v_n,0),'실제적재',v_ins,'목록',coalesce(v_rows,'[]'::jsonb));
end $function$
;

CREATE OR REPLACE FUNCTION public.rpc_voc_digest(p_notify boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- ★2026-08-19 신설 — 주간 VOC 리포트. rpc_funnel_reconcile 구조를 그대로 따랐다.
--   ①이번 주 새로 들어온 고객 어휘 ②승격 대기 후보 ③차단에 걸린 고객 말(놓치는 매출)
--   ★③이 제일 중요하다 — 고객이 실제로 쓴 말인데 우리 규칙이 막고 있는 것이다.
declare v_new int; v_pool int; v_prom int; v_block int; v_top text; v_blocktop text; msg text;
begin
  select count(*) into v_new from mk_voc_terms where 최근등장 >= current_date - 7;
  select count(*) into v_pool from mk_keyword_pool where 출처='문의어휘' and not 활성;
  select coalesce((rpc_kw_promote(true, 20))->>'후보건수','0')::int into v_prom;
  select count(*) into v_block from mk_voc_terms where 차단사유 is not null;
  select string_agg(어휘, ' · ') into v_top from (
    select 어휘 from mk_voc_terms where b2b의도어 is not null and 차단사유 is null
     order by 등장횟수 desc, 최근등장 desc limit 5) x;
  select string_agg(어휘 || '(' || split_part(차단사유,':',1) || ')', ' · ') into v_blocktop from (
    select 어휘, 차단사유 from mk_voc_terms where 차단사유 is not null
     order by 등장횟수 desc limit 5) y;

  if p_notify then
    msg := '🗣 <b>[VOC 주간] 고객이 쓴 말</b>' || chr(10)
        || '① 최근 7일 신규 어휘 ' || v_new || '건' || chr(10)
        || '② 풀 대기(문의어휘) ' || v_pool || '건 · 승격 후보 ' || v_prom || '건' || chr(10)
        || '③ ⚠️ 우리 규칙이 막은 고객 말 ' || v_block || '건' || chr(10)
        || '· 상위 어휘: ' || coalesce(v_top,'-') || chr(10)
        || '· 막힌 말: ' || coalesce(v_blocktop,'-') || chr(10)
        || '→ 승격 실행은 대표 승인 후 rpc_kw_promote(false)';
    insert into mk_notification_queue(이벤트_코드, 메시지, 우선순위, 발송_예정시각)
    values ('VOC_DIGEST', msg, 'P2', now());
  end if;

  return jsonb_build_object('신규어휘_7일',v_new,'풀대기',v_pool,'승격후보',v_prom,'차단된_고객말',v_block,
                            '상위어휘',v_top,'막힌말',v_blocktop);
end $function$
;

CREATE OR REPLACE FUNCTION public.rpc_voc_extract(p_days integer DEFAULT 3650, p_dryrun boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- ★2026-08-19 신설 — 고객 문의 원문에서 「고객이 쓴 말」을 뽑아 키워드 후보로 올린다.
--   [사고] customers.요청사항 을 읽는 DB 함수가 0개였다(2026-08-19 RPC 전수 검색 실측).
--   [설계] rpc_kw_harvest_inflow 의 쌍둥이 구조 — 같은 필터·같은 상태값(활성=false).
--   ★개인정보·고객사명 제거가 1순위다. 전화·이메일·URL·담당자명·회사명을 어절화 전에 지운다.
--     (2026-08-19 1차 추출에서 「세종대학교 호텔관광대학 학생회에서」가 원장에 남았다 — 즉시 회수)
--   ★2~4어절 n-gram 만. 1어절은 헤드 단일어라 이미 차단 대상이다.
--   ★게이트에서 걸려도 원장에는 차단사유와 함께 남긴다 — 「우리 규칙이 막은 고객 말」이
--     주간 리포트의 핵심 지표다(놓치는 매출).
declare
  r record; v_txt text; v_words text[]; v_n int; i int; j int; v_gram text; v_no text; v_tok text;
  v_new int := 0; v_terms int := 0; v_ch text; v_reason text; v_intent text;
  STOP text[] := array['있습니다','합니다','부탁드립니다','감사합니다','관련하여','드립니다','싶습니다','같습니다','예정입니다',
                       '하고자','대하여','경우','정도','위해','대한','통해','있는','하는','되는','이용','진행','문의','안녕하세요',
                       '검토','요청','확인','가능','희망','예정','내용','사항','기준','포함','별도','이번','저희','우리','해당'];
begin
  for r in
    select c."접수번호"::text as no, c."사업부"::text as bu, c."신청일시"::date as 일자, c."예산" as bud,
           coalesce(c."요청사항",'') || ' ' || coalesce(c."희망지역",'') as raw,
           coalesce(c."담당자명",'')::text as pic, coalesce(c."회사명",'')::text as comp
      from customers c
     where c.deleted_at is null
       and c."신청일시" >= now() - (p_days || ' days')::interval
       and coalesce(c."요청사항",'') <> ''
  loop
    v_no := r.no; v_txt := r.raw;
    v_txt := regexp_replace(v_txt, '01[0-9][- ]?[0-9]{3,4}[- ]?[0-9]{4}', ' ', 'g');
    v_txt := regexp_replace(v_txt, '0[2-6][0-9]?[- ]?[0-9]{3,4}[- ]?[0-9]{4}', ' ', 'g');
    v_txt := regexp_replace(v_txt, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+', ' ', 'g');
    v_txt := regexp_replace(v_txt, 'https?://[^\s]+', ' ', 'g');
    if length(r.pic) >= 2 then v_txt := replace(v_txt, r.pic, ' '); end if;
    -- ★회사명 전체와 각 어절(3자 이상)을 모두 지운다
    if length(r.comp) >= 2 then
      v_txt := replace(v_txt, r.comp, ' ');
      foreach v_tok in array regexp_split_to_array(r.comp, '\s+') loop
        if length(v_tok) >= 3 then v_txt := replace(v_txt, v_tok, ' '); end if;
      end loop;
    end if;
    v_txt := regexp_replace(v_txt, '[^가-힣A-Za-z0-9]+', ' ', 'g');
    v_words := regexp_split_to_array(btrim(v_txt), '\s+');
    v_n := coalesce(array_length(v_words,1),0);

    for i in 1..greatest(v_n,0) loop
      for j in 2..4 loop
        exit when i + j - 1 > v_n;
        v_gram := btrim(array_to_string(v_words[i : i+j-1], ' '));
        continue when length(v_gram) < 4 or length(v_gram) > 30;
        continue when v_gram !~ '[가-힣]';
        continue when v_words[i] = any(STOP) or v_words[i+j-1] = any(STOP);
        continue when v_words[i] ~ '^[0-9]+$';
        v_reason := null; v_ch := null;
        select b."키워드패턴" into v_ch from mk_banned_keywords b where b."활성" and v_gram ~* b."키워드패턴" limit 1;
        if v_ch is not null then v_reason := '차단어:'||v_ch; end if;
        if v_reason is null then
          v_ch := null;
          select sm."분류" into v_ch from mk_service_master sm, jsonb_array_elements_text(sm."금지키워드") g
           where sm."활성" and v_gram like '%'||g||'%' limit 1;
          if v_ch is not null then v_reason := '서비스마스터:'||v_ch; end if;
        end if;
        select string_agg(im."의도어", ', ') into v_intent from mk_b2b_intent_map im
         where im."활성" and v_gram like '%'||im."의도어"||'%'
           and (im."제외_패턴" is null or v_gram !~* im."제외_패턴");

        if not p_dryrun then
          insert into mk_voc_terms (어휘, 사업부, 등장횟수, 접수번호_목록, 최초등장, 최근등장, 예산대, b2b의도어, 차단사유)
          values (v_gram, r.bu, 1, array[v_no]::text[], r.일자, r.일자, r.bud, v_intent, v_reason)
          on conflict (어휘, 사업부) do update
            set 등장횟수 = case when mk_voc_terms.접수번호_목록 @> array[v_no]::text[] then mk_voc_terms.등장횟수
                               else mk_voc_terms.등장횟수 + 1 end,
                접수번호_목록 = case when mk_voc_terms.접수번호_목록 @> array[v_no]::text[] then mk_voc_terms.접수번호_목록
                               else mk_voc_terms.접수번호_목록 || array[v_no]::text[] end,
                최근등장 = greatest(mk_voc_terms.최근등장, r.일자),
                b2b의도어 = coalesce(excluded.b2b의도어, mk_voc_terms.b2b의도어),
                차단사유 = excluded.차단사유, 수정일 = now();
          v_terms := v_terms + 1;
        end if;
      end loop;
    end loop;
    v_new := v_new + 1;
  end loop;
  return jsonb_build_object('ok',true,'dryrun',p_dryrun,'처리문의',v_new,'어휘업서트',v_terms,
    '어휘총계',(select count(*) from mk_voc_terms));
end $function$
;

CREATE OR REPLACE FUNCTION public.rpc_voc_to_pool(p_dryrun boolean DEFAULT true, p_limit integer DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- ★2026-08-19 신설 — VOC 원장 → 키워드풀 적재기(추출과 적재를 분리했다).
--   ★문의 원문은 문장이지 검색어가 아니다. 그대로 넣으면 「52명이 단체로」·「워크샵 3」이 들어온다.
--     그래서 명사구만 통과시킨다 — 조사·어미·용언·숫자꼬리·일반어를 전부 거른다.
--   ★그래도 100%는 안 된다(형태소 분석기가 없다). 그래서 이중 관문이다 —
--     여기는 「후보 저장소」이고 실제 채택은 rpc_kw_promote 가 수요점수·의도어로 다시 거른다.
--     검색량 0짜리 조각은 pool-volume-refresh 크론이 실측하면 자연 탈락한다.
--   ★'서'는 거르지 않는다(「힐링 견적서」가 죽는다). '에서'만 거른다.
declare v_n int := 0; v_rows jsonb;
  GEN text[] := array['기타','동안','위한','개념','인원','회사','관련','다음','이후','이전','전체','각각','실제','현재',
                      '지난','오는','전후','정도','수준','부분','경우','상황','방식','형태','대상','필요','가능','문의',
                      '견적','예산','일정','장소','시간','날짜','기간','준비','운영','기획','진행','참석','참여','예정',
                      '공식적인','발표','목적','희망','생각','내용','포함','추가','우선','대략','약간','조금'];
begin
  create temp table if not exists _voc_pick (어휘 text, 사업부 text, 등장 int, 의도어 text, 채널 text) on commit drop;
  delete from _voc_pick;

  insert into _voc_pick
  select t.어휘, t.사업부, t.등장횟수, t.b2b의도어,
         case when t.사업부 = '행사이벤트' then '블B네이버'
              when t.사업부 in ('마케팅교육','온라인마케팅') then '블C네이버'
              else '블A네이버' end
    from mk_voc_terms t
   where t.차단사유 is null and t.b2b의도어 is not null and not t.풀적재
     and length(t.어휘) between 5 and 25
     and t.어휘 !~ '(을|를|은|는|이|가|의|에|에서|와|과|께|랑|로|고|며|면|지|나|자|어|아|다|요|한|할|된|될)$'
     and split_part(t.어휘,' ', array_length(regexp_split_to_array(t.어휘,'\s+'),1)) !~ '^[0-9]+$'
     and not exists (select 1 from unnest(regexp_split_to_array(t.어휘,'\s+')) w where length(w) < 2)
     and not exists (select 1 from unnest(regexp_split_to_array(t.어휘,'\s+')) w
                      where w ~ '(을|를|은|는|의|에서|와|과|며|하며|으로|이며)$')
     -- ★용언 활용형이 섞이면 제외 (「많습니다 2박3일」·「워크샵목적입니다 제주」)
     and t.어휘 !~ '(습니다|입니다|합니다|니다|으나|이나|였|았|었|겠|시길|드려)'
     and not exists (select 1 from unnest(regexp_split_to_array(t.어휘,'\s+')) w where w = any(GEN))
     and not exists (select 1 from mk_keyword_pool p
           where replace(lower(p.키워드),' ','') = replace(lower(t.어휘),' ',''))
   order by t.등장횟수 desc, length(t.어휘)
   limit p_limit;

  if not p_dryrun then
    insert into mk_keyword_pool (키워드, 채널, 출처, 활성, 유입월, 유입횟수)
    select 어휘, 채널, '문의어휘', false, current_date, 등장 from _voc_pick;
    update mk_voc_terms t set 풀적재 = true, 수정일 = now()
      from _voc_pick v where t.어휘 = v.어휘 and t.사업부 is not distinct from v.사업부;
  end if;

  select jsonb_agg(jsonb_build_object('어휘',어휘,'의도어',의도어,'채널',채널) order by 등장 desc, 어휘), count(*)
    into v_rows, v_n from _voc_pick;
  return jsonb_build_object('ok',true,'dryrun',p_dryrun,'적재대상',coalesce(v_n,0),'목록',coalesce(v_rows,'[]'::jsonb));
end $function$
;

-- ===== 3. 문의 귀속 뷰 =====
create or replace view public.mk_inquiry_attribution as
 WITH base AS (
         SELECT c.id,
            c."접수번호",
            c."신청일시",
            c."사업부",
            c."고객상태",
            c."계약금액",
            c."유입경로",
            COALESCE(c."유입_상세" ->> 'utm_source'::text, w.utm_source) AS a_source,
            COALESCE(c."유입_상세" ->> 'utm_medium'::text, w.utm_medium) AS a_medium,
            COALESCE(c."유입_상세" ->> 'utm_campaign'::text, c."유입_상세" ->> 'utm_content'::text, w.utm_campaign, w.utm_content) AS a_slot,
            lw.utm_content AS l_slot,
            fw."유입_출처" AS f_ref,
            COALESCE(c."유입_상세" ->> 'referrer'::text, fw."유입_상세") AS f_referrer
           FROM customers c
             LEFT JOIN LATERAL ( SELECT v.utm_source,
                    v.utm_medium,
                    v.utm_campaign,
                    v.utm_content
                   FROM "web_방문로그" v
                  WHERE c."유입_세션" IS NOT NULL AND v."세션_id" = c."유입_세션" AND (v.utm_source IS NOT NULL OR v.utm_campaign IS NOT NULL OR v.utm_content IS NOT NULL)
                  ORDER BY v."방문_시각"
                 LIMIT 1) w ON true
             LEFT JOIN LATERAL ( SELECT v.utm_content
                   FROM "web_방문로그" v
                  WHERE c."유입_세션" IS NOT NULL AND v."세션_id" = c."유입_세션" AND v.utm_content IS NOT NULL
                  ORDER BY v."방문_시각" DESC
                 LIMIT 1) lw ON true
             LEFT JOIN LATERAL ( SELECT v."유입_출처",
                    v."유입_상세"
                   FROM "web_방문로그" v
                  WHERE c."유입_세션" IS NOT NULL AND v."세션_id" = c."유입_세션"
                  ORDER BY v."방문_시각"
                 LIMIT 1) fw ON true
          WHERE (c."유입_상세" IS NOT NULL OR c."유입_세션" IS NOT NULL) AND c.deleted_at IS NULL
        ), r AS (
         SELECT base.id,
            base."접수번호",
            base."신청일시",
            base."사업부",
            base."고객상태",
            base."계약금액",
            base."유입경로",
            base.a_source,
            base.a_medium,
            base.a_slot,
            base.l_slot,
            base.f_ref,
            base.f_referrer,
            COALESCE(fn_utm_content_to_slot(base.a_slot, base.a_medium), ( SELECT l."매칭_슬롯_id"
                   FROM mk_blog_publish_log l
                  WHERE base.f_referrer IS NOT NULL AND base.f_referrer ~* '(blog\.naver\.com|tistory\.com)/'::text AND fn_normalize_blog_url(l."외부_url") = fn_normalize_blog_url(base.f_referrer)
                 LIMIT 1)) AS slot_uuid,
            fn_utm_content_to_slot(base.l_slot, base.a_medium) AS slot_uuid_last
           FROM base
        )
 SELECT r.id AS customer_id,
    r."접수번호",
    r."신청일시",
    r."사업부",
    r."고객상태",
    r."계약금액",
    r."유입경로",
    r.a_source AS utm_source,
    r.a_medium AS utm_medium,
    r.a_slot AS "슬롯번호",
        CASE
            WHEN y.id IS NOT NULL THEN '유튜브'::text
            WHEN b.id IS NOT NULL THEN '블로그'::text
            WHEN r.f_ref ~* '(chatgpt|perplexity|gemini|copilot|claude)'::text THEN 'AI검색'::text
            ELSE '기타'::text
        END AS "콘텐츠유형",
    COALESCE(y."최종제목", b."최종제목") AS "콘텐츠제목",
    COALESCE(y."코너", b."카테고리") AS "코너_카테고리",
    r.l_slot AS "슬롯번호_최종터치",
    ( SELECT s."최종제목"
           FROM mk_blog_slots s
          WHERE s.id = r.slot_uuid_last) AS "콘텐츠제목_최종터치",
    r.f_ref AS "최초_유입출처",
    r.f_ref ~* '(chatgpt|perplexity|gemini|copilot|claude)'::text AS "AI검색_경유",
    NULLIF("substring"(r.a_slot, '_r([0-9]+)$'::text), ''::text)::integer AS "리라이트회차",
    r.slot_uuid AS "슬롯_id",
    b."채널" AS "발행채널",
    b."핵심키워드",
        CASE
            WHEN r.a_slot IS NOT NULL THEN 'UTM'::text
            WHEN r.slot_uuid IS NOT NULL THEN '리퍼러역매칭'::text
            ELSE '미귀속'::text
        END AS "귀속경로"
   FROM r
     LEFT JOIN mk_youtube_slots y ON y.id = r.slot_uuid OR y."슬롯번호"::text = r.a_slot
     LEFT JOIN mk_blog_slots b ON b.id = r.slot_uuid;

-- ===== 4. 크론 =====
-- voc-extract-daily-0920kst  : 20 0 * * *   rpc_voc_extract(30,false); rpc_voc_to_pool(false,20);
-- voc-digest-weekly-sun-1250kst : 50 3 * * 0  rpc_voc_digest(true);
