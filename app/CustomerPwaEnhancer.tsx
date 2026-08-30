"use client";
import {useEffect,useMemo,useState} from "react";

type InstallPromptEvent=Event&{prompt:()=>Promise<void>;userChoice:Promise<{outcome:"accepted"|"dismissed";platform:string}>};

export default function CustomerPwaEnhancer(){
 const [deferred,setDeferred]=useState<InstallPromptEvent|null>(null),[showIos,setShowIos]=useState(false),[installed,setInstalled]=useState(false),[customerRoute,setCustomerRoute]=useState(false);
 const standalone=useMemo(()=>typeof window!=="undefined"&&(window.matchMedia?.("(display-mode: standalone)").matches||(navigator as any).standalone===true),[]);
 useEffect(()=>{
  const isCustomer=location.pathname.startsWith("/customer");setCustomerRoute(isCustomer);if(!isCustomer)return;
  const manifest=document.querySelector<HTMLLinkElement>('link[rel="manifest"]');if(manifest)manifest.href="/customer-manifest.webmanifest";else{const link=document.createElement("link");link.rel="manifest";link.href="/customer-manifest.webmanifest";document.head.appendChild(link)}
  document.title="My LabaFlow";
  const meta=document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');if(meta)meta.content="#0d405e";
  if(standalone){setInstalled(true);return}
  const before=(e:Event)=>{e.preventDefault();setDeferred(e as InstallPromptEvent)};
  const done=()=>{setInstalled(true);setDeferred(null);setShowIos(false)};
  window.addEventListener("beforeinstallprompt",before);window.addEventListener("appinstalled",done);
  return()=>{window.removeEventListener("beforeinstallprompt",before);window.removeEventListener("appinstalled",done)};
 },[standalone]);
 async function install(){if(deferred){await deferred.prompt();const result=await deferred.userChoice;if(result.outcome==="accepted")setInstalled(true);setDeferred(null);return}const ua=navigator.userAgent.toLowerCase(),ios=/iphone|ipad|ipod/.test(ua);if(ios)setShowIos(true);else setShowIos(true)}
 if(!customerRoute||installed)return null;
 return <><aside className="customerInstallCard" role="region" aria-label="Install My LabaFlow"><div className="customerInstallIcon">LF</div><div><strong>Install My LabaFlow</strong><span>Open orders and rewards like a regular app.</span></div><button type="button" onClick={install}>{deferred?"Install":"How to Install"}</button></aside>{showIos&&<div className="customerInstallBackdrop" onClick={()=>setShowIos(false)}><section className="customerInstallSheet" onClick={e=>e.stopPropagation()}><div className="sheetHandle"/><div className="customerInstallSheetHead"><div><small>MY LABAFLOW</small><h2>Add to Home Screen</h2></div><button type="button" onClick={()=>setShowIos(false)}>×</button></div><ol><li>Open this page in <strong>Safari</strong> on iPhone/iPad, or <strong>Chrome</strong> on Android.</li><li>Tap the browser <strong>Share/Menu</strong> button.</li><li>Choose <strong>Add to Home Screen</strong> or <strong>Install app</strong>.</li><li>Confirm <strong>My LabaFlow</strong>.</li></ol><button className="primary customerInstallDone" type="button" onClick={()=>setShowIos(false)}>Got it</button></section></div>}</>
}
