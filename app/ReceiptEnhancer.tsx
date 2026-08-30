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

     html=html.replace("<header><h1>LabaFlow</h1>",`<div class="receiptActions noPrint"><button onclick="downloadPdf()">↓ Download PDF</button><button onclick="shareReceipt()">↗ Share</button><button onclick="window.print()">🖨 Print</button></div><header><img class="receiptLogo" src="/labaflow-icon.svg" alt="LabaFlow"><h1>LabaFlow</h1>`);

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

     const shareText=`LabaFlow receipt ${receiptWin.document?.title||""}`;
     html=html.replace(/<script>window\.onload=\(\)=>\{window\.print\(\);\}<\/script>/,`<script>
       function downloadPdf(){document.title=document.title.replace(/ Receipt$/,'')+' Receipt';window.print()}
       async function shareReceipt(){
         const clean=document.body.innerText.replace(/↓ Download PDF|↗ Share|🖨 Print/g,'').trim();
         if(navigator.share){try{await navigator.share({title:document.title,text:clean});return}catch(e){if(e&&e.name==='AbortError')return}}
         if(navigator.clipboard){await navigator.clipboard.writeText(clean);alert('Receipt copied. You can paste it into Messenger, email, or another app.');return}
         alert('Sharing is not available in this browser. Use Download PDF instead.');
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
