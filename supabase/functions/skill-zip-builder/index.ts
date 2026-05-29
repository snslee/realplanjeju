// skill-zip-builder v1.0 - JSZip로 .skill 파일 생성 + Supabase Storage 업로드
// Backup: 2026-05-20 (Track D 0-① 위험 차단)
import JSZip from "npm:jszip@3.10.1";
import { createClient } from "npm:@supabase/supabase-js@2.45.0";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "POST only" }), { status: 405 });
  }
  try {
    const body = await req.json();
    const files = body.files as Array<{ name: string; content: string }>;
    const outputName = body.output_name || `realplan-blog-${Date.now()}.skill`;
    const innerFolder = body.inner_folder || "realplan-blog";

    if (!files || !Array.isArray(files) || files.length === 0) {
      return new Response(JSON.stringify({ error: "files array required" }), { status: 400 });
    }

    const zip = new JSZip();
    const folder = zip.folder(innerFolder);
    if (!folder) throw new Error("Failed to create inner folder");
    for (const file of files) {
      folder.file(file.name, file.content);
    }
    const zipBuffer = await zip.generateAsync({ type: "uint8array", compression: "DEFLATE", compressionOptions: { level: 9 } });

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "https://iodfqlkeiwxyuojwcozv.supabase.co";
    const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const filename = `skills/${Date.now()}_${outputName}`;
    const { data: uploadData, error: uploadError } = await supabase.storage.from("blog-drafts").upload(filename, zipBuffer, {
      contentType: "application/zip",
      upsert: true,
    });
    if (uploadError) {
      return new Response(JSON.stringify({ error: `Storage error: ${uploadError.message}` }), { status: 500 });
    }
    const { data: urlData } = supabase.storage.from("blog-drafts").getPublicUrl(filename);

    return new Response(JSON.stringify({
      success: true,
      download_url: urlData.publicUrl,
      filename: outputName,
      file_count: files.length,
      zip_size_bytes: zipBuffer.length,
      zip_size_kb: Math.round(zipBuffer.length / 1024),
    }, null, 2), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    const msg = e instanceof Error ? e.message + " | " + (e.stack || "") : String(e);
    return new Response(JSON.stringify({ error: msg }), { status: 500 });
  }
});
