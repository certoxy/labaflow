"use client";

import { useEffect } from "react";
import { supabase } from "../lib/supabase";

export default function SidebarEnhancer(){
 useEffect(()=>{
  let inventoryEnabled=false;
  void supabase.rpc("get_current_access_context").then(({data})=>{inventoryEnabled=data?.features?.inventory===true;document.querySelectorAll<HTMLElement>('[data-shared-sidebar] button').forEach(button=>{if(button.textContent?.includes("Products & Inventory"))button.style.display=inventoryEnabled?"":"none"})});
  const captureDedicatedNav=(e:MouseEvent)=>{
   const target=e.target as HTMLElement|null;
   const button=target?.closest(".sidebar button") as HTMLButtonElement|null;
   if(!button||button.closest("[data-shared-sidebar]"))return;
   const text=(button.querySelector(".navText")?.textContent||button.textContent||"").trim();
   const href=text==="New Order"?"/new-order":text==="Customers"?"/customers":text==="Orders"?"/orders":null;
   if(href){e.preventDefault();e.stopPropagation();e.stopImmediatePropagation();location.href=href}
  };
  document.addEventListener("click",captureDedicatedNav,true);

  const enhance=()=>{
   document.querySelectorAll<HTMLElement>('[data-shared-sidebar] button').forEach(button=>{if(button.textContent?.includes("Products & Inventory"))button.style.display=inventoryEnabled?"":"none"});
   const sidebar=document.querySelector<HTMLElement>(".sidebar:not([data-shared-sidebar])");
   if(!sidebar)return;
   const collapsed=localStorage.getItem("labaflow.sidebar.collapsed")==="1";sidebar.classList.toggle("collapsed",collapsed);
   const brand=sidebar.querySelector<HTMLElement>(".brand");
   if(brand&&!brand.querySelector(".sidebarToggle")){
    const b=document.createElement("button");b.type="button";b.className="sidebarToggle";b.title=collapsed?"Show navigation":"Hide navigation";b.textContent=collapsed?"›":"‹";
    b.onclick=()=>{const next=!sidebar.classList.contains("collapsed");sidebar.classList.toggle("collapsed",next);localStorage.setItem("labaflow.sidebar.collapsed",next?"1":"0");b.textContent=next?"›":"‹";b.title=next?"Show navigation":"Hide navigation"};brand.appendChild(b)
   }
   const nav=sidebar.querySelector("nav");if(!nav)return;
   const rawButtons=Array.from(nav.querySelectorAll<HTMLElement>(":scope > button"));const hasOrgAdmin=rawButtons.some(x=>x.textContent?.includes("Organization Admin"));
   if(hasOrgAdmin&&!nav.querySelector('[data-loyalty-levels-nav]')){const l=document.createElement("button");l.type="button";l.dataset.loyaltyLevelsNav="1";l.textContent="Loyalty Levels";l.title="Loyalty Levels";l.onclick=()=>{location.href="/organization/loyalty-levels"};const promo=Array.from(nav.querySelectorAll("button")).find(x=>x.textContent?.includes("Promo Codes"));promo?nav.insertBefore(l,promo):nav.appendChild(l)}
   if(!nav.querySelector('[data-promo-nav]')&&hasOrgAdmin){const p=document.createElement("button");p.type="button";p.dataset.promoNav="1";p.textContent="Promo Codes";p.title="Promo Codes";p.onclick=()=>{location.href="/organization/promos"};const platform=Array.from(nav.querySelectorAll("button")).find(x=>x.textContent?.includes("Platform Admin"));platform?nav.insertBefore(p,platform):nav.appendChild(p)}
   nav.querySelectorAll(":scope > button").forEach(btn=>{if(!btn.querySelector(".navText")){const txt=(btn.textContent||"").trim();btn.textContent="";const i=document.createElement("span");i.className="navIcon";i.textContent=txt.slice(0,1);const t=document.createElement("span");t.className="navText";t.textContent=txt;btn.append(i,t);btn.setAttribute("title",txt)}})
   if(nav.dataset.grouped==="1")return;
   const buttons=Array.from(nav.querySelectorAll<HTMLElement>(":scope > button"));const find=(name:string)=>buttons.find(b=>b.querySelector(".navText")?.textContent?.trim()===name);
   const makeSection=(title:string,names:string[])=>{const found=names.map(find).filter(Boolean) as HTMLElement[];if(!found.length)return null;const wrap=document.createElement("div");wrap.className="navSection";const lab=document.createElement("div");lab.className="navSectionLabel navText";lab.textContent=title;wrap.appendChild(lab);found.forEach(b=>wrap.appendChild(b));return wrap};
   const operations=makeSection("Operations",["Dashboard","New Order","Orders"]);const customers=makeSection("Customers",["Customers","Loyalty"]);const management=makeSection("Management",["Services & Pricing","Pickup & Delivery"]);const adminNames=["Organization Admin","Organization Settings","Loyalty Levels","Promo Codes","Delivery Pricing","Platform Admin"];const adminButtons=adminNames.map(find).filter(Boolean) as HTMLElement[];
   Array.from(nav.children).forEach(el=>el.remove());if(operations)nav.appendChild(operations);if(customers)nav.appendChild(customers);if(management)nav.appendChild(management);
   if(adminButtons.length){const admin=document.createElement("div");admin.className="navSection adminGroup";let open=localStorage.getItem("labaflow.sidebar.adminOpen")!=="0";const toggle=document.createElement("button");toggle.type="button";toggle.className="navGroupToggle";toggle.innerHTML='<span class="navIcon">A</span><span class="navText">Administration</span><span class="navChevron navText"></span>';const items=document.createElement("div");items.className="navGroupItems";adminButtons.forEach(b=>items.appendChild(b));const sync=()=>{admin.classList.toggle("open",open);items.style.display=open?"grid":"none";(toggle.querySelector(".navChevron") as HTMLElement).textContent=open?"⌄":"›"};toggle.onclick=()=>{open=!open;localStorage.setItem("labaflow.sidebar.adminOpen",open?"1":"0");sync()};sync();admin.append(toggle,items);nav.appendChild(admin)}
   nav.dataset.grouped="1";
  };
  enhance();const obs=new MutationObserver(enhance);obs.observe(document.body,{childList:true,subtree:true});return()=>{obs.disconnect();document.removeEventListener("click",captureDedicatedNav,true)}
 },[]);return null
}
