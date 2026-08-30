"use client";

import {useEffect,useRef} from "react";

export default function AutoPrintReceiptEnhancer(){
 const triggered=useRef(false);
 useEffect(()=>{
  if(location.pathname!=="/order-details")return;
  const params=new URLSearchParams(location.search);
  if(params.get("print")!=="1")return;
  const tryPrint=()=>{
   if(triggered.current)return true;
   const buttons=Array.from(document.querySelectorAll("button"));
   const printButton=buttons.find(b=>(b.textContent||"").trim()==="Print Receipt") as HTMLButtonElement|undefined;
   if(!printButton)return false;
   triggered.current=true;
   const clean=new URL(location.href);clean.searchParams.delete("print");history.replaceState({},"",clean.toString());
   setTimeout(()=>printButton.click(),120);
   return true;
  };
  if(tryPrint())return;
  const observer=new MutationObserver(()=>{if(tryPrint())observer.disconnect()});
  observer.observe(document.body,{childList:true,subtree:true});
  const timer=setTimeout(()=>observer.disconnect(),10000);
  return()=>{observer.disconnect();clearTimeout(timer)};
 },[]);
 return null;
}
