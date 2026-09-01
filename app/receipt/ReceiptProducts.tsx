"use client";
import {useEffect,useState} from "react";
import {createPortal} from "react-dom";
import {supabase} from "../../lib/supabase";

const peso=new Intl.NumberFormat("en-PH",{style:"currency",currency:"PHP"});
const money=(n:any)=>peso.format(Number(n||0));

type ProductItem={id:string;product_name?:string;name?:string;sku?:string|null;quantity:number;unit_price:number;line_total:number};

export default function ReceiptProducts(){
 const [items,setItems]=useState<ProductItem[]>([]),[mount,setMount]=useState<HTMLElement|null>(null);
 useEffect(()=>{
  const id=new URLSearchParams(location.search).get("id");if(!id)return;
  (async()=>{const {data,error}=await supabase.rpc("get_order_product_items",{p_order_id:id});if(!error)setItems((data??[]).map((x:any)=>({...x,quantity:Number(x.quantity),unit_price:Number(x.unit_price),line_total:Number(x.line_total)})))})();
  const timer=setInterval(()=>{
   const services=Array.from(document.querySelectorAll<HTMLElement>(".receiptSection")).find(x=>x.querySelector("h2")?.textContent?.trim()==="Services");
   const totals=services?.querySelector<HTMLElement>(".receiptTotals");
   if(!services||!totals)return;
   let node=document.getElementById("receipt-products-mount");
   if(!node){node=document.createElement("div");node.id="receipt-products-mount";services.insertBefore(node,totals)}
   setMount(node);
  },200);
  return()=>clearInterval(timer);
 },[]);
 if(!mount||!items.length)return null;
 const subtotal=items.reduce((n,x)=>n+x.line_total,0);
 return createPortal(<div className="receiptProducts"><h2>Products</h2><table className="receiptTable"><thead><tr><th>Product</th><th>Qty</th><th>Rate</th><th>Amount</th></tr></thead><tbody>{items.map((x:any)=><tr key={x.id}><td>{x.product_name||x.name||"Product"}{x.sku&&<small className="receiptProductSku">{x.sku}</small>}</td><td>{x.quantity}</td><td>{money(x.unit_price)}</td><td>{money(x.line_total)}</td></tr>)}</tbody></table><div className="receiptProductSubtotal"><span>Products Subtotal</span><b>{money(subtotal)}</b></div></div>,mount);
}
