-- LabaFlow: idempotent offline status changes and cash payments.

alter table public.offline_sync_operations drop constraint if exists offline_sync_operation_type_check;
alter table public.offline_sync_operations add constraint offline_sync_operation_type_check
  check (operation_type in ('create_order','update_order_status','record_cash_payment'));

create or replace function public.sync_offline_order_status(
  p_operation_id uuid,
  p_order_id uuid,
  p_status public.order_status,
  p_notes text default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_order public.laundry_orders%rowtype;v_existing public.offline_sync_operations%rowtype;v_result jsonb;
begin
  select * into v_order from public.laundry_orders where id=p_order_id and public.can_access_branch(branch_id);
  if v_order.id is null then raise exception 'Order not found'; end if;
  select * into v_existing from public.offline_sync_operations where id=p_operation_id;
  if v_existing.id is not null then
    if v_existing.organization_id<>v_order.organization_id or v_existing.user_id<>auth.uid() or v_existing.operation_type<>'update_order_status' then raise exception 'Offline operation id is already in use'; end if;
    if v_existing.result is not null then return v_existing.result; end if;
  else
    insert into public.offline_sync_operations(id,organization_id,user_id,operation_type) values(p_operation_id,v_order.organization_id,auth.uid(),'update_order_status');
  end if;
  v_result:=to_jsonb(public.update_order_status(p_order_id,p_status,p_notes));
  update public.offline_sync_operations set result=v_result,completed_at=now() where id=p_operation_id;
  return v_result;
end $$;

create or replace function public.sync_offline_cash_payment(
  p_operation_id uuid,
  p_order_id uuid,
  p_amount numeric,
  p_reference text default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_order public.laundry_orders%rowtype;v_existing public.offline_sync_operations%rowtype;v_result jsonb;
begin
  select * into v_order from public.laundry_orders where id=p_order_id and public.can_access_branch(branch_id);
  if v_order.id is null then raise exception 'Order not found'; end if;
  select * into v_existing from public.offline_sync_operations where id=p_operation_id;
  if v_existing.id is not null then
    if v_existing.organization_id<>v_order.organization_id or v_existing.user_id<>auth.uid() or v_existing.operation_type<>'record_cash_payment' then raise exception 'Offline operation id is already in use'; end if;
    if v_existing.result is not null then return v_existing.result; end if;
  else
    insert into public.offline_sync_operations(id,organization_id,user_id,operation_type) values(p_operation_id,v_order.organization_id,auth.uid(),'record_cash_payment');
  end if;
  v_result:=to_jsonb(public.record_order_payment(p_order_id,p_amount,'cash'::public.payment_method,p_reference));
  update public.offline_sync_operations set result=v_result,completed_at=now() where id=p_operation_id;
  return v_result;
end $$;

grant execute on function public.sync_offline_order_status(uuid,uuid,public.order_status,text) to authenticated;
grant execute on function public.sync_offline_cash_payment(uuid,uuid,numeric,text) to authenticated;
