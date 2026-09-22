import {createHmac,timingSafeEqual} from "node:crypto";
import {NextRequest,NextResponse} from "next/server";
import {createClient} from "@supabase/supabase-js";

function validSignature(raw:string,header:string,secret:string,live:boolean){
 const parts=Object.fromEntries(header.split(",").map(part=>part.trim().split("=",2)));
 const timestamp=parts.t,signature=parts[live?"li":"te"];
 if(!timestamp||!signature||Math.abs(Date.now()/1000-Number(timestamp))>300)return false;
 const expected=createHmac("sha256",secret).update(`${timestamp}.${raw}`).digest("hex");
 const a=Buffer.from(expected),b=Buffer.from(signature);
 return a.length===b.length&&timingSafeEqual(a,b);
}

export async function POST(request:NextRequest){
 const raw=await request.text(),signature=request.headers.get("paymongo-signature")||"";
 const webhookSecret=process.env.PAYMONGO_WEBHOOK_SECRET,paymongoKey=process.env.PAYMONGO_SECRET_KEY||"",supabaseUrl=process.env.NEXT_PUBLIC_SUPABASE_URL,serviceKey=process.env.SUPABASE_SERVICE_ROLE_KEY;
 if(!webhookSecret||!supabaseUrl||!serviceKey)return NextResponse.json({error:"Webhook configuration is incomplete"},{status:500});
 if(!validSignature(raw,signature,webhookSecret,paymongoKey.startsWith("sk_live_")))return NextResponse.json({error:"Invalid signature"},{status:401});
 const event=JSON.parse(raw);
 if(event?.data?.attributes?.type!=="checkout_session.payment.paid")return NextResponse.json({received:true});
 const session=event?.data?.attributes?.data,checkoutId=session?.id;
 if(!checkoutId)return NextResponse.json({error:"Checkout session ID is missing"},{status:400});
 const db=createClient(supabaseUrl,serviceKey,{auth:{persistSession:false}});
 const {data:tx,error:findError}=await db.from("subscription_payment_transactions").select("*").eq("provider_checkout_id",checkoutId).maybeSingle();
 if(findError)return NextResponse.json({error:findError.message},{status:500});
 if(!tx)return NextResponse.json({error:"Subscription transaction not found"},{status:404});
 if(tx.status==="paid")return NextResponse.json({received:true,duplicate:true});
 const payment=session?.attributes?.payments?.[0],paidAmount=Number(payment?.attributes?.amount??0)/100;
 if(Math.abs(paidAmount-Number(tx.amount))>.001)return NextResponse.json({error:"Paid amount does not match the subscription transaction"},{status:409});
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
 return NextResponse.json({received:true});
}
