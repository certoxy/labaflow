import {NextRequest,NextResponse} from "next/server";
import {createClient} from "@supabase/supabase-js";

const reply=(body:unknown,status=200)=>NextResponse.json(body,{status});

export async function POST(request:NextRequest){
 const authorization=request.headers.get("authorization");
 const paymongoKey=process.env.PAYMONGO_SECRET_KEY||"";
 const supabaseUrl=process.env.NEXT_PUBLIC_SUPABASE_URL;
 const publishableKey=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
 const serviceKey=process.env.SUPABASE_SERVICE_ROLE_KEY;
 if(!authorization?.startsWith("Bearer "))return reply({error:"Authentication required"},401);
 if(!paymongoKey||!supabaseUrl||!publishableKey||!serviceKey)return reply({error:"Payment reconciliation is not configured"},500);

 const userDb=createClient(supabaseUrl,publishableKey,{global:{headers:{Authorization:authorization}},auth:{persistSession:false}});
 const {data:{user},error:userError}=await userDb.auth.getUser(authorization.slice(7));
 if(userError||!user)return reply({error:"Authentication required"},401);

 const db=createClient(supabaseUrl,serviceKey,{auth:{persistSession:false}});
 const {data:tx,error:txError}=await db.from("subscription_payment_transactions").select("*").eq("requested_by",user.id).eq("status","awaiting_payment").not("provider_checkout_id","is",null).order("created_at",{ascending:false}).limit(1).maybeSingle();
 if(txError)return reply({error:txError.message},500);
 if(!tx)return reply({status:"no_pending_payment"});

 const authHeader={Authorization:`Basic ${Buffer.from(`${paymongoKey}:`).toString("base64")}`};
 const checkoutResponse=await fetch(`https://api.paymongo.com/v1/checkout_sessions/${tx.provider_checkout_id}`,{headers:authHeader,cache:"no-store"});
 const checkoutBody=await checkoutResponse.json();
 if(!checkoutResponse.ok)return reply({error:checkoutBody?.errors?.[0]?.detail||`Unable to verify checkout (${checkoutResponse.status})`},502);
 const session=checkoutBody?.data;
 const metadata=session?.attributes?.metadata||{};
 if(metadata.subscription_transaction_id!==tx.id||metadata.organization_id!==tx.organization_id)return reply({error:"Payment metadata does not match this subscription"},409);

 const intentId=session?.attributes?.payment_intent?.id;
 if(!intentId)return reply({error:"Payment intent is unavailable"},409);
 const intentResponse=await fetch(`https://api.paymongo.com/v1/payment_intents/${intentId}`,{headers:authHeader,cache:"no-store"});
 const intentBody=await intentResponse.json();
 if(!intentResponse.ok)return reply({error:intentBody?.errors?.[0]?.detail||`Unable to verify payment (${intentResponse.status})`},502);
 const intent=intentBody?.data;
 const payment=intent?.attributes?.payments?.find((item:any)=>item?.attributes?.status==="paid")||intent?.attributes?.payments?.[0];
 const paid=payment?.attributes?.status==="paid"||intent?.attributes?.status==="succeeded";
 if(!paid)return reply({status:"pending",payment_status:intent?.attributes?.status||"unknown"},202);

 const paymentAmount=Number(payment?.attributes?.amount??intent?.attributes?.amount);
 const paidAmount=Number.isFinite(paymentAmount)?paymentAmount/100:0;
 if(!paidAmount||Math.abs(paidAmount-Number(tx.amount))>.001)return reply({error:"Paid amount does not match the subscription transaction"},409);

 const now=new Date(),next=new Date(now);
 if(tx.billing_cycle==="yearly")next.setUTCFullYear(next.getUTCFullYear()+1);else next.setUTCMonth(next.getUTCMonth()+1);
 const {error:subscriptionError}=await db.from("organization_subscriptions").update({plan_key:tx.plan_key,billing_cycle:tx.billing_cycle,status:"active",billing_started_at:now.toISOString(),next_billing_at:next.toISOString(),updated_at:now.toISOString()}).eq("organization_id",tx.organization_id);
 if(subscriptionError)return reply({error:subscriptionError.message},500);
 if(tx.product_inventory_addon){
  const {error:grantError}=await db.from("organization_feature_grants").upsert({organization_id:tx.organization_id,feature_key:"inventory",granted:true,updated_at:now.toISOString()},{onConflict:"organization_id,feature_key"});
  if(grantError)return reply({error:grantError.message},500);
  const {error:featureError}=await db.from("organization_features").upsert({organization_id:tx.organization_id,feature_key:"inventory",enabled:true,updated_at:now.toISOString()},{onConflict:"organization_id,feature_key"});
  if(featureError)return reply({error:featureError.message},500);
 }
 await db.from("subscription_upgrade_requests").update({status:"approved",reviewed_at:now.toISOString(),review_notes:"Automatically approved after confirmed PayMongo payment"}).eq("id",tx.upgrade_request_id).eq("status","pending");
 const {error:paymentError}=await db.from("subscription_payment_transactions").update({status:"paid",provider_payment_id:payment?.id||null,provider_payload:{checkout:session,payment_intent:intent,reconciled:true},paid_at:now.toISOString(),updated_at:now.toISOString()}).eq("id",tx.id).eq("status","awaiting_payment");
 if(paymentError)return reply({error:paymentError.message},500);
 console.info("PayMongo subscription reconciled",{transactionId:tx.id,organizationId:tx.organization_id,intentId});
 return reply({status:"activated",plan_key:tx.plan_key});
}
