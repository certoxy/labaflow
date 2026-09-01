"use client";
import {useEffect,useState} from "react";
import {createPortal} from "react-dom";
import {supabase} from "../lib/supabase";
type Trial={status:string;plan_name:string|null;trial_ends_at:string;in_trial:boolean;trial_expired:boolean;can_manage_subscription:boolean};
const excluded=(path:string)=>path==="/"||path.startsWith("/admin")||path.startsWith("/join")||path.startsWith("/staff-login")||path.startsWith("/my-labaflow")||path.startsWith("/receipt");
export default function TrialCountdownEnhancer(){
 const [trial,setTrial]=useState<Trial|null>(null),[mount,setMount]=useState<HTMLElement|null>(null),[now,setNow]=useState(Date.now());
 useEffect(()=>{if(excluded(location.pathname))return;let alive=true;void supabase.auth.getSession().then(async({data})=>{if(!data.session)return;const r=await supabase.rpc("get_my_subscription_status");if(alive&&!r.error)setTrial(r.data)});const find=()=>{const main=document.querySelector<HTMLElement>("main.workspace");if(!main)return;let node=main.querySelector<HTMLElement>(":scope > .trialCountdownMount");if(!node){node=document.createElement("div");node.className="trialCountdownMount";main.prepend(node)}setMount(node)};find();const observer=new MutationObserver(find);observer.observe(document.body,{childList:true,subtree:true});const clock=window.setInterval(()=>setNow(Date.now()),1000);return()=>{alive=false;observer.disconnect();window.clearInterval(clock)}},[]);
 if(!mount||!trial||(!trial.in_trial&&!trial.trial_expired))return null;
 const remaining=Math.max(0,new Date(trial.trial_ends_at).getTime()-now),days=Math.floor(remaining/86400000),hours=Math.floor(remaining%86400000/3600000),minutes=Math.floor(remaining%3600000/60000),seconds=Math.floor(remaining%60000/1000),urgent=remaining<=86400000,warning=remaining<=7*86400000;
 const countdown=warning?`${days}d ${hours}h ${minutes}m ${seconds}s`:`${Math.ceil(remaining/86400000)} days`;
 return createPortal(<section className={`trialCountdown ${trial.trial_expired?"expired":urgent?"urgent":warning?"warning":"standard"}`}><div><strong>{trial.trial_expired?"Your free trial has expired":`Free trial: ${countdown} remaining`}</strong><span>{trial.trial_expired?"Existing data and reports remain available. Activate a subscription to create new transactions.":`Trial ends ${new Date(trial.trial_ends_at).toLocaleString()}.`}</span></div>{trial.can_manage_subscription&&<button type="button" onClick={()=>location.href="/organization/subscription"}>Upgrade Plan</button>}</section>,mount)
}
