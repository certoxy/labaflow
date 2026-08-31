"use client";

import {useEffect,useState} from "react";
import {supabase} from "../lib/supabase";

type Branding={organization_id?:string;organization_name?:string;organization_logo_url?:string|null;branch_id?:string|null;branch_name?:string|null;branch_logo_url?:string|null}|null;
const localStaffKey="labaflow.local_staff_session";
const customerKey="labaflow_customer_access";

function preferredLogo(b:Branding){return b?.branch_logo_url||b?.organization_logo_url||null}
function preferredName(b:Branding){return b?.branch_name||b?.organization_name||null}

export default function BrandingEnhancer(){
 const [branding,setBranding]=useState<Branding>(null);
 useEffect(()=>{
  let mounted=true;
  async function resolve(){
   try{
    const path=location.pathname;
    const orderId=new URLSearchParams(location.search).get("id");
    let localToken:string|null=null;
    try{const raw=localStorage.getItem(localStaffKey);if(raw)localToken=JSON.parse(raw)?.token??null}catch{}
    if(orderId&&(path==="/receipt"||path==="/order-details")){
     const {data}=await supabase.rpc("get_receipt_branding",{p_order_id:orderId,p_staff_token:localToken||null});if(mounted&&data){setBranding(data);return}
    }
    if(path.startsWith("/customer/join")){
     const token=new URLSearchParams(location.search).get("org");if(token){const {data}=await supabase.rpc("get_enrollment_branding",{p_token:token});if(mounted&&data){setBranding(data);return}}
    }
    if(path.startsWith("/customer")){
     const token=localStorage.getItem(customerKey);if(token){const {data}=await supabase.rpc("get_customer_branding",{p_access_token:token});if(mounted&&data){setBranding(data);return}}
    }
    if(localToken){const {data}=await supabase.rpc("get_local_staff_branding",{p_token:localToken});if(mounted&&data){setBranding(data);return}}
    const {data:session}=await supabase.auth.getSession();if(session.session){const {data}=await supabase.rpc("get_my_branding_context");if(mounted&&data)setBranding(data)}
   }catch{}
  }
  resolve();
  const onBranding=(e:Event)=>{const detail=(e as CustomEvent).detail as Branding;if(detail)setBranding(detail)};
  window.addEventListener("labaflow:branding",onBranding);
  return()=>{mounted=false;window.removeEventListener("labaflow:branding",onBranding)};
 },[]);

 useEffect(()=>{
  const logo=preferredLogo(branding),name=preferredName(branding);if(!logo)return;
  const apply=()=>{
   document.querySelectorAll<HTMLImageElement>('img[src="/labaflow-icon.svg"]:not([data-labaflow-powered])').forEach(img=>{img.src=logo;img.dataset.tenantLogo="1";img.alt=name||"Business logo"});
   document.querySelectorAll<HTMLElement>(".logoMark,.customerPortalLogo").forEach(el=>{if(el.closest("[data-labaflow-powered]"))return;el.innerHTML=`<img src="${logo.replaceAll('"','&quot;')}" alt="${(name||"Business logo").replaceAll('"','&quot;')}"/>`;el.classList.add("tenantLogoMark")});
   const sidebarName=document.querySelector<HTMLElement>("[data-shared-sidebar] .brand .navText strong");if(sidebarName&&name)sidebarName.textContent=name;
  };
  apply();const observer=new MutationObserver(apply);observer.observe(document.body,{childList:true,subtree:true});return()=>observer.disconnect();
 },[branding]);

 return <footer className="labaflowPoweredFooter" data-labaflow-powered>
  <img src="/labaflow-icon.svg" alt="LabaFlow" data-labaflow-powered/>
  <span>Powered by <a href="https://labaflow.paotechs.com" target="_blank" rel="noreferrer">LabaFlow</a> · labaflow.paotechs.com · © 2026 PAO Technologies. All rights reserved.</span>
 </footer>;
}
