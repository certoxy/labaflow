"use client";
import {useEffect,useMemo,useState} from "react";
import {createPortal} from "react-dom";
import {supabase} from "../lib/supabase";

type Product={id:string;name:string;sku:string|null;barcode:string|null;selling_price:number;branch_id:string;branch_name:string;quantity:number;active:boolean};
type Pick={product_id:string;quantity:number};
const peso=new Intl.NumberFormat("en-PH",{style:"currency",currency:"PHP"});
const PENDING_KEY="labaflow.pending-products";

export default function ProductSalesEnhancer(){
 const [products,setProducts]=useState<Product[]>([]),[cart,setCart]=useState<Pick[]>([]),[branchId,setBranchId]=useState(""),[search,setSearch]=useState(""),[message,setMessage]=useState(""),[mount,setMount]=useState<HTMLElement|null>(null),[finalizing,setFinalizing]=useState(false);

 useEffect(()=>{
  if(typeof window==="undefined")return;
  if(location.pathname.startsWith("/order-details")){void finalizePending();return}
  if(!location.pathname.startsWith("/new-order"))return;
  void load();
  const hostTimer=setInterval(()=>{
   const host=document.querySelector<HTMLElement>(".newOrderMain");
   const aside=document.querySelector<HTMLElement>(".desktopOrderSummary");
   if(host&&!document.getElementById("labaflow-product-sales-mount")){
    const node=document.createElement("div");node.id="labaflow-product-sales-mount";node.className="productSalesMount";
    if(aside&&aside.parentElement===host)host.insertBefore(node,aside);else host.appendChild(node);
    setMount(node);
   }else if(document.getElementById("labaflow-product-sales-mount"))setMount(document.getElementById("labaflow-product-sales-mount"));
   syncBranch();
  },300);
  const formTimer=setInterval(()=>{
   const form=document.querySelector<HTMLFormElement>(".newOrderExperience form");
   if(!form||form.dataset.productHooked==="1")return;
   form.dataset.productHooked="1";
   form.addEventListener("submit",()=>{if(cart.length)sessionStorage.setItem(PENDING_KEY,JSON.stringify(cart));else sessionStorage.removeItem(PENDING_KEY)},true);
  },300);
  return()=>{clearInterval(hostTimer);clearInterval(formTimer)};
 },[cart]);

 async function load(){
  const {data,error}=await supabase.rpc("get_products_inventory");
  if(error){setMessage(error.message);return}
  setProducts((data??[]).map((x:any)=>({...x,selling_price:Number(x.selling_price),quantity:Number(x.quantity)})).filter((x:any)=>x.active));
  syncBranch();
 }
 function syncBranch(){
  const sel=document.querySelector<HTMLSelectElement>('.orderDetailsPanel select[required]');
  if(sel?.value&&sel.value!==branchId){
   setBranchId(sel.value);
   setCart(current=>current.filter(x=>products.some(p=>p.id===x.product_id&&p.branch_id===sel.value&&p.quantity>=x.quantity)));
  }
 }
 async function finalizePending(){
  const raw=sessionStorage.getItem(PENDING_KEY);if(!raw)return;
  let picks:Pick[]=[];try{picks=JSON.parse(raw)}catch{sessionStorage.removeItem(PENDING_KEY);return}
  if(!picks.length){sessionStorage.removeItem(PENDING_KEY);return}
  const orderId=new URLSearchParams(location.search).get("id");if(!orderId)return;
  const doneKey=`labaflow.products-added.${orderId}`;if(sessionStorage.getItem(doneKey)==="1"){sessionStorage.removeItem(PENDING_KEY);return}
  setFinalizing(true);
  const {error}=await supabase.rpc("add_products_to_order",{p_order_id:orderId,p_products:picks});
  if(error){sessionStorage.setItem("labaflow.product-sale-error",error.message);setFinalizing(false);return}
  sessionStorage.setItem(doneKey,"1");sessionStorage.removeItem(PENDING_KEY);sessionStorage.removeItem("labaflow.product-sale-error");
  location.reload();
 }
 function qty(id:string){return cart.find(x=>x.product_id===id)?.quantity??0}
 function setQty(p:Product,n:number){const next=Math.max(0,Math.min(Math.floor(n),Math.floor(p.quantity)));setCart(c=>next<=0?c.filter(x=>x.product_id!==p.id):c.some(x=>x.product_id===p.id)?c.map(x=>x.product_id===p.id?{...x,quantity:next}:x):[...c,{product_id:p.id,quantity:next}])}
 const visible=useMemo(()=>products.filter(p=>(!branchId||p.branch_id===branchId)&&(`${p.name} ${p.sku??""} ${p.barcode??""}`).toLowerCase().includes(search.trim().toLowerCase())).sort((a,b)=>a.name.localeCompare(b.name)),[products,branchId,search]);
 const total=cart.reduce((n,x)=>n+(products.find(p=>p.id===x.product_id)?.selling_price??0)*x.quantity,0),count=cart.reduce((n,x)=>n+x.quantity,0);
 if(finalizing)return <div className="productFinalizeNotice">Adding products to order…</div>;
 if(!location.pathname.startsWith("/new-order")||!mount)return null;
 return createPortal(<section className="panel productSalesPanel"><div className="mobileServicesHead"><div><p className="eyebrow">PRODUCTS</p><h2>Add Retail Products</h2><span>Optional items for self-service customers</span></div><div className="productCartSummary"><strong>{count} item{count===1?"":"s"}</strong><b>{peso.format(total)}</b></div></div><div className="serviceSearch"><span>⌕</span><input value={search} onChange={e=>setSearch(e.target.value)} placeholder="Search products, SKU or barcode..."/></div><div className="productOrderGrid">{visible.map(p=>{const n=qty(p.id),available=p.quantity>0;return <article className={`productOrderCard ${n?"selected":""} ${available?"":"outOfStock"}`} key={`${p.id}-${p.branch_id}`}><div className="productOrderInfo"><span className="serviceGlyph">▣</span><div><strong>{p.name}</strong><small>{p.sku||"No SKU"} · {peso.format(p.selling_price)}</small><em>{available?`${p.quantity} in stock`:"Out of stock"}</em></div></div><div className="qtyStepper"><button type="button" onClick={()=>setQty(p,n-1)} disabled={!n}>−</button><b>{n}</b><button type="button" onClick={()=>setQty(p,n+1)} disabled={!available||n>=p.quantity}>+</button></div></article>})}</div>{!visible.length&&<p className="empty">No active products are available for the selected branch.</p>}{message&&<p className="notice">{message}</p>}{cart.length>0&&<div className="productOrderFooter"><span>Products subtotal</span><strong>{peso.format(total)}</strong><small>Added to the order total after the laundry order is created.</small></div>}</section>,mount)
}
