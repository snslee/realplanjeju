// web-gsc-collector v1.0 (2026-07-14, 대표 승인 번들 A-4)
// realplanjeju.com GSC 검색어(최근 28일) 상위 20개 → web_gsc_검색어 upsert (홈페이지 전용)
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
const supabase=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false}});
async function gs(n:string){const{data}=await supabase.rpc('realplan_get_secret',{secret_name:n});return data as string|null;}
async function token(){ const id=await gs('realplan_gsc_oauth_client_id'),sec=await gs('realplan_gsc_oauth_client_secret'),rt=await gs('realplan_gsc_oauth_refresh_token'); const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:id!,client_secret:sec!,refresh_token:rt!,grant_type:'refresh_token'})}); const j=await r.json(); return j.access_token as string||null; }
async function q(tok:string, site:string, body:any){ const r=await fetch(`https://searchconsole.googleapis.com/webmasters/v3/sites/${encodeURIComponent(site)}/searchAnalytics/query`,{method:'POST',headers:{'Authorization':`Bearer ${tok}`,'Content-Type':'application/json'},body:JSON.stringify(body)}); return {status:r.status, j: r.ok? await r.json(): await r.text()}; }
Deno.serve(async(req)=>{
  try{
    const u=new URL(req.url); const debug=u.searchParams.get('debug')
    const tok=await token(); if(!tok)return new Response(JSON.stringify({ok:false,err:'token fail'}),{status:500})
    const end=new Date(Date.now()-2*864e5).toISOString().slice(0,10); const start=new Date(Date.now()-30*864e5).toISOString().slice(0,10)
    const body={startDate:start,endDate:end,dimensions:['query'],rowLimit:20}
    const sites=['sc-domain:realplanjeju.com','https://realplanjeju.com/','https://www.realplanjeju.com/']
    let rows:any[]=[],used='',tried:any[]=[]
    for(const s of sites){ const r=await q(tok,s,body); tried.push({site:s,status:r.status}); if(r.status===200&&r.j?.rows){rows=r.j.rows;used=s;break} }
    if(debug)return new Response(JSON.stringify({tried,used,rows:rows.slice(0,5)}),{headers:{'Content-Type':'application/json'}})
    if(!used)return new Response(JSON.stringify({ok:false,err:'no accessible GSC property',tried}),{status:502})
    const today=new Date(Date.now()+9*3600e3).toISOString().slice(0,10)
    const up=rows.map((x:any)=>({검색어:x.keys[0],클릭:x.clicks||0,노출:x.impressions||0,순위:x.position||null,수집일:today}))
    if(up.length){ const {error}=await supabase.from('web_gsc_검색어').upsert(up,{onConflict:'검색어,수집일'}); if(error)return new Response(JSON.stringify({ok:false,err:String(error.message)}),{status:500}) }
    return new Response(JSON.stringify({ok:true,property:used,적재:up.length}),{headers:{'Content-Type':'application/json'}})
  }catch(e){return new Response(JSON.stringify({ok:false,err:String(e)}),{status:500})}
})
