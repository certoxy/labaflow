"use client";
import {useEffect,useState} from "react";
import {supabase} from "../../../lib/supabase";

type Service={id:string;name:string;pricing_unit:string;default_price:number};
type VehicleType="car"|"suv"|"van"|"pickup"|"motorcycle"|"other";
type PriceRow={service_id:string;vehicle_type:VehicleType;price:number};
const TYPES:[VehicleType,string][]=[["car","Car"],["suv","SUV"],["van","Van"],["pickup","Pickup"],["motorcycle","Motorcycle"],["other","Other"]];
const peso=new Intl.NumberFormat("en-PH",{style:"currency",currency:"PHP"});

export default function VehiclePricingPage(){
 const [services,setServices]=useState<Service[]>([]),[prices,setPrices]=useState<Record<string,Record<VehicleType,string>>>({}),[loading,setLoading]=useState(true),[saving,setSaving]=useState(false),[message,setMessage]=useState(""),[isCarWash,setIsCarWash]=useState(false);
 useEffect(()=>{void load()},[]);
 async function load(){
  const [business,serviceResult,priceResult]=await Promise.all([
   supabase.rpc("get_organization_business_type"),
   supabase.from("services").select("id,name,pricing_unit,default_price").eq("active",true).order("name"),
   supabase.rpc("get_service_vehicle_prices")
  ]);
  setLoading(false);
  if(business.error||serviceResult.error||priceResult.error)return setMessage(business.error?.message||serviceResult.error?.message||priceResult.error?.message||"Unable to load vehicle pricing.");
  const carWash=business.data==="car_wash";setIsCarWash(carWash);
  const nextServices=(serviceResult.data??[]).map((s:any)=>({...s,default_price:Number(s.default_price)}));setServices(nextServices);
  const saved=(priceResult.data??[]) as PriceRow[];
  const next:Record<string,Record<VehicleType,string>>={};
  for(const service of nextServices){
   next[service.id]={} as Record<VehicleType,string>;
   for(const [type] of TYPES){const row=saved.find(x=>x.service_id===service.id&&x.vehicle_type===type);next[service.id][type]=String(row?Number(row.price):service.default_price)}
  }
  setPrices(next);
 }
 function change(serviceId:string,type:VehicleType,value:string){setPrices(current=>({...current,[serviceId]:{...current[serviceId],[type]:value}}))}
 async function save(){
  for(const service of services)for(const [type,label] of TYPES){const value=Number(prices[service.id]?.[type]);if(!Number.isFinite(value)||value<0)return setMessage(`Enter a valid price for ${service.name} · ${label}.`)}
  setSaving(true);setMessage("");
  const results=await Promise.all(services.map(service=>supabase.rpc("save_service_vehicle_prices",{p_service_id:service.id,p_prices:Object.fromEntries(TYPES.map(([type])=>[type,Number(prices[service.id][type])]))})));
  setSaving(false);const error=results.find(result=>result.error)?.error;if(error)return setMessage(error.message);
  setMessage("Vehicle pricing saved. New Car Wash orders will use these prices.");await load();
 }
 if(loading)return <main className="workspace"><p>Loading vehicle pricing…</p></main>;
 return <main className="workspace"><header className="pageHeader"><div><p className="eyebrow">CAR WASH</p><h1>Vehicle Pricing</h1><p className="muted">Set a separate price for every service and vehicle type. Existing receipts keep their original charged prices.</p></div></header>
  {message&&<p className="notice">{message}</p>}
  {!isCarWash?<section className="panel"><h2>Car Wash organizations only</h2><p className="muted">Vehicle pricing does not change Laundry services.</p></section>:
  <section className="panel"><div className="tableWrap"><table className="customerTable" style={{minWidth:1000}}><thead><tr><th>Service</th>{TYPES.map(([,label])=><th key={label}>{label}</th>)}</tr></thead><tbody>{services.map(service=><tr key={service.id}><td><strong>{service.name}</strong><small className="muted" style={{display:"block"}}>Base: {peso.format(service.default_price)} / {service.pricing_unit}</small></td>{TYPES.map(([type])=><td key={type}><input aria-label={`${service.name} ${type} price`} type="number" min="0" step="0.01" value={prices[service.id]?.[type]??""} onChange={e=>change(service.id,type,e.target.value)} style={{minWidth:110}}/></td>)}</tr>)}</tbody></table></div><div style={{marginTop:20,display:"flex",justifyContent:"flex-end"}}><button className="primary" onClick={save} disabled={saving}>{saving?"Saving…":"Save Vehicle Pricing"}</button></div></section>}
 </main>
}