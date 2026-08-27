"use client";

import { useEffect } from "react";

export default function SidebarEnhancer(){
 useEffect(()=>{
  const enhance=()=>{
   const sidebar=document.querySelector<HTMLElement>(".sidebar:not([data-shared-sidebar])");
   if(!sidebar)return;
   const collapsed=localStorage.getItem("labaflow.sidebar.collapsed")==="1";sidebar.classList.toggle("collapsed",collapsed);
   const brand=sidebar.querySelector<HTMLElement>(".brand");
   if(brand&&!brand.querySelector(".sidebarToggle")){
    const b=document.createElement("button");b.type="button";b.className="sidebarToggle";b.title=collapsed?"Show navigation":"Hide navigation";b.textContent=collapsed?"›":"‹";
    b.onclick=()=>{const next=!sidebar.classList.contains("collapsed");sidebar.classList.toggle("collapsed",next);localStorage.setItem("labaflow.sidebar.collapsed",next?"1":"0");b.textContent=next?"›":"‹";b.title=next?"Show navigation":"Hide navigation"};brand.appendChild(b)
   }
   const nav=sidebar.querySelector("nav");
   if(nav&&!nav.querySelector('[data-promo-nav]')&&Array.from(nav.querySelectorAll("button")).some(x=>x.textContent?.includes("Organization Admin"))){
    const p=document.createElement("button");p.type="button";p.dataset.promoNav="1";p.innerHTML='<span class="navIcon">P</span><span class="navText">Promo Codes</span>';p.title="Promo Codes";p.onclick=()=>{location.href="/organization/promos"};
    const platform=Array.from(nav.querySelectorAll("button")).find(x=>x.textContent?.includes("Platform Admin"));platform?nav.insertBefore(p,platform):nav.appendChild(p)
   }
   sidebar.querySelectorAll("nav button").forEach(btn=>{if(!btn.querySelector(".navText")){const txt=(btn.textContent||"").trim();btn.textContent="";const i=document.createElement("span");i.className="navIcon";i.textContent=txt.slice(0,1);const t=document.createElement("span");t.className="navText";t.textContent=txt;btn.append(i,t);btn.setAttribute("title",txt)}})
  };
  enhance();const obs=new MutationObserver(enhance);obs.observe(document.body,{childList:true,subtree:true});return()=>obs.disconnect()
 },[]);return null
}
