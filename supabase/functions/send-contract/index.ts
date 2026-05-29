// send-contract v4.4 (P5.7 / v3_blank + minimal-fill)
// PAD_X=0 PAD_Y=0 + fill width = text width only (preserve cell labels)
// Backup: 2026-05-20 (Track D 0-① 위험 차단)
import { serve } from "https://deno.land/std@0.192.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
import { PDFDocument, rgb } from "https://esm.sh/pdf-lib@1.17.1";
import fontkit from "https://esm.sh/@pdf-lib/fontkit@1.1.1";
import nodemailer from "npm:nodemailer@6.9.7";

const SMTP_USER = Deno.env.get("NAVER_SMTP_USER") ?? "realplan01@naver.com";
const SMTP_PASS = Deno.env.get("NAVER_SMTP_PASS") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function respond(b: any, s: number) { return new Response(JSON.stringify(b), { status: s, headers: { ...corsHeaders, "Content-Type": "application/json" } }); }
function buToKey(bu: string | null, cn: string): string {
  if (cn?.startsWith("C-EVENT") || bu === "행사이벤트") return "01_event";
  if (cn?.startsWith("C-MKT")   || bu === "온라인마케팅") return "02_marketing";
  if (cn?.startsWith("C-TOUR")  || bu === "국내여행")     return "03_tour";
  if (cn?.startsWith("C-EDU")   || bu === "마케팅교육")   return "04_education";
  return "01_event";
}
function numToKorean(n: number): string {
  if (!n || n <= 0) return "영원";
  const u = ["", "만", "억", "조"];
  const d = ["영","일","이","삼","사","오","육","칠","팔","구"];
  const p = ["", "십", "백", "천"];
  let s = String(Math.floor(n)), r = "", ui = 0;
  while (s.length > 0) {
    const ch = s.slice(-4); s = s.slice(0, -4);
    let cs = "";
    for (let i = 0; i < ch.length; i++) {
      const di = parseInt(ch[i]);
      if (di > 0) cs += (di === 1 && p[ch.length-1-i] && ui === 0) ? p[ch.length-1-i] : d[di] + p[ch.length-1-i];
    }
    if (cs) r = cs + u[ui] + r;
    ui++;
  }
  return r + "원";
}
function fmtDate(d: any): string {
  if (!d) return "";
  const dt = new Date(d); if (isNaN(dt.getTime())) return String(d);
  return `${dt.getFullYear()}.${String(dt.getMonth()+1).padStart(2,"0")}.${String(dt.getDate()).padStart(2,"0")}`;
}
function fmtNum(n: any): string {
  if (n == null) return "";
  const x = typeof n === "string" ? parseFloat(n) : n;
  return isNaN(x) ? "" : x.toLocaleString("ko-KR");
}
async function fetchFile(sb: any, bk: string, p: string): Promise<Uint8Array> {
  const { data, error } = await sb.storage.from(bk).download(p);
  if (error) throw new Error(`${bk}/${p}: ${error.message}`);
  return new Uint8Array(await data.arrayBuffer());
}
async function overlay(sb: any, key: string, fields: Record<string,string>, dout: any): Promise<Uint8Array> {
  const [blank, coord, font] = await Promise.all([
    fetchFile(sb, "contract-templates", `blanks/${key}.pdf`),
    fetchFile(sb, "contract-templates", `coordinates/${key}.json`),
    fetchFile(sb, "contract-templates", "fonts/NotoSansKR-Regular.ttf"),
  ]);
  dout.fetched = { blank: blank.length, coord: coord.length, font: font.length };
  const cd = JSON.parse(new TextDecoder().decode(coord));
  const fm = cd.field_mapping || {};
  dout.method = cd.method || "legacy";
  const doc = await PDFDocument.load(blank);
  doc.registerFontkit(fontkit);
  const f = await doc.embedFont(font, { subset: true });
  const pages = doc.getPages();
  dout.draws = [];
  for (const [fk, slots] of Object.entries(fm)) {
    const v = fields[fk];
    if (!v || !Array.isArray(slots) || !slots.length) continue;
    for (const s of slots as any[]) {
      const pi = (s.page || 1) - 1;
      if (pi < 0 || pi >= pages.length) continue;
      const pg = pages[pi];
      const { height: ph } = pg.getSize();
      const fs = s.size || 10;
      if (s.bbox && Array.isArray(s.bbox) && s.bbox.length === 4) {
        const [bx0, by0, bx1, by1] = s.bbox;
        const cellH = by1 - by0;
        const tx = s.x !== undefined ? s.x : bx0 + 5;
        const tw = f.widthOfTextAtSize(v, fs);
        const ty = ph - by1 + Math.max(2, (cellH - fs) / 2);
        pg.drawRectangle({ x: tx - 1, y: ty - 1, width: tw + 2, height: fs + 2, color: rgb(1, 1, 1) });
        pg.drawText(v, { x: tx, y: ty, size: fs, font: f, color: rgb(0, 0, 0) });
        if (dout.draws.length < 30) dout.draws.push({ field: fk, val: v, page: s.page, x: tx, y: ty });
      } else {
        const x = s.x || 0, yp = s.y || 0;
        const yl = ph - yp - fs;
        const ot = s.original_text || "";
        const ow = f.widthOfTextAtSize(ot, fs);
        pg.drawRectangle({ x: x-1, y: yl-1, width: ow+2, height: fs+2, color: rgb(1, 1, 1) });
        pg.drawText(v, { x, y: yl, size: fs, font: f, color: rgb(0, 0, 0) });
      }
    }
  }
  return await doc.save();
}
serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return respond({ ok: false, error: "POST only" }, 405);
  const diag: any = { ok: false, version: "v4.4" };
  try {
    const p = await req.json();
    diag.contract_id = p.contract_id;
    diag.diag_mode = p.diag === true;
    if (!p.contract_id) return respond({ ...diag, error: "contract_id" }, 400);
    const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, { auth: { persistSession: false } });
    const { data: c } = await sb.from("contracts").select("*").eq("id", p.contract_id).maybeSingle();
    if (!c) return respond({ ...diag, error: "no contract" }, 404);
    const { data: cu } = await sb.from("customers").select("*").eq("id", c.customer_id).maybeSingle();
    if (!cu) return respond({ ...diag, error: "no customer" }, 404);
    let q: any = null;
    if (c.quotation_id) {
      const { data: qq } = await sb.from("quotations").select("제목, 인원_성인, 인원_아동").eq("id", c.quotation_id).maybeSingle();
      q = qq;
    }
    const cn = c.계약번호 as string;
    let bu: string | null = cu.사업부 || null;
    if (cn?.startsWith("C-EDU")) bu = "마케팅교육";
    else if (cn?.startsWith("C-MKT")) bu = "온라인마케팅";
    else if (cn?.startsWith("C-TOUR")) bu = "국내여행";
    else if (cn?.startsWith("C-EVENT")) bu = "행사이벤트";
    diag.target_bu = bu;
    let fb: string = p.pdf_base64 || "";
    diag.overlay_used = false;
    const od: any = {};
    if (!fb || fb.length < 100) {
      diag.overlay_used = true;
      const k = buToKey(bu, cn);
      diag.overlay_key = k;
      const ad = q?.인원_성인 ?? cu.인원_성인 ?? 0;
      const ch = q?.인원_아동 ?? cu.인원_아동 ?? 0;
      const tt = ad + ch;
      const am = Number(c.계약금액 || 0);
      const dr = Number(c.계약금비율 || 50);
      const br = Number(c.잔금비율 || 50);
      const bizNum = (cu.사업자번호 || "");
      const corpNum = (cu.법인등록번호 || "");
      const bizCorp = corpNum ? `${bizNum} / ${corpNum}` : bizNum;
      const fields: Record<string,string> = {
        "회사명": cu.회사명 || "",
        "사업명": q?.제목 || "",
        "기간_시작": fmtDate(c.계약기간_시작),
        "기간_종료": fmtDate(c.계약기간_종료),
        "인원_성인": ad > 0 ? `${ad}명` : "",
        "인원_아동": ch > 0 ? `${ch}명` : "",
        "인원_총":   tt > 0 ? `${tt}명` : "",
        "금액_숫자": fmtNum(am),
        "금액_한글": numToKorean(am),
        "결제_1차_금액": fmtNum(Math.floor(am * dr / 100)),
        "결제_1차_일자": fmtDate(c.계약기간_시작),
        "결제_2차_금액": fmtNum(Math.floor(am * br / 100)),
        "결제_2차_일자": fmtDate(c.계약기간_종료),
        "대표자": cu.대표자명 || "",
        "사업자번호_법인번호": bizCorp,
        "회사주소": cu.회사주소 || "",
        "연락처": cu.연락처 || "",
      };
      diag.fields = fields;
      try {
        const ob = await overlay(sb, k, fields, od);
        let bn = ""; const cs = 0x8000;
        for (let i = 0; i < ob.length; i += cs) bn += String.fromCharCode.apply(null, Array.from(ob.subarray(i, i+cs)) as any);
        fb = btoa(bn);
        diag.overlay_size = ob.length;
        diag.overlay_diag = od;
      } catch (oe: any) {
        return respond({ ...diag, error: "overlay", overlay_error: oe?.message }, 500);
      }
    }
    if (p.diag === true) { diag.ok = true; return respond({ ...diag, overlay_pdf_base64: fb }, 200); }
    const { data: tpl } = await sb.from("contract_templates").select("사업부, 카테고리, 표시명, 파일명, storage_path").eq("자동첨부_계약", true).eq("활성", true).eq("사업부", bu);
    const al: any[] = [];
    for (const t of (tpl || [])) {
      const { data: sg } = await sb.storage.from("contract-templates").createSignedUrl(t.storage_path, 60*60*24*7);
      if (sg?.signedUrl) al.push({ 카테고리: t.카테고리, 파일명: t.표시명 || t.파일명, url: sg.signedUrl });
    }
    const provider = p.force_provider || c.provider || "self";
    if (provider !== "self") return respond({ ...diag, error: `provider=${provider}` }, 503);
    const to = p.recipient_email || cu.이메일;
    if (!to) return respond({ ...diag, error: "no email" }, 400);
    try {
      const tr = nodemailer.createTransport({ host: "smtp.naver.com", port: 465, secure: true, auth: { user: SMTP_USER, pass: SMTP_PASS } });
      const lh = al.length ? `<ul>${al.map(l => `<li><a href="${l.url}">${l.카테고리} - ${l.파일명}</a></li>`).join("")}</ul>` : "";
      const html = `<div><h2>계약서</h2><p>${cu.회사명}</p><p>${c.계약번호}</p>${lh}</div>`;
      const at: any[] = [];
      if (fb && fb.length > 100) at.push({ filename: `계약서_${c.계약번호}.pdf`, content: fb, encoding: "base64" });
      const info = await tr.sendMail({ from: `"리얼플랜제주" <${SMTP_USER}>`, to, subject: `[리얼플랜제주] ${c.계약번호}`, html, attachments: at });
      diag.mail_messageId = info.messageId;
    } catch (me: any) { return respond({ ...diag, error: "smtp", mail_error: String(me?.message) }, 500); }
    await sb.from("contracts").update({ 서명_상태_세부: "sent", 마지막_발송일: new Date().toISOString(), 발송_횟수: (c.발송_횟수 || 0) + 1, provider }).eq("id", p.contract_id);
    diag.ok = true;
    return respond(diag, 200);
  } catch (e: any) { return respond({ ...diag, error: "outer", outer: e?.message }, 500); }
});
