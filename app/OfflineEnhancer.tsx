"use client";

import {useEffect,useState} from "react";

export default function OfflineEnhancer(){
 const [online,setOnline]=useState(true);
 useEffect(()=>{
  setOnline(navigator.onLine);
  const on=()=>setOnline(true),off=()=>setOnline(false);
  window.addEventListener("online",on);window.addEventListener("offline",off);
  if("serviceWorker" in navigator){navigator.serviceWorker.register("/sw.js").catch(console.error)}
  return()=>{window.removeEventListener("online",on);window.removeEventListener("offline",off)};
 },[]);
 return <div aria-live="polite" style={{position:"fixed",right:16,bottom:16,zIndex:9999,padding:"8px 12px",borderRadius:999,fontSize:13,fontWeight:700,boxShadow:"0 4px 18px rgba(0,0,0,.15)",background:online?"#ecfdf5":"#fff7ed",color:online?"#065f46":"#9a3412",border:`1px solid ${online?"#a7f3d0":"#fed7aa"}`}}>{online?"● Online":"● Offline · changes requiring server sync are unavailable"}</div>;
}