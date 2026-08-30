"use client";
import {useCallback,useEffect,useRef,useState} from "react";
import {usePathname} from "next/navigation";
import {supabase} from "../lib/supabase";
import {addHistory,getResolved,jobs,removeJob,setResolved,updateJob} from "../lib/offlineQueue";
import {currentOfflineScope} from "../lib/offlineScope";

export default function OfflineEnhancer(){
  const pathname=usePathname();
  const isCustomerRoute=pathname?.startsWith("/customer")??false;
  const [online,setOnline]=useState(true),[pending,setPending]=useState(0),[syncing,setSyncing]=useState(false),syncingRef=useRef(false);
  const refresh=useCallback(async()=>{try{const scope=await currentOfflineScope();setPending(scope?(await jobs(scope)).length:0)}catch{}},[]);
  const sync=useCallback(async()=>{if(!navigator.onLine||syncingRef.current)return;const scope=await currentOfflineScope();if(!scope)return;syncingRef.current=true;setSyncing(true);try{for(const job of await jobs(scope)){await updateJob({...job,scope,status:"syncing",error:undefined});let error:any=null,data:any=null,payload={...job.payload};if(job.dependsOn){const resolved=await getResolved(job.dependsOn);if(!resolved){await updateJob({...job,scope,status:"pending",error:"Waiting for related offline record to synchronize."});continue}if(job.kind==="create_order"&&payload.p_customer_id===job.dependsOn)payload.p_customer_id=resolved}if(job.kind==="create_order")({data,error}=await supabase.rpc("sync_offline_order",{p_operation_id:job.id,...payload}));else if(job.kind==="update_order_status")({data,error}=await supabase.rpc("sync_offline_order_status",{p_operation_id:job.id,...payload}));else if(job.kind==="record_cash_payment")({data,error}=await supabase.rpc("sync_offline_cash_payment",{p_operation_id:job.id,...payload}));else if(job.kind==="create_customer")({data,error}=await supabase.rpc("sync_offline_customer",{p_operation_id:job.id,...payload}));if(error){await updateJob({...job,scope,status:"failed",error:error.message});continue}if(job.kind==="create_customer"){const serverId=data?.customer?.id??data?.id;if(serverId)await setResolved(job.id,serverId)}await addHistory({id:job.id,kind:job.kind,syncedAt:new Date().toISOString(),scope});await removeJob(job.id);window.dispatchEvent(new CustomEvent("labaflow:offline-synced",{detail:{operationId:job.id,kind:job.kind,scope}}))}}finally{syncingRef.current=false;setSyncing(false);await refresh()}},[refresh]);
  useEffect(()=>{
    setOnline(navigator.onLine);refresh();
    const on=()=>{setOnline(true);setTimeout(()=>sync(),300)},off=()=>setOnline(false),changed=()=>refresh();
    window.addEventListener("online",on);window.addEventListener("offline",off);window.addEventListener("labaflow:queue-changed",changed);
    if("serviceWorker" in navigator){
      navigator.serviceWorker.register("/sw.js",{updateViaCache:"none"}).then(async registration=>{
        try{await registration.update()}catch{}
      }).catch(console.error);
      const controllerChanged=()=>{
        if(sessionStorage.getItem("labaflow.sw-reloaded")==="1")return;
        sessionStorage.setItem("labaflow.sw-reloaded","1");
        location.reload();
      };
      navigator.serviceWorker.addEventListener("controllerchange",controllerChanged,{once:true});
    }
    if(navigator.onLine)setTimeout(()=>sync(),800);
    return()=>{window.removeEventListener("online",on);window.removeEventListener("offline",off);window.removeEventListener("labaflow:queue-changed",changed)}
  },[refresh,sync]);
  if(isCustomerRoute)return null;
  const text=!online?`● Offline${pending?` · ${pending} pending sync`:""}`:syncing?`↻ Syncing ${pending} change${pending===1?"":"s"}…`:pending?`● Online · ${pending} pending sync`:"● Online";
  return <div className="connectionBadge" data-online={online?"true":"false"} data-pending={pending>0?"true":"false"} aria-live="polite" onClick={()=>location.href="/sync"} title={text} style={{cursor:"pointer",position:"fixed",right:16,bottom:16,zIndex:9999,padding:"8px 12px",borderRadius:999,fontSize:13,fontWeight:700,boxShadow:"0 4px 18px rgba(0,0,0,.15)",background:online&&!pending?"#ecfdf5":"#fff7ed",color:online&&!pending?"#065f46":"#9a3412",border:`1px solid ${online&&!pending?"#a7f3d0":"#fed7aa"}`}}><span className="connectionText">{text}</span></div>
}
