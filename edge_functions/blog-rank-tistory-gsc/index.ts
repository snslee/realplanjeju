// blog-rank-tistory-gsc v1.1 (debug 포함)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
const supabase=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false}});
async function gs(n:string){const{data}=await supabase.rpc('realplan_get_secret',{secret_name:n});return data as string|null;}
const SITE:Record<string,string>={'블A티스토리':'https://wowjj8631.tistory.com/','블B티스토리':'https://realplan-event.tistory.com/','블C티스토리':'https://realplan-marketing.tistory.com/'};
const norm=(s:string)=>(s||'').replace(/\s+/g,'').toLowerCase();
async function token(){ const id=await gs('realplan_gsc_oauth_client_id'),sec=await gs('realplan_gsc_oauth_client_secret'),rt=await gs('realplan_gsc_oauth_refresh_token'); const r=await fetch('https://oauth2.googleapis.com/token',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:new URLSearchParams({client_id:id!,client_secret:sec!,refresh_token:rt!,grant_type:'refresh_token'})}); const j=await r.json(); return j.access_token as string||null; }
async function q(tok:string, site:string, body:any){ const r=await fetch(`https://searchconsole.googleapis.com/webmasters/v3/sites/${encodeURIComponent(site)}/searchAnalytics/query`,{method:'POST',headers:{'Authorization':`Bearer ${tok}`,'Content-Type':'application/json'},body:JSON.stringify(body)}); return {status:r.status, j: r.ok? await r.json(): await r.text()}; }
Deno.serve(async(req)=>{
  let b:any={}; try{b=await req.json();}catch{}
  const tok=await token(); if(!tok) return new Response(JSON.stringify({ok:false,err:'token fail'}),{status:500});
  const end=new Date(Date.now()-2*864e5).toISOString().slice(0,10); const start=new Date(Date.now()-32*864e5).toISOString().slice(0,10);
  if(b.debug){ const site=SITE['블C티스토리']; const r=await q(tok,site,{startDate:start,endDate:end,dimensions:['page'],rowLimit:10}); return new Response(JSON.stringify({site,status:r.status, rows:(r.j?.rows||[]).map((x:any)=>({page:x.keys[0],pos:Math.round(x.position),imp:x.impressions})), raw: r.j?.rows?undefined:r.j}),{headers:{'Content-Type':'application/json'}}); }
  const today=new Date();
  const { data:posts }=await supabase.from('mk_blog_publish_log').select('id,채널,핵심키워드,외부_url,발행일,d_plus_7_rank,d_plus_14_rank,d_plus_30_rank,d_plus_90_rank').like('채널','%티스토리').not('핵심키워드','is',null);
  let measured=0,hit=0; const ev:any[]=[];
  for(const p of (posts||[])){ const site=SITE[p.채널]; if(!site)continue; const age=Math.floor((today.getTime()-new Date(p.발행일).getTime())/864e5); const need=[7,14,30,90].filter(d=>age>=d && (p as any)[`d_plus_${d}_rank`]==null); if(need.length===0)continue;
    const r=await q(tok,site,{startDate:start,endDate:end,dimensions:['query','page'],dimensionFilterGroups:[{filters:[{dimension:'page',operator:'contains',expression:(p.외부_url.split('/entry/')[1]||'').slice(0,30)}]}],rowLimit:100}); measured++;
    const rows=r.j?.rows||[]; let best:number|null=null; const nk=norm(p.핵심키워드);
    for(const row of rows){ const qy=row.keys[0]||''; if(norm(qy).includes(nk)||nk.includes(norm(qy))|| p.핵심키워드.split(/\s+/).some((t:string)=>t.length>1&&qy.includes(t))) best=best===null?row.position:Math.min(best,row.position); }
    if(best===null && rows.length>0) best=Math.min(...rows.map((x:any)=>x.position));
    if(best!=null){ hit++; const rk=Math.round(best); for(const d of need){ await supabase.rpc('rpc_update_d_n_rank',{_id:p.id,_d:d,_rank:rk}); } ev.push({ch:p.채널,kw:p.핵심키워드,rows:rows.length,pos:rk}); } else { ev.push({ch:p.채널,kw:p.핵심키워드,rows:rows.length,pos:null}); }
    await new Promise(r=>setTimeout(r,200)); }
  return new Response(JSON.stringify({ok:true,측정시도:measured,GSC순위확보:hit,events:ev.slice(0,12)}),{headers:{'Content-Type':'application/json'}});
});
