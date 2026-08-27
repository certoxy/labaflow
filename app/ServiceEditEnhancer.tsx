"use client";

import { useEffect } from "react";
import { supabase } from "../lib/supabase";

export default function ServiceEditEnhancer(){
  useEffect(()=>{
    let stopped=false;
    async function enhance(){
      const cards=[...document.querySelectorAll<HTMLElement>(".serviceGrid article")];
      if(!cards.length)return;
      const {data}=await supabase.from("services").select("id,name").eq("active",true);
      if(stopped||!data)return;
      for(const card of cards){
        if(card.querySelector("[data-service-edit]"))continue;
        const name=card.querySelector("strong")?.textContent?.trim();
        const service=data.find((s:any)=>s.name===name);
        if(!service)continue;
        const button=document.createElement("button");
        button.type="button";
        button.className="miniBtn";
        button.dataset.serviceEdit="true";
        button.textContent="Edit";
        button.style.marginTop="8px";
        button.onclick=()=>{window.location.href=`/services/edit?id=${service.id}`};
        card.appendChild(button);
      }
    }
    enhance();
    const observer=new MutationObserver(()=>enhance());
    observer.observe(document.body,{childList:true,subtree:true});
    return()=>{stopped=true;observer.disconnect()};
  },[]);
  return null;
}
