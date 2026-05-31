// system-dod-report v1.0 — 주간 DoD 자동판정 + 폐루프 반영 + 텔레그램 (2026-05-30)
// cron: 매주 월 09:00 KST. 자가치유 핵심: 실측→점수반영 후 A~G 판정 보고.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
const supabase=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,{auth:{persistSession:false}});
async function getSecret(n:string){const{data}=await supabase.rpc('realplan_get_secret',{secret_name:n});return data as string|null;}
async function tg(m:string){try{const t=await getSecret('realplan_telegram_token');const c=await getSecret('realplan_telegram_chat_id');if(!t||!c)return;await fetch(`https://api.telegram.org/bot${t}/sendMessage`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({chat_id:c,text:m,parse_mode:'HTML',disable_web_page_preview:true})});}catch(e){console.error(e);}}
const emo=(s:string)=> s==='GREEN'?'🟢':s==='AMBER'?'🟡':s==='PENDING'?'⏳':'🔴';
Deno.serve(async()=>{
  // 폐루프: 실측 → 키워드 점수 반영
  const { data:fb }=await supabase.rpc('rpc_apply_performance_to_keywords');
  const { data:dod }=await supabase.rpc('rpc_dod_status');
  const items=['A_정합','B_생성','C_품질','D_외부실측','E_폐루프','F_자가치유','G_E2E'];
  let green=0,total=items.length; const lines:string[]=[];
  for(const k of items){ const v=(dod as any)?.[k]; const st=v?.상태||'?'; if(st==='GREEN')green++; lines.push(`${emo(st)} <b>${k}</b> ${st}`);}
  const done = green===total;
  const head = done? '🎉 <b>시스템 완성(DoD 전면 GREEN)</b>' : `📊 <b>주간 DoD 판정</b> (${green}/${total} GREEN)`;
  await tg([head,'',...lines,'',`폐루프 반영: ${JSON.stringify(fb)}`,`→ <a href="https://realplanjeju.com/admin/marketing.html">대시보드</a>`].join('\n'));
  return new Response(JSON.stringify({ok:true,green,total,done,dod,fb}),{headers:{'Content-Type':'application/json'}});
});
