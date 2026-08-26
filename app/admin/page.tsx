"use client";

import { useEffect, useState } from "react";
import { supabase } from "../../lib/supabase";

type Org={id:string;name:string;slug:string;active:boolean;created_at:string};
type Admin={user_id:string;email:string;full_name:string|null;active:boolean;granted_at:string};

export default function PlatformAdminPage(){
  const [orgs,setOrgs]=useState<Org[]>([]),[admins,setAdmins]=useState<Admin[]>([]),[message,setMessage]=useState(""),[email,setEmail]=useState("");
  useEffect(()=>{load()},[]);
  async function load(){const {data,error}=await supabase.rpc("get_platform_admin_context");if(error){setMessage(error.message);return}setOrgs(data?.organizations??[]);setAdmins(data?.platform_admins??[])}
  async function bootstrap(){const {error}=await supabase.rpc("bootstrap_first_platform_admin");setMessage(error?error.message:"Platform administrator enabled.");if(!error)await load()}
  async function toggle(org:Org){const {error}=await supabase.rpc("set_organization_active",{p_organization_id:org.id,p_active:!org.active});if(error)setMessage(error.message);else await load()}
  async function grant(){const {error}=await supabase.rpc("grant_platform_admin",{p_email:email});setMessage(error?error.message:"Platform administrator added.");if(!error){setEmail("");await load()}}
  return <main className="workspace"><p className="eyebrow">PLATFORM ADMINISTRATION</p><h1>LabaFlow Tenants</h1>{message&&<p className="notice">{message}</p>}<div className="adminToolbar"><button className="secondary" onClick={bootstrap}>Bootstrap First Platform Admin</button><div className="scanBar"><input placeholder="Existing LabaFlow user email" value={email} onChange={e=>setEmail(e.target.value)}/><button className="primary" onClick={grant}>Add Platform Admin</button></div></div><section className="panel"><h2>Organizations</h2>{orgs.map(o=><div className="adminRow" key={o.id}><div><strong>{o.name}</strong><small>{o.slug}</small></div><span className={o.active?"status active":"status inactive"}>{o.active?"Active":"Suspended"}</span><button className="miniBtn" onClick={()=>toggle(o)}>{o.active?"Suspend":"Activate"}</button></div>)}</section><section className="panel"><h2>Platform Administrators</h2>{admins.map(a=><div className="adminRow" key={a.user_id}><div><strong>{a.full_name||a.email}</strong><small>{a.email}</small></div><span className={a.active?"status active":"status inactive"}>{a.active?"Active":"Inactive"}</span></div>)}</section></main>;
}
