// keyword-freshness-refresh v1.1 — 풀 키워드 30일↑ 자동 재검증 (네이버 검색광고 API)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
const supabase=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false}});
async function gs(n:string){const{data}=await supabase.rpc('realplan_get_secret',{secret_name:n});return data as string|null;}
async function tg(m:string){try{const t=await gs('realplan_telegram_token');const c=await gs('realplan_telegram_chat_id');if(!t||!c)return;await fetch(`https://api.telegram.org/bot${t}/sendMessage`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({chat_id:c,text:m,parse_mode:'HTML'})});}catch(e){console.error(e);}}
const norm=(s:string)=>s.replace(/\s+/g,'').toUpperCase();
function n2(v:any){ if(typeof v==='string') return v.includes('<')?0:parseInt(v.replace(/,/g,'')||'0'); return Number(v)||0; }
async function sign(ts:string,uri:string,sec:string){ const k=await crypto.subtle.importKey('raw',new TextEncoder().encode(sec),{name:'HMAC',hash:'SHA-256'},false,['sign']); const s=await crypto.subtle.sign('HMAC',k,new TextEncoder().encode(`${ts}.GET.${uri}`)); return btoa(String.fromCharCode(...new Uint8Array(s))); }
Deno.serve(async(req)=>{
  let body:any={}; try{body=await req.json();}catch{}
  const limit=body.limit??40;
  const API=await gs('realplan_naver_ad_api_key'), SEC=await gs('realplan_naver_ad_secret_key'), CID=await gs('realplan_naver_ad_customer_id');
  if(!API||!SEC||!CID) return new Response(JSON.stringify({ok:false,error:'naver ad secret 없음'}),{status:500});
  const cutoff=new Date(Date.now()-30*864e5).toISOString().slice(0,10);
  const { data:rows }=await supabase.from('mk_keyword_pool').select('id,키워드').eq('활성',true).or(`검증일.is.null,검증일.lt.${cutoff}`).limit(limit);
  const list=rows||[]; if(list.length===0) return new Response(JSON.stringify({ok:true,updated:0,msg:'신선 키워드 없음'}),{headers:{'Content-Type':'application/json'}});
  const uri='/keywordstool'; let updated=0, matched=0;
  for(let i=0;i<list.length;i+=5){
    const batch=list.slice(i,i+5); const ts=String(Date.now());
    const q=new URLSearchParams({hintKeywords:batch.map((b:any)=>b.키워드.replace(/\s+/g,'')).join(','),showDetail:'1'}).toString();
    let kl:any[]=[];
    try{ const r=await fetch(`https://api.searchad.naver.com${uri}?${q}`,{headers:{'X-Timestamp':ts,'X-API-KEY':API,'X-Customer':CID,'X-Signature':await sign(ts,uri,SEC)}}); const res=await r.json(); kl=res.keywordList||[]; }catch(e){ kl=[]; }
    const idx:Record<string,any>={}; for(const it of kl) idx[norm(it.relKeyword)]=it;
    for(const b of batch){
      const hit=idx[norm(b.키워드)];
      const upd:any={ 검증일:new Date().toISOString().slice(0,10), 수정일:new Date().toISOString() };
      if(hit){ const vol=n2(hit.monthlyPcQcCnt)+n2(hit.monthlyMobileQcCnt); const ctr=Math.round(((Number(hit.monthlyAvePcCtr)||0)+(Number(hit.monthlyAveMobileCtr)||0))*100)/100; upd['검색량']=vol; upd['클릭률']=ctr; upd['점수']=Math.round(vol*(1+ctr/100)*10)/10; matched++; }
      await supabase.from('mk_keyword_pool').update(upd).eq('id',b.id); updated++;
    }
    await new Promise(r=>setTimeout(r,400));
  }
  await tg(`🔄 <b>키워드 신선도 재검증</b>\n갱신 ${updated} (API매칭 ${matched})`);
  return new Response(JSON.stringify({ok:true,updated,matched}),{headers:{'Content-Type':'application/json'}});
});
