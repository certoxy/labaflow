"use client";

import {useEffect,useMemo,useState} from "react";
import {supabase} from "../../lib/supabase";
import {getStoredLocalStaffSession,getLocalStaffOperationalContext} from "../../lib/localStaff";

type CustomerRef={full_name:string;customer_code:string};
type BranchRef={id:string;name:string;code?:string|null;address?:string|null;phone?:string|null};
type Order={id:string;order_code:string;branch_id:string;customer_id:string|null;status:string;payment_status:string;subtotal:number;discount:number;total:number;amount_paid:number;notes:string|null;created_at:string;customers:CustomerRef|null;branch?:BranchRef|null};
type OrderItem={id:string;service_id:string;service_name:string;pricing_unit:string;quantity:number;unit_price:number;line_total:number;notes:string|null};
type PaymentRecord={id:string;amount:number;method:string;reference:string|null;created_at:string};
type Access={settings?:Record<string,any>;permissions?:Record<string,boolean>;branches?:BranchRef[]};
type GCashAccount={merchant_name:string|null;account_number:string|null;qr_image_url:string|null;instructions:string|null;active:boolean};
const peso=new Intl.NumberFormat("en-PH",{style:"currency",currency:"PHP"});
const label=(s:string)=>s.replaceAll("_"," ").replace(/\b\w/g,c=>c.toUpperCase());
const defaultMethods=["cash","gcash","maya","card","bank_transfer","qrph"];
const fmtQty=(n:number)=>Number.isInteger(n)?String(n):n.toLocaleString("en-PH",{maximumFractionDigits:2});
const esc=(v:unknown)=>String(v??"").replace(/[&<>"']/g,m=>({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#039;"}[m]||m));

export default function OrderDetailsPage(){
 const [order,setOrder]=useState<Order|null>(null),[items,setItems]=useState<OrderItem[]>([]),[payments,setPayments]=useState<PaymentRecord[]>([]),[access,setAccess]=useState<Access>({}),[gcash,setGcash]=useState<GCashAccount|null>(null),[message,setMessage]=useState(""),[loading,setLoading]=useState(true);
 const [payment,setPayment]=useState({amount:"",method:"cash",reference:""});
 const orderId=typeof window!=="undefined"?new URLSearchParams(window.location.search).get("id"):null;
 useEffect(()=>{void load()},[]);

 async function load(){
  setLoading(true);setMessage("");
  if(!orderId){setMessage("Order ID is missing.");setLoading(false);return}
  const local=getStoredLocalStaffSession();
  if(local){
   const [ctx,detail]=await Promise.all([
    getLocalStaffOperationalContext(),
    supabase.rpc("get_local_staff_order_checkout",{p_token:local.token,p_order_id:orderId})
   ]);
   if(ctx.error||!ctx.data){setMessage(ctx.error?.message||"Staff session expired. Sign in again.");setLoading(false);return}
   if(detail.error||!detail.data){setMessage(detail.error?.message||"Unable to load order checkout details.");setLoading(false);return}
   const raw=detail.data.order;
   const normalized={...raw,subtotal:Number(raw.subtotal),discount:Number(raw.discount),total:Number(raw.total),amount_paid:Number(raw.amount_paid)} as Order;
   setOrder(normalized);
   setItems((detail.data.items??[]).map((x:any)=>({...x,quantity:Number(x.quantity),unit_price:Number(x.unit_price),line_total:Number(x.line_total)})));
   setPayments((detail.data.payments??[]).map((x:any)=>({...x,amount:Number(x.amount)})));
   const nextAccess={permissions:ctx.data.permissions??{},branches:ctx.data.branches??[],settings:ctx.data.settings??{}};setAccess(nextAccess);
   const methods=(nextAccess.settings?.payment_methods?.methods as string[]|undefined)?.filter(Boolean)??defaultMethods;
   setPayment(p=>({...p,method:methods[0]??"cash",amount:Math.max(normalized.total-normalized.amount_paid,0).toFixed(2)}));
   setLoading(false);return
  }

  const [a,o,i,p,g]=await Promise.all([
   supabase.rpc("get_current_access_context"),
   supabase.from("laundry_orders").select("id,order_code,branch_id,customer_id,status,payment_status,subtotal,discount,total,amount_paid,notes,created_at,customers(full_name,customer_code),branches(id,name,code,address,phone)").eq("id",orderId).maybeSingle(),
   supabase.from("laundry_order_items").select("id,service_id,quantity,unit_price,line_total,notes,services(name,pricing_unit)").eq("order_id",orderId).order("created_at"),
   supabase.from("payments").select("id,amount,method,reference,created_at").eq("order_id",orderId).order("created_at"),
   supabase.rpc("get_organization_payment_account",{p_payment_method:"gcash"})
  ]);
  if(a.error||o.error||!o.data||i.error||p.error){setMessage(a.error?.message||o.error?.message||i.error?.message||p.error?.message||"Order not found.");setLoading(false);return}
  const raw=o.data as any;
  const normalized={...raw,subtotal:Number(raw.subtotal),discount:Number(raw.discount),total:Number(raw.total),amount_paid:Number(raw.amount_paid),branch:Array.isArray(raw.branches)?raw.branches[0]??null:raw.branches??null} as Order;
  setOrder(normalized);setAccess(a.data??{});if(!g.error)setGcash(g.data??null);
  setItems((i.data??[]).map((x:any)=>({...x,service_name:Array.isArray(x.services)?x.services[0]?.name??"Service":x.services?.name??"Service",pricing_unit:Array.isArray(x.services)?x.services[0]?.pricing_unit??"":x.services?.pricing_unit??"",quantity:Number(x.quantity),unit_price:Number(x.unit_price),line_total:Number(x.line_total)})));
  setPayments((p.data??[]).map((x:any)=>({...x,amount:Number(x.amount)})));
  const methods=((a.data?.settings?.payment_methods?.methods as string[]|undefined)?.filter(Boolean)??defaultMethods);
  setPayment(x=>({...x,method:methods[0]??"cash",amount:Math.max(normalized.total-normalized.amount_paid,0).toFixed(2)}));setLoading(false)
 }

 const methods=(access.settings?.payment_methods?.methods as string[]|undefined)?.filter(Boolean)??defaultMethods;
 const permissions=access.permissions??{};
 const balance=order?Math.max(order.total-order.amount_paid,0):0;
 const paid=order?order.amount_paid>=order.total:false;
 const branchName=useMemo(()=>order?(order.branch?.name??access.branches?.find(b=>b.id===order.branch_id)?.name??"LabaFlow"):"LabaFlow",[order,access]);

 async function pay(){
  if(!order||paid)return;const amount=Number(payment.amount);if(!amount||amount<=0)return setMessage("Enter a valid payment amount.");if(amount>balance)return setMessage("Payment exceeds remaining balance.");
  const local=getStoredLocalStaffSession();
  if(local){if(payment.method==="qrph")return setMessage("QR Ph remains online-only through the gateway flow.");const {error}=await supabase.rpc("record_order_payment_local",{p_token:local.token,p_order_id:order.id,p_amount:amount,p_method:payment.method,p_reference:payment.reference||null});if(error)return setMessage(error.message);setMessage(`Payment recorded by ${local.staff.full_name}.`);await load();return}
  if(payment.method==="qrph")return setMessage("QR Ph remains online-only through the gateway flow.");
  const {error}=await supabase.rpc("record_order_payment",{p_order_id:order.id,p_amount:amount,p_method:payment.method,p_reference:payment.reference||null});if(error)return setMessage(error.message);setMessage("Payment recorded.");await load()
 }

 function printReceipt(){
  if(!order)return;
  const itemRows=items.map(i=>`<tr><td>${esc(i.service_name)}${i.notes?`<small>${esc(i.notes)}</small>`:""}</td><td class="num">${esc(fmtQty(i.quantity))}</td><td class="num">${esc(peso.format(i.unit_price))}</td><td class="num">${esc(peso.format(i.line_total))}</td></tr>`).join("");
  const paymentRows=payments.length?payments.map(p=>`<tr><td>${esc(new Date(p.created_at).toLocaleString())}</td><td>${esc(label(p.method))}${p.reference?`<small>Ref: ${esc(p.reference)}</small>`:""}</td><td class="num">${esc(peso.format(p.amount))}</td></tr>`).join(""):`<tr><td colspan="3">No payment recorded yet.</td></tr>`;
  const win=window.open("","_blank","width=760,height=900");if(!win)return setMessage("Please allow pop-ups to print the receipt.");
  win.document.write(`<!doctype html><html><head><title>${esc(order.order_code)} Receipt</title><style>body{font-family:Arial,sans-serif;color:#111;margin:28px;max-width:760px}h1,h2,p{margin:0}header{text-align:center;margin-bottom:20px}.muted{color:#666}.line{border-top:1px dashed #777;margin:16px 0}.meta{display:grid;grid-template-columns:1fr 1fr;gap:8px 20px;font-size:14px}.meta div{display:flex;justify-content:space-between;gap:12px}table{width:100%;border-collapse:collapse;margin-top:10px;font-size:13px}th,td{padding:8px 4px;border-bottom:1px solid #ddd;text-align:left;vertical-align:top}.num{text-align:right}small{display:block;color:#666;margin-top:3px}.totals{margin-left:auto;width:min(340px,100%);margin-top:14px}.totals div{display:flex;justify-content:space-between;padding:6px 0}.grand{font-size:18px;font-weight:bold;border-top:2px solid #111}.paid{font-weight:bold}.thanks{text-align:center;margin-top:26px;font-weight:bold}@media print{body{margin:8mm}button{display:none}}</style></head><body><header><h1>LabaFlow</h1><p>${esc(branchName)}</p>${order.branch?.address?`<p class="muted">${esc(order.branch.address)}</p>`:""}<p class="muted">Laundry Service Receipt</p></header><div class="line"></div><div class="meta"><div><span>Order</span><strong>${esc(order.order_code)}</strong></div><div><span>Date</span><strong>${esc(new Date(order.created_at).toLocaleString())}</strong></div><div><span>Customer</span><strong>${esc(order.customers?.full_name??"Walk-in Customer")}</strong></div><div><span>Status</span><strong>${esc(label(order.status))}</strong></div>${order.customers?.customer_code?`<div><span>Customer Code</span><strong>${esc(order.customers.customer_code)}</strong></div>`:""}<div><span>Payment</span><strong>${esc(paid?"Paid":label(order.payment_status))}</strong></div></div><div class="line"></div><h2>Services</h2><table><thead><tr><th>Service</th><th class="num">Qty</th><th class="num">Rate</th><th class="num">Amount</th></tr></thead><tbody>${itemRows||`<tr><td colspan="4">No service lines found.</td></tr>`}</tbody></table><div class="totals"><div><span>Subtotal</span><strong>${esc(peso.format(order.subtotal))}</strong></div>${order.discount>0?`<div><span>Discounts / Points</span><strong>-${esc(peso.format(order.discount))}</strong></div>`:""}<div class="grand"><span>Total</span><strong>${esc(peso.format(order.total))}</strong></div><div><span>Paid</span><strong>${esc(peso.format(order.amount_paid))}</strong></div><div><span>Balance</span><strong>${esc(peso.format(balance))}</strong></div></div>${order.notes?`<div class="line"></div><p><strong>Notes:</strong> ${esc(order.notes)}</p>`:""}<div class="line"></div><h2>Payments</h2><table><thead><tr><th>Date</th><th>Method</th><th class="num">Amount</th></tr></thead><tbody>${paymentRows}</tbody></table><p class="thanks">Thank you for choosing LabaFlow.</p><script>window.onload=()=>{window.print();}</script></body></html>`);
  win.document.close();
 }

 if(loading)return <main className="center"><div className="loader">Loading order…</div></main>;
 if(!order)return <main className="workspace"><p className="notice">{message||"Order not found."}</p><button className="secondary" onClick={()=>location.href="/orders"}>Back to Orders</button></main>;
 return <main className="workspace ordersExperience"><header><div><p className="eyebrow">ORDER CHECKOUT</p><h1>{order.order_code}</h1><p className="muted">Review services, collect payment, and print the customer receipt.</p></div><div className="headerActions"><button className="primary" onClick={printReceipt}>Print Receipt</button><button className="secondary" onClick={()=>location.href="/new-order"}>+ New Order</button><button className="secondary" onClick={()=>location.href="/orders"}>All Orders</button></div></header>{message&&<p className="notice">{message}</p>}
 <section className="stats orderStats"><article><span>Order Status</span><strong>{label(order.status)}</strong></article><article><span>Payment Status</span><strong>{paid?"Paid":label(order.payment_status)}</strong></article><article><span>Total</span><strong>{peso.format(order.total)}</strong></article><article><span>Balance</span><strong>{peso.format(balance)}</strong></article></section>
 <section className="panel"><div className="panelHead"><div><p className="eyebrow">CUSTOMER & ORDER</p><h2>{order.customers?.full_name??"Walk-in Customer"}</h2><span>{order.customers?.customer_code??"No customer account"} · {branchName} · {new Date(order.created_at).toLocaleString()}</span></div><span className={`status ${order.status}`}>{label(order.status)}</span></div>{order.notes&&<p className="muted"><strong>Notes:</strong> {order.notes}</p>}</section>
 <section className="panel"><div className="panelHead"><div><p className="eyebrow">SERVICES</p><h2>Order Items</h2><span>{items.length} service line{items.length===1?"":"s"}</span></div></div><div className="customerTableWrap"><table className="customerTable" style={{minWidth:720}}><thead><tr><th>Service</th><th>Quantity</th><th>Unit Price</th><th>Line Total</th></tr></thead><tbody>{items.map(i=><tr key={i.id}><td><strong>{i.service_name}</strong><small>{i.pricing_unit?`Per ${i.pricing_unit}`:""}{i.notes?` · ${i.notes}`:""}</small></td><td><strong>{fmtQty(i.quantity)}</strong></td><td><strong>{peso.format(i.unit_price)}</strong></td><td><strong>{peso.format(i.line_total)}</strong></td></tr>)}</tbody></table>{!items.length&&<div className="customerEmpty">No service lines found for this order.</div>}</div><div className="totals" style={{maxWidth:420,marginLeft:"auto",marginTop:18}}><div><span>Subtotal</span><b>{peso.format(order.subtotal)}</b></div>{order.discount>0&&<div><span>Discounts / Points</span><b>-{peso.format(order.discount)}</b></div>}<div className="grand"><span>Total</span><b>{peso.format(order.total)}</b></div><div><span>Amount Paid</span><b>{peso.format(order.amount_paid)}</b></div><div><span>Balance Due</span><b>{peso.format(balance)}</b></div></div></section>
 {!paid&&permissions.record_payments!==false&&<section className="panel"><div className="panelHead"><div><p className="eyebrow">PAYMENT</p><h2>Payment Options</h2><span>Collect full or partial payment now, or leave it for later.</span></div></div><div className="gridForm"><label>Payment Method<select value={payment.method} onChange={e=>setPayment({...payment,method:e.target.value,amount:payment.amount||balance.toFixed(2)})}>{methods.map(m=><option value={m} key={m}>{label(m)}</option>)}</select></label><label>Amount<input type="number" min="0.01" max={balance} step="0.01" value={payment.amount} onChange={e=>setPayment({...payment,amount:e.target.value})}/></label><label className="wide">Reference / Transaction No.<input value={payment.reference} onChange={e=>setPayment({...payment,reference:e.target.value})} placeholder="Optional for cash; recommended for digital payments"/></label></div>{payment.method==="gcash"&&<div className="panel" style={{marginTop:16}}><div style={{display:"flex",gap:20,alignItems:"center",flexWrap:"wrap"}}>{gcash?.qr_image_url?<img src={gcash.qr_image_url} alt="GCash QR" style={{width:220,maxWidth:"100%",height:"auto",borderRadius:12}}/>:<div className="notice">GCash QR is not available in this session. You can still record the payment after confirming it manually.</div>}<div><p className="eyebrow">GCASH PAYMENT</p><h3>{peso.format(Number(payment.amount)||balance)}</h3>{gcash?.merchant_name&&<p><strong>{gcash.merchant_name}</strong>{gcash.account_number?<><br/>{gcash.account_number}</>:null}</p>}<p className="muted">{gcash?.instructions||"Confirm the customer's successful GCash payment before recording it."}</p></div></div></div>}<div className="actions" style={{marginTop:18}}><button className="primary" onClick={pay}>Record Payment</button><button className="secondary" onClick={()=>location.href="/orders"}>Pay Later</button></div></section>}
 <section className="panel"><div className="panelHead"><div><p className="eyebrow">PAYMENT HISTORY</p><h2>Payments</h2><span>{payments.length?`${payments.length} payment${payments.length===1?"":"s"} recorded`:"No payment recorded yet"}</span></div></div>{payments.length?<div className="customerTableWrap"><table className="customerTable" style={{minWidth:620}}><thead><tr><th>Date</th><th>Method</th><th>Reference</th><th>Amount</th></tr></thead><tbody>{payments.map(p=><tr key={p.id}><td>{new Date(p.created_at).toLocaleString()}</td><td><strong>{label(p.method)}</strong></td><td>{p.reference||"—"}</td><td><strong>{peso.format(p.amount)}</strong></td></tr>)}</tbody></table></div>:<p className="muted">Payment can be collected now or later from Order Management.</p>}</section>
 {paid&&<section className="panel"><p className="notice"><strong>✓ Payment complete.</strong> This order has been fully paid.</p><div className="actions"><button className="primary" onClick={printReceipt}>Print Receipt</button><button className="secondary" onClick={()=>location.href="/orders"}>Continue to Order Management</button><button className="secondary" onClick={()=>location.href="/new-order"}>Create Another Order</button></div></section>}
 </main>
}
