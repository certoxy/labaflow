"use client";

import {useEffect,useState} from "react";
import {createPortal} from "react-dom";

const apkUrl="https://github.com/certoxy/labaflow/releases/download/android-staging/LabaFlow-Staging-Android.apk";

export default function AndroidAppDownloadEnhancer(){
 const [host,setHost]=useState<HTMLElement|null>(null);
 useEffect(()=>{if(location.pathname!=="/organization")return;let mounted=true;const find=()=>{const head=document.querySelector<HTMLElement>(".orgAdminPage .panelHead");if(head&&!document.getElementById("android-app-download-host")){const node=document.createElement("div");node.id="android-app-download-host";head.insertAdjacentElement("afterend",node);if(mounted)setHost(node)}};find();const observer=new MutationObserver(find);observer.observe(document.body,{childList:true,subtree:true});return()=>{mounted=false;observer.disconnect()}},[]);
 if(!host)return null;
 return createPortal(<section className="panel"><div className="panelHead"><div><p className="eyebrow">ANDROID STAFF APP</p><h2>Download LabaFlow for Android</h2><span>Install the staging app for native Bluetooth receipt printing without the browser print dialog.</span></div><span className="status active">Pilot</span></div><div className="actions" style={{marginTop:18}}><a className="primary" href={apkUrl} download>Download Android APK</a><button className="secondary" onClick={()=>location.href="/organization/printer"}>Printer Settings</button></div><p className="muted" style={{marginTop:14}}>Android may ask you to allow installation from your browser. This pilot connects to LabaFlow Staging and is intended for testing before Play Store release.</p></section>,host);
}
