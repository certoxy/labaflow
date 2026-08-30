"use client";

import {FormEvent,useEffect,useState} from "react";
import {supabase} from "../../lib/supabase";

type LocalSession={token:string;expires_at:string;staff:{id:string;full_name:string;username:string;role:string};organization:{id:string;name:string;slug:string};branch:{id:string;name:string;code:string}|null};
const key="labaflow.local_staff_session";
const orgKey="labaflow.last_staff_org";
export default function StaffLoginPage(){
 const [org,setOrg]=useState(""),[username,setUsername]=useState(""),[pin,setPin]=useState(""),[message,setMessage]=useState(""),[busy,setBusy]=useState(false);
 useEffect(()=>{
  const params=new URLSearchParams(location.search);
  const fromUrl=(params.get("org")??"").toLowerCase().replace(/[^a-z0-9-]/g,"");
  const remembered=(localStorage.getItem(orgKey)??"").toLowerCase().replace(/[^a-z0-9-]/g,"");
  if(fromUrl){setOrg(fromUrl);localStorage.setItem(orgKey,fromUrl)}else if(remembered)setOrg(remembered);
  try{const raw=localStorage.getItem(key);if(!raw)return;const saved=JSON.parse(raw) as LocalSession;supabase.rpc("get_local_staff_session",{p_token:saved.token}).then(({data})=>{if(data){localStorage.setItem(key,JSON.stringify(data));location.replace("/dashboard")}else localStorage.removeItem(key)})}catch{localStorage.removeItem(key)}
 },[]);
 async function login(e:FormEvent){e.preventDefault();setBusy(true);setMessage("");const normalizedOrg=org.trim().toLowerCase();const {data,error}=await supabase.rpc("authenticate_local_staff",{p_organization_slug:normalizedOrg,p_username:username.trim().toLowerCase(),p_pin:pin});if(error){setBusy(false);setMessage(error.message);return}const session=data as LocalSession;await supabase.auth.signOut();localStorage.setItem(key,JSON.stringify(session));localStorage.setItem(orgKey,session.organization.slug||normalizedOrg);setBusy(false);location.replace("/dashboard")}
 return <main className="authPage"><section className="brandPanel"><div className="logoMark">LF</div><h1>LabaFlow</h1><p>Quick branch staff access.</p><div className="authBenefits"><span>No email required</span><span>Organization-based account</span><span>Username + permanent PIN</span><span>12-hour login session</span></div></section><section className="authCard"><p className="eyebrow">STAFF LOGIN</p><h2>Sign in to your organization</h2><p className="muted">Use your organization code, username, and permanent PIN. On this device, LabaFlow remembers the organization code for your next sign in.</p><form className="stack" onSubmit={login}><label>Organization Code<input value={org} onChange={e=>{const value=e.target.value.toLowerCase().replace(/[^a-z0-9-]/g,"");setOrg(value);localStorage.setItem(orgKey,value)}} placeholder="your-organization" autoCapitalize="none" required/></label><label>Username<input value={username} onChange={e=>setUsername(e.target.value.toLowerCase().replace(/[^a-z0-9._-]/g,""))} placeholder="maria" autoCapitalize="none" required/></label><label>Permanent PIN<input type="password" inputMode="numeric" value={pin} onChange={e=>setPin(e.target.value.replace(/\D/g,"").slice(0,8))} minLength={4} maxLength={8} placeholder="4-8 digits" required/><small className="muted">Your PIN stays the same until an administrator resets it. The 12-hour limit applies only to the login session.</small></label><button className="primary" disabled={busy}>{busy?"Signing in…":"Staff Sign In"}</button><button type="button" className="secondary" onClick={()=>location.href="/"}>Administrator Login</button></form>{message&&<p className="notice">{message}</p>}</section></main>
}
