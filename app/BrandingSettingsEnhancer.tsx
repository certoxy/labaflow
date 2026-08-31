"use client";

import {ChangeEvent,useEffect,useState} from "react";
import {createPortal} from "react-dom";
import {supabase} from "../lib/supabase";

type Org={id:string;name:string;logo_url?:string|null};
type Branch={id:string;name:string;code:string;logo_url?:string|null};
const allowed=["image/png","image/jpeg","image/webp"];

export default function BrandingSettingsEnhancer(){
 const [host,setHost]=useState<HTMLElement|null>(null),[org,setOrg]=useState<Org|null>(null),[branches,setBranches]=useState<Branch[]>([]),[message,setMessage]=useState(""),[busy,setBusy]=useState("");
 useEffect(()=>{
  if(location.pathname!=="/organization")return;
  let mounted=true,observer:MutationObserver;
  const find=()=>{const head=document.querySelector<HTMLElement>(".orgAdminPage .panelHead");if(head&&!document.getElementById("branding-settings-host")){const node=document.createElement("div");node.id="branding-settings-host";head.insertAdjacentElement("afterend",node);if(mounted)setHost(node)}};
  find();observer=new MutationObserver(find);observer.observe(document.body,{childList:true,subtree:true});
  supabase.auth.getSession().then(({data})=>{if(data.session)load()});
  return()=>{mounted=false;observer.disconnect()};
 },[]);
 async function load(){const {data,error}=await supabase.rpc("get_organization_admin_context");if(error){setMessage(error.message);return}setOrg(data?.organization??null);setBranches(data?.branches??[])}
 function ext(file:File){if(file.type==="image/png")return"png";if(file.type==="image/webp")return"webp";return"jpg"}
 function validate(file:File){if(!allowed.includes(file.type))return"Use a PNG, JPG, or WebP image.";if(file.size>2*1024*1024)return"Logo must be 2 MB or smaller.";return""}
 async function upload(file:File,target:"organization"|"branch",branch?:Branch){
  if(!org)return;const problem=validate(file);if(problem){setMessage(problem);return}setBusy(target==="organization"?"org":branch?.id||"");setMessage("");
  const path=target==="organization"?`${org.id}/organization/logo-${Date.now()}.${ext(file)}`:`${org.id}/branches/${branch!.id}/logo-${Date.now()}.${ext(file)}`;
  const {error:uploadError}=await supabase.storage.from("business-logos").upload(path,file,{cacheControl:"3600",upsert:false,contentType:file.type});
  if(uploadError){setMessage(uploadError.message);setBusy("");return}
  const {data:urlData}=supabase.storage.from("business-logos").getPublicUrl(path);const url=urlData.publicUrl;
  const result=target==="organization"?await supabase.rpc("set_organization_logo",{p_logo_url:url}):await supabase.rpc("set_branch_logo",{p_branch_id:branch!.id,p_logo_url:url});
  if(result.error){setMessage(result.error.message);setBusy("");return}
  setMessage(target==="organization"?"Business logo updated.":`${branch!.name} logo updated.`);await load();setBusy("");window.dispatchEvent(new CustomEvent("labaflow:branding",{detail:target==="organization"?{organization_id:org.id,organization_name:org.name,organization_logo_url:url}:{organization_id:org.id,organization_name:org.name,organization_logo_url:org.logo_url,branch_id:branch!.id,branch_name:branch!.name,branch_logo_url:url}}))
 }
 async function remove(target:"organization"|"branch",branch?:Branch){if(!org)return;setBusy(target==="organization"?"org":branch?.id||"");const result=target==="organization"?await supabase.rpc("set_organization_logo",{p_logo_url:""}):await supabase.rpc("set_branch_logo",{p_branch_id:branch!.id,p_logo_url:""});setMessage(result.error?result.error.message:"Logo removed. Organization logo will be used as fallback.");await load();setBusy("");location.reload()}
 function pick(target:"organization"|"branch",branch?:Branch){return (e:ChangeEvent<HTMLInputElement>)=>{const file=e.target.files?.[0];if(file)upload(file,target,branch);e.target.value=""}}
 if(!host||!org)return null;
 return createPortal(<section className="panel brandingSettingsPanel"><div className="brandingPanelHead"><div><p className="eyebrow">BUSINESS BRANDING</p><h2>Business & Branch Logos</h2><p className="muted">Your uploaded logo replaces the LabaFlow logo throughout your organization. Branch logos override the business logo for that branch.</p></div></div>{message&&<p className="notice">{message}</p>}
  <div className="brandingLogoRow"><div className="brandingPreview">{org.logo_url?<img src={org.logo_url} alt={`${org.name} logo`}/>:<span>LF</span>}</div><div className="brandingLogoInfo"><strong>{org.name}</strong><small>Organization default logo · PNG, JPG, or WebP · max 2 MB</small><div className="brandingActions"><label className="primary brandingUploadButton">{busy==="org"?"Uploading…":"Upload Business Logo"}<input type="file" accept="image/png,image/jpeg,image/webp" disabled={Boolean(busy)} onChange={pick("organization")}/></label>{org.logo_url&&<button className="secondary" disabled={Boolean(busy)} onClick={()=>remove("organization")}>Remove</button>}</div></div></div>
  <h3>Branch Logos</h3><div className="brandingBranchGrid">{branches.map(b=><article key={b.id} className="brandingBranchCard"><div className="brandingPreview small">{b.logo_url?<img src={b.logo_url} alt={`${b.name} logo`}/>:org.logo_url?<img src={org.logo_url} alt={`${org.name} logo`}/>:<span>LF</span>}</div><div><strong>{b.name}</strong><small>{b.code} · {b.logo_url?"Custom branch logo":"Using business logo"}</small></div><div className="brandingActions"><label className="miniBtn brandingUploadButton">{busy===b.id?"Uploading…":"Upload"}<input type="file" accept="image/png,image/jpeg,image/webp" disabled={Boolean(busy)} onChange={pick("branch",b)}/></label>{b.logo_url&&<button className="miniBtn" disabled={Boolean(busy)} onClick={()=>remove("branch",b)}>Use Business Logo</button>}</div></article>)}</div>
 </section>,host)
}
