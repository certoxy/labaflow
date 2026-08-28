"use client";

import {useEffect,useMemo,useState} from "react";
import {supabase} from "../../lib/supabase";

type DispatchJob={job_type:"pickup"|"delivery";status:string};
type Order={id:string;order_code:string;branch_id:string;customer_id:string|null;status:string;payment_status:string;subtotal:number;discount:number;total:number;amount_paid:number;created_at:string;delivery_addon_type?:"pickup"|"delivery"|"pickup_delivery"|null;delivery_distance_label?:string|null;delivery_fee?:number;delivery_jobs?:DispatchJob[];customers:{full_name:string;customer_code:string}|null};
type Access={settings?:Record<string,any>;permissions?:Record<string,boolean>};
type GCashAccount={integration_type:string;merchant_name:string|null;account_number:string|null;qr_image_url:string|null;instructions:string|null;active:boolean};
type QrPayment={transaction_id?:string;payment_intent_id?:string;amount:number;status:string;qr_image_data?:string|null;expires_at?:string|null;loading?:boolean;error?:string|null};
const peso=new Intl.NumberFormat("en-PH",{style:"currency",currency:"PHP"});
const label=(s:string)=>s==="qrph"?"QR Ph":s.replaceAll("_"," ").replace(/\b\w/g,c=>c.toUpperCase());
const fallbackWorkflow=["received","sorting","washing","drying","folding","ready","completed"];
const fallbackPayments=["cash","gcash","maya","card","bank_transfer","qrph"];

export default function OrdersPage(){
 const [orders,setOrders]=useState<Order[]>([]),[access,setAccess]=useState<Access>({}),[gcash,setGcash]=useState<GCashAccount|null>(null),[message,setMessage]=useState(""),[search,setSearch]=useState(""),[statusFilter,setStatusFilter]=useState("all");
 const [payment,setPayment]=useState<Record<string,{amount:string;method:string;reference:string}>>({});
 const [qrPayments,setQrPayments]=useState<Record<string,QrPayment>>({});
 useEffect(()=>{load()},[]);
 useEffect(()=>{
  const timer=setInterval(()=>{
   Object.entries(qrPayments).forEach(([orderId,q])=>{if(q.status==="awaiting_payment")checkQr(orderId,false)});
  },3000);
  return()=>clearInterval(timer);
 },[qrPayments]);
 async function load(){
  setMessage("");
  const [a,o,g]=await Promise.all([
   supabase.rpc("get_current_access_context"),
   supabase.from("laundry_orders").select("id,order_code,branch_id,customer_id,status,payment_status,subtotal,discount,total,amount_paid,created_at,delivery_addon_type,delivery_distance_label,delivery_fee,delivery_jobs(job_type,status),customers(full_name,customer_code)").order("created_at",{ascending:false}).limit(200),
   supabase.rpc("get_organization_payment_account",{p_payment_method:"gcash"})
  ]);
  if(a.error||o.error){setMessage(a.error?.message||o.error?.message||"Unable to load orders");return}
  setAccess(a.data??{});
  setOrders((o.data??[]).map((x:any)=>({...x,subtotal:Number(x.subtotal),discount:Number(x.discount),total:Number(x.total),amount_paid:Number(x.amount_paid),delivery_fee:Number(x.delivery_fee??0)})));
  if(!g.error)setGcash(g.data??null);
 }
 const permissions=access.permissions??{};const workflow=(access.settings?.order_workflow?.stages as string[]|undefined)?.filter(Boolean)??fallbackWorkflow;const methods=(access.settings?.payment_methods?.methods as string[]|undefined)?.filter(Boolean)??fallbackPayments;const requireFull=Boolean(access.settings?.completion_rules?.require_full_payment_before_completion);
 const nextStatus=(s:string)=>{const i=workflow.indexOf(s);return i>=0&&i<workflow.length-1?workflow[i+1]:null};
 async function move(o:Order){const next=nextStatus(o.status);if(!next)return;if(next==="completed"&&requireFull&&o.amount_paid<o.total){setMessage(`Full payment is required before completing ${o.order_code}.`);return}const {error}=await supabase.rpc("update_order_status",{p_order_id:o.id,p_status:next,p_notes:null});if(error)setMessage(error.message);else await load()}
 async function pay(o:Order){const p=payment[o.id]??{amount:"",method:methods[0]??"cash",reference:""};if(p.method==="qrph"){await generateQr(o);return}const amount=Number(p.amount);if(!amount)return;const {error}=await supabase.rpc("record_order_payment",{p_order_id:o.id,p_amount:amount,p_method:p.method,p_reference:p.reference||null});if(error){setMessage(error.message);return}setPayment(x=>({...x,[o.id]:{amount:"",method:p.method,reference:""}}));await load();setMessage(amount>=Math.max(o.total-o.amount_paid,0)?"Payment completed. Loyalty rewards were calculated automatically.":"Partial payment recorded.")}
 async function generateQr(o:Order){
  const p=payment[o.id]??{amount:"",method:"qrph",reference:""};const balance=Math.max(o.total-o.amount_paid,0);const amount=Number(p.amount)||balance;
  if(amount<=0||amount>balance){setMessage("Enter a valid QR Ph payment amount up to the remaining balance.");return}
  setQrPayments(x=>({...x,[o.id]:{amount,status:"creating",loading:true,error:null}}));
  const {data,error}=await supabase.functions.invoke("create-paymongo-qr",{body:{order_id:o.id,amount}});
  if(error||data?.error){const detail=data?.error||error?.message||"Unable to generate QR Ph";setQrPayments(x=>({...x,[o.id]:{amount,status:"failed",loading:false,error:detail}}));setMessage(detail);return}
  setQrPayments(x=>({...x,[o.id]:{transaction_id:data.transaction_id,payment_intent_id:data.payment_intent_id,amount:Number(data.amount),status:data.status,qr_image_data:data.qr_image_data,expires_at:data.expires_at,loading:false,error:null}}));
  setMessage(`QR Ph generated for ${o.order_code}. Waiting for PayMongo payment confirmation.`);
 }
 async function checkQr(orderId:string,showMessage=true){
  const {data,error}=await supabase.rpc("get_order_gateway_transaction",{p_order_id:orderId});
  if(error){if(showMessage)setMessage(error.message);return}
  if(!data)return;
  const status=data.status as string;
  setQrPayments(x=>({...x,[orderId]:{...(x[orderId]??{amount:Number(data.amount)}),transaction_id:data.id,payment_intent_id:data.provider_payment_intent_id,amount:Number(data.amount),status,qr_image_data:data.qr_image_data,expires_at:data.expires_at,loading:false,error:null}}));
  if(status==="paid"){
   await load();setMessage("QR Ph payment confirmed automatically. Order payment and loyalty were updated.");
  }else if(showMessage)setMessage(status==="expired"?"QR Ph expired. Generate a new QR to continue.":status==="failed"?"QR Ph payment failed. Generate a new QR to retry.":"Payment is still awaiting confirmation.");
 }
 const visible=useMemo(()=>{const q=search.trim().toLowerCase();return orders.filter(o=>(statusFilter==="all"||o.status===statusFilter)&&(!q||`${o.order_code} ${o.customers?.full_name??""} ${o.customers?.customer_code??""}`.toLowerCase().includes(q)))},[orders,search,statusFilter]);
 const stats=useMemo(()=>({open:orders.filter(o=>!["completed","cancelled"].includes(o.status)).length,ready:orders.filter(o=>o.status==="ready").length,unpaid:orders.filter(o=>o.amount_paid<o.total).length,revenue:orders.filter(o=>o.payment_status==="paid"||o.amount_paid>=o.total).reduce((n,o)=>n+o.total,0)}),[orders]);
 return <main className="workspace ordersExperience"><header><div><p className="eyebrow">ORDERS</p><h1>Order Management</h1><p className="muted">Track laundry progress, payments, and Pickup/Delivery from one place.</p></div><div className="headerActions"><button className="primary" onClick={()=>location.href="/new-order"}>+ New Order</button></div></header>{message&&<p className="notice">{message}</p>}
 <section className="stats orderStats"><article><span>Open Orders</span><strong>{stats.open}</strong></article><article><span>Ready</span><strong>{stats.ready}</strong></article><article><span>Unpaid</span><strong>{stats.unpaid}</strong></article><article><span>Paid Revenue</span><strong>{peso.format(stats.revenue)}</strong></article></section>
 <section className="panel ordersPanel"><div className="ordersToolbar"><div><h2>Orders</h2><span>{visible.length} shown · {orders.length} total</span></div><div className="ordersFilters"><select value={statusFilter} onChange={e=>setStatusFilter(e.target.value)}><option value="all">All statuses</option>{workflow.map(s=><option key={s} value={s}>{label(s)}</option>)}</select><input placeholder="Search order or customer" value={search} onChange={e=>setSearch(e.target.value)}/></div></div><div className="orderList">{visible.map(o=>{const p=payment[o.id]??{amount:"",method:methods[0]??"cash",reference:""};const next=nextStatus(o.status);const paid=o.payment_status==="paid"||o.amount_paid>=o.total;const balance=Math.max(o.total-o.amount_paid,0);const gcashAmount=Number(p.amount)||balance;const q=qrPayments[o.id];return <article className="orderCard polishedOrder" key={o.id}><div className="orderTop"><div><strong>{o.order_code}</strong><small>{o.customers?.full_name??"Walk-in"}{o.customers?.customer_code?` · ${o.customers.customer_code}`:""}</small></div><div><span className={`status ${o.status}`}>{label(o.status)}</span><b>{peso.format(o.total)}</b></div></div><div className="orderMeta"><span>Paid <b>{peso.format(o.amount_paid)}</b></span><span>Balance <b>{peso.format(balance)}</b></span><span>Payment <b>{paid?"Paid":label(o.payment_status)}</b></span>{o.delivery_addon_type&&<span>Pickup/Delivery <b>{label(o.delivery_addon_type)}{o.delivery_distance_label?` · ${o.delivery_distance_label}`:""}</b></span>}</div><div className="orderActions">{o.delivery_jobs?.length?<button className="secondary" onClick={()=>location.href="/pickup-delivery"}>Dispatch Board</button>:null}{permissions.process_orders&&next&&<button className="secondary" disabled={next==="completed"&&requireFull&&!paid} onClick={()=>move(o)}>{next==="completed"?"Complete Order":`Move to ${label(next)}`}</button>}{permissions.record_payments&&(paid?<span className="status active">✓ Paid</span>:<><select value={p.method} onChange={e=>{const method=e.target.value;setPayment(x=>({...x,[o.id]:{...p,method,amount:(method==="gcash"||method==="qrph")&&!p.amount?balance.toFixed(2):p.amount}}))}}>{methods.map(m=><option key={m} value={m}>{label(m)}</option>)}</select><input type="number" min="0.01" max={balance} step="0.01" placeholder={`Balance ${peso.format(balance)}`} value={p.amount} onChange={e=>setPayment(x=>({...x,[o.id]:{...p,amount:e.target.value}}))}/>{p.method!=="gcash"&&p.method!=="qrph"&&<input placeholder="Reference (optional)" value={p.reference} onChange={e=>setPayment(x=>({...x,[o.id]:{...p,reference:e.target.value}}))}/>}<button className="primary" disabled={p.method==="qrph"&&q?.loading} onClick={()=>pay(o)}>{p.method==="gcash"?"Confirm GCash Payment":p.method==="qrph"?(q?.loading?"Generating…":"Generate QR Ph"):"Record Payment"}</button></>)}</div>{permissions.record_payments&&!paid&&p.method==="gcash"&&<div className="panel" style={{marginTop:14}}><div style={{display:"flex",gap:20,alignItems:"center",flexWrap:"wrap"}}>{gcash?.qr_image_url?<img src={gcash.qr_image_url} alt="GCash QR" style={{width:220,maxWidth:"100%",height:"auto",borderRadius:12}}/>:<div className="notice">GCash QR is not configured. Ask an Organization Admin to set it under Payment Settings.</div>}<div style={{minWidth:220,flex:1}}><p className="eyebrow">GCASH PAYMENT</p><h3 style={{marginTop:4}}>{peso.format(gcashAmount)}</h3><p><strong>{gcash?.merchant_name||"GCash Merchant"}</strong>{gcash?.account_number?<><br/>{gcash.account_number}</>:null}</p><p className="muted">{gcash?.instructions||"Ask the customer to scan the QR and confirm the successful payment before recording it."}</p><label>GCash Reference / Transaction No.<input placeholder="Optional but recommended" value={p.reference} onChange={e=>setPayment(x=>({...x,[o.id]:{...p,reference:e.target.value}}))}/></label><small className="muted">Manual confirmation: verify the customer's successful GCash receipt or merchant notification, then click Confirm GCash Payment.</small></div></div></div>}{permissions.record_payments&&!paid&&p.method==="qrph"&&<div className="panel" style={{marginTop:14}}><p className="eyebrow">QR PH · PAYMONGO</p><h3 style={{marginTop:4}}>{peso.format(q?.amount??Number(p.amount)||balance)}</h3>{q?.qr_image_data&&q.status==="awaiting_payment"?<div style={{display:"flex",gap:20,alignItems:"center",flexWrap:"wrap"}}><img src={q.qr_image_data} alt="PayMongo QR Ph" style={{width:240,maxWidth:"100%",height:"auto",borderRadius:12}}/><div style={{minWidth:220,flex:1}}><p><strong>Scan using GCash, Maya, or a participating bank app.</strong></p><p className="muted">LabaFlow is waiting for PayMongo to confirm the payment automatically.</p>{q.expires_at&&<p className="muted">Expires: {new Date(q.expires_at).toLocaleString()}</p>}<button className="secondary" onClick={()=>checkQr(o.id)}>Check Payment</button></div></div>:q?.status==="paid"?<p className="notice">✓ Payment confirmed automatically.</p>:q?.error?<p className="notice">{q.error}</p>:q&&(q.status==="expired"||q.status==="failed")?<><p className="notice">QR Ph {q.status}. Generate a new QR to retry.</p><button className="secondary" onClick={()=>generateQr(o)}>Generate New QR</button></>:<p className="muted">Click Generate QR Ph to create a unique QR for this order. The QR can be scanned with GCash, Maya, or participating banking apps.</p>}</div>}</article>})}{!visible.length&&<p className="empty">No orders match your filters.</p>}</div></section></main>
}
