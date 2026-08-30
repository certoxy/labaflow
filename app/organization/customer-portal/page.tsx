"use client";
import {useEffect,useState} from "react";
import QRCode from "qrcode";
import {supabase} from "../../../lib/supabase";

export default function CustomerPortalAdminPage(){
 const [orgName,setOrgName]=useState(""),[qr,setQr]=useState(""),[joinUrl,setJoinUrl]=useState(""),[message,setMessage]=useState("Loading customer QR…");
 useEffect(()=>{load()},[]);
 async function load(){
  const {data,error}=await supabase.rpc("get_organization_customer_qr");
  if(error){setMessage(error.message);return}
  const url=`${location.origin}/customer/join?org=${data.enrollment_token}`;
  setOrgName(data.organization_name||"LabaFlow Organization");setJoinUrl(url);
  setQr(await QRCode.toDataURL(url,{width:560,margin:2,errorCorrectionLevel:"M"}));setMessage("");
 }
 async function copy(){await navigator.clipboard.writeText(joinUrl);setMessage("Customer enrollment link copied.")}
 return <main className="workspace customerQrAdminPage"><header><div><p className="eyebrow">CUSTOMER PORTAL</p><h1>Organization Customer QR</h1><p className="muted">Customers scan this QR to register with {orgName||"your organization"}, then use My LabaFlow to follow orders and loyalty rewards.</p></div></header>{message&&<p className="notice">{message}</p>}<section className="panel customerQrAdminGrid"><div className="customerQrPreview">{qr?<><img src={qr} alt={`${orgName} customer enrollment QR`}/><strong>{orgName}</strong><span>Scan to open My LabaFlow</span></>:<p className="muted">Generating QR…</p>}</div><div className="customerQrInstructions"><h2>How customers use it</h2><ol><li>Scan this QR using the phone camera.</li><li>Enter name and mobile number or email.</li><li>LabaFlow creates or connects the customer's record for this organization.</li><li>The customer opens My LabaFlow to see current order status and loyalty rewards.</li></ol><label>Customer enrollment link<input readOnly value={joinUrl}/></label><div className="actions"><button className="primary" onClick={copy} disabled={!joinUrl}>Copy Link</button><button className="secondary" onClick={()=>window.print()} disabled={!qr}>Print QR</button></div></div></section><section className="panel"><h2>Recommended placement</h2><p className="muted">Print and display this QR at the counter, cashier area, customer claim area, or include the enrollment link in digital promotions. The same organization QR can be reused for all customers.</p></section></main>
}
