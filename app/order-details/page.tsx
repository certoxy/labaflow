"use client";

import {useEffect,useMemo,useState} from "react";
import {supabase} from "../../lib/supabase";
import {getStoredLocalStaffSession,getLocalStaffOperationalContext} from "../../lib/localStaff";

type Order={id:string;order_code:string;branch_id:string;customer_id:string|null;status:string;payment_status:string;subtotal:number;discount:number;total:number;amount_paid:number;notes:string|null;created_at:string;customers:{full_name:string;customer_code:string}|null};
type Access={settings?:Record<string,any>;permissions?:Record<string,boolean>;branches?:{id:string;name:string}[]};
type GCashAccount={merchant_name:string|null;account_number:string|null;qr_image_url:string|null;instructions:string|null;active:boolean};
const peso=new Intl.NumberFormat("en-PH",{style:"currency",currency:"PHP"});
const label=(s:string)=>s.replaceAll("_"," ").replace(/\b\w/g,c=>c.toUpperCase());
const defaultMethods=["cash","gcash","maya","card","bank_transfer","qrph"];

export default function OrderDetailsPage(){
 const [order,setOrder]=useState<Order|null>(null),[access,setAccess]=useState<Access>({}),[gcash,setGcash]=useState<GCashAccount|null>(null),[message,setMessage]=useState(""),[loading,setLoading]=useState(true);
 const [payment,setPayment]=useState({amount:"",method:"cash",reference:""});
 const orderId=typeof window!=="undefined"?new URLSearchParams(window.location.search).get("id"):null;
 useEffect(()=>{void load()},[]);
 async function load(){
  setLoading(true);setMessage("");
  if(!orderId){setMessage("Order ID is missing.");setLoading(false);return}
  const local=getStoredLocalStaffSession();
  if(local){
   const r=await getLocalStaffOperationalContext();
   if(r.error||!r.data){setMessage(r.error?.message||"Staff session expired. Sign in again.");setLoading(false);return}
   const found=(r.data.orders??[]).find((x:any)=>x.id===orderId);
   if(!found){setMessage("Order not found in your current branch access.");setLoading(false);return}
   setOrder({...found,subtotal:Number(found.subtotal),discount:Number(found.discount),total:Number(found.total),amount_paid:Number(found.amount_paid),notes:found.notes??null});
   const nextAccess={permissions:r.data.permissions??{},branches:r.data.branches??[],settings:r.data.settings??{}};setAccess(nextAccess);
   const methods=(nextAccess.settings?.payment_methods?.methods as string[]|undefined)?.filter(Boolean)??defaultMethods;setPayment(p=>({...p,method:methods[0]??"cash"}));setLoading(false);return
  }
  const [a,o,g]=await Promise.all([
   supabase.rpc("get_current_access_context"),
   supabase.from("laundry_orders").select("id,order_code,branch_id,customer_id,status,payment_status,subtotal,discount,total,amount_paid,notes,created_at,customers(full_name,customer_code)").eq("id",orderId).maybeSingle(),
   supabase.rpc("get_organization_payment_account",{p_payment_method:"gcash"})
  ]);
  if(a.error||o.error||!o.data){setMessage(a.error?.message||o.error?.message||"Order not found.");setLoading(false);return}
  const normalized={...(o.data as any),subtotal:Number((o.data as any).subtotal),discount:Number((o.data as any).discount),total:Number((o.data as any).total),amount_paid:Number((o.data as any).amount_paid)} as Order;
  setOrder(normalized);setAccess(a.data??{});if(!g.error)setGcash(g.data??null);
  const methods=((a.data?.settings?.payment_methods?.methods as string[]|undefined)?.filter(Boolean)??defaultMethods);setPayment(p=>({...p,method:methods[0]??"cash",amount:Math.max(normalized.total-normalized.amount_paid,0).toFixed(2)}));setLoading(false)
 }
 const methods=(access.settings?.payment_methods?.methods as string[]|undefined)?.filter(Boolean)??defaultMethods;
 const permissions=access.permissions??{};
 const balance=order?Math.max(order.total-order.amount_paid,0):0;
 const paid=order?order.amount_paid>=order.total:false;
 const branchName=useMemo(()=>order?access.branches?.find(b=>b.id===order.branch_id)?.name??"LabaFlow":"LabaFlow",[order,access]);
 async function pay(){
  if(!order||paid)return;const amount=Number(payment.amount);if(!amount||amount<=0)return setMessage("Enter a valid payment amount.");if(amount>balance)return setMessage("Payment exceeds remaining balance.");
  const local=getStoredLocalStaffSession();
  if(local){if(payment.method==="qrph")return setMessage("QR Ph remains online-only through the gateway flow.");const {error}=await supabase.rpc("record_order_payment_local",{p_token:local.token,p_order_id:order.id,p_amount:amount,p_method:payment.method,p_reference:payment.reference||null});if(error)return setMessage(error.message);setMessage(`Payment recorded by ${local.staff.full_name}.`);await load();return}
  if(payment.method==="qrph")return setMessage("QR Ph remains online-only through the gateway flow.");
  const {error}=await supabase.rpc("record_order_payment",{p_order_id:order.id,p_amount:amount,p_method:payment.method,p_reference:payment.reference||null});if(error)return setMessage(error.message);setMessage("Payment recorded.");await load()
 }
 if(loading)return <main className="center"><div className="loader">Loading order…</div></main>;
 if(!order)return <main className="workspace"><p className="notice">{message||"Order not found."}</p><button className="secondary" onClick={()=>location.href="/orders"}>Back to Orders</button></main>;
 return <main className="workspace ordersExperience"><header><div><p className="eyebrow">ORDER CREATED</p><h1>{order.order_code}</h1><p className="muted">Review the order, customer, payment status, and collect payment.</p></div><div className="headerActions"><button className="secondary" onClick={()=>location.href="/new-order"}>+ New Order</button><button className="secondary" onClick={()=>location.href="/orders"}>All Orders</button></div></header>{message&&<p className="notice">{message}</p>}
 <section className="stats orderStats"><article><span>Order Status</span><strong>{label(order.status)}</strong></article><article><span>Payment Status</span><strong>{paid?"Paid":label(order.payment_status)}</strong></article><article><span>Total</span><strong>{peso.format(order.total)}</strong></article><article><span>Balance</span><strong>{peso.format(balance)}</strong></article></section>
 <section className="panel"><div className="panelHead"><div><p className="eyebrow">ORDER DETAILS</p><h2>{order.customers?.full_name??"Walk-in Customer"}</h2><span>{order.customers?.customer_code??"No customer account"} · {branchName}</span></div><span className={`status ${order.status}`}>{label(order.status)}</span></div><div className="settingsGrid"><div><span>Subtotal</span><strong>{peso.format(order.subtotal)}</strong></div><div><span>Discounts / Points</span><strong>{peso.format(order.discount)}</strong></div><div><span>Amount Paid</span><strong>{peso.format(order.amount_paid)}</strong></div><div><span>Balance Due</span><strong>{peso.format(balance)}</strong></div></div>{order.notes&&<p className="muted"><strong>Notes:</strong> {order.notes}</p>}</section>
 {!paid&&permissions.record_payments!==false&&<section className="panel"><div className="panelHead"><div><p className="eyebrow">PAYMENT</p><h2>Payment Options</h2><span>Collect now or leave the order unpaid/partial.</span></div></div><div className="gridForm"><label>Payment Method<select value={payment.method} onChange={e=>setPayment({...payment,method:e.target.value,amount:payment.amount||balance.toFixed(2)})}>{methods.map(m=><option value={m} key={m}>{label(m)}</option>)}</select></label><label>Amount<input type="number" min="0.01" max={balance} step="0.01" value={payment.amount} onChange={e=>setPayment({...payment,amount:e.target.value})}/></label><label className="wide">Reference / Transaction No.<input value={payment.reference} onChange={e=>setPayment({...payment,reference:e.target.value})} placeholder="Optional for cash; recommended for digital payments"/></label></div>{payment.method==="gcash"&&<div className="panel" style={{marginTop:16}}><div style={{display:"flex",gap:20,alignItems:"center",flexWrap:"wrap"}}>{gcash?.qr_image_url?<img src={gcash.qr_image_url} alt="GCash QR" style={{width:220,maxWidth:"100%",height:"auto",borderRadius:12}}/>:<div className="notice">GCash QR is not available in this session. You can still record the payment after confirming it manually.</div>}<div><p className="eyebrow">GCASH PAYMENT</p><h3>{peso.format(Number(payment.amount)||balance)}</h3>{gcash?.merchant_name&&<p><strong>{gcash.merchant_name}</strong>{gcash.account_number?<><br/>{gcash.account_number}</>:null}</p>}<p className="muted">{gcash?.instructions||"Confirm the customer's successful GCash payment before recording it."}</p></div></div></div>}<div className="actions" style={{marginTop:18}}><button className="primary" onClick={pay}>Record Payment</button><button className="secondary" onClick={()=>location.href="/orders"}>Pay Later</button></div></section>}
 {paid&&<section className="panel"><p className="notice"><strong>✓ Payment complete.</strong> This order has been fully paid.</p><div className="actions"><button className="primary" onClick={()=>location.href="/orders"}>Continue to Order Management</button><button className="secondary" onClick={()=>location.href="/new-order"}>Create Another Order</button></div></section>}
 </main>
}
