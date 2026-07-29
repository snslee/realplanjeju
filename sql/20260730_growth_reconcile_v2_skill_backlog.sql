-- 20260730_growth_reconcile_v2_skill_backlog.sql
-- 승인: 대표 2026-07-30 (권장번들 4번)
-- 변경점 1건만: ⑦스킬동기화의 skill_pending 산식
--   before) 상태='반영완료' 전량(83건)을 "검증 대기"로 집계 → 다음 단계가 없어 영구 AMBER 고정
--   after ) 상태='반영완료' AND 조치일 IS NULL (9건)만 집계 → 조치일 백필하면 GREEN으로 내려감
--   근거) rpc_feedback_reconcile ②역제안정합이 이미 '반영완료_조치일누락'을 진짜 백로그로 보고 있음(정합)
-- 키명 '역제안검증대기'는 유지(참조처: rpc_growth_reconcile 단독 — 전수 확인 완료)
-- 롤백: 아래 ROLLBACK 블록 주석 해제 후 실행 (WHERE 절에서 AND 조치일 IS NULL 제거)

CREATE OR REPLACE FUNCTION public.rpc_growth_reconcile()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  ghost int; fb jsonb; live int; ch_wait int; ch_recent7 int; sns_wait int; skill_pending int; dod jsonb; d7 numeric;
  blog_rules int; ch_rules int; sns_rules int;
  s_supply text; s_qual text; s_rank text; s_ch text; s_sns text; s_live text; s_skill text; s_fresh text;
  reds int; ambers int; overall text;
begin
  select count(*) into ghost from mk_blog_slots s where s.상태='completed' and not exists(select 1 from mk_blog_drafts d where d.슬롯_id=s.id);
  select count(*) into ch_wait from mk_channel_cards where 상태='대기';
  select count(*) into ch_recent7 from mk_channel_cards where 상태 in ('발송','카드발송') and 발송_시각 >= now()-interval '7 days';
  select count(*) into sns_wait from mk_sns_slots where 상태='대기' and 플랫폼='쓰레드';
  -- ★v2 교정: 반영완료 전량이 아니라 '조치일 누락분'만 검증 백로그로 집계
  select count(*) into skill_pending from mk_improvement_suggestions where 상태='반영완료' and 조치일 is null;
  -- 스킬 거버넌스: 3개 스킬 규칙 저장소 활성 규칙 수
  select count(*) into blog_rules from mk_blog_skill_rules where 활성;
  select count(*) into ch_rules   from mk_channel_rules where 활성 and coalesce(스킬버전,'') not like 'sns%';
  select count(*) into sns_rules  from mk_channel_rules where 활성 and 스킬버전 like 'sns%';
  fb := rpc_feedback_reconcile();
  live := coalesce((fb->'⑤라이브보완'->>'발행완료_게이트미달_14일')::int,0);
  dod := rpc_dod_status();
  select round(avg("d7_평균순위"),1) into d7 from rpc_channel_d7_diag();

  s_supply := case when ghost>10 then 'RED' when ghost>0 then 'AMBER' else 'GREEN' end;
  s_qual   := fb->>'종합';
  s_rank   := coalesce(dod->'D_외부실측'->>'상태','PENDING');
  s_ch     := case when ch_wait>10 then 'RED' when ch_wait>0 then 'AMBER' else 'GREEN' end;
  s_sns    := case when sns_wait>10 then 'RED' when sns_wait>0 then 'AMBER' else 'GREEN' end;
  s_live   := case when live>0 then 'AMBER' else 'GREEN' end;
  -- ⑦ 스킬동기화: 3개 스킬 규칙저장소 완비(blog·channel·sns) + 반영완료 중 조치일 누락 백로그
  s_skill  := case when (blog_rules=0 or ch_rules=0 or sns_rules=0) then 'RED' when skill_pending>0 then 'AMBER' else 'GREEN' end;
  s_fresh  := coalesce(dod->'F_자가치유'->>'상태','GREEN');

  reds   := (select count(*) from unnest(array[s_supply,s_qual,s_rank,s_ch,s_sns,s_live,s_skill,s_fresh]) x where x='RED');
  ambers := (select count(*) from unnest(array[s_supply,s_qual,s_rank,s_ch,s_sns,s_live,s_skill,s_fresh]) x where x in ('AMBER','RED'));
  overall := case when reds>0 then 'RED' when ambers>0 then 'AMBER' else 'GREEN' end;

  return jsonb_build_object(
    '①공급',      jsonb_build_object('신호',s_supply,'유령슬롯',ghost,'등급','P1즉시','비고','completed 슬롯 초안없음'),
    '②품질',      jsonb_build_object('신호',s_qual,'등급','P2일','비고','rpc_feedback_reconcile 재활용'),
    '③순위성장',  jsonb_build_object('신호',s_rank,'D7평균순위',d7,'등급','P2일','비고','rpc_dod_status·channel_d7 재활용'),
    '④채널확산',  jsonb_build_object('신호',s_ch,'대기이월',ch_wait,'최근7일발송',ch_recent7,'등급','P2일','비고','월수금·요일사업부(월여행수행사금마케팅)·place/kakao/gbp'),
    '⑤SNS채널',   jsonb_build_object('신호',s_sns,'쓰레드대기',sns_wait,'등급','P2일','비고','쓰레드 전용(규칙저장소 mk_channel_rules sns-v2.0)'),
    '⑥라이브보완',jsonb_build_object('신호',s_live,'발행완료미달',live,'등급','P2일','비고','live_edit_autoroute 연동'),
    '⑦스킬동기화',jsonb_build_object('신호',s_skill,'블로그규칙',blog_rules,'채널규칙',ch_rules,'SNS규칙',sns_rules,'역제안검증대기',skill_pending,'등급','P2일','비고','3개 스킬 규칙저장소 완비 대조 + 반영완료 중 조치일 누락분(v2 교정)'),
    '⑧신선도',    jsonb_build_object('신호',s_fresh,'등급','P3주간','비고','rpc_dod_status 자가치유 재활용'),
    '종합', overall, '판정시각', now()
  );
end $function$;

-- ── ROLLBACK (v1 복원) ─────────────────────────────────────────────
-- 위 정의를 그대로 다시 실행하되 아래 한 줄만 되돌린다:
--   select count(*) into skill_pending from mk_improvement_suggestions where 상태='반영완료';
-- (v1 산출값: 역제안검증대기=83 · ⑦=AMBER 고정)
