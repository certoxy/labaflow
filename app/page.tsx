"use client";

import { FormEvent, useEffect, useMemo, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "../lib/supabase";

type Branch={id:string;code:string;name:string;address:string|null};
type Customer={id:string;customer_code:string;full_name:string;mobile:string|null;email:string|null;loyalty_points:number;lifetime_visits:number;lifetime_spend:number;created_at:string};
type Context={profile?:{full_name:string|null;email:string};organization?:{id:string;name:string;slug:string}|null;membership?:{role:string}|null;branches?:Branch[];settings?:Record<string,unknown>};

type View="dashboard"|"customers"|"loyalty"|"settings";

export default function Home(){
  const [session,setSession]=useState<Session|null>(null);
  const [checking,setChecking]=useState(true);
  const [email,setEmail]=useState("");
  const [password,setPassword]=useState("");
  const [message,setMessage]=useState("");
  const [context,setContext]=useState<Context>({});
  const [view,setView]=useState<View>("dashboard");
  const [customers,setCustomers]=useState<Customer[]>([]);
  const [showCustomer,setShowCustomer]=useState(false);
  const [customerForm,setCustomerForm]=useState({full_name:"",mobile:"",email:"",preferred_branch_id:""});
  const [orgForm,setOrgForm]=useState({name:"",slug:"",branch_name:"Main Branch",branch_code:"MAIN"});
  const [lastQr,setLastQr]=useState<{customer:string;code:string;token:string}|null>(null);

  useEffect(()=>{
    supabase.auth.getSession().then(({data})=>{setSession(data.session);setChecking(false)});
    const {data}=supabase.auth.onAuthStateChange((_event,next)=>setSession(next));
    return()=>data.subscription.unsubscribe();
  },[]);

  useEffect(()=>{if(session){loadContext()}else{setContext({});setCustomers([])}},[session]);

  async function loadContext(){
    setMessage("");
    const {data,error}=await supabase.rpc("get_my_labaflow_context");
    if(error){setMessage(error.message);return;}
    const next=(data??{}) as Context;
    setContext(next);
    if(next.organization) loadCustomers();
  }

  async function loadCustomers(){
    const {data,error}=await supabase.from("customers").select("id,customer_code,full_name,mobile,email,loyalty_points,lifetime_visits,lifetime_spend,created_at").eq("active",true).order("created_at",{ascending:false}).limit(50);
    if(error){setMessage(error.message);return;}
    setCustomers((data??[]) as Customer[]);
  }

  async function signIn(e:FormEvent){
    e.preventDefault();setMessage("");
    const {error}=await supabase.auth.signInWithPassword({email,password});
    if(error)setMessage(error.message);
  }

  async function signUp(){
    setMessage("");
    const {error}=await supabase.auth.signUp({email,password});
    setMessage(error?error.message:"Account created. Check your email if confirmation is enabled, then sign in.");
  }

  async function createOrganization(e:FormEvent){
    e.preventDefault();setMessage("");
    const {error}=await supabase.rpc("create_organization_with_main_branch",{
      p_name:orgForm.name,p_slug:orgForm.slug,p_branch_name:orgForm.branch_name,p_branch_code:orgForm.branch_code
    });
    if(error){setMessage(error.message);return;}
    await loadContext();
  }

  async function createCustomer(e:FormEvent){
    e.preventDefault();setMessage("");
    const {data,error}=await supabase.rpc("create_customer_with_qr",{
      p_full_name:customerForm.full_name,
      p_mobile:customerForm.mobile||null,
      p_email:customerForm.email||null,
      p_preferred_branch_id:customerForm.preferred_branch_id||null
    });
    if(error){setMessage(error.message);return;}
    const result=data as {customer:Customer;qr_token:string};
    setLastQr({customer:result.customer.full_name,code:result.customer.customer_code,token:result.qr_token});
    setCustomerForm({full_name:"",mobile:"",email:"",preferred_branch_id:""});
    setShowCustomer(false);
    await loadCustomers();
  }

  async function adjustPoints(customer:Customer,points:number){
    const {error}=await supabase.rpc("adjust_customer_loyalty",{p_customer_id:customer.id,p_points:points,p_description:points>0?"Manual loyalty award":"Reward redemption",p_branch_id:context.branches?.[0]?.id??null});
    if(error){setMessage(error.message);return;}
    await loadCustomers();
  }

  const stats=useMemo(()=>({
    customers:customers.length,
    points:customers.reduce((sum,c)=>sum+c.loyalty_points,0),
    visits:customers.reduce((sum,c)=>sum+c.lifetime_visits,0)
  }),[customers]);

  if(checking)return <main className="center"><div className="loader">Loading LabaFlow…</div></main>;

  if(!session)return <main className="authPage">
    <section className="brandPanel"><div className="logoMark">LF</div><h1>LabaFlow</h1><p>Laundry management, simplified.</p><div className="washGraphic"><span/><span/><span/></div></section>
    <section className="authCard"><div><p className="eyebrow">WELCOME</p><h2>Sign in to your laundry workspace</h2><p className="muted">Manage customers, loyalty, branches, orders, and daily operations from one place.</p></div>
      <form onSubmit={signIn} className="stack"><label>Email<input type="email" value={email} onChange={e=>setEmail(e.target.value)} required/></label><label>Password<input type="password" value={password} onChange={e=>setPassword(e.target.value)} required/></label><button className="primary">Sign In</button><button type="button" className="secondary" onClick={signUp}>Create Account</button></form>
      {message&&<p className="notice">{message}</p>}
    </section>
  </main>;

  if(!context.organization)return <main className="onboarding"><section className="onboardCard"><div className="logoMark">LF</div><p className="eyebrow">FIRST-TIME SETUP</p><h1>Create your LabaFlow organization</h1><p className="muted">Your first branch and loyalty program will be created automatically.</p><form onSubmit={createOrganization} className="gridForm"><label>Business name<input value={orgForm.name} onChange={e=>setOrgForm({...orgForm,name:e.target.value,slug:e.target.value.toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-|-$/g,"")})} required/></label><label>Organization slug<input value={orgForm.slug} onChange={e=>setOrgForm({...orgForm,slug:e.target.value})} required/></label><label>Main branch name<input value={orgForm.branch_name} onChange={e=>setOrgForm({...orgForm,branch_name:e.target.value})} required/></label><label>Branch code<input value={orgForm.branch_code} onChange={e=>setOrgForm({...orgForm,branch_code:e.target.value.toUpperCase()})} required/></label><button className="primary wide">Create Organization</button></form>{message&&<p className="notice">{message}</p>}</section></main>;

  return <div className="appShell">
    <aside className="sidebar"><div className="brand"><div className="logoMark small">LF</div><div><strong>LabaFlow</strong><small>{context.organization.name}</small></div></div><nav><button className={view==="dashboard"?"active":""} onClick={()=>setView("dashboard")}>Dashboard</button><button disabled>New Order <span>Soon</span></button><button disabled>Orders <span>Soon</span></button><button className={view==="customers"?"active":""} onClick={()=>setView("customers")}>Customers</button><button className={view==="loyalty"?"active":""} onClick={()=>setView("loyalty")}>Loyalty</button><button disabled>Services & Pricing <span>Soon</span></button><button disabled>Pickup & Delivery <span>Soon</span></button><hr/><button className={view==="settings"?"active":""} onClick={()=>setView("settings")}>Organization Settings</button></nav><div className="sidebarFooter"><small>{session.user.email}</small><button onClick={()=>supabase.auth.signOut()}>Sign out</button></div></aside>
    <main className="workspace"><header><div><p className="eyebrow">{context.branches?.[0]?.name??"LabaFlow"}</p><h1>{view==="dashboard"?"Good day — here’s your laundry flow.":view==="customers"?"Customers":view==="loyalty"?"Customer Loyalty":"Organization Settings"}</h1></div><button className="primary" onClick={()=>setShowCustomer(true)}>+ New Customer</button></header>
      {message&&<p className="notice">{message}</p>}
      {view==="dashboard"&&<><section className="stats"><article><span>Today's Orders</span><strong>0</strong><small>Order module is next</small></article><article><span>Ready for Pickup</span><strong>0</strong><small>No active orders yet</small></article><article><span>Customers</span><strong>{stats.customers}</strong><small>Registered profiles</small></article><article><span>Loyalty Points</span><strong>{stats.points}</strong><small>Current balance issued</small></article></section><section className="panel"><div className="panelHead"><div><p className="eyebrow">OPERATIONS</p><h2>Laundry Workflow</h2></div><small>Orders will appear here in v0.2</small></div><div className="workflow">{["Received","Sorting","Washing","Drying","Folding","Ready"].map((x,i)=><div key={x}><span>{i+1}</span><strong>{x}</strong><b>0</b></div>)}</div></section><section className="twoCols"><article className="panel"><p className="eyebrow">CUSTOMERS</p><h2>Recent Customers</h2>{customers.length?customers.slice(0,5).map(c=><div className="customerRow" key={c.id}><div><strong>{c.full_name}</strong><small>{c.customer_code}</small></div><b>{c.loyalty_points} pts</b></div>):<p className="empty">Add your first customer to begin building loyalty.</p>}</article><article className="panel"><p className="eyebrow">LOYALTY</p><h2>Program Snapshot</h2><div className="bigMetric">{stats.points}<span>points active</span></div><p className="muted">Default program: 10 points per qualifying visit. Organization-level configuration is already stored in Supabase.</p></article></section></>}
      {view==="customers"&&<section className="panel"><div className="panelHead"><div><p className="eyebrow">CRM</p><h2>Customer Directory</h2></div><span>{customers.length} customers</span></div>{customers.length?<div className="table"><div className="tableHeader"><span>Customer</span><span>Contact</span><span>Loyalty</span><span>Visits</span></div>{customers.map(c=><div className="tableRow" key={c.id}><span><strong>{c.full_name}</strong><small>{c.customer_code}</small></span><span>{c.mobile||c.email||"—"}</span><span><b>{c.loyalty_points}</b> pts</span><span>{c.lifetime_visits}</span></div>)}</div>:<p className="empty">No customers yet.</p>}</section>}
      {view==="loyalty"&&<section className="panel"><div className="panelHead"><div><p className="eyebrow">REWARDS</p><h2>Loyalty Accounts</h2></div><span>{stats.points} total points</span></div>{customers.map(c=><div className="loyaltyRow" key={c.id}><div><strong>{c.full_name}</strong><small>{c.customer_code}</small></div><div className="points">{c.loyalty_points} pts</div><div className="actions"><button onClick={()=>adjustPoints(c,10)}>+10</button><button disabled={c.loyalty_points<10} onClick={()=>adjustPoints(c,-10)}>-10</button></div></div>)}</section>}
      {view==="settings"&&<section className="panel"><p className="eyebrow">ADMINISTRATION</p><h2>{context.organization.name}</h2><div className="settingsGrid"><div><span>Organization slug</span><strong>{context.organization.slug}</strong></div><div><span>Your role</span><strong>{context.membership?.role??"Member"}</strong></div><div><span>Branches</span><strong>{context.branches?.length??0}</strong></div><div><span>Loyalty</span><strong>Enabled</strong></div></div><h3>Features</h3><div className="featureList">{["Customer loyalty","Pickup & delivery","Inventory","Expenses","Order workflow"].map(f=><div key={f}><span>{f}</span><b>Enabled</b></div>)}</div></section>}
    </main>
    {showCustomer&&<div className="modalBackdrop" onMouseDown={()=>setShowCustomer(false)}><section className="modal" onMouseDown={e=>e.stopPropagation()}><div className="panelHead"><div><p className="eyebrow">NEW CUSTOMER</p><h2>Create customer profile</h2></div><button className="iconBtn" onClick={()=>setShowCustomer(false)}>×</button></div><form onSubmit={createCustomer} className="gridForm"><label>Full name<input value={customerForm.full_name} onChange={e=>setCustomerForm({...customerForm,full_name:e.target.value})} required/></label><label>Mobile<input value={customerForm.mobile} onChange={e=>setCustomerForm({...customerForm,mobile:e.target.value})}/></label><label>Email<input type="email" value={customerForm.email} onChange={e=>setCustomerForm({...customerForm,email:e.target.value})}/></label><label>Preferred branch<select value={customerForm.preferred_branch_id} onChange={e=>setCustomerForm({...customerForm,preferred_branch_id:e.target.value})}><option value="">None</option>{context.branches?.map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select></label><button className="primary wide">Create Customer + QR</button></form></section></div>}
    {lastQr&&<div className="qrToast"><strong>{lastQr.customer}</strong><span>{lastQr.code}</span><small>Secure QR token created</small><code>{lastQr.token}</code><button onClick={()=>setLastQr(null)}>Dismiss</button></div>}
  </div>;
}
