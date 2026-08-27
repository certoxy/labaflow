"use client";

import { FormEvent, useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "../../lib/supabase";

type Branch={id:string;code:string;name:string;address:string|null;phone:string|null;active:boolean};
type Member={user_id:string;email:string;full_name:string|null;role:string;active:boolean};
type Invitation={id:string;email:string;role:string;branch_id:string|null;token:string;expires_at:string;accepted_at:string|null;revoked_at:string|null};
type Org={id:string;name:string;slug:string;active:boolean};
type BusinessSettings={loyalty:any;payments:{methods:string[]};workflow:{stages:string[]};completion:{require_full_payment_before_completion:boolean}};

const featureKeys=["customer_loyalty","pickup_delivery","inventory","expenses","order_workflow","qr_customer_id"];
const paymentOptions=["cash","gcash","maya","card","bank_transfer"];
const workflowOptions=["received","sorting","washing","drying","folding","ready","out_for_delivery","completed"];
const label=(v:string)=>v.replaceAll("_"," ").replace(/\b\w/g,c=>c.toUpperCase());

export default function OrganizationAdminPage(){
 const [session,setSession]=useState<Session|null>(null),[checking,setChecking]=useState(true);
 const [email,setEmail]=useState(""),[password,setPassword]=useState("");
 const [org,setOrg]=useState<Org|null>(null),[branches,setBranches]=useState<Branch[]>([]),[members,setMembers]=useState<Member[]>([]),[features,setFeatures]=useState<Record<string,boolean>>({}),[invitations,setInvitations]=useState<Invitation[]>([]),[message,setMessage]=useState("");
 const [branch,setBranch]=useState({code:"",name:"",address:"",phone:""});
 const [invite,setInvite]=useState({email:"",role:"laundry_staff",branch_id:""});
 const [business,setBusiness]=useState<BusinessSettings>({
   loyalty:{enabled:true,earning_method:"per_visit",points_per_visit:10,spend_amount_per_point:10,minimum_order_amount:0,same_day_visit_limit:1,points_expiry_months:null},
   payments:{methods:[...paymentOptions]},workflow:{stages:["received","sorting","washing","drying","folding","ready","completed"]},completion:{require_full_payment_before_completion:false}
 });

 useEffect(()=>{
   supabase.auth.getSession().then(({data})=>{setSession(data.session);setChecking(false)});
   const {data}=supabase.auth.onAuthStateChange((_event,next)=>setSession(next));
   return()=>data.subscription.unsubscribe();
 },[]);
 useEffect(()=>{if(session)load();else{setOrg(null);setBranches([]);setMembers([]);setInvitations([])}},[session]);

 async function signIn(e:FormEvent){e.preventDefault();setMessage("");const {error}=await supabase.auth.signInWithPassword({email:email.trim(),password});if(error)setMessage(error.message)}
 async function load(){
   const [{data,error},{data:settings,error:settingsError}]=await Promise.all([supabase.rpc("get_organization_admin_context"),supabase.rpc("get_organization_business_settings")]);
   if(error){setMessage(error.message);return}if(settingsError){setMessage(settingsError.message);return}
   setMessage("");setOrg(data.organization);setBranches(data.branches??[]);setMembers(data.members??[]);setFeatures(data.features??{});setInvitations(data.invitations??[]);
   if(settings)setBusiness(settings as BusinessSettings);
 }
 async function addBranch(){if(!branch.code||!branch.name){setMessage("Branch code and name are required.");return}const {error}=await supabase.rpc("create_branch",{p_code:branch.code,p_name:branch.name,p_address:branch.address||null,p_phone:branch.phone||null});if(error)setMessage(error.message);else{setBranch({code:"",name:"",address:"",phone:""});await load()}}
 async function toggleFeature(key:string){const next=features[key]!==false?false:true;const {error}=await supabase.rpc("set_organization_feature",{p_feature_key:key,p_enabled:next});if(error)setMessage(error.message);else await load()}
 async function sendInvite(){if(!invite.email){setMessage("Enter an email address.");return}const {data,error}=await supabase.rpc("invite_organization_user",{p_email:invite.email,p_role:invite.role,p_branch_id:invite.branch_id||null});if(error)setMessage(error.message);else{const link=`${window.location.origin}/join?invite=${data.token}`;setMessage(`Invitation created: ${link}`);setInvite({email:"",role:"laundry_staff",branch_id:""});await load()}}
 async function copyInvite(i:Invitation){const link=`${window.location.origin}/join?invite=${i.token}`;await navigator.clipboard.writeText(link);setMessage(`Invitation link copied for ${i.email}.`)}
 async function updateMember(member:Member,role:string,active:boolean){const {error}=await supabase.rpc("set_member_role",{p_user_id:member.user_id,p_role:role,p_active:active});if(error)setMessage(error.message);else await load()}
 function togglePayment(method:string){setBusiness(b=>({...b,payments:{methods:b.payments.methods.includes(method)?b.payments.methods.filter(x=>x!==method):[...b.payments.methods,method]}}))}
 function toggleStage(stage:string){if(stage==="received"||stage==="completed")return;setBusiness(b=>({...b,workflow:{stages:b.workflow.stages.includes(stage)?b.workflow.stages.filter(x=>x!==stage):workflowOptions.filter(x=>x==="received"||x==="completed"||b.workflow.stages.includes(x)||x===stage)}}))}
 async function saveBusiness(){
   const {error}=await supabase.rpc("save_organization_business_settings",{p_loyalty:business.loyalty,p_payment_methods:business.payments,p_workflow_stages:business.workflow,p_completion_rules:business.completion});
   setMessage(error?error.message:"Business settings saved.");if(!error)await load();
 }

 if(checking)return <main className="center"><div className="loader">Loading LabaFlow…</div></main>;
 if(!session)return <main className="authPage"><section className="brandPanel"><div className="logoMark">LF</div><h1>LabaFlow</h1><p>Organization administration.</p><div className="washGraphic"><span/><span/><span/></div></section><section className="authCard"><div><p className="eyebrow">ORGANIZATION ADMINISTRATION</p><h2>Sign in to manage your organization</h2><p className="muted">Use your LabaFlow owner or administrator account.</p></div><form onSubmit={signIn} className="stack"><label>Email<input type="email" value={email} onChange={e=>setEmail(e.target.value)} required/></label><label>Password<input type="password" value={password} onChange={e=>setPassword(e.target.value)} required/></label><button className="primary">Sign In</button><button type="button" className="secondary" onClick={()=>window.location.href="/"}>Back to LabaFlow</button></form>{message&&<p className="notice">{message}</p>}</section></main>;

 return <main className="workspace"><div className="panelHead"><div><p className="eyebrow">ORGANIZATION ADMINISTRATION</p><h1>{org?.name??"LabaFlow Organization"}</h1></div><div className="headerActions"><button className="secondary" onClick={()=>window.location.href="/"}>LabaFlow</button><button className="secondary" onClick={()=>supabase.auth.signOut()}>Sign Out</button></div></div>{message&&<p className="notice">{message}</p>}
 <section className="panel"><h2>Business Rules</h2><div className="settingsGrid"><div><span>Loyalty Program</span><button className="miniBtn" onClick={()=>setBusiness(b=>({...b,loyalty:{...b.loyalty,enabled:!b.loyalty.enabled}}))}>{business.loyalty.enabled?"Enabled":"Disabled"}</button></div><div><span>Full Payment Before Completion</span><button className="miniBtn" onClick={()=>setBusiness(b=>({...b,completion:{require_full_payment_before_completion:!b.completion.require_full_payment_before_completion}}))}>{business.completion.require_full_payment_before_completion?"Required":"Not required"}</button></div></div>
 <div className="gridForm"><label>Loyalty earning method<select value={business.loyalty.earning_method} onChange={e=>setBusiness(b=>({...b,loyalty:{...b.loyalty,earning_method:e.target.value}}))}><option value="per_visit">Per Visit</option><option value="per_spend">Per Spend</option><option value="per_service">Per Service</option></select></label>{business.loyalty.earning_method==="per_visit"&&<label>Points per visit<input type="number" min="0" value={business.loyalty.points_per_visit??0} onChange={e=>setBusiness(b=>({...b,loyalty:{...b.loyalty,points_per_visit:Number(e.target.value)}}))}/></label>}{business.loyalty.earning_method==="per_spend"&&<label>Spend amount per point<input type="number" min="0.01" step="0.01" value={business.loyalty.spend_amount_per_point??""} onChange={e=>setBusiness(b=>({...b,loyalty:{...b.loyalty,spend_amount_per_point:Number(e.target.value)}}))}/></label>}<label>Minimum qualifying order<input type="number" min="0" step="0.01" value={business.loyalty.minimum_order_amount??0} onChange={e=>setBusiness(b=>({...b,loyalty:{...b.loyalty,minimum_order_amount:Number(e.target.value)}}))}/></label><label>Same-day visit limit<input type="number" min="0" value={business.loyalty.same_day_visit_limit??1} onChange={e=>setBusiness(b=>({...b,loyalty:{...b.loyalty,same_day_visit_limit:Number(e.target.value)}}))}/></label></div>
 <h3>Accepted Payment Methods</h3><div className="featureList">{paymentOptions.map(m=><div key={m}><span>{label(m)}</span><button className="miniBtn" onClick={()=>togglePayment(m)}>{business.payments.methods.includes(m)?"Enabled":"Disabled"}</button></div>)}</div>
 <h3>Order Workflow</h3><div className="featureList">{workflowOptions.map(stage=><div key={stage}><span>{label(stage)}</span><button className="miniBtn" disabled={stage==="received"||stage==="completed"} onClick={()=>toggleStage(stage)}>{business.workflow.stages.includes(stage)?"Enabled":"Disabled"}</button></div>)}</div>
 <button className="primary" style={{marginTop:18}} onClick={saveBusiness}>Save Business Settings</button></section>
 <section className="panel"><h2>Branches</h2><div className="gridForm"><label>Code<input value={branch.code} onChange={e=>setBranch({...branch,code:e.target.value.toUpperCase()})}/></label><label>Name<input value={branch.name} onChange={e=>setBranch({...branch,name:e.target.value})}/></label><label>Address<input value={branch.address} onChange={e=>setBranch({...branch,address:e.target.value})}/></label><label>Phone<input value={branch.phone} onChange={e=>setBranch({...branch,phone:e.target.value})}/></label><button className="primary wide" type="button" onClick={addBranch}>Add Branch</button></div>{branches.map(b=><div className="adminRow" key={b.id}><div><strong>{b.name}</strong><small>{b.code}{b.address?` · ${b.address}`:""}</small></div><span className={b.active?"status active":"status inactive"}>{b.active?"Active":"Inactive"}</span></div>)}</section>
 <section className="panel"><h2>Feature Controls</h2><div className="featureList">{featureKeys.map(key=><div key={key}><span>{label(key)}</span><button className="miniBtn" onClick={()=>toggleFeature(key)}>{features[key]!==false?"Enabled":"Disabled"}</button></div>)}</div></section>
 <section className="panel"><h2>Staff Invitations</h2><div className="gridForm"><label>Email<input type="email" value={invite.email} onChange={e=>setInvite({...invite,email:e.target.value})}/></label><label>Role<select value={invite.role} onChange={e=>setInvite({...invite,role:e.target.value})}><option value="admin">Admin</option><option value="manager">Manager</option><option value="cashier">Cashier</option><option value="laundry_staff">Laundry Staff</option><option value="delivery_staff">Delivery Staff</option><option value="auditor">Auditor</option></select></label><label>Branch<select value={invite.branch_id} onChange={e=>setInvite({...invite,branch_id:e.target.value})}><option value="">All / none</option>{branches.map(b=><option key={b.id} value={b.id}>{b.name}</option>)}</select></label><button className="primary" type="button" onClick={sendInvite}>Create Invitation</button></div>{invitations.map(i=><div className="adminRow" key={i.id}><div><strong>{i.email}</strong><small>{i.role} · expires {new Date(i.expires_at).toLocaleDateString()}</small></div><span className={i.accepted_at?"status active":"status inactive"}>{i.accepted_at?"Accepted":i.revoked_at?"Revoked":"Pending"}</span>{!i.accepted_at&&!i.revoked_at&&<button className="miniBtn" onClick={()=>copyInvite(i)}>Copy Join Link</button>}</div>)}</section>
 <section className="panel"><h2>Staff</h2>{members.map(m=><div className="adminRow" key={m.user_id}><div><strong>{m.full_name||m.email}</strong><small>{m.email}</small></div>{m.role==="owner"?<span className="status active">Owner</span>:<><select value={m.role} onChange={e=>updateMember(m,e.target.value,m.active)}><option value="admin">Admin</option><option value="manager">Manager</option><option value="cashier">Cashier</option><option value="laundry_staff">Laundry Staff</option><option value="delivery_staff">Delivery Staff</option><option value="auditor">Auditor</option></select><button className="miniBtn" onClick={()=>updateMember(m,m.role,!m.active)}>{m.active?"Deactivate":"Activate"}</button></>}</div>)}</section></main>;
}
