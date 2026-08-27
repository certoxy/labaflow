"use client";

import { FormEvent,useEffect,useState } from "react";
import { supabase } from "../../../lib/supabase";

type Level={id:string;name:string;minimum_points:number;active:boolean;sort_order:number};
const blank={id:"",name:"",minimum_points:"0",active:true,sort_order:"0"};

export default function LoyaltyLevelsPage(){
 const [levels,setLevels]=useState<Level[]>([]),[form,setForm]=useState(blank),[message,setMessage]=useState("");
 useEffect(()=>{load()},[]);
 async function load(){const {data,error}=await supabase.from("loyalty_levels").select("id,name,minimum_points,active,sort_order").order("minimum_points");if(error)setMessage(error.message);else setLevels((data??[]).map((x:any)=>({...x,minimum_points:Number(x.minimum_points),sort_order:Number(x.sort_order)})))}
 async function save(e:FormEvent){e.preventDefault();const {error}=await supabase.rpc("save_loyalty_level",{p_level_id:form.id||null,p_name:form.name,p_minimum_points:Number(form.minimum_points),p_active:form.active,p_sort_order:Number(form.sort_order)||0});if(error){setMessage(error.message);return}setMessage(form.id?"Loyalty level updated.":"Loyalty level added.");setForm(blank);await load()}
 async function remove(l:Level){if(!confirm(`Delete ${l.name}?`))return;const {error}=await supabase.rpc("delete_loyalty_level",{p_level_id:l.id});if(error)setMessage(error.message);else{setMessage("Loyalty level deleted.");await load()}}
 function edit(l:Level){setForm({id:l.id,name:l.name,minimum_points:String(l.minimum_points),active:l.active,sort_order:String(l.sort_order)})}
 return <main className="workspace"><header><div><p className="eyebrow">ADMINISTRATION</p><h1>Loyalty Levels</h1><p className="muted">Define your own customer membership levels using cumulative points. The highest matching minimum-points level is assigned automatically.</p></div></header>{message&&<p className="notice">{message}</p>}
  <section className="panel"><div className="panelHead"><div><h2>Configured Levels</h2><span>Names and thresholds are controlled by your organization.</span></div></div><div className="table"><div className="tableHeader" style={{gridTemplateColumns:"1.2fr .8fr .6fr .8fr"}}><span>Level</span><span>Minimum Points</span><span>Status</span><span>Actions</span></div>{levels.map(l=><div className="tableRow" style={{gridTemplateColumns:"1.2fr .8fr .6fr .8fr"}} key={l.id}><strong>{l.name}</strong><span>{l.minimum_points.toLocaleString()}</span><span className={`status ${l.active?"active":"completed"}`}>{l.active?"Active":"Inactive"}</span><div className="actions"><button className="miniBtn" onClick={()=>edit(l)}>Edit</button><button className="miniBtn" onClick={()=>remove(l)}>Delete</button></div></div>)}</div></section>
  <section className="panel"><h2>{form.id?"Edit Loyalty Level":"Add Loyalty Level"}</h2><form className="gridForm" onSubmit={save}><label>Level name<input placeholder="e.g. VIP, Gold, Platinum" value={form.name} onChange={e=>setForm({...form,name:e.target.value})} required/></label><label>Minimum cumulative points<input type="number" min="0" step="1" value={form.minimum_points} onChange={e=>setForm({...form,minimum_points:e.target.value})} required/></label><label>Sort order<input type="number" value={form.sort_order} onChange={e=>setForm({...form,sort_order:e.target.value})}/></label><label><span><input style={{width:"auto",marginRight:8}} type="checkbox" checked={form.active} onChange={e=>setForm({...form,active:e.target.checked})}/>Active</span></label><div className="wide actions"><button className="primary">{form.id?"Save Changes":"Add Level"}</button>{form.id&&<button type="button" className="secondary" onClick={()=>setForm(blank)}>Cancel</button>}</div></form></section>
 </main>
}
