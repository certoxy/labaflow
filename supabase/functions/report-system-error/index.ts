import {createClient} from "https://esm.sh/@supabase/supabase-js@2";
const cors={"Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type","Content-Type":"application/json"};
const json=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers:cors});
const esc=(v:unknown)=>String(v??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]!));

Deno.serve(async(req)=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});
 try{
  const auth=req.headers.get("Authorization");if(!auth)return json({error:"Authentication required"},401);
  const url=Deno.env.get("SUPABASE_URL")!,anon=Deno.env.get("SUPABASE_ANON_KEY")!,service=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const userDb=createClient(url,anon,{global:{headers:{Authorization:auth}}}),admin=createClient(url,service);
  const {data:{user},error:userError}=await userDb.auth.getUser();if(userError||!user)return json({error:"Invalid session"},401);
  const body=await req.json();
  const {data:reported,error:reportError}=await userDb.rpc("report_system_error",{p_message:body.message,p_route:body.route??null,p_error_code:body.error_code??null,p_stack:body.stack??null,p_severity:body.severity??"medium",p_source:body.source??"client",p_user_agent:body.user_agent??null,p_details:body.details??{}});
  if(reportError)return json({error:reportError.message},400);
  if(!reported?.should_notify)return json({reported:true,event_id:reported?.event_id,emailed:false});
  const resend=Deno.env.get("RESEND_API_KEY"),from=Deno.env.get("ERROR_ALERT_FROM")??"LabaFlow Alerts <alerts@labaflow.paotechs.com>";
  if(!resend)return json({reported:true,event_id:reported.event_id,emailed:false,email_warning:"RESEND_API_KEY is not configured"});
  const [{data:event,error:eventError},{data:admins,error:adminsError}]=await Promise.all([admin.from("system_error_events").select("id,severity,message,route,error_code,occurrence_count,last_occurred_at,organizations(name),affected_user:profiles!system_error_events_user_id_fkey(email,full_name)").eq("id",reported.event_id).single(),admin.from("platform_admins").select("admin_profile:profiles!platform_admins_user_id_fkey(email)").eq("active",true)]);
  if(eventError||adminsError)return json({reported:true,event_id:reported.event_id,emailed:false,email_warning:eventError?.message||adminsError?.message||"Unable to load alert recipients"});
  const recipients=[...new Set((admins??[]).map((a:any)=>a.admin_profile?.email).filter(Boolean))];if(!event||!recipients.length)return json({reported:true,event_id:reported.event_id,emailed:false,email_warning:"No Platform Admin email recipient"});
  const org=(event as any).organizations?.name??"Unknown organization",affected=(event as any).affected_user?.email??"Unknown user";
  const email=await fetch("https://api.resend.com/emails",{method:"POST",headers:{Authorization:`Bearer ${resend}`,"Content-Type":"application/json"},body:JSON.stringify({from,to:recipients,subject:`[${String(event.severity).toUpperCase()}] LabaFlow system error · ${org}`,html:`<h2>LabaFlow System Alert</h2><p><strong>Severity:</strong> ${esc(event.severity)}</p><p><strong>Organization:</strong> ${esc(org)}</p><p><strong>Affected user:</strong> ${esc(affected)}</p><p><strong>Page:</strong> ${esc(event.route||"Unknown")}</p><p><strong>Error:</strong> ${esc(event.message)}</p><p><strong>Code:</strong> ${esc(event.error_code||"—")}</p><p><strong>Occurrences:</strong> ${esc(event.occurrence_count)}</p><p>Open Platform Admin → System Alerts to investigate.</p>`})});
  if(!email.ok)return json({reported:true,event_id:reported.event_id,emailed:false,email_warning:`Resend returned ${email.status}`});
  await admin.from("system_error_events").update({notified_at:new Date().toISOString()}).eq("id",reported.event_id);
  return json({reported:true,event_id:reported.event_id,emailed:true});
 }catch(e){return json({error:e instanceof Error?e.message:"Unable to report system error"},500)}
});
