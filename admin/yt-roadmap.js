/* 리얼플랜여행 성장 로드맵 데이터 칸 v1.0.1 · 2026-10-28 동영상 방 · 대표 「니가 직접 권장 진행해」
   marketing.html RP-GROWTH 의 ytCard 가 #gr-yt-l1 칸을 만들고 ytFill() 이 이 파일의 window.__rpYtFill 을 부른다.
   원천 = mk_youtube_slots(발행) · mk_youtube_metrics · mk_youtube_strengths · 규칙 6-5(기준선 = 4번째 편 28일) · 지침 제12조 */
(function(){
'use strict';
function $(i){return document.getElementById(i);}
function N(v){return v==null||v===''?'-':Number(v).toLocaleString('ko-KR');}
function E(s){return (s==null?'':String(s)).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function pct(a,b){return b?Math.round(a/b*1000)/10:0;}
function bar(p,c){return '<div style="height:9px;background:#e2e8f0;border-radius:6px;overflow:hidden"><i style="display:block;height:100%;width:'+Math.max(0.8,Math.min(100,p))+'%;background:'+(c||'#2563eb')+'"></i></div>';}
async function ytFill(){
  var el=$('gr-yt-l1');if(!el||typeof sb==='undefined')return;
  try{
    var CH='리얼플랜여행',T=new Date(Date.now()+9*3600e3).toISOString().slice(0,10);
    var r1=await sb.from('mk_youtube_slots').select('id,슬롯번호,영상형식,발행일,상태,판정').eq('채널',CH).eq('상태','발행').in('영상형식',['롱폼','쇼츠']).order('발행일',{ascending:true});
    if(r1.error)throw r1.error;
    var S=(r1.data||[]).filter(function(s){return /^R\d/.test(s['슬롯번호']||'');});
    var ids=S.map(function(s){return s.id;});
    var r2=ids.length?await sb.from('mk_youtube_metrics').select('슬롯id,측정시점,조회수,노출클릭률_pct,평균시청지속률_pct,수집_시각').in('슬롯id',ids).order('수집_시각',{ascending:true}):{data:[]};
    if(r2.error)throw r2.error;
    var r3=await sb.from('mk_youtube_strengths').select('상태');
    var ver=r3.error?null:(r3.data||[]).filter(function(x){return x['상태']==='검증됨';}).length;
    var M={};(r2.data||[]).forEach(function(m){(M[m['슬롯id']]=M[m['슬롯id']]||[]).push(m);});
    function at(s,p){var a=(M[s.id]||[]).filter(function(m){return m['측정시점']===p&&m['조회수']!=null;});return a.length?a[a.length-1]:null;}
    function lastv(s,k){var a=(M[s.id]||[]).filter(function(m){return m[k]!=null;});return a.length?a[a.length-1]:null;}
    function add(d,n){var x=new Date(String(d).slice(0,10)+'T00:00:00Z');x.setUTCDate(x.getUTCDate()+n);return x.toISOString().slice(0,10);}
    function md2(d){return String(d).slice(5,10).replace('-','/');}
    var L=S.filter(function(s){return s['영상형식']==='롱폼';}),SH=S.filter(function(s){return s['영상형식']==='쇼츠';});
    function base(list){
      var f=list.slice(0,4);if(f.length<4)return {txt:'첫 4편 대기('+f.length+'/4)',v:null,ok:false};
      var due=add(f[3]['발행일'],28),a28=f.map(function(s){return at(s,'28일');});
      if(a28.every(Boolean)){var v=Math.round(a28.reduce(function(t,m){return t+(+m['조회수']);},0)/4);return {txt:'<b>'+N(v)+'회</b> (첫 4편 28일 · 확정)',v:v,ok:true,p:'28일'};}
      var a7=f.map(function(s){return at(s,'7일');});
      var t=a7.every(Boolean)?Math.round(a7.reduce(function(x,m){return x+(+m['조회수']);},0)/4):null;
      return {txt:'확정 대기 · '+md2(due)+' (4번째 편 28일 · 규칙 6-5)'+(t!=null?' · 임시 7일 평균 '+N(t)+'회(참고)':''),v:t,ok:false,p:'7일'};
    }
    var BL=base(L),BS=base(SH);
    var judged=S.filter(function(s){return s['판정'];}).length;
    var lv=(L.length>=12&&judged>=8&&ver!=null&&ver>=5)?2:1;
    var stg=['L1 시험','L2 방향 확정','L3 확장'];
    var h='<div style="display:flex;gap:4px;margin:2px 0 8px">'+stg.map(function(s,i){var on=i+1===lv,dn=i+1<lv;return '<span style="flex:1;text-align:center;font-size:.72rem;padding:5px 2px;border-radius:6px;'+(on?'background:#2563eb;color:#fff;font-weight:700':dn?'background:#bfdbfe;color:#1e3a8a':'background:#f1f5f9;color:#64748b')+'">'+s+'</span>';}).join('')+'</div>';
    function cond(t,a,b){return '<div style="background:#f8fafc;border-radius:8px;padding:7px 10px;font-size:.76rem;color:#475569">'+t+'<div style="font-size:1.05rem;font-weight:700;color:#0f172a">'+(a==null?'—':a)+' / '+b+'</div>'+bar(a==null?0:pct(a,b))+'</div>';}
    h+='<div style="display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-bottom:8px">'+cond('발행 롱폼',L.length,12)+cond('4칸 판정',judged,8)+cond('검증된 장점',ver,5)+'</div>';
    h+='<div style="font-size:.76rem;color:#334155;margin-bottom:6px">기준선 · 롱폼 '+BL.txt+'<br>기준선 · 쇼츠 '+BS.txt+'</div>';
    function row(s){
      var B=s['영상형식']==='쇼츠'?BS:BL,m7=at(s,'7일'),m28=at(s,'28일'),use=B.p==='28일'?m28:m7;
      var ratio=(B.v&&use)?(+use['조회수']/B.v):null;
      var rc=ratio==null?'#94a3b8':ratio>=1.5?'#16a34a':ratio<0.8?'#dc2626':'#475569';
      var c7=m7&&m7['노출클릭률_pct']!=null?m7:null,cl=c7||lastv(s,'노출클릭률_pct');
      var ctr=s['영상형식']==='쇼츠'?'<span style="color:#94a3b8">—</span>':cl?(+cl['노출클릭률_pct']).toFixed(1)+'%'+(c7?'':' <span style="color:#94a3b8;font-size:.68rem">('+md2(cl['수집_시각'])+')</span>'):'<span style="color:#b45309">기록 필요</span>';
      var ds=lastv(s,'평균시청지속률_pct');
      var due=add(s['발행일'],28);
      var k4=s['판정']?'<b>'+E(s['판정'])+'</b>':(!BL.ok&&s['영상형식']!=='쇼츠')?'<span style="color:#94a3b8">기준선 대기</span>':(T<due?'<span style="color:#94a3b8">28일 '+md2(due)+'</span>':'<span style="color:#b45309">판정 필요</span>');
      if(s['영상형식']==='쇼츠')k4='<span style="color:#94a3b8">쇼츠 따로</span>';
      return '<tr style="border-top:1px solid #e2e8f0"><td style="padding:5px">'+E(s['슬롯번호'])+'</td><td style="padding:5px">'+(m7?N(m7['조회수']):'—')+'</td><td style="padding:5px;color:'+rc+';font-weight:700">'+(ratio==null?'—':ratio.toFixed(1)+'배')+'</td><td style="padding:5px">'+ctr+'</td><td style="padding:5px">'+(ds?Math.round(+ds['평균시청지속률_pct'])+'%':'—')+'</td><td style="padding:5px">'+k4+'</td></tr>';
    }
    h+='<table style="width:100%;border-collapse:collapse;font-size:.76rem"><tr style="background:#f8fafc;text-align:left"><th style="padding:5px">편</th><th style="padding:5px">7일 조회</th><th style="padding:5px">기준선 대비</th><th style="padding:5px">클릭률</th><th style="padding:5px">지속률</th><th style="padding:5px">4칸</th></tr>'+L.concat(SH).map(row).join('')+'</table>';
    h+='<div style="font-size:.7rem;color:#94a3b8;margin-top:4px">원천 = mk_youtube_slots(발행) · mk_youtube_metrics(2·7·28일 · 클릭률은 7일 값이 없으면 최근 수시 값과 날짜) · 임시 기준선은 참고용이며 판정에 쓰지 않음 · 게시물은 커뮤니티 운영안(12-9)에서 따로 잼</div>';
    el.innerHTML=h;el.style.color='';
  }catch(e){el.innerHTML='<span style="color:#dc2626">로드맵 데이터를 읽지 못했습니다: '+E((e&&e.message)||e)+'</span>';}
}
window.__rpYtFill=ytFill;
ytFill();
})();
