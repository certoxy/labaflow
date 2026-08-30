import {supabase} from "./supabase";
import {offlineScope} from "./offlineQueue";

export async function currentOfflineScope(){
 const {data:{session}}=await supabase.auth.getSession();
 const userId=session?.user?.id;
 if(!userId)return null;
 let organizationId:string|null=null;
 if(navigator.onLine){
  const {data}=await supabase.rpc("get_my_labaflow_context");
  organizationId=data?.organization?.id??null;
  if(organizationId)localStorage.setItem(`labaflow.scope.org.${userId}`,organizationId);
 }else organizationId=localStorage.getItem(`labaflow.scope.org.${userId}`);
 return organizationId?offlineScope(userId,organizationId):null;
}

export async function scopedCacheKey(key:string){const scope=await currentOfflineScope();return {key,scope:scope??undefined}}
