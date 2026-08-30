"use client";

import {useEffect} from "react";
import {supabase} from "../lib/supabase";
import {getStoredLocalStaffSession,getLocalStaffOperationalContext} from "../lib/localStaff";

export default function OrdersReceiptEnhancer(){
 useEffect(()=>{
  if(location.pathname!=="/orders")return;
  const onClick=async(e:MouseEvent)=>{
   const button=(e.target as HTMLElement|null)?.closest("button");
   if(!button||(button.textContent||"").trim()!=="Print Receipt")return;
   const card=button.closest(".orderCard");
   const code=card?.querySelector(".orderTop strong")?.textContent?.trim();
   if(!code)return;
   e.preventDefault();e.stopPropagation();e.stopImmediatePropagation();
   button.setAttribute("disabled","true");
   const original=button.textContent;button.textContent="Opening receipt…";
   try{
    let id:string|undefined;
    const local=getStoredLocalStaffSession();
    if(local){
     const ctx=await getLocalStaffOperationalContext();
     id=ctx.data?.orders?.find((o:any)=>o.order_code===code)?.id;
    }else{
     const {data}=await supabase.from("laundry_orders").select("id").eq("order_code",code).maybeSingle();
     id=data?.id;
    }
    if(id){location.href=`/order-details?id=${encodeURIComponent(id)}&print=1`;return}
   }catch{}
   button.removeAttribute("disabled");button.textContent=original||"Print Receipt";
  };
  document.addEventListener("click",onClick,true);
  return()=>document.removeEventListener("click",onClick,true);
 },[]);
 return null;
}
