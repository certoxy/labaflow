import {NextRequest,NextResponse} from "next/server";
import {createClient} from "@supabase/supabase-js";

const reply=(body:unknown,status=200)=>NextResponse.json(body,{status});

export async function POST(request:NextRequest){
 const authorization=request.headers.get("authorization");
 const paymongoKey=process.env.PAYMONGO_SECRET_KEY;
 const supabaseUrl=process.env.NEXT_PUBLIC_SUPABASE_URL;
 const supabaseKey=process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
 if(!authorization?.startsWith("Bearer "))return reply({error:"Authentication required"},401);
 if(!supabaseUrl||!supabaseKey)return reply({error:"Supabase server configuration is incomplete"},500);
 if(!paymongoKey)return reply({error:"PayMongo is not configured"},500);
 const db=createClient(supabaseUrl,supabaseKey,{global:{headers:{Authorization:authorization}},auth:{persistSession:false}});
 let transactionId:string|undefined;
 try{
  const input=await request.json();
  const {data:checkout,error:prepareError}=await db.rpc("prepare_subscription_checkout",{p_plan_key:input.plan_key,p_billing_cycle:input.billing_cycle??"monthly",p_product_inventory_addon:Boolean(input.product_inventory_addon),p_billing_contact:input.billing_contact||null,p_billing_email:input.billing_email||null,p_notes:input.notes||null});
  if(prepareError)return reply({error:prepareError.message},400);
  transactionId=checkout.transaction_id;
  // Always return the customer to the same LabaFlow deployment that created
  // the checkout. This keeps Preview, staging, and production redirects from
  // being mixed up by an environment variable copied from another service.
  const origin=request.nextUrl.origin;
  const description=`${checkout.plan_name} ${checkout.billing_cycle} subscription${checkout.product_inventory_addon?" + Product & Inventory":""}`;
  const paymongoResponse=await fetch("https://api.paymongo.com/v1/checkout_sessions",{method:"POST",headers:{Authorization:`Basic ${Buffer.from(`${paymongoKey}:`).toString("base64")}`,"Content-Type":"application/json"},body:JSON.stringify({data:{attributes:{billing:{email:checkout.billing_email||undefined,name:input.billing_contact||undefined},cancel_url:`${origin}/organization/subscription?payment=cancelled`,description,line_items:[{amount:Math.round(Number(checkout.amount)*100),currency:"PHP",description,name:`LabaFlow ${checkout.plan_name}`,quantity:1}],payment_method_types:["card","gcash","grab_pay","paymaya","qrph"],reference_number:transactionId,send_email_receipt:true,show_description:true,show_line_items:true,success_url:`${origin}/organization/subscription?payment=success`,metadata:{subscription_transaction_id:transactionId,organization_id:checkout.organization_id}}}})});
  const paymongo=await paymongoResponse.json();
  if(!paymongoResponse.ok)throw new Error(paymongo?.errors?.[0]?.detail||paymongo?.errors?.[0]?.code||`PayMongo error ${paymongoResponse.status}`);
  const providerId=paymongo?.data?.id,checkoutUrl=paymongo?.data?.attributes?.checkout_url;
  if(!providerId||!checkoutUrl)throw new Error("PayMongo did not return a checkout URL");
  const {error:attachError}=await db.rpc("attach_subscription_checkout",{p_transaction_id:transactionId,p_provider_checkout_id:providerId,p_checkout_url:checkoutUrl});
  if(attachError)throw attachError;
  return reply({checkout_url:checkoutUrl,transaction_id:transactionId});
 }catch(error){
  const message=error instanceof Error?error.message:"Unable to create subscription checkout";
  if(transactionId)await db.rpc("fail_subscription_checkout",{p_transaction_id:transactionId,p_error:message});
  return reply({error:message},500);
 }
}
