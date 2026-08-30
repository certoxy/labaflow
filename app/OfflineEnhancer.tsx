"use client";

import {useCallback,useEffect,useState} from "react";
import {supabase} from "../lib/supabase";
import {jobs,removeJob,updateJob} from "../lib/offlineQueue";

export default function OfflineEnhancer(){
 const [online,setOnline]=useState(true),[pending,setPending]=useState(0),[syncing,setSyncing]=useState(false);
 const refresh=useCallback(async()=>{try{setPending((await jobs()).length)}catch{}},[]);
 const sync=useCallback(async()=>{
  if(!navigator.onLine||syncing)return;
  setSyncing(true);
  try{
   for(const job of await jobs()){
    if(job.kind!=="create_order")continue;
    await updateJob({...job,status:"syncing",error:undefined});
    const {error}=await supabase.rpc("create_laundry_order",job.payload);
    if(error){await updateJob({...job,status:"failed",error:error.message});continue}
    await removeJob(job.id);
   }
  }finally{setSyncing(false);await refresh()}
 },[refresh,syncing]);
 useEffect(()=>{
  setOnline(navigator.onLine);refresh();
  const on=()=>{setOnline(true);setTimeout(()=>sync(),300)},off=()=>setOnline(false),changed=()=>refresh();
  window.addEventListener("online",on);window.addEventListener("offline",off);window.addEventListener("labaflow:queue-changed",changed);
  if("serviceWorker" in navigator)navigator.serviceWorker.register("/sw.js").catch(console.error);
  if(navigator.onLine)setTimeout(()=>sync(),800);
  return()=>{window.removeEventListener("online",on);window.removeEventListener("offline",off);window.removeEventListener("labaflow:queue-changed",changed)};
 },[refresh,sync]);
 const text=!online?`● Offline${pending?` · ${pending} pending sync`:""}`:syncing?`↻ Syncing ${pending} change${pending===1?"":"s"}…`:pending?`● Online · ${pending} pending sync`:"● Online";
 return <div aria-live="polite" title={pending?"Queued changes automatically sync when internet is available.":undefined} style={{position:"fixed",right:16,bottom:16,zIndex:9999,padding:"8px 12px",borderRadius:999,fontSize:13,fontWeight:700,boxShadow:"0 4px 18px rgba(0,0,0,.15)",background:online&&!pending?"#ecfdf5":"#fff7ed",color:online&&!pending?"#065f46":"#9a3412",border:`1px solid ${online&&!pending?"#a7f3d0":"#fed7aa"}`}}>{text}</div>;
}
