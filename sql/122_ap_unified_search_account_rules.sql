-- 122. 결재 기안 통합 검색 + 출금계좌 규칙을 DB로 (2026-08-31 · 대표 승인)
--
-- 배경
--  · 기안 화면에 「프로젝트 검색」과 「고객 검색」 두 칸이 나란히 있어 담당자가 뭘 써야 할지 알 수 없었다.
--    대표 지적: 「새프로젝트하고 고객 검색이랑 겹치는 기능 아냐??」
--  · 출금계좌 매핑이 admin.html 에 계좌번호로 하드코딩(DEPT_ACCT)돼 있어, 계좌가 바뀌면 화면을 고쳐야 했다.
--
-- 대표 확정 (2026-08-31)
--  · IBK기업(법인 출금)은 현재 결재에 쓰지 않는다 — 2026년 16건 전부 법인카드 자동출금·4대보험·이자였다.
--    단 자동이체가 살아 있으므로 「활성」은 끄지 않는다(끄면 통장 업로드·대사가 막힌다).
--  · 농협(마케팅·회사)는 본사공통과 온라인마케팅을 겸용한다.
--  · 마케팅교육은 법인 건이면 마케팅 통장으로 온다 → 같은 계좌.
--  · 여행/행사 계좌 분리는 최근이라, 과거 행사 지출이 농협(여행)에서 나간 것은 분리 전 기록이다.

alter table public."acc_계좌"
  add column if not exists "결재_출금_사용" boolean not null default true,
  add column if not exists "결재_기본_사업부" text[];

comment on column public."acc_계좌"."결재_출금_사용" is
  '결재 기안 화면의 출금계좌 목록에 넣을지. false여도 통장 업로드·대사는 그대로 동작한다.';
comment on column public."acc_계좌"."결재_기본_사업부" is
  '이 계좌가 기본 출금계좌가 되는 사업부 목록. 화면에 하드코딩하지 않는다.';

update public."acc_계좌" set "결재_기본_사업부"=array['국내여행'],   "결재_출금_사용"=true  where "별칭"='농협(여행)';
update public."acc_계좌" set "결재_기본_사업부"=array['행사이벤트'], "결재_출금_사용"=true  where "별칭"='농협(행사)';
update public."acc_계좌" set "결재_기본_사업부"=array['온라인마케팅','마케팅교육','본사공통'], "결재_출금_사용"=true where "별칭"='농협(마케팅·회사)';
update public."acc_계좌" set "결재_기본_사업부"=null, "결재_출금_사용"=false where "은행"='IBK기업';

-- 기안 화면 마스터 — 고객DB 값을 더 내려보낸다(표시 전용, 저장하지 않는다)
CREATE OR REPLACE FUNCTION public.rpc_ap_form_master()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $fn$
declare v jsonb;
begin
  if not fn_is_role(array['owner','manager']) then raise exception '권한 없음'; end if;
  select jsonb_build_object(
    'cats', coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'카테고리명',c.카테고리명,'유형',c.유형) order by c.정렬)
                      from acc_카테고리 c where c.활성),'[]'::jsonb),
    'accs', coalesce((select jsonb_agg(jsonb_build_object(
                        'id',a.id,'별칭',a.별칭,'은행',a.은행,'계좌번호',a.계좌번호,'사업부',a.사업부,
                        '결재사용',a."결재_출금_사용",'기본사업부',coalesce(a."결재_기본_사업부",'{}'::text[])) order by a.은행)
                      from acc_계좌 a where a.활성),'[]'::jsonb),
    'vendors', coalesce((select jsonb_agg(jsonb_build_object('id',d.id,'거래처명',d.거래처명,'은행',d.계좌_은행,
                        '계좌번호',d.계좌_번호,'예금주',d.계좌_예금주,'사업자번호',d.사업자번호) order by d.거래처명)
                      from vd_vendors d where d.is_active and d.deleted_at is null),'[]'::jsonb),
    'customers', coalesce((select jsonb_agg(jsonb_build_object(
                        'id',cu.id,'회사명',cu.회사명,'사업부',cu.사업부,'접수번호',cu.접수번호,'고객상태',cu.고객상태,
                        '담당자명',cu.담당자명,'시작일',cu.시작일,'종료일',cu.종료일,
                        '인원',coalesce(cu.인원_성인,0)+coalesce(cu.인원_아동,0),'희망지역',cu.희망지역) order by cu.회사명)
                      from customers cu where cu.deleted_at is null),'[]'::jsonb)
  ) into v;
  return v;
end $fn$;

REVOKE ALL ON FUNCTION public.rpc_ap_form_master() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_ap_form_master() TO authenticated;

-- 🔴 접수번호는 접수 시점 분류다. 사업부와 다르면 사업부가 정본이다.
--    2026년 불일치 5건은 요청사항 실물을 읽어 확인한 결과 전부 사업부가 맞았다. 접수번호는 고치지 않는다.
