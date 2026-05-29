// blog-validator v3.0 - docx@9.5.1 + Supabase Storage direct upload
// Backup: 2026-05-20 (Track D 0-① 위험 차단)
import { Document, Packer, Paragraph, TextRun, HeadingLevel } from "npm:docx@9.5.1";
import { createClient } from "npm:@supabase/supabase-js@2.45.0";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response(JSON.stringify({ error: "POST only" }), { status: 405 });
  const body = await req.json();
  const md: string = body.md_content || "";
  const slot_name: string = body.slot_name || "unknown";
  const want_docx: boolean = body.want_docx !== false;
  const body_only = md.split("\n---\n")[0];
  const total = body_only.length;
  const no_space = body_only.replace(/\s/g, "").length;
  const forbidden_keywords = ["직접계약","직접 계약","직접 연결","직접 진행","중간업체 없이","수수료 없이","대행사 거치지 않고","저렴한","최저가","가성비","합리적인 가격","저희 같은 작은 회사","부족하지만","아직 작지만","최고의","전국 최초","독보적인","유일한","신록","정취","풍광","운치","처음이라면","처음 맡았다면"];
  const forbidden_count: Record<string, number> = {};
  for (const f of forbidden_keywords) {
    const re = new RegExp(f.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"), "g");
    const m = md.match(re);
    if (m && m.length > 0) forbidden_count[f] = m.length;
  }
  const intro = body_only.replace(/^#[^\n]*\n/, "").substring(0, 300);
  const greetings = ["안녕하세요","반갑습니다","리얼플랜제주입니다","리얼플랜제주의","오늘은","포스팅을","반가워요"];
  const greeting_count: Record<string, number> = {};
  for (const g of greetings) {
    if (intro.includes(g)) greeting_count[g] = (intro.match(new RegExp(g, "g")) || []).length;
  }
  const core_kw: string = body.core_keyword || "그랜드오픈 행사";
  const core_kw_count = (body_only.match(new RegExp(core_kw, "g")) || []).length;
  const url_in_parens = (md.match(/\([^)]*https?:\/\/[^)]*\)/g) || []);
  const slogan_count = (body_only.match(/고객의 상황에 딱 맞는 리얼한 플랜, 그게 리얼플랜제주/g) || []).length;
  const onetone_count = (body_only.match(/1:1 맞춤 플랜/g) || []).length;
  const years_count = (body_only.match(/19년/g) || []).length;
  const naver_event_urls = (body_only.match(/blog\.naver\.com\/realplan_event\/\d+/g) || []);
  const tistory_event_urls = (body_only.match(/realplan-event\.tistory\.com\/entry\/\S+/g) || []);
  const ai_notice = body_only.includes("이미지는 AI로 제작되어 참고만 하세요");
  const hashtag_lines = body_only.match(/#[-￿]+/g) || [];
  const hashtag_count = hashtag_lines.length;
  const has_event_cta = body_only.includes("realplanjeju.creatorlink.net/행사이벤트");
  const h2_count = (body_only.match(/^## /gm) || []).length;
  const h3_count = (body_only.match(/^### /gm) || []).length;
  let docx_url = "";
  let docx_size_kb = 0;
  let docx_error = "";
  if (want_docx) {
    try {
      const lines = body_only.split("\n");
      const paragraphs: Paragraph[] = [];
      for (const line of lines) {
        if (line.startsWith("# ")) {
          paragraphs.push(new Paragraph({ text: line.substring(2), heading: HeadingLevel.HEADING_1 }));
        } else if (line.startsWith("## ")) {
          paragraphs.push(new Paragraph({ text: line.substring(3), heading: HeadingLevel.HEADING_2 }));
        } else if (line.startsWith("### ")) {
          paragraphs.push(new Paragraph({ text: line.substring(4), heading: HeadingLevel.HEADING_3 }));
        } else if (line.trim() === "") {
          paragraphs.push(new Paragraph({}));
        } else {
          paragraphs.push(new Paragraph({ children: [new TextRun(line)] }));
        }
      }
      const doc = new Document({
        creator: "리얼플랜제주",
        title: slot_name,
        description: slot_name,
        sections: [{ properties: {}, children: paragraphs }],
      });
      const buf = await Packer.toBuffer(doc);
      const u8 = new Uint8Array(buf);
      docx_size_kb = Math.round(u8.length / 1024);
      const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "https://iodfqlkeiwxyuojwcozv.supabase.co";
      const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
      const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
      const filename = `${Date.now()}_${slot_name}.docx`;
      const { data: uploadData, error: uploadError } = await supabase.storage.from("blog-drafts").upload(filename, u8, {
        contentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        upsert: true,
      });
      if (uploadError) {
        docx_error = `Storage upload error: ${uploadError.message}`;
      } else {
        const { data: urlData } = supabase.storage.from("blog-drafts").getPublicUrl(filename);
        docx_url = urlData.publicUrl;
      }
    } catch (e) {
      docx_error = e instanceof Error ? e.message + " | " + (e.stack || "") : String(e);
    }
  }
  return new Response(JSON.stringify({
    slot_name, char_count: { total, no_space },
    forbidden_count, greeting_count,
    core_keyword: core_kw, core_keyword_count: core_kw_count,
    url_in_parens, slogan_count, onetone_count, years_count,
    naver_event_urls, tistory_event_urls,
    has_ai_notice: ai_notice, hashtag_count, has_event_cta,
    h2_count, h3_count,
    docx_url, docx_size_kb, docx_error,
  }, null, 2), { headers: { "Content-Type": "application/json" } });
});
