import {createClient} from "https://esm.sh/@supabase/supabase-js@2";

const hex=(a:ArrayBuffer)=>[...new Uint8Array(a)].map(b=>b.toString(16).padStart(2,"0")).join("");
async function hmac(secret:string,message:string){const key=await crypto.subtle.importKey("raw",new TextEncoder().encode(secret),{name:"HMAC",hash:"SHA-256"},false,["sign"]);return hex(await crypto.subtle.sign("HMAC",key,new TextEncoder().encode(message)))}
function safeEqual(a:string,b:string){if(a.length!==b.length)return false;let n=0;for(let i=0;i<a.length;i++)n|=a.charCodeAt(i)^b.charCodeAt(i);return n===0}

Deno.serve(async(req)=>{
 if(req.method!=="POST")return new Response("Method not allowed",{status:405});
 const raw=await req.text();
 try{
  const secret=Deno.env.get("PAYMONGO_WEBHOOK_SECRET");
  if(!secret)return new Response("Webhook secret not configured",{status:500});
  const sig=req.headers.get("Paymongo-Signature")||"";
  const parts=Object.fromEntries(sig.split(",").map(x=>x.split("=",2)));
  const t=parts.t||"",provided=parts.te||parts.li||"";
  if(!t||!provided)return new Response("Missing signature",{status:401});
  const expected=await hmac(secret,`${t}.${raw}`);
  if(!safeEqual(expected,provided))return new Response("Invalid signature",{status:401});
  const event=JSON.parse(raw);const eventId=event?.data?.id;const type=event?.data?.attributes?.type;const resource=event?.data?.attributes?.data;
  if(!eventId||!type)return new Response("ok",{status:200});
  const url=Deno.env.get("SUPABASE_URL")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;const db=createClient(url,service);
  let intentId=resource?.attributes?.payment_intent_id||resource?.attributes?.payment_intent?.id||resource?.id;
  if(type==="payment.paid"||type==="payment.failed"){
   if(type==="payment.paid"&&!resource?.attributes?.payment_intent_id&&resource?.id){const key=Deno.env.get("PAYMONGO_SECRET_KEY");if(key){const r=await fetch(`https://api.paymongo.com/v1/payments/${resource.id}`,{headers:{Authorization:"Basic "+btoa(key+":")}});const p=await r.json();intentId=p?.data?.attributes?.payment_intent_id||intentId;}}
   const {data:tx}=await db.from("payment_gateway_transactions").select("*").eq("provider","paymongo").eq("provider_payment_intent_id",intentId).maybeSingle();
   if(!tx)return new Response("ok",{status:200});
   if(tx.provider_event_id||tx.status==="paid")return new Response("ok",{status:200});
   if(type==="payment.failed"){await db.from("payment_gateway_transactions").update({status:"failed",provider_event_id:eventId,updated_at:new Date().toISOString()}).eq("id",tx.id);return new Response("ok",{status:200});}
   const {error:paymentError}=await db.rpc("record_gateway_order_payment",{p_order_id:tx.order_id,p_amount:Number(tx.amount),p_method:"qrph",p_reference:resource?.id||intentId,p_provider:"paymongo",p_provider_payment_id:resource?.id||null,p_provider_event_id:eventId});
   if(paymentError)throw paymentError;
  }else if(type==="qrph.expired"){
   await db.from("payment_gateway_transactions").update({status:"expired",provider_event_id:eventId,updated_at:new Date().toISOString()}).eq("provider_payment_intent_id",intentId).neq("status","paid");
  }
  return new Response("ok",{status:200});
 }catch(e){console.error(e);return new Response("Webhook processing failed",{status:500})}
});
