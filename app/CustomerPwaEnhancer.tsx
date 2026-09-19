"use client";
import {useEffect} from "react";

export default function CustomerPwaEnhancer(){
 useEffect(()=>{
  const isCustomer=location.pathname==="/customer"||location.pathname.startsWith("/customer/");
  if(!isCustomer)return;
  const manifest=document.querySelector<HTMLLinkElement>('link[rel="manifest"]');if(manifest)manifest.href="/customer-manifest.webmanifest";else{const link=document.createElement("link");link.rel="manifest";link.href="/customer-manifest.webmanifest";document.head.appendChild(link)}
  let apple=document.querySelector<HTMLLinkElement>('link[rel="apple-touch-icon"]');if(apple)apple.href="/my-labaflow-icon.svg";else{apple=document.createElement("link");apple.rel="apple-touch-icon";apple.href="/my-labaflow-icon.svg";document.head.appendChild(apple)}
  document.title="My LabaFlow";
  const meta=document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');if(meta)meta.content="#0ea5c6";
 },[]);
 return null;
}
