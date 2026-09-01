"use client";
import {useEffect} from "react";
import {supabase} from "../lib/supabase";

export default function AdminSubpagesEnhancer(){
 useEffect(()=>{
  let qrEnabled=true;
  void supabase.rpc("get_current_access_context").then(({data})=>{qrEnabled=data?.features?.qr_customer_id!==false;enhance()});
  const enhance=()=>{
   const path=location.pathname;
   const main=document.querySelector<HTMLElement>("main.workspace");
   if(!main)return;
   main.classList.remove("adminSubpage","paymentSettingsPage","loyaltyLevelsPage","promoCodesPage","pickupDeliveryPage");
   if(path==="/organization"&&qrEnabled){
    const actions=main.querySelector<HTMLElement>(":scope > .panelHead .headerActions");
    if(actions&&!actions.querySelector('[data-customer-qr-link="1"]')){
      const btn=document.createElement("button");btn.className="primary";btn.type="button";btn.dataset.customerQrLink="1";btn.textContent="Customer QR";btn.onclick=()=>{location.href="/organization/customer-qr"};actions.prepend(btn)
    }
   }else if(path==="/organization"){main.querySelector('[data-customer-qr-link="1"]')?.remove()}
   if(path==="/organization/payments"){main.classList.add("adminSubpage","paymentSettingsPage");const btn=Array.from(main.querySelectorAll<HTMLButtonElement>("button.miniBtn")).find(b=>/Enabled|Disabled/.test(b.textContent||""));if(btn){btn.classList.add("compactToggleBtn");btn.classList.toggle("on",/Enabled/.test(btn.textContent||""));btn.textContent=/Enabled/.test(btn.textContent||"")?"On":"Off"}const card=main.querySelector<HTMLElement>(".customerCard");if(card)card.classList.add("gcashPreview")}
   if(path==="/organization/loyalty-levels"){main.classList.add("adminSubpage","loyaltyLevelsPage");const checkbox=main.querySelector<HTMLInputElement>('input[type="checkbox"]');const lab=checkbox?.closest("label");if(lab){lab.classList.add("loyaltyActiveToggle");const span=lab.querySelector("span");if(span)span.childNodes.forEach(n=>{if(n.nodeType===Node.TEXT_NODE)n.textContent="Active"})}}
   if(path==="/organization/promos"){main.classList.add("adminSubpage","promoCodesPage");main.querySelectorAll<HTMLButtonElement>(".adminRow .miniBtn").forEach(btn=>{if(/Enable|Disable/.test(btn.textContent||"")){const on=/Disable/.test(btn.textContent||"");btn.classList.add("compactToggleBtn");btn.classList.toggle("on",on);btn.textContent=on?"On":"Off"}})}
   if(path==="/pickup-delivery")main.classList.add("pickupDeliveryPage");
   if(path==="/admin/subscriptions"){const actions=main.querySelector<HTMLElement>(":scope > .panelHead .headerActions");if(actions&&!actions.querySelector('[data-upgrade-requests-link="1"]')){const btn=document.createElement("button");btn.className="primary";btn.type="button";btn.dataset.upgradeRequestsLink="1";btn.textContent="Upgrade Requests";btn.onclick=()=>{location.href="/admin/upgrade-requests"};actions.prepend(btn)}}
  };
  enhance();const obs=new MutationObserver(enhance);obs.observe(document.body,{childList:true,subtree:true,characterData:true});return()=>obs.disconnect()
 },[]);return null
}
