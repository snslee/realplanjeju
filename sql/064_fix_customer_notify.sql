-- sql/064_fix_customer_notify.sql
-- 고객 접수 신규 알림 수정 (59차 버그픽스 / 2026-05-29)
-- 문제: fn_notify_new_customer()의 URL이 'REPLACE_WITH_MAKE_WEBHOOK_URL' 플레이스홀더
--       → early return으로 알림 미발송
-- 수정: Make 웹훅 → telegram-notifier EF 직접 호출
-- 적용: 2026-05-29 라이브 (apply_migration 불필요 — execute_sql 적용 완료)

CREATE OR REPLACE FUNCTION public.fn_notify_new_customer()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  _url TEXT := 'https://iodfqlkeiwxyuojwcozv.supabase.co/functions/v1/telegram-notifier';
  _메시지 TEXT;
BEGIN
  _메시지 := format(
    E'접수번호: <b>%s</b>\n사업부: %s\n담당자명: %s\n연락처: %s\n요청사항: %s\n신청일시: %s',
    NEW.접수번호,
    COALESCE(NEW.사업부, '-'),
    COALESCE(NEW.담당자명, '-'),
    COALESCE(NEW.연락처, '-'),
    LEFT(COALESCE(NEW.요청사항, '(없음)'), 80),
    to_char((NEW.신청일시 AT TIME ZONE 'Asia/Seoul'), 'YYYY-MM-DD HH24:MI')
  );

  PERFORM net.http_post(
    url := _url,
    headers := '{"Content-Type":"application/json"}'::jsonb,
    body := jsonb_build_object(
      '메시지',  _메시지,
      '심각도',  'P1',
      '제목',    '🔔 신규 고객 접수: ' || NEW.접수번호
    )
  );

  RETURN NEW;
END;
$$;

-- 검증: 함수 존재 확인
-- SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'fn_notify_new_customer';
