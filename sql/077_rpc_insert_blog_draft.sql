-- 077_rpc_insert_blog_draft.sql
-- 2026-05-31 / 블로그 초안 → 초안 보관소(mk_blog_drafts 상태=draft) 적재 RPC
-- 🔴1 보관소 적재 단계 신설 + 🔴2 점수·버전 기록 의무화
-- 점수 가드 9.0 / 상태=draft / 스킬·알고리즘버전 자동 주입 / GRANT service_role·authenticated
-- 설계서: D:\자동화\설계\개발 설계서\블로그_초안보관소_적재_설계서_v1.0_2026-05-31.md

CREATE OR REPLACE FUNCTION public.rpc_insert_blog_draft(
  p_채널 text,
  p_핵심키워드 text,
  p_제목 text,
  p_본문_네이버 text,
  p_자가검증_점수 numeric,
  p_자가검증_결과 jsonb,
  p_본문_티스토리 text DEFAULT NULL,
  p_슬롯_id uuid DEFAULT NULL,
  p_슬롯유형 text DEFAULT NULL,
  p_글자수_네이버 integer DEFAULT NULL,
  p_글자수_티스토리 integer DEFAULT NULL,
  p_스킬_버전 text DEFAULT '7.10'
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id uuid;
  v_algo text;
BEGIN
  IF p_채널 IS NULL OR btrim(p_채널) = '' THEN
    RAISE EXCEPTION '채널은 필수입니다';
  END IF;
  IF p_제목 IS NULL OR btrim(p_제목) = '' THEN
    RAISE EXCEPTION '제목은 필수입니다';
  END IF;
  IF p_본문_네이버 IS NULL OR length(p_본문_네이버) <= 50 THEN
    RAISE EXCEPTION '본문_네이버는 50자 초과여야 합니다 (현재 %)', COALESCE(length(p_본문_네이버),0);
  END IF;
  IF p_자가검증_점수 IS NULL OR p_자가검증_점수 < 9.0 THEN
    RAISE EXCEPTION '자가검증 점수 9.0 이상만 보관소 적재 가능 (현재 %)', COALESCE(p_자가검증_점수, -1);
  END IF;

  SELECT 알고리즘_버전 INTO v_algo
  FROM mk_blog_algorithm
  WHERE 활성 = true
    AND 플랫폼 = CASE WHEN p_채널 = '티스토리' THEN '티스토리' ELSE '네이버블로그' END
  LIMIT 1;

  INSERT INTO mk_blog_drafts (
    채널, 핵심키워드, 제목, 본문_네이버, 본문_티스토리,
    자가검증_점수, 자가검증_결과, 상태, 스킬_버전, 알고리즘_버전,
    생성_방식, 슬롯_id, 슬롯유형, 글자수_네이버, 글자수_티스토리
  ) VALUES (
    p_채널, p_핵심키워드, p_제목, p_본문_네이버, p_본문_티스토리,
    p_자가검증_점수, p_자가검증_결과, 'draft', p_스킬_버전, v_algo,
    'skill', p_슬롯_id, p_슬롯유형, p_글자수_네이버, p_글자수_티스토리
  )
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_insert_blog_draft(text,text,text,text,numeric,jsonb,text,uuid,text,integer,integer,text)
  TO service_role, authenticated;

NOTIFY pgrst, 'reload schema';
