// ef-source-backup v2.0 — 59차 P5
// 변경: manifest.json(목록) + 실제 EF 소스코드 Storage 저장
// Supabase Management API로 배포된 EF 소스 직접 읽어 ef-backup/source/{date}/{slug}/index.ts 저장

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PROJECT_REF = SUPABASE_URL.replace("https://", "").replace(".supabase.co", "");

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false, autoRefreshToken: false } });

async function getSecret(name: string): Promise<string | null> {
  const { data } = await supabase.rpc("realplan_get_secret", { secret_name: name });
  return data as string | null;
}

async function githubGetFile(pat: string, path: string): Promise<string | null> {
  const r = await fetch(
    `https://api.github.com/repos/snslee/realplanjeju/contents/${encodeURIComponent(path)}?ref=main`,
    { headers: { "Authorization": `Bearer ${pat}`, "Accept": "application/vnd.github+json", "User-Agent": "realplanjeju-ef" } }
  );
  if (!r.ok) return null;
  const d = await r.json();
  if (!d.content) return null;
  return atob(d.content.replace(/\n/g, ""));
}

const EF_SLUGS = [
  "send-quotation", "send-contract", "contract-webhook", "create-payment", "payment-webhook",
  "github-push", "bulk-storage-upload", "mk-blog-fullauto", "blog-validator", "skill-zip-builder",
  "agent-evaluate", "agent-digest", "secrets-monitor", "usage-monitor", "api-cost-monitor",
  "secrets-vault-sync", "error-digest", "telegram-notifier", "system-audit-hourly", "system-audit-digest",
  "blog-publish-detector", "blog-stats-collector", "blog-rank-tracker", "notion-blog-sync",
  "blog-skill-suggest", "blog-daily-digest", "sitemap-submit",
  "blog-rank-d-n-tracker", "blog-index-checker", "blog-keyword-monthly", "blog-content-mover-suggest",
  "naver-stats-collector", "notion-publish-url-pusher", "ef-source-backup", "telegram-queue-flush"
];

Deno.serve(async (_req) => {
  const bucketName = "ef-backup";
  try {
    const { data: buckets } = await supabase.storage.listBuckets();
    if (!buckets?.some((b: any) => b.name === bucketName)) {
      await supabase.storage.createBucket(bucketName, { public: false });
    }
  } catch (e) { console.error("bucket", e); }

  const ts = new Date().toISOString().slice(0, 10);
  const pat = await getSecret("realplan_gith