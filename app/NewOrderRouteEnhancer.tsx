"use client";

import { useEffect } from "react";

export default function NewOrderRouteEnhancer(){
  useEffect(()=>{
    const handler=(event:MouseEvent)=>{
      if(location.pathname==="/new-order") return;
      const el=(event.target as HTMLElement)?.closest("button");
      if(!el) return;
      const text=(el.textContent||"").trim().replace(/^\+\s*/,"");
      if(text!=="New Order") return;
      event.preventDefault();
      event.stopPropagation();
      location.href="/new-order";
    };
    document.addEventListener("click",handler,true);
    return()=>document.removeEventListener("click",handler,true);
  },[]);
  return null;
}
