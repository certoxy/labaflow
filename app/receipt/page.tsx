"use client";
import {useEffect,useState} from "react";
import {supabase} from "../../lib/supabase";
import {getStoredLocalStaffSession} from "../../lib/localStaff";
import "./receipt.css";

const peso=new Intl.NumberFormat("en-PH",{style:"currency",currency:"PHP"});
const label=(s:string)=>s.replaceAll("_"," ").replace(/\b\w/g,c=>c.toUpperCase());

export default function ReceiptPage(){
 const [data,setData]=useState<any>(null),[branding,setBranding]=useState<any>(null),[error,setError]=useState("");
 const id=typeof window!=="undefined"?new URLSearchParams(location.search).get("id"):null;

 useEffect(()=>{(async()=>{
  if(!id)return setError("Order ID is missing.");
  const local=getStoredLocalStaffSession();let result:any;
  if(local){
   const r=await supabase.rpc("get_local_staff_order_checkout",{p_token:local.token,p_order_id:id});
   if(r.error)return setError(r.error.message);result=r.data;
  }else{
   const [o,i,p]=await Promise.all([
    supabase.from("laundry_orders").select("id,order_code,status,payment_status,subtotal,discount,total,amount_paid,created_at,notes,customers(full_name,customer_code,loyalty_points),branches(name,address,phone)").eq("id",id).maybeSingle(),
    supabase.from("laundry_order_items").select("id,quantity,unit_price,line_total,services(name,pricing_unit)").eq("order_id",id).order("created_at"),
    supabase.from("payments").select("id,amount,method,reference,created_at").eq("order_id",id).order("created_at")
   ]);
   if(o.error||!o.data)return setError(o.error?.message||"Order not found.");
   result={order:o.data,items:(i.data??[]).map((x:any)=>({...x,service_name:Array.isArray(x.services)?x.services[0]?.name:x.services?.name})),payments:p.data??[]};
  }
  setData(result);
  const b=await supabase.rpc("get_receipt_branding",{p_order_id:id,p_staff_token:local?.token??null});
  if(!b.error)setBranding(b.data);
 })()},[id]);

 if(error)return <main className="center"><section className="onboardCard"><h2>Receipt unavailable</h2><p>{error}</p></section></main>;
 if(!data)return <main className="center"><div className="loader">Loading receipt…</div></main>;

 const o=data.order;
 const customer=Array.isArray(o.customers)?o.customers[0]:o.customers;
 const branch=Array.isArray(o.branches)?o.branches[0]:o.branches;
 const items=data.items??[],payments=data.payments??[];
 const balance=Math.max(Number(o.total)-Number(o.amount_paid),0);
 const points=Number(customer?.loyalty_points??data.customer?.loyalty_points??0);
 const business=branding?.organization_name||"LabaFlow";
 const branchName=branding?.branch_name||branch?.name||"";
 const logo=branding?.branch_logo_url||branding?.organization_logo_url||"/labaflow-icon.svg";
 const address=branding?.branch_address||branding?.business_address||branch?.address;
 const phone=branding?.branch_phone||branding?.business_phone||branch?.phone;
 const email=branding?.business_email;
 const website=branding?.business_website;
 const thanks=branding?.receipt_footer||`Thank you for choosing ${business}.`;

 return <main className="receiptPage">
  <div className="receiptToolbar noPrint">
   <button onClick={()=>history.back()}>← Back</button>
   <button onClick={()=>window.print()}>↗ Share / Print</button>
   <button onClick={()=>window.print()}>🖨 Print / PDF</button>
  </div>

  <article className="receiptCard">
   <header className="receiptBrandHeader">
    <img src={logo} alt={`${business} logo`}/>
    <h1>{business}</h1>
    {branchName&&branchName!==business&&<p className="receiptBranch">{branchName}</p>}
    <small className="receiptType">Laundry Service Receipt</small>

    {(address||phone||email||website)&&<div className="receiptContactBar">
     <div className="receiptContactItem"><span className="receiptContactIcon">⌖</span><span>{address||"—"}</span></div>
     <div className="receiptContactItem"><span className="receiptContactIcon">☎</span><span>{phone||"—"}</span></div>
     <div className="receiptContactItem"><span className="receiptContactIcon">✉</span><span>{email||"—"}</span></div>
     <div className="receiptContactItem"><span className="receiptContactIcon">◎</span><span>{website||"—"}</span></div>
    </div>}
   </header>

   <section className="receiptMeta">
    <div><span>Order</span><b>{o.order_code}</b></div>
    <div><span>Date</span><b>{new Date(o.created_at).toLocaleString()}</b></div>
    <div><span>Customer</span><b>{customer?.full_name||"Walk-in Customer"}</b></div>
    <div><span>Status</span><b>{label(o.status)}</b></div>
    {customer?.customer_code&&<div><span>Customer Code</span><b>{customer.customer_code}</b></div>}
    <div><span>Payment</span><b>{balance<=0?"Paid":label(o.payment_status)}</b></div>
    {customer&&<div><span>Loyalty Points</span><b>{points.toLocaleString()} points</b></div>}
   </section>

   <section className="receiptSection">
    <h2>Services</h2>
    <table className="receiptTable">
     <thead><tr><th>Service</th><th>Qty</th><th>Rate</th><th>Amount</th></tr></thead>
     <tbody>{items.map((x:any)=><tr key={x.id}><td>{x.service_name||"Service"}</td><td>{x.quantity}</td><td>{peso.format(Number(x.unit_price))}</td><td>{peso.format(Number(x.line_total))}</td></tr>)}</tbody>
    </table>
    <div className="receiptTotals">
     <div><span>Subtotal</span><b>{peso.format(Number(o.subtotal))}</b></div>
     {Number(o.discount)>0&&<div><span>Discount</span><b>-{peso.format(Number(o.discount))}</b></div>}
     <div className="grand"><span>Total</span><b>{peso.format(Number(o.total))}</b></div>
     <div><span>Paid</span><b>{peso.format(Number(o.amount_paid))}</b></div>
     <div className={balance>0?"balanceDue":""}><span>Balance</span><b>{peso.format(balance)}</b></div>
    </div>
   </section>

   <section className="receiptSection">
    <h2>Payments</h2>
    {payments.length?<table className="receiptTable receiptPaymentsTable">
     <thead><tr><th>Date & Time</th><th>Method</th><th>Amount</th></tr></thead>
     <tbody>{payments.map((p:any)=><tr key={p.id}><td>{new Date(p.created_at).toLocaleString()}</td><td>{label(p.method)}</td><td>{peso.format(Number(p.amount))}</td></tr>)}</tbody>
    </table>:<p className="receiptPaymentEmpty">No payment recorded yet.</p>}
   </section>

   <div className="receiptThanks">
    <span className="receiptThanksIcon">♡</span>
    <div><strong>{thanks}</strong><small>We appreciate your trust in our laundry service.</small></div>
   </div>

   <div className="receiptPowered" data-labaflow-powered>
    <span className="receiptPoweredLogo">◉</span>Powered by <b>LabaFlow</b> · labaflow.paotechs.com · © 2026 PAO Technologies. All rights reserved.
   </div>
  </article>
 </main>;
}
