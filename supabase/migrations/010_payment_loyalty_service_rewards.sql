-- LabaFlow v0.5.1
-- Award loyalty when an order becomes fully paid and support fixed points per service rendered.

begin;

alter table public.services
  add column if not exists loyalty_points integer not null default 0 check (loyalty_points >= 0);

-- Replace the service-creation RPC with a reward-aware signature.
drop function if exists public.create_laundry_service(text,text,public.pricing_unit,numeric);

create or replace function public.create_laundry_service(
  p_name text,
  p_description text,
  p_pricing_unit public.pricing_unit,
  p_default_price numeric,
  p_loyalty_points integer default 0
)
returns public.services
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid;
  v_service public.services%rowtype;
begin
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid() and active
  order by created_at limit 1;

  if v_org is null or not public.has_role_permission('manage_services') then
    raise exception 'Service management permission required';
  end if;
  if nullif(trim(p_name),'') is null then raise exception 'Service name is required'; end if;
  if p_default_price < 0 then raise exception 'Price cannot be negative'; end if;
  if coalesce(p_loyalty_points,0) < 0 then raise exception 'Loyalty points cannot be negative'; end if;

  insert into public.services(organization_id,name,description,pricing_unit,default_price,loyalty_points)
  values(v_org,trim(p_name),nullif(trim(coalesce(p_description,'')),''),p_pricing_unit,p_default_price,coalesce(p_loyalty_points,0))
  returning * into v_service;

  return v_service;
end;
$$;

create or replace function public.update_service_loyalty_points(p_service_id uuid,p_loyalty_points integer)
returns public.services
language plpgsql
security definer
set search_path=public
as $$
declare
  v_service public.services%rowtype;
begin
  if coalesce(p_loyalty_points,0) < 0 then raise exception 'Loyalty points cannot be negative'; end if;

  select * into v_service from public.services where id=p_service_id;
  if v_service.id is null then raise exception 'Service not found'; end if;
  if not public.has_role_permission('manage_services') or not public.is_organization_member(v_service.organization_id) then
    raise exception 'Service management permission required';
  end if;

  update public.services
  set loyalty_points=coalesce(p_loyalty_points,0),updated_at=now()
  where id=p_service_id
  returning * into v_service;

  return v_service;
end;
$$;

-- Centralized one-time order loyalty/visit award.
create or replace function public.award_paid_order_loyalty(p_order_id uuid)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order public.laundry_orders%rowtype;
  v_program public.loyalty_programs%rowtype;
  v_points integer := 0;
  v_today_count integer := 0;
begin
  select * into v_order
  from public.laundry_orders
  where id=p_order_id
  for update;

  if v_order.id is null then raise exception 'Order not found'; end if;
  if v_order.amount_paid < v_order.total then return 0; end if;
  if v_order.loyalty_awarded then return 0; end if;

  -- No registered customer: mark handled so repeated payment calls cannot reprocess it.
  if v_order.customer_id is null then
    update public.laundry_orders set loyalty_awarded=true,updated_at=now() where id=v_order.id;
    return 0;
  end if;

  select * into v_program
  from public.loyalty_programs
  where organization_id=v_order.organization_id;

  if v_program.id is not null and v_program.enabled and v_order.total >= v_program.minimum_order_amount then
    if v_program.earning_method='per_visit' then
      select count(*) into v_today_count
      from public.loyalty_transactions
      where customer_id=v_order.customer_id
        and transaction_type='earn'
        and reference_type='laundry_order'
        and created_at::date=current_date;
      if v_today_count < v_program.same_day_visit_limit then
        v_points := v_program.points_per_visit;
      end if;
    elsif v_program.earning_method='per_spend' and coalesce(v_program.spend_amount_per_point,0)>0 then
      v_points := floor(v_order.total/v_program.spend_amount_per_point)::integer;
    elsif v_program.earning_method='per_service' then
      select coalesce(sum(s.loyalty_points),0)::integer into v_points
      from public.laundry_order_items oi
      join public.services s on s.id=oi.service_id
      where oi.order_id=v_order.id;
    end if;
  end if;

  if v_points>0 then
    insert into public.loyalty_transactions(
      organization_id,customer_id,branch_id,transaction_type,points,description,reference_type,reference_id,created_by
    ) values(
      v_order.organization_id,v_order.customer_id,v_order.branch_id,'earn',v_points,
      'Points earned from fully paid laundry order','laundry_order',v_order.id,auth.uid()
    );
  end if;

  update public.customers
  set loyalty_points=loyalty_points+v_points,
      lifetime_points=lifetime_points+v_points,
      lifetime_visits=lifetime_visits+1,
      lifetime_spend=lifetime_spend+v_order.total,
      last_visit_at=now(),
      updated_at=now()
  where id=v_order.customer_id;

  update public.laundry_orders
  set loyalty_awarded=true,updated_at=now()
  where id=v_order.id;

  return v_points;
end;
$$;

create or replace function public.record_order_payment(
  p_order_id uuid,
  p_amount numeric,
  p_method public.payment_method,
  p_reference text default null
)
returns public.laundry_orders
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order public.laundry_orders%rowtype;
  v_new_paid numeric;
  v_methods jsonb;
begin
  select * into v_order
  from public.laundry_orders
  where id=p_order_id and public.can_access_branch(branch_id)
  for update;

  if v_order.id is null then raise exception 'Order not found'; end if;
  if not public.has_role_permission('record_payments',v_order.branch_id) then raise exception 'Payment permission required'; end if;
  if v_order.payment_status='paid' or v_order.amount_paid>=v_order.total then raise exception 'Order is already fully paid'; end if;

  select setting_value into v_methods
  from public.organization_settings
  where organization_id=v_order.organization_id and setting_key='payment_methods';
  if v_methods is not null and not (v_methods->'methods' ? p_method::text) then
    raise exception 'Payment method is disabled for this organization';
  end if;
  if p_amount<=0 then raise exception 'Payment must be greater than zero'; end if;

  -- Prevent accidental overpayment for now.
  if v_order.amount_paid+p_amount>v_order.total then
    raise exception 'Payment exceeds remaining balance';
  end if;

  insert into public.payments(organization_id,branch_id,order_id,amount,method,reference,received_by)
  values(v_order.organization_id,v_order.branch_id,v_order.id,p_amount,p_method,p_reference,auth.uid());

  v_new_paid:=v_order.amount_paid+p_amount;
  update public.laundry_orders
  set amount_paid=v_new_paid,
      payment_status=case when v_new_paid>=total then 'paid'::public.payment_status else 'partial'::public.payment_status end,
      updated_at=now()
  where id=v_order.id
  returning * into v_order;

  if v_new_paid>=v_order.total then
    perform public.award_paid_order_loyalty(v_order.id);
    select * into v_order from public.laundry_orders where id=v_order.id;
  end if;

  return v_order;
end;
$$;

-- Completion remains a fallback for historical orders that became paid before this migration.
create or replace function public.update_order_status(p_order_id uuid,p_status public.order_status,p_notes text default null)
returns public.laundry_orders
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order public.laundry_orders%rowtype;
  v_workflow jsonb;
  v_completion jsonb;
begin
  select * into v_order from public.laundry_orders where id=p_order_id and public.can_access_branch(branch_id) for update;
  if v_order.id is null then raise exception 'Order not found'; end if;
  if not public.has_role_permission('process_orders',v_order.branch_id) then raise exception 'Order processing permission required'; end if;

  select setting_value into v_workflow from public.organization_settings where organization_id=v_order.organization_id and setting_key='order_workflow';
  if v_workflow is not null and not (v_workflow->'stages' ? p_status::text) and p_status not in ('cancelled','on_hold') then
    raise exception 'Order status is disabled for this organization';
  end if;
  select setting_value into v_completion from public.organization_settings where organization_id=v_order.organization_id and setting_key='completion_rules';
  if p_status='completed' and coalesce((v_completion->>'require_full_payment_before_completion')::boolean,false) and v_order.amount_paid<v_order.total then
    raise exception 'Full payment is required before completing this order';
  end if;

  update public.laundry_orders
  set status=p_status,
      completed_at=case when p_status='completed' then coalesce(completed_at,now()) else completed_at end,
      updated_at=now()
  where id=v_order.id
  returning * into v_order;

  insert into public.order_status_history(order_id,status,changed_by,notes)
  values(v_order.id,p_status,auth.uid(),p_notes);

  if p_status='completed' and v_order.amount_paid>=v_order.total and not v_order.loyalty_awarded then
    perform public.award_paid_order_loyalty(v_order.id);
    select * into v_order from public.laundry_orders where id=v_order.id;
  end if;

  return v_order;
end;
$$;

grant execute on function public.create_laundry_service(text,text,public.pricing_unit,numeric,integer) to authenticated;
grant execute on function public.update_service_loyalty_points(uuid,integer) to authenticated;
grant execute on function public.award_paid_order_loyalty(uuid) to authenticated;

commit;
