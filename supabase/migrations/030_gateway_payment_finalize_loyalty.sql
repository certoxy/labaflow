-- LabaFlow: finalize verified gateway payments using the normal payment/loyalty rules.

create or replace function public.record_gateway_order_payment(
  p_order_id uuid,
  p_amount numeric,
  p_method text,
  p_reference text,
  p_provider text,
  p_provider_payment_id text,
  p_provider_event_id text
) returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_tx public.payment_gateway_transactions;
  v_order public.laundry_orders;
  v_new_paid numeric;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role required';
  end if;

  select * into v_tx
  from public.payment_gateway_transactions
  where order_id=p_order_id
    and provider=p_provider
    and amount=p_amount
    and status in ('pending','awaiting_payment')
  order by created_at desc
  limit 1
  for update;

  if v_tx.id is null then
    if exists(
      select 1 from public.payment_gateway_transactions
      where order_id=p_order_id
        and provider=p_provider
        and provider_event_id=p_provider_event_id
        and status='paid'
    ) then return; end if;
    raise exception 'Matching gateway transaction not found';
  end if;

  select * into v_order from public.laundry_orders where id=p_order_id for update;
  if v_order.id is null then raise exception 'Order not found'; end if;
  if v_order.payment_status='paid' or v_order.amount_paid>=v_order.total then
    update public.payment_gateway_transactions
    set status='paid',provider_payment_id=p_provider_payment_id,provider_event_id=p_provider_event_id,updated_at=now()
    where id=v_tx.id;
    return;
  end if;
  if p_amount<=0 or p_amount>greatest(v_order.total-v_order.amount_paid,0)+0.001 then
    raise exception 'Invalid gateway payment amount';
  end if;

  insert into public.payments(organization_id,branch_id,order_id,amount,method,reference,received_by)
  values(v_order.organization_id,v_order.branch_id,v_order.id,p_amount,p_method::public.payment_method,p_reference,null);

  v_new_paid:=v_order.amount_paid+p_amount;
  update public.laundry_orders
  set amount_paid=v_new_paid,
      payment_status=case when v_new_paid>=total then 'paid'::public.payment_status else 'partial'::public.payment_status end,
      updated_at=now()
  where id=v_order.id;

  if v_new_paid>=v_order.total then
    perform public.award_paid_order_loyalty(v_order.id);
  end if;

  update public.payment_gateway_transactions
  set status='paid',provider_payment_id=p_provider_payment_id,provider_event_id=p_provider_event_id,updated_at=now()
  where id=v_tx.id;
end;
$$;

revoke all on function public.record_gateway_order_payment(uuid,numeric,text,text,text,text,text) from public;
revoke all on function public.record_gateway_order_payment(uuid,numeric,text,text,text,text,text) from anon;
revoke all on function public.record_gateway_order_payment(uuid,numeric,text,text,text,text,text) from authenticated;
grant execute on function public.record_gateway_order_payment(uuid,numeric,text,text,text,text,text) to service_role;
