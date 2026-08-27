-- LabaFlow v0.7.3 - loyalty accumulation hardening
begin;

-- Guarantee every organization has a loyalty program row.
insert into public.loyalty_programs(organization_id)
select o.id
from public.organizations o
where not exists (
  select 1 from public.loyalty_programs lp where lp.organization_id=o.id
);

-- One earn transaction per order prevents duplicate rewards while allowing stale
-- loyalty_awarded flags to be repaired safely.
create unique index if not exists loyalty_order_earn_uidx
on public.loyalty_transactions(reference_id)
where transaction_type='earn' and reference_type='laundry_order' and reference_id is not null;

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

  -- Transaction history is the source of truth. If this order already earned,
  -- simply repair the flag and stop.
  if exists(
    select 1 from public.loyalty_transactions
    where reference_type='laundry_order'
      and reference_id=v_order.id
      and transaction_type='earn'
  ) then
    update public.laundry_orders set loyalty_awarded=true,updated_at=now() where id=v_order.id;
    return 0;
  end if;

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
    ) on conflict do nothing;

    -- Only increment if the transaction was actually inserted.
    if found then
      update public.customers
      set loyalty_points=coalesce(loyalty_points,0)+v_points,
          lifetime_points=coalesce(lifetime_points,0)+v_points,
          lifetime_visits=coalesce(lifetime_visits,0)+1,
          lifetime_spend=coalesce(lifetime_spend,0)+v_order.total,
          last_visit_at=now(),
          updated_at=now()
      where id=v_order.customer_id;
    end if;
  else
    -- A paid registered-customer order still counts as a visit/spend event even
    -- when the configured reward calculates to zero.
    update public.customers
    set lifetime_visits=coalesce(lifetime_visits,0)+1,
        lifetime_spend=coalesce(lifetime_spend,0)+v_order.total,
        last_visit_at=now(),
        updated_at=now()
    where id=v_order.customer_id
      and not v_order.loyalty_awarded;
  end if;

  update public.laundry_orders
  set loyalty_awarded=true,updated_at=now()
  where id=v_order.id;

  return v_points;
end;
$$;

-- Make business-settings save an UPSERT so missing loyalty rows cannot silently
-- ignore configuration changes.
create or replace function public.save_organization_business_settings(
  p_loyalty jsonb,
  p_payment_methods jsonb,
  p_workflow_stages jsonb,
  p_completion_rules jsonb
)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid;
  v_method text;
  v_stage text;
begin
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid() and active and role in ('owner','admin')
  order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;

  if jsonb_array_length(coalesce(p_payment_methods->'methods','[]'::jsonb))=0 then
    raise exception 'At least one payment method is required';
  end if;
  for v_method in select jsonb_array_elements_text(p_payment_methods->'methods') loop
    if v_method not in ('cash','gcash','maya','card','bank_transfer') then raise exception 'Invalid payment method: %',v_method; end if;
  end loop;

  if jsonb_array_length(coalesce(p_workflow_stages->'stages','[]'::jsonb))<2 then
    raise exception 'Workflow must contain at least two stages';
  end if;
  if not (p_workflow_stages->'stages' ? 'received') or not (p_workflow_stages->'stages' ? 'completed') then
    raise exception 'Workflow must include received and completed';
  end if;
  for v_stage in select jsonb_array_elements_text(p_workflow_stages->'stages') loop
    if v_stage not in ('received','sorting','washing','drying','folding','ready','out_for_delivery','completed','on_hold','cancelled') then raise exception 'Invalid workflow stage: %',v_stage; end if;
  end loop;

  insert into public.loyalty_programs(
    organization_id,enabled,earning_method,points_per_visit,spend_amount_per_point,
    minimum_order_amount,same_day_visit_limit,points_expiry_months,updated_at
  ) values(
    v_org,
    coalesce((p_loyalty->>'enabled')::boolean,true),
    coalesce(p_loyalty->>'earning_method','per_visit'),
    greatest(coalesce((p_loyalty->>'points_per_visit')::integer,10),0),
    nullif((p_loyalty->>'spend_amount_per_point')::numeric,0),
    greatest(coalesce((p_loyalty->>'minimum_order_amount')::numeric,0),0),
    greatest(coalesce((p_loyalty->>'same_day_visit_limit')::integer,1),0),
    nullif((p_loyalty->>'points_expiry_months')::integer,0),
    now()
  )
  on conflict(organization_id) do update set
    enabled=excluded.enabled,
    earning_method=excluded.earning_method,
    points_per_visit=excluded.points_per_visit,
    spend_amount_per_point=excluded.spend_amount_per_point,
    minimum_order_amount=excluded.minimum_order_amount,
    same_day_visit_limit=excluded.same_day_visit_limit,
    points_expiry_months=excluded.points_expiry_months,
    updated_at=now();

  insert into public.organization_settings(organization_id,setting_key,setting_value,updated_at)
  values
    (v_org,'payment_methods',p_payment_methods,now()),
    (v_org,'order_workflow',p_workflow_stages,now()),
    (v_org,'completion_rules',p_completion_rules,now())
  on conflict(organization_id,setting_key) do update
  set setting_value=excluded.setting_value,updated_at=now();

  return true;
end;
$$;

-- Reconcile fully paid orders that have no earn transaction yet. Orders that
-- legitimately calculate to zero stay at zero; future calls remain idempotent.
do $$
declare r record;
begin
  for r in
    select o.id
    from public.laundry_orders o
    where o.customer_id is not null
      and o.amount_paid>=o.total
      and not exists(
        select 1 from public.loyalty_transactions lt
        where lt.reference_type='laundry_order'
          and lt.reference_id=o.id
          and lt.transaction_type='earn'
      )
  loop
    perform public.award_paid_order_loyalty(r.id);
  end loop;
end $$;

grant execute on function public.award_paid_order_loyalty(uuid) to authenticated;
grant execute on function public.save_organization_business_settings(jsonb,jsonb,jsonb,jsonb) to authenticated;

commit;
