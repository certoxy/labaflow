-- Allow Platform Admins to create an organization-specific PayMongo checkout.
begin;

create or replace function public.prepare_platform_subscription_checkout(
  p_organization_id uuid,
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
  v_plan public.subscription_plans%rowtype;
  v_subscription public.organization_subscriptions%rowtype;
  v_existing public.subscription_payment_transactions%rowtype;
  v_monthly numeric(12,2);
  v_amount numeric(12,2);
  v_request_id uuid;
  v_transaction_id uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Platform administrator access required';
  end if;
  if not exists(select 1 from public.organizations where id=p_organization_id and active) then
    raise exception 'Active organization not found';
  end if;
  if p_billing_cycle not in ('monthly','yearly') then
    raise exception 'Invalid billing cycle';
  end if;

  select * into v_existing
  from public.subscription_payment_transactions
  where organization_id=p_organization_id and status='awaiting_payment' and checkout_url is not null
  order by created_at desc limit 1;
  if v_existing.id is not null then
    return jsonb_build_object(
      'transaction_id',v_existing.id,'organization_id',v_existing.organization_id,
      'plan_key',v_existing.plan_key,'billing_cycle',v_existing.billing_cycle,
      'amount',v_existing.amount,'currency',v_existing.currency,
      'checkout_url',v_existing.checkout_url,'reused',true
    );
  end if;

  select * into v_plan from public.subscription_plans
  where plan_key=lower(trim(p_plan_key)) and active;
  if v_plan.plan_key is null then raise exception 'Select a valid plan'; end if;

  select * into v_subscription from public.organization_subscriptions
  where organization_id=p_organization_id;
  if v_subscription.organization_id is null then raise exception 'Organization subscription not found'; end if;

  v_monthly := case
    when v_plan.plan_key='enterprise' then coalesce(v_subscription.custom_monthly_price,0)
    else coalesce(v_plan.monthly_price,0)
  end;
  v_monthly := round(v_monthly*(1-(coalesce(v_subscription.discount_percent,0)/100.0)),2)
    + case when p_product_inventory_addon then 299 else 0 end;
  if v_monthly <= 0 then raise exception 'This organization needs a billable subscription price'; end if;
  v_amount := case when p_billing_cycle='yearly' then round(v_monthly*12*.90,2) else v_monthly end;

  if exists(select 1 from public.subscription_upgrade_requests where organization_id=p_organization_id and request_type='plan_upgrade' and status='pending') then
    raise exception 'A pending plan upgrade already exists for this organization';
  end if;

  insert into public.subscription_upgrade_requests(
    organization_id,request_type,requested_plan_key,billing_contact,billing_email,
    payment_method,notes,requested_by,billing_cycle,product_inventory_addon
  ) values (
    p_organization_id,'plan_upgrade',v_plan.plan_key,nullif(trim(coalesce(p_billing_contact,'')),''),
    nullif(lower(trim(coalesce(p_billing_email,''))),''),'paymongo',
    nullif(trim(coalesce(p_notes,'')),''),auth.uid(),p_billing_cycle,p_product_inventory_addon
  ) returning id into v_request_id;

  insert into public.subscription_payment_transactions(
    organization_id,requested_by,upgrade_request_id,plan_key,billing_cycle,
    product_inventory_addon,amount,billing_contact,billing_email,notes
  ) values (
    p_organization_id,auth.uid(),v_request_id,v_plan.plan_key,p_billing_cycle,
    p_product_inventory_addon,v_amount,nullif(trim(coalesce(p_billing_contact,'')),''),
    nullif(lower(trim(coalesce(p_billing_email,''))),''),nullif(trim(coalesce(p_notes,'')),'')
  ) returning id into v_transaction_id;

  return jsonb_build_object(
    'transaction_id',v_transaction_id,'request_id',v_request_id,'organization_id',p_organization_id,
    'organization_name',(select name from public.organizations where id=p_organization_id),
    'plan_key',v_plan.plan_key,'plan_name',v_plan.display_name,'billing_cycle',p_billing_cycle,
    'product_inventory_addon',p_product_inventory_addon,'amount',v_amount,'currency','PHP',
    'billing_email',nullif(lower(trim(coalesce(p_billing_email,''))),'')
  );
end;
$$;

grant execute on function public.prepare_platform_subscription_checkout(uuid,text,text,boolean,text,text,text) to authenticated;

commit;
