"use client";
import {useEffect,useMemo,useRef,useState} from "react";
import {createPortal} from "react-dom";
import {supabase} from "../lib/supabase";

type Product={id:string;name:string;sku:string|null;barcode:string|null;selling_price:number;branch_id:string;branch_name:string;quantity:number;active:boolean};
type Pick={product_id:string;quantity:number};
const peso=new Intl.NumberFormat("en-PH",{style:"currency",currency:"PHP"});
const PENDING_KEY="labaflow.pending-products";

export default function ProductSalesEnhancer(){
 const [products,setProducts]=useState<Product[]>([]),[cart,setCart]=useState<Pick[]>([]),[branchId,setBranchId]=useState(""),[search,setSearch]=useState(""),[message,setMessage]=useState(""),[mount,setMount]=useState<HTMLElement|null>(null),[finalizing,setFinalizing]=useState(false),[clientReady,setClientReady]=useState(false),[isNewOrder,setIsNewOrder]=useState(false),[featureEnabled,setFeatureEnabled]=useState(false);
 const productsRef=useRef<Product[]>([]),cartRef=useRef<Pick[]>([]),branchRef=useRef("");
 useEffect(()=>{productsRef.current=products},[products]);
 useEffect(()=>{cartRef.current=cart;syncSummary()},[cart,products]);
 useEffect(()=>{branchRef.current=branchId},[branchId]);

 useEffect(()=>{
  if(typeof window==="undefined")return;
  setClientReady(true);
  const path=window.location.pathname;
  setIsNewOrder(path.startsWith("/new-order"));
  if(path.startsWith("/order-details")){void finalizePending();return}
  if(!path.startsWith("/new-order"))return;

  void load();
  let branchSelect:HTMLSelectElement|null=null;
  const mountTimer=window.setInterval(()=>{
   const host=document.querySelector<HTMLElement>(".newOrderMain");
   if(host&&!document.getElementById("labaflow-product-sales-mount")){
    const node=document.createElement("div");node.id="labaflow-product-sales-mount";node.className="productSalesMount";host.appendChild(node);setMount(node);
   }else{
    const existing=document.getElementById("labaflow-product-sales-mount");if(existing)setMount(existing);
   }
   const sel=document.querySelector<HTMLSelectElement>('.orderDetailsPanel select[required]');
   if(sel&&sel!==branchSelect){
    if(branchSelect)branchSelect.removeEventListener("change",handleBranchChange);
    branchSelect=sel;branchSelect.addEventListener("change",handleBranchChange);handleBranchChange();
   }
   syncSummary();
  },250);

  const submitTimer=window.setInterval(()=>{
   const form=document.querySelector<HTMLFormElement>(".newOrderExperience form");
   if(!form||form.dataset.productHooked==="1")return;
   form.dataset.productHooked="1";
   form.addEventListener("submit",handleSubmitCapture,true);
  },300);

  function handleSubmitCapture(){const current=cartRef.current;if(current.length)sessionStorage.setItem(PENDING_KEY,JSON.stringify(current));else sessionStorage.removeItem(PENDING_KEY)}
  function handleBranchChange(){const value=branchSelect?.value??"";if(!value||value===branchRef.current)return;branchRef.current=value;setBranchId(value);setCart(current=>current.filter(x=>productsRef.current.some(p=>p.id===x.product_id&&p.branch_id===value&&p.quantity>=x.quantity)))}

  return()=>{window.clearInterval(mountTimer);window.clearInterval(submitTimer);if(branchSelect)branchSelect.removeEventListener("change",handleBranchChange)};
 },[]);

 async function load(){const access=await supabase.rpc("get_current_access_context");if(access.error||access.data?.features?.inventory!==true){setFeatureEnabled(false);return}setFeatureEnabled(true);const {data,error}=await supabase.rpc("get_products_inventory");if(error){setMessage(error.message);return}const next=(data??[]).map((x:any)=>({...x,selling_price:Number(x.selling_price),quantity:Number(x.quantity)})).filter((x:any)=>x.active);productsRef.current=next;setProducts(next);const sel=document.querySelector<HTMLSelectElement>('.orderDetailsPanel select[required]');if(sel?.value){branchRef.current=sel.value;setBranchId(sel.value)}}
 function productTotal(){return cart.reduce((n,x)=>n+(products.find(p=>p.id===x.product_id)?.selling_price??0)*x.quantity,0)}
 function syncSummary(){if(typeof document==="undefined")return;const summary=document.querySelector<HTMLElement>(".desktopOrderSummary .orderSummary");if(!summary)return;let row=summary.querySelector<HTMLElement>(".productSummaryRow");if(!row){row=document.createElement("div");row.className="productSummaryRow";const totals=summary.querySelector<HTMLElement>(".totals");if(totals)totals.prepend(row);else summary.appendChild(row)}const total=cartRef.current.reduce((n,x)=>n+(productsRef.current.find(p=>p.id===x.product_id)?.selling_price??0)*x.quantity,0);row.innerHTML=`<span>Products Subtotal</span><strong>${peso.format(total)}</strong>`}
 async function finalizePending(){if(typeof window==="undefined")return;const raw=sessionStorage.getItem(PENDING_KEY);if(!raw)return;let picks:Pick[]=[];try{picks=JSON.parse(raw)}catch{sessionStorage.removeItem(PENDING_KEY);return}if(!picks.length){sessionStorage.removeItem(PENDING_KEY);return}const orderId=new URLSearchParams(window.location.search).get("id");if(!orderId)return;const doneKey=`labaflow.products-added.${orderId}`;if(sessionStorage.getItem(doneKey)==="1"){sessionStorage.removeItem(PENDING_KEY);return}setFinalizing(true);const {error}=await supabase.rpc("add_products_to_order",{p_order_id:orderId,p_products:picks});if(error){sessionStorage.setItem("labaflow.product-sale-error",error.message);setFinalizing(false);return}sessionStorage.setItem(doneKey,"1");sessionStorage.removeItem(PENDING_KEY);sessionStorage.removeItem("labaflow.product-sale-error");window.location.reload()}
 function qty(id:string){return cart.find(x=>x.product_id===id)?.quantity??0}
 function setQty(p:Product,n:number){const next=Math.max(0,Math.min(Math.floor(n),Math.floor(p.quantity)));setCart(c=>next<=0?c.filter(x=>x.product_id!==p.id):c.some(x=>x.product_id===p.id)?c.map(x=>x.product_id===p.id?{...x,quantity:next}:x):[...c,{product_id:p.id,quantity:next}])}
 const visible=useMemo(()=>products.filter(p=>(!branchId||p.branch_id===branchId)&&(`${p.name} ${p.sku??""} ${p.barcode??""}`).toLowerCase().includes(search.trim().toLowerCase())).sort((a,b)=>a.name.localeCompare(b.name)),[products,branchId,search]);
 const total=productTotal(),count=cart.reduce((n,x)=>n+x.quantity,0);
 if(!clientReady)return null;
 if(finalizing)return <div className="productFinalizeNotice">Adding products to order…</div>;
 if(!featureEnabled||!isNewOrder||!mount)return null;
 return createPortal(<section className="panel productSalesPanel"><div className="productSalesHead"><div><p className="eyebrow">PRODUCTS</p><h2>Add Retail Products</h2><span>Optional retail items from the selected branch inventory</span></div><div className="productCartSummary"><strong>{count} item{count===1?"":"s"}</strong><b>{peso.format(total)}</b></div></div><div className="serviceSearch productSearch"><span>⌕</span><input value={search} onChange={e=>setSearch(e.target.value)} placeholder="Search products, SKU or barcode..."/></div><div className="productTableWrap"><table className="productOrderTable"><thead><tr><th>Product</th><th>SKU</th><th className="num">Price</th><th className="num">Available</th><th>Quantity</th><th className="num">Line Total</th></tr></thead><tbody>{visible.map(p=>{const n=qty(p.id),available=p.quantity>0;return <tr key={`${p.id}-${p.branch_id}`} className={`${n?"selected":""} ${available?"":"outOfStock"}`}><td data-label="Product"><strong>{p.name}</strong>{p.barcode&&<small>{p.barcode}</small>}</td><td data-label="SKU">{p.sku||"—"}</td><td data-label="Price" className="num">{peso.format(p.selling_price)}</td><td data-label="Available" className="num"><span className={`stockBadge ${available?"":"empty"}`}>{available?p.quantity:"Out"}</span></td><td data-label="Quantity"><div className="qtyStepper productQty"><button type="button" onClick={()=>setQty(p,n-1)} disabled={!n}>−</button><b>{n}</b><button type="button" onClick={()=>setQty(p,n+1)} disabled={!available||n>=p.quantity}>+</button></div></td><td data-label="Line Total" className="num lineTotal">{peso.format(p.selling_price*n)}</td></tr>})}</tbody></table></div>{!visible.length&&<p className="empty">No active products are available for the selected branch.</p>}{message&&<p className="notice">{message}</p>}<div className="productOrderFooter"><span>Products subtotal</span><strong>{peso.format(total)}</strong></div></section>,mount)
}
