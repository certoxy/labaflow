alter table public.offline_sync_operations drop constraint if exists offline_sync_operation_type_check;
alter table public.offline_sync_operations add constraint offline_sync_operation_type_check check(operation_type in ('create_order','update_order_status','record_cash_payment','create_customer'));

create or replace function public.sync_offline_customer(
 p_operation_id uuid,p_full_name text,p_mobile text default null,p_email text default null,p_preferred_branch_id uuid default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_existing public.offline_sync_operations%rowtype;v_result jsonb;
begin
 select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
 if v_org is null then raise exception 'Active organization membership required'; end if;
 select * into v_existing from public.offline_sync_operations where id=p_operation_id;
 if v_existing.id is not null then
  if v_existing.organization_id<>v_org or v_existing.user_id<>auth.uid() or v_existing.operation_type<>'create_customer' then raise exception 'Offline operation id is already in use'; end if;
  if v_existing.result is not null then return v_existing.result; end if;
 else insert into public.offline_sync_operations(id,organization_id,user_id,operation_type) values(p_operation_id,v_org,auth.uid(),'create_customer'); end if;
 v_result:=public.create_customer_with_qr(p_full_name,p_mobile,p_email,p_preferred_branch_id);
 update public.offline_sync_operations set result=v_result,completed_at=now() where id=p_operation_id;
 return v_result;
end $$;
grant execute on function public.sync_offline_customer(uuid,text,text,text,uuid) to authenticated;
