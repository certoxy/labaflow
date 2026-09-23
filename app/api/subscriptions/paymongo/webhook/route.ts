import {createHmac,timingSafeEqual} from "node:crypto";
import {NextRequest,NextResponse} from "next/server";
import {createClient} from "@supabase/supabase-js";

function validSignature(raw:string,header:string,secret:string,live:boolean){
 const parts=Object.fromEntries(header.split(",").map(part=>part.trim().split("=",2)));
 const timestamp=parts.t,signature=parts[live?"li":"te"];
 // PayMongo can redeliver the same signed event well after its original
 // delivery. Signature-age validation is optional in PayMongo's guidance, so
 // authenticate the complete signed payload without rejecting legitimate
 // delayed/manual retries.
 if(!timestamp||!signature)return false;
 const expected=createHmac("sha256",secret).update(`${timestamp}.${raw}`).digest("hex");
 const a=Buffer.from(expected),b=Buffer.from(signature);
 return a.length===b.length&&timingSafeEqual(a,b);
}

export async function POST(request:NextRequest){
 const raw=await request.text(),signature=request.headers.get("paymongo-signature")||"";
 const webhookSecret=process.env.PAYMONGO_WEBHOOK_SECRET,paymongoKey=process.env.PAYMONGO_SECRET_KEY||"",supabaseUrl=process.env.NEXT_PUBLIC_SUPABASE_URL,serviceKey=process.env.SUPABASE_SERVICE_ROLE_KEY;
 if(!webhookSecret||!supabaseUrl||!serviceKey){
  console.error("PayMongo webhook configuration is incomplete");
  return NextResponse.json({error:"Webhook configuration is incomplete"},{status:500});
 }
 if(!validSignature(raw,signature,webhookSecret,paymongoKey.startsWith("sk_live_"))){
  console.error("PayMongo webhook signature validation failed");
  return NextResponse.json({error:"Invalid signature"},{status:401});
 }
 const event=JSON.parse(raw);
 if(event?.data?.attributes?.type!=="checkout_session.payment.paid")return NextResponse.json({received:true});
 const session=event?.data?.attributes?.data,checkoutId=session?.id;
 const eventId=event?.data?.id||"unknown";
 if(!checkoutId){
  console.error("PayMongo webhook checkout session ID is missing",{eventId});
  return NextResponse.json({error:"Checkout session ID is missing"},{status:400});
 }
 console.info("Processing PayMongo checkout payment",{eventId,checkoutId});
 const db=createClient(supabaseUrl,serviceKey,{auth:{persistSession:false}});
 const {data:tx,error:findError}=await db.from("subscription_payment_transactions").select("*").eq("provider_checkout_id",checkoutId).maybeSingle();
 if(findError){
  console.error("PayMongo webhook transaction lookup failed",{eventId,checkoutId,error:findError.message});
  return NextResponse.json({error:findError.message},{status:500});
 }
 if(!tx){
  console.error("PayMongo webhook transaction not found",{eventId,checkoutId});
  return NextResponse.json({error:"Subscription transaction not found"},{status:404});
 }
 if(tx.status==="paid")return NextResponse.json({received:true,duplicate:true});
 const intentId=session?.attributes?.payment_intent?.id;
 let intent=session?.attributes?.payment_intent;
 if(intentId){
  const response=await fetch(`https://api.paymongo.com/v1/payment_intents/${intentId}`,{headers:{Authorization:`Basic ${Buffer.from(`${paymongoKey}:`).toString("base64")}`}});
  if(response.ok)intent=(await response.json())?.data;
  else console.error("PayMongo payment intent lookup failed",{eventId,checkoutId,intentId,status:response.status});
 }
 const payment=intent?.attributes?.payments?.[0]||session?.attributes?.payments?.[0];
 const paymentIsPaid=payment?.attributes?.status==="paid"||intent?.attributes?.status==="succeeded";
 if(!paymentIsPaid){
  console.error("PayMongo payment intent is not paid",{eventId,checkoutId,intentId,status:intent?.attributes?.status});
  return NextResponse.json({error:"Payment intent is not paid"},{status:409});
 }
 const paymentAmount=Number(payment?.attributes?.amount??intent?.attributes?.amount);
 const lineItems=Array.isArray(session?.attributes?.line_items)?session.attributes.line_items:[];
 const lineItemAmount=lineItems.reduce((total:number,item:any)=>total+(Number(item?.amount)||0)*(Number(item?.quantity)||0),0);
 const paidAmount=Number.isFinite(paymentAmount)&&paymentAmount>0?paymentAmount/100:lineItemAmount/100;
 if(!paidAmount||Math.abs(paidAmount-Number(tx.amount))>.001){
  console.error("PayMongo paid amount mismatch",{eventId,checkoutId,paidAmount,expectedAmount:Number(tx.amount)});
  return NextResponse.json({error:"Paid amount does not match the subscription transaction"},{status:409});
 }
 const now=new Date(),next=new Date(now);
 if(tx.billing_cycle==="yearly")next.setUTCFullYear(next.getUTCFullYear()+1);else next.setUTCMonth(next.getUTCMonth()+1);
 const {error:subscriptionError}=await db.from("organization_subscriptions").update({plan_key:tx.plan_key,billing_cycle:tx.billing_cycle,status:"active",billing_started_at:now.toISOString(),next_billing_at:next.toISOString(),updated_at:now.toISOString()}).eq("organization_id",tx.organization_id);
 if(subscriptionError)return NextResponse.json({error:subscriptionError.message},{status:500});
 if(tx.product_inventory_addon){
  await db.from("organization_feature_grants").upsert({organization_id:tx.organization_id,feature_key:"inventory",granted:true,updated_at:now.toISOString()},{onConflict:"organization_id,feature_key"});
  await db.from("organization_features").upsert({organization_id:tx.organization_id,feature_key:"inventory",enabled:true,updated_at:now.toISOString()},{onConflict:"organization_id,feature_key"});
 }
 await db.from("subscription_upgrade_requests").update({status:"approved",reviewed_at:now.toISOString(),review_notes:"Automatically approved after confirmed PayMongo payment"}).eq("id",tx.upgrade_request_id).eq("status","pending");
 await db.from("subscription_payment_transactions").update({status:"paid",provider_payment_id:payment?.id||null,provider_payload:event,paid_at:now.toISOString(),updated_at:now.toISOString()}).eq("id",tx.id).eq("status","awaiting_payment");
 console.info("PayMongo subscription activated",{eventId,checkoutId,transactionId:tx.id,organizationId:tx.organization_id});
 return NextResponse.json({received:true});
}
