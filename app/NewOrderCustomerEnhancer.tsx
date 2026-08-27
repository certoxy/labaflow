"use client";

import {useEffect} from "react";

const PENDING_KEY="labaflow.newOrder.pendingCustomerId";

export default function NewOrderCustomerEnhancer(){
 useEffect(()=>{
  const openNewCustomer=(event:MouseEvent)=>{
   if(location.pathname!=="/new-order")return;
   const button=(event.target as HTMLElement|null)?.closest("button");
   if(!button)return;
   const text=(button.textContent||"").trim().replace(/^\+\s*/,"");
   if(text!=="Walk-in Customer")return;
   event.preventDefault();
   event.stopPropagation();
   event.stopImmediatePropagation();
   window.dispatchEvent(new Event("labaflow:open-new-customer"));
  };

  const customerCreated=(event:Event)=>{
   if(location.pathname!=="/new-order")return;
   const customer=(event as CustomEvent<{customer?:{id?:string}}>).detail?.customer;
   if(!customer?.id)return;
   sessionStorage.setItem(PENDING_KEY,customer.id);
   location.reload();
  };

  const selectPending=()=>{
   if(location.pathname!=="/new-order")return false;
   const id=sessionStorage.getItem(PENDING_KEY);
   if(!id)return true;
   const selects=Array.from(document.querySelectorAll<HTMLSelectElement>(".newOrderExperience select"));
   const customerSelect=selects.find(select=>Array.from(select.options).some(option=>option.value===id));
   if(!customerSelect)return false;
   const setter=Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,"value")?.set;
   setter?.call(customerSelect,id);
   customerSelect.dispatchEvent(new Event("change",{bubbles:true}));
   sessionStorage.removeItem(PENDING_KEY);
   return true;
  };

  document.addEventListener("click",openNewCustomer,true);
  window.addEventListener("labaflow:customer-created",customerCreated);
  selectPending();
  const observer=new MutationObserver(()=>{if(selectPending())observer.disconnect()});
  observer.observe(document.body,{childList:true,subtree:true});
  return()=>{
   observer.disconnect();
   document.removeEventListener("click",openNewCustomer,true);
   window.removeEventListener("labaflow:customer-created",customerCreated);
  };
 },[]);
 return null;
}
