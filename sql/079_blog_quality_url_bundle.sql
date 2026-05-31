-- 079_blog_quality_url_bundle.sql
-- 2026-05-31 / 고품질 URL자산화 번들
-- 1) mk_blog_drafts.이미지프롬프트(jsonb) 컬럼 신설
-- 2) rpc_insert_blog_draft 재생성 (+ p_이미지프롬프트, 네이버 8장 가드)
-- 3) rpc_upsert_blog_fact 신설 (사실 신규 적재: 수집→사실DB 저장)
-- 4) drafts.발행_url 백필 (슬롯 조인 — 실제 발행 URL만)
-- 설계서: 블로그자동화_노션대조_고품질보완_보고서_v1.0_2026-05-31.md

ALTER TABLE mk_blog_drafts ADD COLUMN IF NOT EXISTS 이미지프롬프트 jsonb;

DROP FUNCTION IF EXISTS public.rpc_insert_blog_draft(text,text,text,text,numeric,jsonb,text,uuid,text,integer,integer,text);

CREATE OR REPLACE FUNCTION public.rpc_insert_blog_draft(
  p_채널 text, p_핵심키워드 text, p_제목 text, p_본문_네이버 text,
  p_자가검증_점수 numeric, p_자가검증_결과 jsonb,
  p_본문_티스토리 text DEFAULT NULL, p_이미지프롬프트 jsonb DEFAULT NULL,
  p_슬롯_id uuid DEFAULT NULL, p_슬롯유형 text DEFAULT NULL,
  p_글자수_네이버 integer DEFAULT NULL, p_글자수_티스토리 integer DEFAULT NULL,
  p_스킬_버전 text DEFAULT '7.10'
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_algo text; v_img_cnt int := 0;
BEGIN
  IF p_채널 IS NULL OR btrim(p_채널)='' THEN RAISE EXCEPTION '채널은 필수입니다'; END IF;
  IF p_제목 IS NULL OR btrim(p_제목)='' THEN RAISE EXCEPTION '제목은 필수입니다'; END IF;
  IF p_본문_네이버 IS NULL OR length(p_본문_네이버)<=50 THEN RAISE EXCEPTION '본문_네이버는 50자 초과여야 합니다 (현재 %)', COALESCE(length(p_본문_네이버),0); END IF;
  IF p_자가검증_점수 IS NULL OR p_자가검증_점수<9.0 THEN RAISE EXCEPTION '자가검증 점수 9.0 이상만 보관소 적재 가능 (현재 %)', COALESCE(p_자가검증_점수,-1); END IF;
  IF p_이미지프롬프트 IS NOT NULL AND jsonb_typeof(p_이미지프롬프트)='array' THEN v_img_cnt := jsonb_array_length(p_이미지프롬프트); END IF;
  IF p_채널 ILIKE '%네이버%' AND v_img_cnt<8 THEN RAISE EXCEPTION '네이버 채널은 이미지 프롬프트 8장 필수 (현재 %)', v_img_cnt; END IF;

  SELECT 알고리즘_버전 INTO v_algo FROM mk_blog_algorithm
  WHERE 활성=true AND 플랫폼 = CASE WHEN p_채널 ILIKE '%티스토리%' THEN '티스토리' ELSE '네이버블로그' END LIMIT 1;

  INSERT INTO mk_blog_drafts (채널,핵심키워드,제목,본문_네이버,본문_티스토리,이미지프롬프트,자가검증_점수,자가검증_결과,상태,스킬_버전,알고리즘_버전,생성_방식,슬롯_id,슬롯유형,글자수_네이버,글자수_티스토리)
  VALUES (p_채널,p_핵심키워드,p_제목,p_본문_네이버,p_본문_티스토리,p_이미지프롬프트,p_자가검증_점수,p_자가검증_결과,'draft',p_스킬_버전,v_algo,'skill',p_슬롯_id,p_슬롯유형,p_글자수_네이버,p_글자수_티스토리)
  RETURNING id INTO v_id;
  RETURN v_id;
END; $$;

GRANT EXECUTE ON FUNCTION public.rpc_insert_blog_draft(text,text,text,text,numeric,jsonb,text,jsonb,uuid,text,integer,integer,text) TO service_role, authenticated;

CREATE OR REPLACE FUNCTION public.rpc_upsert_blog_fact(
  p_항목명 text, p_고정값내용 text, p_출처 text,
  p_카테고리 text DEFAULT NULL, p_세부유형 text DEFAULT NULL,
  p_적용채널 text[] DEFAULT NULL, p_업데이트주기 text DEFAULT '수시', p_만료예정일 date DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id uuid; v_action text; v_expire date;
BEGIN
  IF p_항목명 IS NULL OR btrim(p_항목명)='' THEN RAISE EXCEPTION '항목명 필수'; END IF;
  IF p_고정값내용 IS NULL OR length(p_고정값내용)<=10 THEN RAISE EXCEPTION '고정값내용 10자 초과 필수'; END IF;
  IF p_출처 IS NULL OR btrim(p_출처)='' THEN RAISE EXCEPTION '출처 필수'; END IF;
  v_expire := COALESCE(p_만료예정일, CURRENT_DATE + 90);
  SELECT id INTO v_id FROM mk_blog_facts WHERE 항목명=p_항목명 AND 활성=true ORDER BY updated_at DESC NULLS LAST LIMIT 1;
  IF v_id IS NOT NULL THEN
    UPDATE mk_blog_facts SET 고정값내용=p_고정값내용, 출처=p_출처,
      카테고리=COALESCE(p_카테고리,카테고리), 세부유형=COALESCE(p_세부유형,세부유형),
      적용채널=CASE WHEN p_적용채널 IS NULL THEN 적용채널 ELSE (SELECT array_agg(DISTINCT e) FROM unnest(COALESCE(적용채널,'{}')||p_적용채널) e) END,
      점검상태='✅최신', 최종업데이트=CURRENT_DATE, 만료예정일=v_expire, updated_at=now()
    WHERE id=v_id;
    v_action:='update';
  ELSE
    INSERT INTO mk_blog_facts (항목명,고정값내용,출처,카테고리,세부유형,적용채널,점검상태,업데이트주기,만료예정일,최종업데이트,활성)
    VALUES (p_항목명,p_고정값내용,p_출처,p_카테고리,p_세부유형,p_적용채널,'✅최신',p_업데이트주기,v_expire,CURRENT_DATE,true)
    RETURNING id INTO v_id;
    v_action:='insert';
  END IF;
  RETURN jsonb_build_object('id',v_id,'action',v_action);
END; $$;

GRANT EXECUTE ON FUNCTION public.rpc_upsert_blog_fact(text,text,text,text,text,text[],text,date) TO service_role, authenticated;

UPDATE mk_blog_drafts d SET 발행_url=p.외부_url, 수정일=now()
FROM mk_blog_publish_log p
WHERE d.슬롯_id=p.매칭_슬롯_id AND p.외부_url IS NOT NULL AND p.외부_url<>'' AND (d.발행_url IS NULL OR d.발행_url='');

NOTIFY pgrst, 'reload schema';
