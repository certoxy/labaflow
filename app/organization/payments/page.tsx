"use client";
import {FormEvent,useEffect,useState} from "react";
import {supabase} from "../../../lib/supabase";

type GCashSettings={integration_type:"manual_qr"|"gateway";merchant_name:string;account_number:string;qr_image_url:string;instructions:string;active:boolean};
const empty:GCashSettings={integration_type:"manual_qr",merchant_name:"",account_number:"",qr_image_url:"",instructions:"Scan the QR using GCash and show the successful payment confirmation to the cashier.",active:true};

export default function OrganizationPaymentsPage(){
 const [settings,setSettings]=useState<GCashSettings>(empty),[message,setMessage]=useState(""),[saving,setSaving]=useState(false),[uploading,setUploading]=useState(false),[orgId,setOrgId]=useState<string|null>(null);
 useEffect(()=>{load()},[]);
 async function load(){
  const [account,access]=await Promise.all([supabase.rpc("get_organization_payment_account",{p_payment_method:"gcash"}),supabase.rpc("get_current_access_context")]);
  if(account.error){setMessage(account.error.message);return}
  if(access.error){setMessage(access.error.message);return}
  setOrgId(access.data?.organization_id??null);
  if(account.data)setSettings({integration_type:account.data.integration_type??"manual_qr",merchant_name:account.data.merchant_name??"",account_number:account.data.account_number??"",qr_image_url:account.data.qr_image_url??"",instructions:account.data.instructions??"",active:account.data.active!==false})
 }
 async function uploadQr(file:File){
  if(!orgId){setMessage("Organization could not be identified.");return}
  if(!["image/png","image/jpeg","image/webp"].includes(file.type)){setMessage("Please upload a PNG, JPG, or WEBP image.");return}
  if(file.size>5*1024*1024){setMessage("QR image must be 5 MB or smaller.");return}
  setUploading(true);setMessage("");
  const ext=(file.name.split(".").pop()||"png").toLowerCase();
  const path=`${orgId}/gcash/gcash-qr-${Date.now()}.${ext}`;
  const {error}=await supabase.storage.from("organization-payment-qrs").upload(path,file,{cacheControl:"3600",upsert:false,contentType:file.type});
  if(error){setUploading(false);setMessage(error.message);return}
  const {data}=supabase.storage.from("organization-payment-qrs").getPublicUrl(path);
  setSettings(s=>({...s,qr_image_url:data.publicUrl}));
  setUploading(false);setMessage("QR image uploaded. Click Save GCash Settings to finish.");
 }
 async function save(e:FormEvent){e.preventDefault();setSaving(true);setMessage("");const {error}=await supabase.rpc("save_organization_gcash_settings",{p_integration_type:settings.integration_type,p_merchant_name:settings.merchant_name,p_account_number:settings.account_number,p_qr_image_url:settings.qr_image_url,p_instructions:settings.instructions,p_active:settings.active});setSaving(false);setMessage(error?error.message:"GCash settings saved for this organization.")}
 return <main className="workspace"><header><div><p className="eyebrow">PAYMENT SETTINGS</p><h1>GCash</h1><p className="muted">Configure this organization's own GCash merchant account. Payments are never shared with another LabaFlow organization.</p></div></header>{message&&<p className="notice">{message}</p>}<section className="panel"><div className="panelHead"><div><h2>GCash Account</h2><span>Phase 1 uses your merchant QR with cashier confirmation. Automatic confirmation can be enabled later through a connected gateway.</span></div><button className="miniBtn" onClick={()=>setSettings(x=>({...x,active:!x.active}))}>{settings.active?"Enabled":"Disabled"}</button></div><form className="stack" onSubmit={save}><label>Integration Type<select value={settings.integration_type} onChange={e=>setSettings({...settings,integration_type:e.target.value as GCashSettings["integration_type"]})}><option value="manual_qr">Manual QR</option><option value="gateway" disabled>Payment Gateway — coming next</option></select></label><div className="gridForm"><label>Merchant / Business Name<input value={settings.merchant_name} onChange={e=>setSettings({...settings,merchant_name:e.target.value})} placeholder="ABC Laundry"/></label><label>GCash Number<input value={settings.account_number} onChange={e=>setSettings({...settings,account_number:e.target.value})} placeholder="09XX XXX XXXX"/></label></div><label>GCash QR Code<input type="file" accept="image/png,image/jpeg,image/webp" disabled={uploading} onChange={e=>{const f=e.target.files?.[0];if(f)uploadQr(f)}}/><small>{uploading?"Uploading QR image…":"Upload your GCash or QRPH merchant QR image (PNG, JPG, or WEBP, max 5 MB)."}</small></label>{settings.qr_image_url&&<div className="customerCard"><img src={settings.qr_image_url} alt="Organization GCash QR" style={{maxWidth:280,width:"100%",height:"auto"}}/><strong>{settings.merchant_name||"GCash Merchant"}</strong><span>{settings.account_number}</span><button type="button" className="secondary" onClick={()=>setSettings(s=>({...s,qr_image_url:""}))}>Remove QR</button></div>}<label>Payment Instructions<textarea value={settings.instructions} onChange={e=>setSettings({...settings,instructions:e.target.value})}/></label><button className="primary" disabled={saving||uploading}>{saving?"Saving…":"Save GCash Settings"}</button></form></section><section className="panel"><h2>Automatic Payment Confirmation</h2><p className="muted">The data model is gateway-ready, but automatic confirmation stays disabled until a payment provider is connected securely through a server-side integration. Provider secret keys will not be stored in the browser.</p></section></main>
}
