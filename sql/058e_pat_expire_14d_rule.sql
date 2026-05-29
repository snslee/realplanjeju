-- sql/058e — F_PAT_EXPIRE_14D + E축 14일 긴급 (50-1차 / 2026-05-21)
-- 14일 내 만료 시크릿 P1 즉시 알림 + Vault ↔ inventory 정합

INSERT INTO public.hr_audit_rule (룰_코드, 감사축, 룰_이름, 설명, 점검_방법, 임계치, 심각도) VALUES
('E_SECRETS_EXPIRE_14D','E_보안시크릿','시크릿 14일내 만료 (긴급)','만료 임박 P1 알림 (활성 시크릿만)','sql_count',
 '{"sql":"SELECT count(*) FROM secrets_inventory WHERE 활성=true AND 만료일 IS NOT NULL AND 만료일 < now() + interval ''14 days''","threshold":1}'::jsonb,'P1'),
('F_VAULT_INVENTORY_MISMATCH','F_시스템개선','Vault ↔ secrets_inventory 정합','Vault 등록건이 인벤토리에 없는 관리 누락 탐지','sql_count',
 '{"sql":"SELECT count(*) FROM vault.secrets v WHERE v.name LIKE ''realplan_%'' AND NOT EXISTS (SELECT 1 FROM secrets_inventory s WHERE s.위치_vault = v.name)","threshold":1}'::jsonb,'P3')
ON CONFLICT (룰_코드) DO NOTHING;

NOTIFY pgrst, 'reload schema';
