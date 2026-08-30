"use client";

import {useEffect,useRef} from "react";
import {supabase} from "../lib/supabase";
import {getStoredLocalStaffSession} from "../lib/localStaff";

function esc(v:unknown){return String(v??"").replace(/[&<>"']/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#039;"}[m]||m))}

export default function ReceiptEnhancer(){
 const loyaltyRef=useRef<number|null>(null);
 const customerRef=useRef<string|null>(null);

 useEffect(()=>{
  if(location.pathname!=="/order-details")return;
  const orderId=new URLSearchParams(location.search).get("id");
  if(!orderId)return;
  let mounted=true;
  (async()=>{
   try{
    const local=getStoredLocalStaffSession();
    if(local){
     const {data}=await supabase.rpc("get_local_staff_order_checkout",{p_token:local.token,p_order_id:orderId});
     const raw=data?.order;
     const points=raw?.customers?.loyalty_points??raw?.customer?.loyalty_points??data?.customer?.loyalty_points;
     const name=raw?.customers?.full_name??raw?.customer?.full_name??data?.customer?.full_name;
     if(mounted&&points!=null)loyaltyRef.current=Number(points);
     if(mounted&&name)customerRef.current=String(name);
     return;
    }
    const {data:order}=await supabase.from("laundry_orders").select("customer_id,customers(full_name,loyalty_points)").eq("id",orderId).maybeSingle();
    const customer:any=Array.isArray((order as any)?.customers)?(order as any)?.customers?.[0]:(order as any)?.customers;
    if(mounted&&customer?.loyalty_points!=null)loyaltyRef.current=Number(customer.loyalty_points);
    if(mounted&&customer?.full_name)customerRef.current=String(customer.full_name);
   }catch{}
  })();

  const originalOpen=window.open.bind(window);
  const patchedOpen:typeof window.open=((...args:any[])=>{
   const receiptWin=originalOpen(...args as Parameters<typeof window.open>);
   if(!receiptWin)return receiptWin;
   try{
    const originalWrite=receiptWin.document.write.bind(receiptWin.document);
    receiptWin.document.write=((...chunks:string[])=>{
     let html=chunks.join("");
     if(!html.includes("Laundry Service Receipt")){originalWrite(html);return}

     const points=loyaltyRef.current;
     const loyaltyText=points==null?"Not available":`${points.toLocaleString()} points`;
     const loyaltyRow=`<div class="loyaltyMeta"><span>Loyalty Points</span><strong>${esc(loyaltyText)}</strong></div>`;
     html=html.replace(/(<div><span>Payment<\/span><strong>.*?<\/strong><\/div>)/s,`$1${loyaltyRow}`);

     html=html.replace("<header><h1>LabaFlow</h1>",`<div class="receiptActions noPrint"><button onclick="downloadPdf()">↓ Download PDF</button><button onclick="shareReceipt()">↗ Share Image</button><button onclick="window.print()">🖨 Print</button></div><header><img class="receiptLogo" src="/labaflow-icon.svg" alt="LabaFlow"><h1>LabaFlow</h1>`);

     const extraCss=`
      :root{color-scheme:light}*{box-sizing:border-box}body{background:#f3f7f9!important;color:#0b2f47!important;margin:0 auto!important;padding:18px!important;max-width:760px!important;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif!important}
      header{background:#fff;border:1px solid #e2eaee;border-radius:18px 18px 0 0;padding:18px 18px 14px;margin:56px 0 0!important;box-shadow:0 8px 30px rgba(5,49,68,.06)}
      .receiptLogo{width:58px;height:58px;border-radius:15px;display:block;margin:0 auto 8px}header h1{font-size:36px!important;line-height:1!important;color:#062e49;margin:0 0 5px!important}header p{font-size:15px!important;line-height:1.35!important}.line{margin:0!important;border-top:1px dashed #9db0ba!important;background:#fff}
      .meta{background:#fff;padding:16px 18px;grid-template-columns:1fr 1fr!important;gap:12px 24px!important;font-size:13px!important;border-left:1px solid #e2eaee;border-right:1px solid #e2eaee}.meta div{display:grid!important;grid-template-columns:110px minmax(0,1fr);gap:8px!important;align-items:start!important;justify-content:unset!important}.meta span{color:#59717d}.meta strong{color:#0b3048;overflow-wrap:anywhere}.loyaltyMeta strong{display:inline-block;color:#8a5b00!important;background:#fff3c9;border-radius:8px;padding:4px 8px;width:max-content;max-width:100%}
      h2{font-size:22px!important;color:#092f48;margin:0!important;padding:16px 18px 5px;background:#fff}table{background:#fff!important;margin:0!important;padding:0 18px;font-size:12px!important}th,td{padding:9px 8px!important}.totals{width:100%!important;max-width:none!important;margin:0!important;background:#fff;padding:12px 18px 16px}.totals div{padding:5px 0!important}.totals .grand{font-size:18px!important;border-top:2px solid #14384d!important;margin-top:3px!important;padding-top:8px!important}.totals div:last-child strong{color:#d61f2c}.thanks{background:#eaf8f9;border:1px solid #cde8eb;border-radius:12px;padding:14px 16px;margin:16px 0 0!important;color:#0b3a50;font-size:15px!important}.receiptActions{position:fixed;top:10px;left:50%;transform:translateX(-50%);z-index:30;display:flex;gap:7px;width:min(724px,calc(100% - 24px));padding:7px;background:rgba(255,255,255,.96);border:1px solid #d8e4e9;border-radius:13px;box-shadow:0 6px 22px rgba(5,49,68,.12);backdrop-filter:blur(8px)}.receiptActions button{flex:1;border:0;border-radius:9px;min-height:38px;background:#087f91;color:#fff;font-weight:750;font-size:12px}.receiptActions button:first-child{background:#0b3554}.receiptActions button:nth-child(2){background:#0b93a6}
      @media(max-width:560px){body{padding:10px!important}header{margin-top:52px!important;padding:14px 12px 12px}.receiptLogo{width:48px;height:48px}header h1{font-size:30px!important}.meta{grid-template-columns:1fr!important;padding:12px!important;gap:8px!important}.meta div{grid-template-columns:100px minmax(0,1fr)}h2{font-size:20px!important;padding:13px 12px 5px}table{font-size:11px!important}th,td{padding:8px 5px!important}.totals{padding:10px 12px 14px}.receiptActions{width:calc(100% - 20px)}.receiptActions button{font-size:11px;padding:0 6px}}
      @media print{body{background:#fff!important;padding:0!important;max-width:none!important}.noPrint{display:none!important}header{margin-top:0!important;box-shadow:none!important;border:0!important}.meta{border:0!important}.thanks{break-inside:avoid}.line{border-color:#777!important}}
     `;
     html=html.replace("</style>",extraCss+"</style>");

     html=html.replace(/<script>window\.onload=\(\)=>\{window\.print\(\);\}<\/script>/,`<script>
       function downloadPdf(){document.title=document.title.replace(/ Receipt$/,'')+' Receipt';window.print()}

       function text(el,selector){var n=el.querySelector(selector);return n?n.textContent.trim():''}
       function wrap(ctx,value,x,y,maxWidth,lineHeight){
         var words=String(value||'').split(/\\s+/),line='',yy=y;
         for(var i=0;i<words.length;i++){
           var test=line?line+' '+words[i]:words[i];
           if(ctx.measureText(test).width>maxWidth&&line){ctx.fillText(line,x,yy);line=words[i];yy+=lineHeight}else line=test;
         }
         if(line)ctx.fillText(line,x,yy);return yy;
       }
       function money(v){return v||''}
       async function makeReceiptImage(){
         var canvas=document.createElement('canvas'),w=1080,pad=70;
         var meta=Array.from(document.querySelectorAll('.meta>div')).map(function(d){return {k:text(d,'span'),v:text(d,'strong')}});
         var tables=document.querySelectorAll('table');
         var serviceRows=tables[0]?Array.from(tables[0].querySelectorAll('tbody tr')).map(function(r){var c=r.querySelectorAll('td');return [c[0]?.innerText.trim()||'',c[1]?.innerText.trim()||'',c[2]?.innerText.trim()||'',c[3]?.innerText.trim()||'']}):[];
         var paymentRows=tables[1]?Array.from(tables[1].querySelectorAll('tbody tr')).map(function(r){var c=r.querySelectorAll('td');return Array.from(c).map(function(x){return x.innerText.trim()})}):[];
         var totalRows=Array.from(document.querySelectorAll('.totals>div')).map(function(d){var s=d.querySelectorAll('span,strong');return [s[0]?.textContent.trim()||'',s[1]?.textContent.trim()||'']});
         var h=560+meta.length*58+serviceRows.length*72+totalRows.length*58+Math.max(paymentRows.length,1)*60+180;
         canvas.width=w;canvas.height=h;
         var ctx=canvas.getContext('2d');if(!ctx)throw new Error('Canvas unavailable');
         ctx.fillStyle='#ffffff';ctx.fillRect(0,0,w,h);
         ctx.textBaseline='top';ctx.fillStyle='#082f49';ctx.textAlign='center';ctx.font='700 62px Arial';ctx.fillText('LabaFlow',w/2,50);
         ctx.font='400 30px Arial';ctx.fillStyle='#334e5c';ctx.fillText(text(document,'header p:first-of-type')||'LabaFlow',w/2,125);ctx.fillText('Laundry Service Receipt',w/2,168);
         ctx.strokeStyle='#91a4ae';ctx.setLineDash([8,8]);ctx.beginPath();ctx.moveTo(pad,225);ctx.lineTo(w-pad,225);ctx.stroke();ctx.setLineDash([]);
         var y=255;ctx.textAlign='left';
         meta.forEach(function(m){ctx.font='400 25px Arial';ctx.fillStyle='#607985';ctx.fillText(m.k,pad,y);ctx.font='700 27px Arial';ctx.fillStyle='#0b3048';wrap(ctx,m.v,310,y,w-380,32);y+=58});
         y+=10;ctx.strokeStyle='#91a4ae';ctx.setLineDash([8,8]);ctx.beginPath();ctx.moveTo(pad,y);ctx.lineTo(w-pad,y);ctx.stroke();ctx.setLineDash([]);y+=34;
         ctx.font='700 40px Arial';ctx.fillStyle='#092f48';ctx.fillText('Services',pad,y);y+=62;
         ctx.font='700 24px Arial';ctx.fillText('Service',pad,y);ctx.fillText('Qty',500,y);ctx.fillText('Rate',650,y);ctx.fillText('Amount',830,y);y+=38;
         ctx.strokeStyle='#d9e1e5';ctx.beginPath();ctx.moveTo(pad,y);ctx.lineTo(w-pad,y);ctx.stroke();y+=14;
         serviceRows.forEach(function(r){ctx.font='400 25px Arial';ctx.fillStyle='#173b50';ctx.fillText(r[0],pad,y);ctx.fillText(r[1],500,y);ctx.fillText(r[2],650,y);ctx.fillText(r[3],830,y);y+=58;ctx.strokeStyle='#e8eef1';ctx.beginPath();ctx.moveTo(pad,y-10);ctx.lineTo(w-pad,y-10);ctx.stroke()});
         y+=18;totalRows.forEach(function(r,idx){var grand=(r[0]||'').toLowerCase()==='total';ctx.font=(grand?'700 ':'400 ')+(grand?'34':'29')+'px Arial';ctx.fillStyle=grand?'#092f48':'#243f4e';ctx.fillText(r[0],pad,y);ctx.textAlign='right';ctx.fillText(r[1],w-pad,y);ctx.textAlign='left';if(grand){ctx.strokeStyle='#173b50';ctx.beginPath();ctx.moveTo(pad,y-10);ctx.lineTo(w-pad,y-10);ctx.stroke()}y+=58});
         y+=15;ctx.strokeStyle='#91a4ae';ctx.setLineDash([8,8]);ctx.beginPath();ctx.moveTo(pad,y);ctx.lineTo(w-pad,y);ctx.stroke();ctx.setLineDash([]);y+=34;
         ctx.font='700 40px Arial';ctx.fillStyle='#092f48';ctx.fillText('Payments',pad,y);y+=55;
         ctx.font='400 24px Arial';ctx.fillStyle='#425d6b';if(paymentRows.length){paymentRows.forEach(function(r){ctx.fillText(r.join('   '),pad,y);y+=55})}else{ctx.fillText('No payment recorded yet.',pad,y);y+=55}
         y+=35;ctx.fillStyle='#eaf8f9';ctx.fillRect(pad,y,w-pad*2,100);ctx.textAlign='center';ctx.fillStyle='#0b3a50';ctx.font='700 28px Arial';ctx.fillText('Thank you for choosing LabaFlow.',w/2,y+22);ctx.font='400 22px Arial';ctx.fillText('We appreciate your trust and support!',w/2,y+58);
         return await new Promise(function(resolve,reject){canvas.toBlob(function(blob){blob?resolve(blob):reject(new Error('Unable to create image'))},'image/png',0.95)});
       }
       async function shareReceipt(){
         try{
           var blob=await makeReceiptImage();
           var safe=(document.title||'LabaFlow Receipt').replace(/[^a-z0-9_-]+/gi,'-');
           var file=new File([blob],safe+'.png',{type:'image/png'});
           if(navigator.share&&navigator.canShare&&navigator.canShare({files:[file]})){await navigator.share({title:document.title,text:'LabaFlow receipt',files:[file]});return}
           if(navigator.share){try{await navigator.share({title:document.title,text:'LabaFlow receipt'});return}catch(e){if(e&&e.name==='AbortError')return}}
           var url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=file.name;document.body.appendChild(a);a.click();a.remove();setTimeout(function(){URL.revokeObjectURL(url)},2000);alert('Receipt image downloaded. You can attach it in Messenger, email, or another app.');
         }catch(e){if(e&&e.name==='AbortError')return;alert('Unable to prepare the receipt image. Please use Download PDF instead.')}
       }
     <\/script>`);
     originalWrite(html);
    }) as typeof receiptWin.document.write;
   }catch{}
   return receiptWin;
  }) as typeof window.open;
  window.open=patchedOpen;
  return()=>{mounted=false;window.open=originalOpen};
 },[]);
 return null;
}
