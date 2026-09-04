"use client";

import {useEffect,useState} from "react";
import {createPortal} from "react-dom";
import {supabase} from "../lib/supabase";

type Branding={organization_name:string;organization_logo_url:string|null};

export default function CustomerBrandHeaderEnhancer(){
 const [host,setHost]=useState<HTMLElement|null>(null),[branding,setBranding]=useState<Branding|null>(null);
 useEffect(()=>{
  if(location.pathname!=="/customer")return;
  let mounted=true;const token=localStorage.getItem("labaflow_customer_access");if(token)supabase.rpc("get_customer_branding",{p_access_token:token}).then(({data})=>{if(mounted&&data)setBranding(data)});return()=>{mounted=false};
 },[]);
 useEffect(()=>{if(!branding)return;let mounted=true;const attach=()=>{const header=document.querySelector<HTMLElement>(".customerAppHeader");if(!header)return;let node=header.querySelector<HTMLElement>(".customerBrandHeaderHost");if(!node){node=document.createElement("div");node.className="customerBrandHeaderHost";header.prepend(node)}if(mounted)setHost(node)};attach();const observer=new MutationObserver(attach);observer.observe(document.body,{childList:true,subtree:true});return()=>{mounted=false;observer.disconnect()}},[branding]);
 if(!host||!branding)return null;
 return createPortal(<div className="customerAppIdentity"><div className="customerAppOrgLogo">{branding.organization_logo_url?<img src={branding.organization_logo_url} alt={`${branding.organization_name} logo`}/>:<span>LF</span>}</div><div><small>MY LABAFLOW</small><strong>{branding.organization_name}</strong></div></div>,host);
}
