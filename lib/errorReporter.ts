import {supabase} from "./supabase";
export type ErrorSeverity="low"|"medium"|"high"|"critical";
const recent=new Map<string,number>();
export async function reportSystemError(error:unknown,options:{severity?:ErrorSeverity;code?:string;source?:"client"|"server"|"edge";details?:Record<string,unknown>}={}){
 if(typeof window==="undefined")return;
 const value=error instanceof Error?error:new Error(typeof error==="string"?error:"Unexpected application error");
 const route=location.pathname+location.search,key=`${route}|${options.code??""}|${value.message}`,now=Date.now();
 if(now-(recent.get(key)??0)<10000)return;recent.set(key,now);
 const payload={message:value.message||"Unexpected application error",route,error_code:options.code??null,stack:value.stack??null,severity:options.severity??"medium",source:options.source??"client",user_agent:navigator.userAgent,details:options.details??{}};
 const edge=await supabase.functions.invoke("report-system-error",{body:payload});
 if(edge.error)await supabase.rpc("report_system_error",{p_message:payload.message,p_route:payload.route,p_error_code:payload.error_code,p_stack:payload.stack,p_severity:payload.severity,p_source:payload.source,p_user_agent:payload.user_agent,p_details:payload.details});
}
