"use client";

import {FormEvent,useEffect,useState} from "react";
import {supabase} from "../lib/supabase";

type Context={organization?:{id:string;name:string}|null};

export default function HomePage(){
 const [checking,setChecking]=useState(true);
 const [email,setEmail]=useState("");
 const [password,setPassword]=useState("");
 const [message,setMessage]=useState("");
 const [needsOrganization,setNeedsOrganization]=useState(false);
 const [orgForm,setOrgForm]=useState({name:"",slug:"",branch_name:"Main Branch",branch_code:"MAIN"});

 useEffect(()=>{void initialize()},[]);
 async function initialize(){
  const {data}=await supabase.auth.getSession();
  if(!data.session){setChecking(false);return}
  if(!navigator.onLine){location.replace("/dashboard");return}
  const [context,access]=await Promise.all([supabase.rpc("get_my_labaflow_context"),supabase.rpc("get_current_access_context")]);
  if(context.error||access.error){setMessage(context.error?.message||access.error?.message||"Unable to load workspace");setChecking(false);return}
  const c=(context.data??{}) as Context;
  if(access.data?.has_membership&&c.organization){location.replace("/dashboard");return}
  setNeedsOrganization(true);setChecking(false)
 }
 async function signIn(e:FormEvent){e.preventDefault();setMessage("");const {error}=await supabase.auth.signInWithPassword({email:email.trim(),password});if(error){setMessage(error.message);return}location.replace("/dashboard")}
 async function signUp(){if(!email.trim()||password.length<8){setMessage("Enter an email and a password with at least 8 characters.");return}const {error}=await supabase.auth.signUp({email:email.trim(),password});setMessage(error?error.message:"Account created. Confirm your email if required, then sign in.")}
 async function createOrganization(e:FormEvent){e.preventDefault();const {error}=await supabase.rpc("create_organization_with_main_branch",{p_name:orgForm.name,p_slug:orgForm.slug,p_branch_name:orgForm.branch_name,p_branch_code:orgForm.branch_code});if(error){setMessage(error.message);return}location.replace("/dashboard")}
 if(checking)return <main className="center"><div className="loader">Loading LabaFlow…</div></main>;
 if(needsOrganization)return <main className="onboarding"><section className="onboardCard"><p className="eyebrow">FIRST-TIME SETUP</p><h1>Create your LabaFlow organization</h1><p className="muted">Set up your organization and first branch to begin.</p><form onSubmit={createOrganization} className="stack"><label>Organization Name<input value={orgForm.name} onChange={e=>setOrgForm(x=>({...x,name:e.target.value}))} required/></label><label>Organization Slug<input value={orgForm.slug} onChange={e=>setOrgForm(x=>({...x,slug:e.target.value.toLowerCase().replace(/[^a-z0-9-]/g,"-" )}))} required/></label><label>Main Branch Name<input value={orgForm.branch_name} onChange={e=>setOrgForm(x=>({...x,branch_name:e.target.value}))} required/></label><label>Branch Code<input value={orgForm.branch_code} onChange={e=>setOrgForm(x=>({...x,branch_code:e.target.value.toUpperCase()}))} required/></label><button className="primary">Create Organization</button></form>{message&&<p className="notice">{message}</p>}</section></main>;
 return <main className="authPage"><section className="brandPanel"><div className="logoMark">LF</div><h1>LabaFlow</h1><p>Laundry management, simplified.</p></section><section className="authCard"><p className="eyebrow">WELCOME</p><h2>Sign in to your laundry workspace</h2><form onSubmit={signIn} className="stack"><label>Email<input type="email" value={email} onChange={e=>setEmail(e.target.value)} required/></label><label>Password<input type="password" value={password} onChange={e=>setPassword(e.target.value)} required/></label><button className="primary">Sign In</button><button type="button" className="secondary" onClick={signUp}>Create Account</button></form>{message&&<p className="notice">{message}</p>}</section></main>
}
