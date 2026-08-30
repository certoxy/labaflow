import {supabase} from "./supabase";

export const LOCAL_STAFF_SESSION_KEY="labaflow.local_staff_session";

export type LocalStaffSession={
 token:string;
 expires_at:string;
 staff:{id:string;full_name:string;username:string;role:string};
 organization:{id:string;name:string;slug:string};
 branch:{id:string;name:string;code:string}|null;
};

export function getStoredLocalStaffSession():LocalStaffSession|null{
 if(typeof window==="undefined")return null;
 try{
  const raw=localStorage.getItem(LOCAL_STAFF_SESSION_KEY);
  if(!raw)return null;
  return JSON.parse(raw) as LocalStaffSession;
 }catch{return null}
}

export function clearLocalStaffSession(){if(typeof window!=="undefined")localStorage.removeItem(LOCAL_STAFF_SESSION_KEY)}

export async function getLocalStaffOperationalContext(){
 const session=getStoredLocalStaffSession();
 if(!session)return {session:null,data:null,error:null};
 const {data,error}=await supabase.rpc("get_local_staff_operational_context",{p_token:session.token});
 if(error||!data){clearLocalStaffSession();return {session:null,data:null,error}}
 return {session,data,error:null};
}
