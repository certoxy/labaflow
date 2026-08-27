"use client";

import { FormEvent,useEffect,useMemo,useState } from "react";
import { supabase } from "../../lib/supabase";

type Branch={id:string;name:string};
type Customer={id:string;customer_code:string;full_name:string;mobile:string|null;email:string|null;preferred_branch_id:string|null;loyalty_points:number;lifetime_points:number;lifetime_visits:number;lifetime_spend:number};
type Address={id:string;label:string;address_line:string;barangay:string|null;city:string|null;province:string|null;postal_code:string|null;landmark:string|null;is_default:boolean;active:boolean};
type Distance={address_id:string;branch_id:string;distance_km:number};
type Level={id:string;name:string;minimum_points:number;active:boolean};
const peso=new Intl.NumberFormat("en-PH",{style:"currency",currency:"PHP"});

export default function CustomersPage(){
 const [customers,setCustomers]=useState<Customer[]>([]),[branches,setBranches]=useState<Branch[]>([]),[levels,setLevels]=useState<Level[]>([]),[message,setMessage]=useState("");
 const [search,setSearch]=useState(""),[editing,setEditing]=useState<Customer|null>(null),[addresses,setAddresses]=useState<Address[]>([]),[distances,setDistances]=useState<Record<string,string>>({});
 const [profile,setProfile]=useState({full_name:"",mobile:"",email:"",preferred_branch_id:""});
 const [addressForm,setAddressForm]=useState({id:"",label:"Home",address_line:"",barangay:"",city:"",province:"",postal_code:"",landmark:"",is_default:false});

 useEffect(()=>{load()},[]);
 async function load(){
  setMessage("");
  const [a,c,l]=await Promise.all([
   supabase.rpc("get_current_access_context"),
   supabase.from("customers").select("id,customer_code,full_name,mobile,email,preferred_branch_id,loyalty_points,lifetime_points,lifetime_visits,lifetime_spend").eq("active",true).order("full_name"),
   supabase.from("loyalty_levels").select("id,name,minimum_points,active").eq("active",true).order("minimum_points")
  ]);
  if(a.error||c.error||l.error){setMessage(a.error?.message||c.error?.message||l.error?.message||"Unable to load customers");return}
  setBranches((a.data?.branches??[]) as Branch[]);
  setCustomers((c.data??[]).map((x:any)=>({...x,loyalty_points:Number(x.loyalty_points??0),lifetime_points:Number(x.lifetime_points??0),lifetime_visits:Number(x.lifetime_visits??0),lifetime_spend:Number(x.lifetime_spend??0)})));
  setLevels((l.data??[]).map((x:any)=>({...x,minimum_points:Number(x.minimum_points??0)})));
 }
 function levelFor(points:number){return [...levels].filter(l=>l.active&&l.minimum_points<=points).sort((a,b)=>b.minimum_points-a.minimum_points)[0]?.name??"Member"}
 const filtered=useMemo(()=>{const q=search.trim().toLowerCase();return q?customers.filter(c=>`${c.full_name} ${c.customer_code} ${c.mobile??""} ${c.email??""}`.toLowerCase().includes(q)):customers},[customers,search]);

 async function openEdit(c:Customer){
  setEditing(c);setProfile({full_name:c.full_name,mobile:c.mobile??"",email:c.email??"",preferred_branch_id:c.preferred_branch_id??""});setAddressForm({id:"",label:"Home",address_line:"",barangay:"",city:"",province:"",postal_code:"",landmark:"",is_default:false});
  const [a,d]=await Promise.all([
   supabase.from("customer_addresses").select("id,label,address_line,barangay,city,province,postal_code,landmark,is_default,active").eq("customer_id",c.id).eq("active",true).order("is_default",{ascending:false}),
   supabase.from("customer_address_branch_distances").select("address_id,branch_id,distance_km")
  ]);
  if(a.error||d.error){setMessage(a.error?.message||d.error?.message||"Unable to load customer addresses");return}
  setAddresses((a.data??[]) as Address[]);
  const customerAddressIds=new Set((a.data??[]).map((x:any)=>x.id));
  const map:Record<string,string>={};
  (d.data??[]).filter((x:any)=>customerAddressIds.has(x.address_id)).forEach((x:any)=>{map[`${x.address_id}:${x.branch_id}`]=String(x.distance_km)});
  setDistances(map);
 }
 async function saveProfile(e:FormEvent){e.preventDefault();if(!editing)return;const {error}=await supabase.rpc("update_customer_profile",{p_customer_id:editing.id,p_full_name:profile.full_name,p_mobile:profile.mobile||null,p_email:profile.email||null,p_preferred_branch_id:profile.preferred_branch_id||null});if(error){setMessage(error.message);return}setMessage("Customer details updated.");await load();setEditing(x=>x?{...x,...profile,preferred_branch_id:profile.preferred_branch_id||null}:x)}
 function editAddress(a:Address){setAddressForm({id:a.id,label:a.label,address_line:a.address_line,barangay:a.barangay??"",city:a.city??"",province:a.province??"",postal_code:a.postal_code??"",landmark:a.landmark??"",is_default:a.is_default})}
 async function saveAddress(e:FormEvent){e.preventDefault();if(!editing)return;let addressId=addressForm.id;
  if(addressId){const {error}=await supabase.rpc("update_customer_address",{p_address_id:addressId,p_label:addressForm.label,p_address_line:addressForm.address_line,p_barangay:addressForm.barangay||null,p_city:addressForm.city||null,p_province:addressForm.province||null,p_postal_code:addressForm.postal_code||null,p_landmark:addressForm.landmark||null,p_is_default:addressForm.is_default});if(error){setMessage(error.message);return}}
  else{const {data,error}=await supabase.rpc("create_customer_address",{p_customer_id:editing.id,p_label:addressForm.label,p_address_line:addressForm.address_line,p_barangay:addressForm.barangay||null,p_city:addressForm.city||null,p_province:addressForm.province||null,p_postal_code:addressForm.postal_code||null,p_landmark:addressForm.landmark||null,p_is_default:addressForm.is_default,p_branch_id:null,p_distance_km:null});if(error){setMessage(error.message);return}addressId=data.id}
  for(const b of branches){const raw=distances[`${addressId}:${b.id}`];if(raw!==undefined&&raw!==""){const {error}=await supabase.rpc("set_customer_address_distance",{p_address_id:addressId,p_branch_id:b.id,p_distance_km:Number(raw)});if(error){setMessage(error.message);return}}}
  setMessage("Customer address updated.");await openEdit(editing);
 }

 return <main className="workspace"><header><div><p className="eyebrow">CUSTOMERS</p><h1>Customer Directory</h1><p className="muted">Maintain customer details, delivery addresses, branch distances, and loyalty status.</p></div></header>{message&&<p className="notice">{message}</p>}
  <section className="panel"><div className="panelHead"><div><h2>Customers</h2><span>{customers.length} active customers</span></div><input style={{maxWidth:360}} placeholder="Search name, code, mobile or email" value={search} onChange={e=>setSearch(e.target.value)}/></div>
   <div className="table"><div className="tableHeader" style={{gridTemplateColumns:"1.3fr .8fr .8fr .8fr .6fr"}}><span>Customer</span><span>Level</span><span>Available</span><span>Cumulative</span><span>Action</span></div>{filtered.map(c=><div className="tableRow" style={{gridTemplateColumns:"1.3fr .8fr .8fr .8fr .6fr"}} key={c.id}><div><strong>{c.full_name}</strong><small>{c.customer_code} · {c.mobile||c.email||"No contact"}</small></div><span className="status active">{levelFor(c.lifetime_points)}</span><strong>{c.loyalty_points.toLocaleString()} pts</strong><span>{c.lifetime_points.toLocaleString()} pts<br/><small>{c.lifetime_visits} visits · {peso.format(c.lifetime_spend)}</small></span><button className="miniBtn" onClick={()=>openEdit(c)}>Edit Customer</button></div>)}</div>
  </section>
  {editing&&<div className="modalBackdrop"><section className="modal" style={{width:"min(980px,100%)"}}><div className="panelHead"><div><p className="eyebrow">EDIT CUSTOMER</p><h2>{editing.full_name}</h2><span>{editing.customer_code} · {levelFor(editing.lifetime_points)} · {editing.lifetime_points.toLocaleString()} cumulative points</span></div><button className="iconBtn" onClick={()=>setEditing(null)}>×</button></div>
   <form className="gridForm" onSubmit={saveProfile}><label>Full name<input value={profile.full_name} onChange={e=>setProfile({...profile,full_name:e.target.value})} required/></label><label>Mobile<input value={profile.mobile} onChange={e=>setProfile({...profile,mobile:e.target.value})}/></label><label>Email<input type="email" value={profile.email} onChange={e=>setProfile({...profile,email:e.target.value})}/></label><label>Preferred branch<select value={profile.preferred_branch_id} onChange={e=>setProfile({...profile,preferred_branch_id:e.target.value})}><option value="">None</option>{branches.map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select></label><div className="wide"><button className="primary">Save Customer Details</button></div></form>
   <h3>Addresses & Delivery Distance</h3>{addresses.length===0&&<p className="muted">No saved addresses yet.</p>}{addresses.map(a=><div className="orderCard" key={a.id}><div className="orderTop"><div><strong>{a.label}{a.is_default?" · Default":""}</strong><small>{[a.address_line,a.barangay,a.city,a.province].filter(Boolean).join(", ")}</small>{a.landmark&&<small>Landmark: {a.landmark}</small>}</div><button className="miniBtn" onClick={()=>editAddress(a)}>Edit Address</button></div><div className="settingsGrid">{branches.map(b=><div key={b.id}><span>{b.name}</span><strong>{distances[`${a.id}:${b.id}`]?`${distances[`${a.id}:${b.id}`]} km`:"Not set"}</strong></div>)}</div></div>)}
   <form className="gridForm" onSubmit={saveAddress}><div className="wide"><h3>{addressForm.id?"Edit Address":"Add Address"}</h3></div><label>Label<input value={addressForm.label} onChange={e=>setAddressForm({...addressForm,label:e.target.value})}/></label><label className="wide">Address<input value={addressForm.address_line} onChange={e=>setAddressForm({...addressForm,address_line:e.target.value})} required/></label><label>Barangay<input value={addressForm.barangay} onChange={e=>setAddressForm({...addressForm,barangay:e.target.value})}/></label><label>City<input value={addressForm.city} onChange={e=>setAddressForm({...addressForm,city:e.target.value})}/></label><label>Province<input value={addressForm.province} onChange={e=>setAddressForm({...addressForm,province:e.target.value})}/></label><label>Postal Code<input value={addressForm.postal_code} onChange={e=>setAddressForm({...addressForm,postal_code:e.target.value})}/></label><label className="wide">Landmark / Instructions<input value={addressForm.landmark} onChange={e=>setAddressForm({...addressForm,landmark:e.target.value})}/></label>{branches.map(b=><label key={b.id}>Distance from {b.name} (km)<input type="number" min="0" step="0.01" value={addressForm.id?distances[`${addressForm.id}:${b.id}`]??"":""} onChange={e=>setDistances({...distances,[`${addressForm.id||"new"}:${b.id}`]:e.target.value})}/></label>)}<label className="wide"><span><input style={{width:"auto",marginRight:8}} type="checkbox" checked={addressForm.is_default} onChange={e=>setAddressForm({...addressForm,is_default:e.target.checked})}/>Use as default pickup/delivery address</span></label><div className="wide actions"><button className="primary">{addressForm.id?"Save Address":"Add Address"}</button>{addressForm.id&&<button type="button" className="secondary" onClick={()=>setAddressForm({id:"",label:"Home",address_line:"",barangay:"",city:"",province:"",postal_code:"",landmark:"",is_default:false})}>Add Another Address</button>}</div></form>
  </section></div>}
 </main>
}
