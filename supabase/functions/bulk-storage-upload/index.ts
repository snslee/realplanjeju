// bulk-storage-upload v1.1 (POST=upload / GET=download)
// Backup: 2026-05-20 (Track D 0-① 위험 차단)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization, apikey',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  const supabase = createClient(SUPABASE_URL, SERVICE_ROLE);
  try {
    if (req.method === 'GET') {
      const url = new URL(req.url);
      const bucket = url.searchParams.get('bucket') || 'contract-templates';
      const path = url.searchParams.get('path');
      if (!path) return new Response(JSON.stringify({ error: 'path required' }), { status: 400, headers: { ...cors, 'Content-Type': 'application/json' } });
      const { data, error } = await supabase.storage.from(bucket).download(path);
      if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { ...cors, 'Content-Type': 'application/json' } });
      const buf = await data.arrayBuffer();
      const bytes = new Uint8Array(buf);
      let bin = '';
      const cs = 0x8000;
      for (let i = 0; i < bytes.length; i += cs) bin += String.fromCharCode.apply(null, Array.from(bytes.subarray(i, i + cs)) as any);
      const b64 = btoa(bin);
      return new Response(JSON.stringify({ success: true, base64: b64, size: bytes.length }), { headers: { ...cors, 'Content-Type': 'application/json' } });
    }
    if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'POST/GET only' }), { status: 405, headers: { ...cors, 'Content-Type': 'application/json' } });
    const { bucket, path, base64, contentType } = await req.json();
    if (!bucket || !path || !base64) return new Response(JSON.stringify({ error: 'bucket, path, base64 required' }), { status: 400, headers: { ...cors, 'Content-Type': 'application/json' } });
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    const { data, error } = await supabase.storage.from(bucket).upload(path, bytes, { contentType: contentType || 'application/octet-stream', upsert: true });
    if (error) return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: { ...cors, 'Content-Type': 'application/json' } });
    return new Response(JSON.stringify({ success: true, path: data.path, size: bytes.length }), { headers: { ...cors, 'Content-Type': 'application/json' } });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: String(e?.message || e) }), { status: 500, headers: { ...cors, 'Content-Type': 'application/json' } });
  }
});
