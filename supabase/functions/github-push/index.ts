// Supabase Edge Function: github-push v2.0
// 59차 P2 — 배치 모드 추가 (files 배열) / 단건 호환 유지
// - 단건: { path, content, message } (기존 방식)
// - 배치: { files: [{path, content}], message } (신규)
// - GitHub Contents API / PAT 기반 / snslee/realplanjeju
import { serve } from "https://deno.land/std@0.192.0/http/server.ts";

const GITHUB_TOKEN = Deno.env.get("GITHUB_TOKEN") ?? "";
const GITHUB_OWNER = Deno.env.get("GITHUB_OWNER") ?? "snslee";
const GITHUB_REPO = Deno.env.get("GITHUB_REPO") ?? "realplanjeju";
const GITHUB_BRANCH = Deno.env.get("GITHUB_BRANCH") ?? "main";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey, x-client-info",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

function json(d: any, s = 200) {
  return new Response(JSON.stringify(d), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } });
}

async function ghApi(method: string, path: string, body?: any) {
  const res = await fetch(`https://api.github.com${path}`, {
    method,
    headers: {
      "Authorization": `Bearer ${GITHUB_TOKEN}`,
      "Accept": "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "Content-Type": "application/json",
      "User-Agent": "realplanjeju-edge-fn",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data: any = null;
  try { data = JSON.parse(text); } catch { data = { raw: text }; }
  return { status: res.status, ok: res.ok, data };
}

async function getFileSha(filePath: string): Promise<string | null> {
  const r = await ghApi("GET", `/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${encodeURIComponent(filePath)}?ref=${GITHUB_BRANCH}`);
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`GET file fail (${r.status}): ${r.data?.message || ""}`);
  return r.data?.sha || null;
}

function toBase64(content: string): string {
  const enc = new TextEncoder().encode(content);
  let bin = "";
  for (const byte of enc) bin += String.fromCharCode(byte);
  return btoa(bin);
}

async function pushSingleFile(filePath: string, content: string | undefined, content_base64: string | undefined, commitMsg: string, action: string) {
  if (action === "delete") {
    const sha = await getFileSha(filePath);
    if (!sha) return { ok: false, error: "파일 없음 (삭제 불가)", path: filePath };
    const r = await ghApi("DELETE", `/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${encodeURIComponent(filePath)}`, {
      message: commitMsg, sha, branch: GITHUB_BRANCH,
    });
    if (!r.ok) return { ok: false, error: r.data?.message || "delete fail", path: filePath };
    return { ok: true, action: "delete", path: filePath, commit_sha: r.data?.commit?.sha };
  }

  let b64: string;
  if (content_base64 && typeof content_base64 === "string") {
    b64 = content_base64;
  } else if (typeof content === "string") {
    b64 = toBase64(content);
  } else {
    return { ok: false, error: "content 또는 content_base64 필수", path: filePath };
  }

  const sha = await getFileSha(filePath);
  const payload: any = { message: commitMsg, content: b64, branch: GITHUB_BRANCH };
  if (sha) payload.sha = sha;

  const r = await ghApi("PUT", `/repos/${GITHUB_OWNER}/${GITHUB_REPO}/contents/${encodeURIComponent(filePath)}`, payload);
  if (!r.ok) return { ok: false, error: r.data?.message || "PUT fail", path: filePath, status: r.status };

  return {
    ok: true,
    action: sha ? "update" : "create",
    path: filePath,
    commit_sha: r.data?.commit?.sha,
    commit_url: r.data?.commit?.html_url,
  };
}

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST" && req.method !== "GET") return json({ ok: false, error: "GET/POST only" }, 405);
  if (!GITHUB_TOKEN) return json({ ok: false, error: "GITHUB_TOKEN 미등록 (Supabase Secret)" }, 500);

  if (req.method === "GET") {
    const r = await ghApi("GET", `/repos/${GITHUB_OWNER}/${GITHUB_REPO}`);
    return json({
      ok: r.ok, status: r.status,
      repo: r.data?.full_name || null,
      default_branch: r.data?.default_branch || null,
      private: r.data?.private,
      pages_url: `https://${GITHUB_OWNER}.github.io/${GITHUB_REPO}/`,
      message: r.ok ? "GITHUB_TOKEN 정상 / repo 접근 가능" : (r.data?.message || "unknown error"),
      version: "v2.0",
    }, r.ok ? 200 : 502);
  }

  let body: any = {};
  try { body = await req.json(); }
  catch { return json({ ok: false, error: "Invalid JSON" }, 400); }

  try {
    // ── 배치 모드: files 배열 ──────────────────────────────────────────
    if (Array.isArray(body.files) && body.files.length > 0) {
      const batchMsg = body.message || `Batch push ${body.files.length}개 파일 (${new Date().toISOString().slice(0, 19)})`;
      const results: any[] = [];
      let successCount = 0, failCount = 0;

      for (const f of body.files) {
        if (!f.path) { results.push({ ok: false, error: "path 필수", path: f.path }); failCount++; continue; }
        try {
          const r =