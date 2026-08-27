"use client";

import { FormEvent, useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "../../../lib/supabase";

type Rate={id:string;label:string;min_km:number;max_km:number|null;price:number;active:boolean;sort_order:number};
const peso=new Intl.NumberFormat("en-PH",{style:"currency",currency:"PHP"});

export default function DeliveryPricingPage(){
 const [session,setSession]=useState<Session|null>(null),[checking,setChecking]=useState(true),[message,setMessage]=useState("");
 const [rates,setRates]=useState<Rate[]>([]),[editing,setEditing]=useState<string|null>(null);
 const [form,setForm]=useState({label:"",min_km:"0",max_km:"",price:"0",active:true,sort_order:"0"});
 useEffect(()=>{supabase.auth.getSession().then(({data})=>{setSession(data.session);setChecking(false)});const {data}=supabase.auth.onAuthStateChange((_e,s)=>setSession(s));return()=>data.subscription.unsubscribe()},[]);
 useEffect(()=>{if(session)load()},[session]);
 async function load(){const {data,error}=await supabase.from("delivery_distance_rates").select("id,label,min_km,max_km,price,active,sort_order").order("sort_order").order("min_km");if(error)setMessage(error.message);else setRates((data??[]).map((r:any)=>({...r,min_km:Number(r.min_km),max_km:r.max_km==null?null:Number(r.max_km),price:Number(r.price)})))}
 function edit(r:Rate){setEditing(r.id);setForm({label:r.label,min_km:String(r.min_km),max_km:r.max_km==null?"":String(r.max_km),price:String(r.price),active:r.active,sort_order:String(r.sort_order)})}
 function reset(){setEditing(null);setForm({label:"",min_km:"0",max_km:"",price:"0",active:true,sort_order:"0"})}
 async function save(e:FormEvent){e.preventDefault();const {error}=await supabase.rpc("upsert_delivery_distance_rate",{p_id:editing,p_label:form.label,p_min_km:Number(form.min_km)||0,p_max_km:form.max_km===""?null:Number(form.max_km),p_price:Number(form.price)||0,p_active:form.active,p_sort_order:Number(form.sort_order)||0});if(error)setMessage(error.message);else{setMessage(editing?"Distance rate updated.":"Distance rate created.");reset();await load()}}
 if(checking)return <main className="center"><div className="loader">Loading distance pricing…</div></main>;
 if(!session)return <main className="center"><section className="onboardCard"><h2>Sign in required</h2><button className="primary" onClick={()=>location.href="/organization"}>Organization Administration</button></section></main>;
 return <main className="workspace"><div className="panelHead"><div><p className="eyebrow">PICKUP & DELIVERY</p><h1>Distance Pricing</h1><p className="muted">Configure the distance bands used when Pickup/Delivery is selected as an order add-on.</p></div><div className="headerActions"><button className="secondary" onClick={()=>location.href="/organization"}>Organization Admin</button><button className="primary" onClick={()=>location.href="/"}>LabaFlow</button></div></div>{message&&<p className="notice">{message}</p>}
 <section className="twoCols"><article className="panel"><h2>{editing?"Edit Distance Band":"New Distance Band"}</h2><form onSubmit={save} className="gridForm"><label>Label<input value={form.label} onChange={e=>setForm({...form,label:e.target.value})} placeholder="0–3 km" required/></label><label>Sort order<input type="number" value={form.sort_order} onChange={e=>setForm({...form,sort_order:e.target.value})}/></label><label>Minimum km<input type="number" min="0" step="0.1" value={form.min_km} onChange={e=>setForm({...form,min_km:e.target.value})} required/></label><label>Maximum km<input type="number" min="0" step="0.1" value={form.max_km} onChange={e=>setForm({...form,max_km:e.target.value})} placeholder="Leave blank for unlimited"/></label><label>Price<input type="number" min="0" step="0.01" value={form.price} onChange={e=>setForm({...form,price:e.target.value})} required/></label><label><span>Availability</span><button type="button" className="miniBtn" onClick={()=>setForm({...form,active:!form.active})}>{form.active?"Active":"Inactive"}</button></label><button className="primary wide">{editing?"Save Changes":"Add Distance Band"}</button>{editing&&<button type="button" className="secondary wide" onClick={reset}>Cancel Edit</button>}</form></article>
 <article className="panel"><h2>Configured Rates</h2>{rates.length?rates.map(r=><div className="adminRow" key={r.id}><div><strong>{r.label}</strong><small>{r.min_km} km – {r.max_km==null?"No limit":`${r.max_km} km`} · {peso.format(r.price)}</small></div><span className={r.active?"status active":"status inactive"}>{r.active?"Active":"Inactive"}</span><button className="miniBtn" onClick={()=>edit(r)}>Edit</button></div>):<p className="empty">No distance rates configured yet.</p>}</article></section>
 </main>;
}
