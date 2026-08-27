-- LabaFlow v0.7.4 - loyalty payment diagnostics + repair
begin;

-- Explicitly reassert payment -> loyalty awarding so later migrations cannot leave
-- an older record_order_payment implementation active.
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
  if not public.has_role_permission('record_payments',v_order.branch_id) then
    raise exception 'Payment permission required';
  end if;
  if v_order.payment_status='paid' or v_order.amount_paid>=v_order.total then
    raise exception 'Order is already fully paid';
  end if;

  select setting_value into v_methods
  from public.organization_settings
  where organization_id=v_order.organization_id and setting_key='payment_methods';

  if v_methods is not null and not (v_methods->'methods' ? p_method::text) then
    raise exception 'Payment method is disabled for this organization';
  end if;
  if p_amount<=0 then raise exception 'Payment must be greater than zero'; end if;
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

-- Diagnostic helper for an order's loyalty result.
create or replace function public.get_order_loyalty_diagnostic(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order public.laundry_orders%rowtype;
  v_program public.loyalty_programs%rowtype;
  v_service_points integer:=0;
  v_existing_points integer;
  v_expected integer:=0;
  v_today_count integer:=0;
begin
  select * into v_order
  from public.laundry_orders
  where id=p_order_id and public.can_access_branch(branch_id);
  if v_order.id is null then raise exception 'Order not found'; end if;

  select * into v_program
  from public.loyalty_programs
  where organization_id=v_order.organization_id;

  select coalesce(sum(s.loyalty_points),0)::integer
  into v_service_points
  from public.laundry_order_items oi
  join public.services s on s.id=oi.service_id
  where oi.order_id=v_order.id;

  select points into v_existing_points
  from public.loyalty_transactions
  where reference_type='laundry_order'
    and reference_id=v_order.id
    and transaction_type='earn'
  limit 1;

  if v_program.id is not null and v_program.enabled and v_order.total>=v_program.minimum_order_amount then
    if v_program.earning_method='per_service' then
      v_expected:=v_service_points;
    elsif v_program.earning_method='per_spend' and coalesce(v_program.spend_amount_per_point,0)>0 then
      v_expected:=floor(v_order.total/v_program.spend_amount_per_point)::integer;
    elsif v_program.earning_method='per_visit' then
      select count(*) into v_today_count
      from public.loyalty_transactions
      where customer_id=v_order.customer_id
        and transaction_type='earn'
        and reference_type='laundry_order'
        and created_at::date=current_date
        and reference_id<>v_order.id;
      if v_today_count<v_program.same_day_visit_limit then
        v_expected:=v_program.points_per_visit;
      end if;
    end if;
  end if;

  return jsonb_build_object(
    'order_code',v_order.order_code,
    'customer_id',v_order.customer_id,
    'total',v_order.total,
    'amount_paid',v_order.amount_paid,
    'payment_status',v_order.payment_status,
    'loyalty_awarded_flag',v_order.loyalty_awarded,
    'program_exists',v_program.id is not null,
    'program_enabled',coalesce(v_program.enabled,false),
    'earning_method',v_program.earning_method,
    'minimum_order_amount',v_program.minimum_order_amount,
    'same_day_visit_limit',v_program.same_day_visit_limit,
    'service_points',v_service_points,
    'expected_points',v_expected,
    'existing_earn_points',v_existing_points
  );
end;
$$;

-- Repair any fully-paid orders with positive expected points but no earn transaction.
do $$
declare r record;v_program public.loyalty_programs%rowtype;v_expected integer;v_today integer;
begin
  for r in
    select o.*
    from public.laundry_orders o
    where o.customer_id is not null
      and o.amount_paid>=o.total
      and not exists(
        select 1 from public.loyalty_transactions lt
        where lt.reference_type='laundry_order'
          and lt.reference_id=o.id
          and lt.transaction_type='earn'
      )
    order by o.created_at
  loop
    select * into v_program from public.loyalty_programs where organization_id=r.organization_id;
    v_expected:=0;
    if v_program.id is not null and v_program.enabled and r.total>=v_program.minimum_order_amount then
      if v_program.earning_method='per_service' then
        select coalesce(sum(s.loyalty_points),0)::integer into v_expected
        from public.laundry_order_items oi join public.services s on s.id=oi.service_id
        where oi.order_id=r.id;
      elsif v_program.earning_method='per_spend' and coalesce(v_program.spend_amount_per_point,0)>0 then
        v_expected:=floor(r.total/v_program.spend_amount_per_point)::integer;
      elsif v_program.earning_method='per_visit' then
        select count(*) into v_today from public.loyalty_transactions
        where customer_id=r.customer_id and transaction_type='earn' and reference_type='laundry_order'
          and created_at::date=r.created_at::date;
        if v_today<v_program.same_day_visit_limit then v_expected:=v_program.points_per_visit; end if;
      end if;
    end if;
    if v_expected>0 then
      perform public.award_paid_order_loyalty(r.id);
    end if;
  end loop;
end $$;

grant execute on function public.get_order_loyalty_diagnostic(uuid) to authenticated;

commit;
