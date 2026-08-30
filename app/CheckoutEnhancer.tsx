"use client";
import {useEffect} from "react";
export default function CheckoutEnhancer(){
 useEffect(()=>{
  const onClick=(e:MouseEvent)=>{
   if(location.pathname!=="/order-details")return;
   const el=(e.target as HTMLElement)?.closest("button");
   if(!el||el.textContent?.trim()!=="Print Receipt")return;
   const id=new URLSearchParams(location.search).get("id");
   if(!id)return;
   e.preventDefault();e.stopPropagation();e.stopImmediatePropagation();
   location.href=`/receipt?id=${encodeURIComponent(id)}`;
  };
  document.addEventListener("click",onClick,true);
  return()=>document.removeEventListener("click",onClick,true);
 },[]);
 return null;
}
