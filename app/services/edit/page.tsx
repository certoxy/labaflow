"use client";

import { FormEvent, useEffect, useState } from "react";
import { supabase } from "../../../lib/supabase";

type Service={id:string;name:string;description:string|null;pricing_unit:"kg"|"piece"|"load"|"package";default_price:number;loyalty_points:number;active:boolean};

export default function EditServicePage(){
  const [service,setService]=useState<Service|null>(null);
  const [message,setMessage]=useState("");
  const [loading,setLoading]=useState(true);

  useEffect(()=>{
    const id=new URLSearchParams(window.location.search).get("id");
    if(!id){setMessage("Service ID is missing.");setLoading(false);return}
    supabase.from("services").select("id,name,description,pricing_unit,default_price,loyalty_points,active").eq("id",id).single().then(({data,error})=>{
      if(error)setMessage(error.message);else setService({...data,default_price:Number(data.default_price),loyalty_points:Number(data.loyalty_points??0)} as Service);
      setLoading(false);
    });
  },[]);

  async function save(e:FormEvent){
    e.preventDefault();
    if(!service)return;
    setMessage("");
    const {error}=await supabase.rpc("update_laundry_service",{
      p_service_id:service.id,
      p_name:service.name,
      p_description:service.description||null,
      p_pricing_unit:service.pricing_unit,
      p_default_price:Number(service.default_price),
      p_loyalty_points:Number(service.loyalty_points)||0,
      p_active:service.active
    });
    if(error){setMessage(error.message);return}
    setMessage("Service updated successfully.");
  }

  if(loading)return <main className="center"><div className="loader">Loading service…</div></main>;
  if(!service)return <main className="center"><section className="onboardCard"><h2>Unable to open service</h2><p className="notice">{message}</p><button className="secondary" onClick={()=>location.href="/"}>Back to LabaFlow</button></section></main>;

  return <main className="workspace"><div className="panelHead"><div><p className="eyebrow">SERVICES & PRICING</p><h1>Edit Service</h1></div><button className="secondary" onClick={()=>location.href="/"}>Back to LabaFlow</button></div>{message&&<p className="notice">{message}</p>}<section className="panel"><form className="gridForm" onSubmit={save}><label>Service name<input value={service.name} onChange={e=>setService({...service,name:e.target.value})} required/></label><label>Pricing unit<select value={service.pricing_unit} onChange={e=>setService({...service,pricing_unit:e.target.value as Service["pricing_unit"]})}><option value="kg">Per kg</option><option value="piece">Per piece</option><option value="load">Per load</option><option value="package">Package</option></select></label><label>Price<input type="number" min="0" step="0.01" value={service.default_price} onChange={e=>setService({...service,default_price:Number(e.target.value)})} required/></label><label>Reward points<input type="number" min="0" step="1" value={service.loyalty_points} onChange={e=>setService({...service,loyalty_points:Number(e.target.value)})}/></label><label className="wide">Description<input value={service.description??""} onChange={e=>setService({...service,description:e.target.value})}/></label><label>Status<select value={service.active?"active":"inactive"} onChange={e=>setService({...service,active:e.target.value==="active"})}><option value="active">Active</option><option value="inactive">Inactive</option></select></label><button className="primary wide">Save Changes</button></form></section></main>;
}
