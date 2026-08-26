"use client";

import { FormEvent, useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "../../lib/supabase";

type Invitation={email:string;role:string;organization:{id:string;name:string;slug:string};branch:{id:string;name:string;code:string}|null;expires_at:string};

export default function JoinPage(){
  const [session,setSession]=useState<Session|null>(null),[checking,setChecking]=useState(true),[invite,setInvite]=useState<Invitation|null>(null),[message,setMessage]=useState("");
  const [email,setEmail]=useState(""),[password,setPassword]=useState("");
  const token=typeof window!=="undefined"?new URLSearchParams(window.location.search).get("invite")??"":"";

  useEffect(()=>{supabase.auth.getSession().then(({data})=>{setSession(data.session);setChecking(false)});const {data}=supabase.auth.onAuthStateChange((_e,s)=>setSession(s));return()=>data.subscription.unsubscribe()},[]);
  useEffect(()=>{if(token)loadInvite()},[token]);

  async function loadInvite(){const {data,error}=await supabase.rpc("get_invitation_details",{p_token:token});if(error){setMessage(error.message);return}setInvite(data as Invitation);setEmail((data as Invitation).email)}
  async function signIn(e:FormEvent){e.preventDefault();setMessage("");const {error}=await supabase.auth.signInWithPassword({email:email.trim(),password});if(error)setMessage(error.message)}
  async function signUp(){setMessage("");if(password.length<8){setMessage("Use a password with at least 8 characters.");return}const {error}=await supabase.auth.signUp({email:email.trim(),password});setMessage(error?error.message:"Account created. Confirm your email if required, then return to this invitation link and sign in.")}
  async function accept(){if(!session){setMessage("Sign in first to accept the invitation.");return}const {error}=await supabase.rpc("accept_organization_invitation",{p_token:token});if(error){setMessage(error.message);return}window.location.href="/"}

  if(checking)return <main className="center"><div className="loader">Loading invitation…</div></main>;
  if(!token)return <main className="onboarding"><section className="onboardCard"><h1>Invitation link required</h1><p className="muted">Open the invitation link supplied by your LabaFlow administrator.</p></section></main>;
  if(!invite)return <main className="onboarding"><section className="onboardCard"><h1>LabaFlow invitation</h1>{message?<p className="notice">{message}</p>:<p className="muted">Checking invitation…</p>}</section></main>;

  return <main className="authPage"><section className="brandPanel"><div className="logoMark">LF</div><h1>Join LabaFlow</h1><p>{invite.organization.name}</p><div className="inviteSummary"><strong>{invite.role.replaceAll("_"," ")}</strong><span>{invite.branch?`${invite.branch.name} (${invite.branch.code})`:"Organization-wide assignment"}</span><small>Invitation expires {new Date(invite.expires_at).toLocaleString()}</small></div></section><section className="authCard"><p className="eyebrow">STAFF INVITATION</p><h2>{session?"Accept your invitation":"Sign in or create your account"}</h2><p className="muted">This invitation is for <strong>{invite.email}</strong>.</p>{!session?<form onSubmit={signIn} className="stack"><label>Email<input type="email" value={email} readOnly/></label><label>Password<input type="password" value={password} onChange={e=>setPassword(e.target.value)} required/></label><button className="primary">Sign In</button><button type="button" className="secondary" onClick={signUp}>Create Account</button></form>:<div className="stack"><div className="inviteAcceptBox"><span>Signed in as</span><strong>{session.user.email}</strong></div><button className="primary" onClick={accept}>Accept Invitation</button><button className="secondary" onClick={()=>supabase.auth.signOut()}>Use Different Account</button></div>}{message&&<p className="notice">{message}</p>}</section></main>;
}
