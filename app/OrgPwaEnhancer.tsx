"use client";
import {useEffect,useMemo,useState} from "react";

type InstallPromptEvent=Event&{prompt:()=>Promise<void>;userChoice:Promise<{outcome:"accepted"|"dismissed";platform:string}>};

export default function OrgPwaEnhancer(){
 const [deferred,setDeferred]=useState<InstallPromptEvent|null>(null),[showHelp,setShowHelp]=useState(false),[installed,setInstalled]=useState(false),[eligible,setEligible]=useState(false),[dismissed,setDismissed]=useState(false);
 const standalone=useMemo(()=>typeof window!=="undefined"&&(window.matchMedia?.("(display-mode: standalone)").matches||(navigator as any).standalone===true),[]);
 useEffect(()=>{
  const path=location.pathname;
  const allowed=!path.startsWith("/customer")&&!path.startsWith("/receipt");
  setEligible(allowed);
  if(!allowed)return;
  const manifest=document.querySelector<HTMLLinkElement>('link[rel="manifest"]');
  if(manifest)manifest.href="/manifest.webmanifest";
  const apple=document.querySelector<HTMLLinkElement>('link[rel="apple-touch-icon"]');
  if(apple)apple.href="/labaflow-icon.svg";
  document.title=document.title==="My LabaFlow"?"LabaFlow":document.title;
  if(standalone){setInstalled(true);return}
  setDismissed(sessionStorage.getItem("labaflow.install-dismissed")==="1");
  const before=(e:Event)=>{e.preventDefault();setDeferred(e as InstallPromptEvent)};
  const done=()=>{setInstalled(true);setDeferred(null);setShowHelp(false)};
  window.addEventListener("beforeinstallprompt",before);window.addEventListener("appinstalled",done);
  return()=>{window.removeEventListener("beforeinstallprompt",before);window.removeEventListener("appinstalled",done)};
 },[standalone]);
 async function install(){
  if(deferred){await deferred.prompt();const result=await deferred.userChoice;if(result.outcome==="accepted")setInstalled(true);setDeferred(null);return}
  setShowHelp(true);
 }
 function dismiss(){sessionStorage.setItem("labaflow.install-dismissed","1");setDismissed(true)}
 if(!eligible||installed||dismissed)return null;
 return <><aside className="orgInstallCard" role="region" aria-label="Install LabaFlow"><img src="/labaflow-icon.svg" alt=""/><div><strong>Install LabaFlow</strong><span>Run your laundry operations like a regular app.</span></div><button className="orgInstallAction" type="button" onClick={install}>{deferred?"Install":"How to Install"}</button><button className="orgInstallDismiss" type="button" onClick={dismiss} aria-label="Dismiss install prompt">×</button></aside>{showHelp&&<div className="orgInstallBackdrop" onClick={()=>setShowHelp(false)}><section className="orgInstallSheet" onClick={e=>e.stopPropagation()}><div className="orgInstallHandle"/><header><div><small>LABAFLOW BUSINESS</small><h2>Install LabaFlow</h2></div><button type="button" onClick={()=>setShowHelp(false)}>×</button></header><ol><li>On <strong>Android/Chrome</strong>, open the browser menu and choose <strong>Install app</strong> or <strong>Add to Home screen</strong>.</li><li>On <strong>iPhone/iPad</strong>, open in Safari, tap <strong>Share</strong>, then <strong>Add to Home Screen</strong>.</li><li>On desktop Chrome or Edge, use the <strong>Install</strong> icon in the address bar.</li><li>Confirm the app name <strong>LabaFlow</strong>.</li></ol><button className="primary orgInstallDone" type="button" onClick={()=>setShowHelp(false)}>Got it</button></section></div>}</>
}
