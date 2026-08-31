-- LabaFlow subscription plans v1.
-- Replaces feature-price estimation with plan-based pricing while preserving the 30-day trial.

begin;

create table if not exists public.subscription_plans (
  plan_key text primary key,
  display_name text not null,
  monthly_price numeric(12,2),
  branch_limit integer,
  staff_limit integer,
  transaction_limit integer,
  customer_limit integer,
  capabilities jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  sort_order integer not null default 100,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id),
  constraint subscription_plan_price check (monthly_price is null or monthly_price >= 0),
  constraint subscription_plan_branches check (branch_limit is null or branch_limit > 0),
  constraint subscription_plan_staff check (staff_limit is null or staff_limit > 0),
  constraint subscription_plan_transactions check (transaction_limit is null or transaction_limit > 0),
  constraint subscription_plan_customers check (customer_limit is null or customer_limit > 0)
);

insert into public.subscription_plans(
  plan_key,display_name,monthly_price,branch_limit,staff_limit,transaction_limit,customer_limit,capabilities,sort_order
)
values
  ('starter','Starter',799,1,3,500,1000,
   '{"orders_payments":true,"customer_qr":true,"receipt_printing":true,"basic_reporting":true,"loyalty":false,"promos":false,"pickup_delivery":false,"online_payment":false,"advanced_reports":false,"multi_branch_reporting":false,"offline":"basic","audit_admin":"none","priority_support":false}'::jsonb,10),
  ('business','Business',1499,2,10,2000,5000,
   '{"orders_payments":true,"customer_qr":true,"receipt_printing":true,"basic_reporting":true,"loyalty":true,"promos":true,"pickup_delivery":true,"online_payment":true,"advanced_reports":true,"multi_branch_reporting":true,"offline":"full","audit_admin":"basic","priority_support":false}'::jsonb,20),
  ('pro','Pro',2499,5,25,7500,null,
   '{"orders_payments":true,"customer_qr":true,"receipt_printing":true,"basic_reporting":true,"loyalty":true,"promos":true,"pickup_delivery":true,"online_payment":true,"advanced_reports":true,"multi_branch_reporting":true,"offline":"full","audit_admin":"full","priority_support":true}'::jsonb,30),
  ('enterprise','Enterprise',null,null,null,null,null,
   '{"orders_payments":true,"customer_qr":true,"receipt_printing":true,"basic_reporting":true,"loyalty":true,"promos":true,"pickup_delivery":true,"online_payment":true,"advanced_reports":true,"multi_branch_reporting":true,"offline":"full","audit_admin":"full","priority_support":true}'::jsonb,40)
on conflict(plan_key) do update set
  display_name=excluded.display_name,
  monthly_price=excluded.monthly_price,
  branch_limit=excluded.branch_limit,
  staff_limit=excluded.staff_limit,
  transaction_limit=excluded.transaction_limit,
  customer_limit=excluded.customer_limit,
  capabilities=excluded.capabilities,
  sort_order=excluded.sort_order,
  updated_at=now();

alter table public.organization_subscriptions
  add column if not exists plan_key text references public.subscription_plans(plan_key),
  add column if not exists custom_monthly_price numeric(12,2),
  add column if not exists discount_percent numeric(5,2) not null default 0,
  add column if not exists promo_code text,
  add column if not exists referral_name text,
  add column if not exists referral_email text;

alter table public.organization_subscriptions
  drop constraint if exists organization_subscription_custom_price_check,
  add constraint organization_subscription_custom_price_check check (custom_monthly_price is null or custom_monthly_price >= 0),
  drop constraint if exists organization_subscription_discount_check,
  add constraint organization_subscription_discount_check check (discount_percent >= 0 and discount_percent <= 100);

update public.organization_subscriptions
set plan_key='business'
where plan_key is null and status='trialing';

update public.organization_subscriptions
set plan_key='starter'
where plan_key is null;

alter table public.organization_subscriptions
  alter column plan_key set default 'starter',
  alter column plan_key set not null;

create or replace function public.get_platform_subscription_context()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_orgs jsonb;v_plans jsonb;v_summary jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Platform administrator access required';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'plan_key',p.plan_key,
    'display_name',p.display_name,
    'monthly_price',p.monthly_price,
    'branch_limit',p.branch_limit,
    'staff_limit',p.staff_limit,
    'transaction_limit',p.transaction_limit,
    'customer_limit',p.customer_limit,
    'capabilities',p.capabilities,
    'active',p.active,
    'sort_order',p.sort_order
  ) order by p.sort_order,p.display_name),'[]'::jsonb)
  into v_plans
  from public.subscription_plans p
  where p.active;

  with org_data as (
    select
      o.id,o.name,o.slug,o.active,o.created_at,
      s.trial_started_at,s.trial_ends_at,
      case when s.status='trialing' and now()>=s.trial_ends_at then 'active' else s.status end as status,
      s.billing_started_at,s.next_billing_at,s.notes,
      s.plan_key,s.custom_monthly_price,s.discount_percent,s.promo_code,s.referral_name,s.referral_email,
      p.display_name as plan_name,p.monthly_price as plan_monthly_price,
      p.branch_limit,p.staff_limit,p.transaction_limit,p.customer_limit,p.capabilities,
      greatest(0,ceil(extract(epoch from (s.trial_ends_at-now()))/86400.0))::int as trial_days_remaining,
      now() < s.trial_ends_at and s.status='trialing' as in_trial,
      case
        when s.plan_key='enterprise' then coalesce(s.custom_monthly_price,0)
        else coalesce(s.custom_monthly_price,p.monthly_price,0)
      end::numeric(12,2) as base_monthly_price,
      round((case
        when s.plan_key='enterprise' then coalesce(s.custom_monthly_price,0)
        else coalesce(s.custom_monthly_price,p.monthly_price,0)
      end) * (1-(coalesce(s.discount_percent,0)/100.0)),2)::numeric(12,2) as net_monthly_price,
      (select count(*) from public.branches b where b.organization_id=o.id and b.active) as branches_used,
      (select count(*) from public.organization_memberships m where m.organization_id=o.id and m.active) as staff_used,
      (select count(*) from public.customers c where c.organization_id=o.id and c.active) as customers_used,
      (select count(*) from public.laundry_orders lo where lo.organization_id=o.id and lo.created_at>=date_trunc('month',now())) as transactions_used
    from public.organizations o
    join public.organization_subscriptions s on s.organization_id=o.id
    join public.subscription_plans p on p.plan_key=s.plan_key
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',d.id,'name',d.name,'slug',d.slug,'active',d.active,'created_at',d.created_at,
    'trial_started_at',d.trial_started_at,'trial_ends_at',d.trial_ends_at,
    'trial_days_remaining',d.trial_days_remaining,'in_trial',d.in_trial,
    'status',d.status,'billing_started_at',d.billing_started_at,'next_billing_at',d.next_billing_at,
    'notes',d.notes,'plan_key',d.plan_key,'plan_name',d.plan_name,
    'plan_monthly_price',d.plan_monthly_price,'custom_monthly_price',d.custom_monthly_price,
    'discount_percent',d.discount_percent,'promo_code',d.promo_code,
    'referral_name',d.referral_name,'referral_email',d.referral_email,
    'base_monthly_price',d.base_monthly_price,'net_monthly_price',d.net_monthly_price,
    'branch_limit',d.branch_limit,'staff_limit',d.staff_limit,'transaction_limit',d.transaction_limit,'customer_limit',d.customer_limit,
    'branches_used',d.branches_used,'staff_used',d.staff_used,'transactions_used',d.transactions_used,'customers_used',d.customers_used,
    'capabilities',d.capabilities
  ) order by d.created_at desc),'[]'::jsonb)
  into v_orgs from org_data d;

  with billable as (
    select s.*,p.monthly_price,
      case when s.plan_key='enterprise' then coalesce(s.custom_monthly_price,0) else coalesce(s.custom_monthly_price,p.monthly_price,0) end as base_price
    from public.organization_subscriptions s
    join public.subscription_plans p on p.plan_key=s.plan_key
  )
  select jsonb_build_object(
    'organizations',count(*),
    'trialing',count(*) filter(where now()<b.trial_ends_at and b.status='trialing'),
    'billable',count(*) filter(where now()>=b.trial_ends_at and b.status in ('trialing','active','past_due')),
    'past_due',count(*) filter(where b.status='past_due'),
    'estimated_mrr',coalesce(sum(case when now()>=b.trial_ends_at and b.status in ('trialing','active')
      then round(b.base_price*(1-(coalesce(b.discount_percent,0)/100.0)),2) else 0 end),0)
  ) into v_summary
  from billable b;

  return jsonb_build_object('summary',v_summary,'plans',v_plans,'organizations',v_orgs);
end;
$$;

create or replace function public.set_organization_subscription(
  p_organization_id uuid,
  p_status text,
  p_trial_ends_at timestamptz default null,
  p_next_billing_at timestamptz default null,
  p_notes text default null,
  p_plan_key text default null,
  p_custom_monthly_price numeric default null,
  p_discount_percent numeric default 0,
  p_promo_code text default null,
  p_referral_name text default null,
  p_referral_email text default null
)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
  if p_status not in ('trialing','active','past_due','suspended','cancelled') then raise exception 'Invalid subscription status'; end if;
  if p_plan_key is not null and not exists(select 1 from public.subscription_plans where plan_key=lower(trim(p_plan_key)) and active) then raise exception 'Invalid subscription plan'; end if;
  if p_discount_percent < 0 or p_discount_percent > 100 then raise exception 'Discount must be between 0 and 100 percent'; end if;
  if p_custom_monthly_price is not null and p_custom_monthly_price < 0 then raise exception 'Custom monthly price cannot be negative'; end if;

  update public.organization_subscriptions
  set status=p_status,
      plan_key=coalesce(lower(trim(p_plan_key)),plan_key),
      custom_monthly_price=p_custom_monthly_price,
      discount_percent=coalesce(p_discount_percent,0),
      promo_code=nullif(upper(trim(coalesce(p_promo_code,''))),''),
      referral_name=nullif(trim(coalesce(p_referral_name,'')),''),
      referral_email=nullif(lower(trim(coalesce(p_referral_email,''))),''),
      trial_ends_at=coalesce(p_trial_ends_at,trial_ends_at),
      billing_started_at=case when p_status='active' then coalesce(billing_started_at,now()) else billing_started_at end,
      next_billing_at=p_next_billing_at,
      notes=nullif(trim(coalesce(p_notes,'')),''),
      updated_at=now(),updated_by=auth.uid()
  where organization_id=p_organization_id;
  if not found then raise exception 'Organization subscription not found'; end if;
  return true;
end;
$$;

alter table public.subscription_plans enable row level security;

drop policy if exists "platform admins read subscription plans" on public.subscription_plans;
create policy "platform admins read subscription plans"
on public.subscription_plans for select to authenticated
using(public.is_platform_admin());

grant execute on function public.get_platform_subscription_context() to authenticated;
grant execute on function public.set_organization_subscription(uuid,text,timestamptz,timestamptz,text,text,numeric,numeric,text,text,text) to authenticated;

commit;
