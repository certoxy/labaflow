"use client";
import {useEffect,useState} from "react";
import QRCode from "qrcode";
import {supabase} from "../../../lib/supabase";

type PortalQr={organization_id:string;organization_name:string;enrollment_token:string};

export default function OrganizationCustomerQrPage(){
 const [qr,setQr]=useState<PortalQr|null>(null),[image,setImage]=useState(""),[message,setMessage]=useState("Loading customer QR…");
 useEffect(()=>{load()},[]);
 async function load(){
  setMessage("");
  const {data,error}=await supabase.rpc("get_organization_customer_qr");
  if(error||!data){setMessage(error?.message||"Unable to create customer enrollment QR.");return}
  const d=data as PortalQr;setQr(d);
  const link=`${window.location.origin}/customer/join?org=${d.enrollment_token}`;
  setImage(await QRCode.toDataURL(link,{width:520,margin:3,errorCorrectionLevel:"M"}));
 }
 async function copyLink(){if(!qr)return;const link=`${window.location.origin}/customer/join?org=${qr.enrollment_token}`;await navigator.clipboard.writeText(link);setMessage("Customer enrollment link copied.")}
 function download(){if(!image||!qr)return;const a=document.createElement("a");a.href=image;a.download=`${qr.organization_name.replace(/[^a-z0-9]+/gi,"-").toLowerCase()}-customer-qr.png`;a.click()}
 return <main className="workspace orgCustomerQrPage"><header><div><p className="eyebrow">CUSTOMER PORTAL</p><h1>Customer Scan QR</h1><p className="muted">Display or print this QR at the counter. Customers scan it to register for My LabaFlow and connect directly to your organization.</p></div><div className="headerActions"><button className="secondary" onClick={()=>location.href="/organization"}>Organization Admin</button></div></header>{message&&<p className="notice">{message}</p>}<section className="panel orgQrPanel"><div className="orgQrIntro"><div><h2>{qr?.organization_name||"Organization Customer QR"}</h2><p className="muted">This QR is organization-specific and permanent. It can be placed at your counter, on receipts, posters, or social posts.</p></div><span className="status active">Customer Portal Active</span></div>{image&&<div className="orgQrDisplay"><div className="orgQrPrintCard"><p className="eyebrow">SCAN TO JOIN</p><h2>{qr?.organization_name}</h2><img src={image} alt="Organization customer enrollment QR"/><strong>My LabaFlow</strong><span>Track your laundry. View your rewards.</span></div><div className="orgQrActions"><button className="primary" onClick={()=>window.print()}>Print QR</button><button className="secondary" onClick={download}>Download PNG</button><button className="secondary" onClick={copyLink}>Copy Link</button></div></div>}</section><section className="panel"><h2>Customer Experience</h2><div className="orgQrSteps"><div><b>1</b><span><strong>Scan</strong><small>Customer scans your QR with their phone.</small></span></div><div><b>2</b><span><strong>Register</strong><small>Customer enters name plus mobile or email.</small></span></div><div><b>3</b><span><strong>Connect</strong><small>Existing customer is matched or a new record is created for your organization.</small></span></div><div><b>4</b><span><strong>Track</strong><small>Customer sees active orders, payment status, and loyalty rewards in My LabaFlow.</small></span></div></div></section></main>}
