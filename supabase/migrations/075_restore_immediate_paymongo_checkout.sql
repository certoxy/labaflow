-- Restore immediate PayMongo checkout and paid-subscription activation.
begin;

update public.subscription_upgrade_requests
set status='declined',
    reviewed_at=now(),
    review_notes='Deferred trial billing was removed; start a new PayMongo checkout when ready.'
where request_type='plan_upgrade'
  and status='pending'
  and payment_method='paymongo_after_trial';

drop function if exists public.schedule_subscription_after_trial(text,text,boolean,text,text,text);

create or replace function public.prepare_subscription_checkout(
  p_plan_key text,
  p_billing_cycle text default 'monthly',
  p_product_inventory_addon boolean default false,
  p_billing_contact text default null,
  p_billing_email text default null,
  p_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid;
  v_role public.staff_role;
  v_plan public.subscription_plans%rowtype;
  v_monthly numeric(12,2);
  v_amount numeric(12,2);
  v_request_id uuid;
  v_transaction_id uuid;
begin
  select organization_id,role into v_org,v_role
  from public.organization_memberships
  where user_id=auth.uid() and active
  order by created_at limit 1;

  if v_org is null or v_role not in ('owner','admin') then
    raise exception 'Organization administrator access required';
  end if;
  if p_billing_cycle not in ('monthly','yearly') then
    raise exception 'Invalid billing cycle';
  end if;

  select * into v_plan from public.subscription_plans
  where plan_key=lower(trim(p_plan_key)) and active;
  if v_plan.plan_key is null then raise exception 'Select a valid plan'; end if;
  if v_plan.monthly_price is null then raise exception 'Enterprise plans require a custom quotation'; end if;

  v_monthly := v_plan.monthly_price + case when p_product_inventory_addon then 299 else 0 end;
  v_amount := case when p_billing_cycle='yearly' then round(v_monthly*12*.90,2) else v_monthly end;

  if exists(select 1 from public.subscription_upgrade_requests where organization_id=v_org and request_type='plan_upgrade' and status='pending') then
    raise exception 'A pending plan upgrade already exists';
  end if;

  insert into public.subscription_upgrade_requests(
    organization_id,request_type,requested_plan_key,billing_contact,billing_email,
    payment_method,notes,requested_by,billing_cycle,product_inventory_addon
  ) values (
    v_org,'plan_upgrade',v_plan.plan_key,nullif(trim(coalesce(p_billing_contact,'')),''),
    nullif(lower(trim(coalesce(p_billing_email,''))),''),'paymongo',
    nullif(trim(coalesce(p_notes,'')),''),auth.uid(),p_billing_cycle,p_product_inventory_addon
  ) returning id into v_request_id;

  insert into public.subscription_payment_transactions(
    organization_id,requested_by,upgrade_request_id,plan_key,billing_cycle,
    product_inventory_addon,amount,billing_contact,billing_email,notes
  ) values (
    v_org,auth.uid(),v_request_id,v_plan.plan_key,p_billing_cycle,
    p_product_inventory_addon,v_amount,nullif(trim(coalesce(p_billing_contact,'')),''),
    nullif(lower(trim(coalesce(p_billing_email,''))),''),nullif(trim(coalesce(p_notes,'')),'')
  ) returning id into v_transaction_id;

  return jsonb_build_object(
    'transaction_id',v_transaction_id,'request_id',v_request_id,'organization_id',v_org,
    'organization_name',(select name from public.organizations where id=v_org),
    'plan_key',v_plan.plan_key,'plan_name',v_plan.display_name,'billing_cycle',p_billing_cycle,
    'product_inventory_addon',p_product_inventory_addon,'amount',v_amount,'currency','PHP',
    'billing_email',nullif(lower(trim(coalesce(p_billing_email,''))),'')
  );
end;
$$;

grant execute on function public.prepare_subscription_checkout(text,text,boolean,text,text,text) to authenticated;

commit;
