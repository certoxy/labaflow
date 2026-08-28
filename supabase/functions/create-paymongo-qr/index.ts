import {createClient} from "https://esm.sh/@supabase/supabase-js@2";

const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Content-Type":"application/json"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:cors});

Deno.serve(async(req)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 try{
  const auth=req.headers.get("Authorization");
  if(!auth)return json({error:"Authentication required"},401);
  const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,paymongo=Deno.env.get("PAYMONGO_SECRET_KEY");
  if(!paymongo)return json({error:"PAYMONGO_SECRET_KEY is not configured"},500);
  const userDb=createClient(url,anon,{global:{headers:{Authorization:auth}}});
  const admin=createClient(url,service);
  const {data:{user},error:userError}=await userDb.auth.getUser();
  if(userError||!user)return json({error:"Invalid session"},401);
  const {order_id,amount}=await req.json();
  if(!order_id)return json({error:"order_id is required"},400);
  const {data:membership}=await admin.from("organization_memberships").select("organization_id,active").eq("user_id",user.id).eq("active",true).limit(1).maybeSingle();
  if(!membership)return json({error:"Organization membership required"},403);
  const {data:order,error:orderError}=await admin.from("laundry_orders").select("id,order_code,organization_id,total,amount_paid,payment_status").eq("id",order_id).eq("organization_id",membership.organization_id).single();
  if(orderError||!order)return json({error:"Order not found"},404);
  const balance=Math.max(Number(order.total)-Number(order.amount_paid),0);
  const charge=Number(amount??balance);
  if(!Number.isFinite(charge)||charge<=0||charge>balance+0.001)return json({error:"Invalid payment amount"},400);
  const cents=Math.round(charge*100);
  const basic="Basic "+btoa(paymongo+":");
  const pm=async(path:string,body:unknown)=>{const r=await fetch(`https://api.paymongo.com/v1/${path}`,{method:"POST",headers:{"Content-Type":"application/json",Authorization:basic},body:JSON.stringify(body)});const j=await r.json();if(!r.ok)throw new Error(j?.errors?.[0]?.detail||j?.errors?.[0]?.code||`PayMongo error ${r.status}`);return j;};
  const intent=await pm("payment_intents",{data:{attributes:{amount:cents,currency:"PHP",payment_method_allowed:["qrph"],description:`LabaFlow ${order.order_code}`}}});
  const intentId=intent.data.id;
  const clientKey=intent.data.attributes.client_key;
  const method=await pm("payment_methods",{data:{attributes:{type:"qrph",expiry_seconds:1800}}});
  const attached=await pm(`payment_intents/${intentId}/attach`,{data:{attributes:{payment_method:method.data.id,client_key:clientKey}}});
  const qr=attached.data?.attributes?.next_action?.code?.image_url;
  if(!qr)throw new Error("PayMongo did not return a QR Ph image");
  const expiresAt=new Date(Date.now()+30*60*1000).toISOString();
  const {data:tx,error:txError}=await admin.from("payment_gateway_transactions").insert({organization_id:membership.organization_id,order_id:order.id,provider:"paymongo",provider_payment_intent_id:intentId,payment_method:"qrph",amount:charge,currency:"PHP",status:"awaiting_payment",qr_image_data:qr,expires_at:expiresAt}).select().single();
  if(txError)throw txError;
  return json({transaction_id:tx.id,payment_intent_id:intentId,amount:charge,status:"awaiting_payment",qr_image_data:qr,expires_at:expiresAt});
 }catch(e){return json({error:e instanceof Error?e.message:"Unable to create QR payment"},500)}
});
