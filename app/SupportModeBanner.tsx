"use client";
import {useEffect,useState} from "react";
import {supabase} from "../lib/supabase";
type Support={id:string;organization_name:string;expires_at:string};
export default function SupportModeBanner(){
 const [session,setSession]=useState<Support|null>(null),[remaining,setRemaining]=useState("");
 useEffect(()=>{let mounted=true;const check=async()=>{const {data}=await supabase.rpc("get_active_platform_support_session");if(!mounted)return;setSession(data??null);document.body.classList.toggle("platformSupportMode",Boolean(data));if(data)void supabase.rpc("log_platform_support_activity",{p_path:location.pathname})};void check();const id=setInterval(check,30000);return()=>{mounted=false;clearInterval(id);document.body.classList.remove("platformSupportMode")}},[]);
 useEffect(()=>{if(!session)return;const tick=()=>{const seconds=Math.max(0,Math.ceil((new Date(session.expires_at).getTime()-Date.now())/1000));setRemaining(`${Math.floor(seconds/60)}:${String(seconds%60).padStart(2,"0")}`);if(seconds===0){document.body.classList.remove("platformSupportMode");location.href="/admin"}};tick();const id=setInterval(tick,1000);return()=>clearInterval(id)},[session]);
 async function exit(){await supabase.rpc("end_platform_support_session");document.body.classList.remove("platformSupportMode");location.href="/admin"}
 if(!session)return null;
 return <div className="supportModeBanner"><div><strong>Platform Support Mode</strong><span>Viewing {session.organization_name} · read-only · expires in {remaining}</span></div><button className="supportExit" onClick={exit}>Return to Platform Admin</button></div>
}
