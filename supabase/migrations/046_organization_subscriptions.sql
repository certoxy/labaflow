-- LabaFlow organization subscription monitoring and feature-based billing estimates.
-- Each organization receives a 30-day free trial. After trial, estimated monthly billing
-- is calculated from enabled subscription features and their platform-configured prices.

begin;

create table if not exists public.subscription_feature_prices (
  feature_key text primary key,
  display_name text not null,
  monthly_price numeric(12,2) not null default 0 check (monthly_price >= 0),
  active boolean not null default true,
  sort_order integer not null default 100,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id)
);

insert into public.subscription_feature_prices(feature_key,display_name,monthly_price,sort_order)
values
  ('customer_loyalty','Customer Loyalty',0,10),
  ('pickup_delivery','Pickup & Delivery',0,20),
  ('inventory','Inventory',0,30),
  ('expenses','Expense Tracking',0,40),
  ('order_workflow','Advanced Order Workflow',0,50),
  ('qr_customer_id','Customer QR ID',0,60)
on conflict(feature_key) do nothing;

create table if not exists public.organization_subscriptions (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  trial_started_at timestamptz not null,
  trial_ends_at timestamptz not null,
  status text not null default 'trialing' check (status in ('trialing','active','past_due','suspended','cancelled')),
  billing_started_at timestamptz,
  next_billing_at timestamptz,
  notes text,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id),
  constraint organization_subscription_trial_window check (trial_ends_at >= trial_started_at)
);

insert into public.organization_subscriptions(organization_id,trial_started_at,trial_ends_at,status)
select o.id,o.created_at,o.created_at + interval '30 days',
       case when now() < o.created_at + interval '30 days' then 'trialing' else 'active' end
from public.organizations o
on conflict(organization_id) do nothing;

create or replace function public.ensure_organization_subscription()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  insert into public.organization_subscriptions(organization_id,trial_started_at,trial_ends_at,status)
  values(new.id,new.created_at,new.created_at + interval '30 days','trialing')
  on conflict(organization_id) do nothing;
  return new;
end;
$$;

drop trigger if exists organizations_create_subscription on public.organizations;
create trigger organizations_create_subscription
after insert on public.organizations
for each row execute function public.ensure_organization_subscription();

create or replace function public.get_platform_subscription_context()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_orgs jsonb;v_prices jsonb;v_summary jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Platform administrator access required';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'feature_key',p.feature_key,
    'display_name',p.display_name,
    'monthly_price',p.monthly_price,
    'active',p.active,
    'sort_order',p.sort_order
  ) order by p.sort_order,p.display_name),'[]'::jsonb)
  into v_prices
  from public.subscription_feature_prices p;

  with org_data as (
    select
      o.id,o.name,o.slug,o.active,o.created_at,
      s.trial_started_at,s.trial_ends_at,s.status,s.billing_started_at,s.next_billing_at,s.notes,
      greatest(0,ceil(extract(epoch from (s.trial_ends_at-now()))/86400.0))::int as trial_days_remaining,
      now() < s.trial_ends_at as in_trial,
      coalesce((
        select sum(p.monthly_price)
        from public.subscription_feature_prices p
        left join public.organization_features f
          on f.organization_id=o.id and f.feature_key=p.feature_key
        where p.active and coalesce(f.enabled,true)
      ),0)::numeric(12,2) as monthly_estimate,
      coalesce((
        select jsonb_agg(jsonb_build_object(
          'feature_key',p.feature_key,
          'display_name',p.display_name,
          'enabled',coalesce(f.enabled,true),
          'monthly_price',p.monthly_price
        ) order by p.sort_order,p.display_name)
        from public.subscription_feature_prices p
        left join public.organization_features f
          on f.organization_id=o.id and f.feature_key=p.feature_key
        where p.active
      ),'[]'::jsonb) as features
    from public.organizations o
    join public.organization_subscriptions s on s.organization_id=o.id
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',d.id,'name',d.name,'slug',d.slug,'active',d.active,'created_at',d.created_at,
    'trial_started_at',d.trial_started_at,'trial_ends_at',d.trial_ends_at,
    'trial_days_remaining',d.trial_days_remaining,'in_trial',d.in_trial,
    'status',d.status,'billing_started_at',d.billing_started_at,'next_billing_at',d.next_billing_at,
    'notes',d.notes,'monthly_estimate',d.monthly_estimate,'features',d.features
  ) order by d.created_at desc),'[]'::jsonb)
  into v_orgs from org_data d;

  select jsonb_build_object(
    'organizations',count(*),
    'trialing',count(*) filter(where now()<s.trial_ends_at and s.status='trialing'),
    'billable',count(*) filter(where now()>=s.trial_ends_at and s.status in ('active','past_due')),
    'past_due',count(*) filter(where s.status='past_due'),
    'estimated_mrr',coalesce(sum(case when now()>=s.trial_ends_at and s.status='active' then (
      select coalesce(sum(p.monthly_price),0)
      from public.subscription_feature_prices p
      left join public.organization_features f on f.organization_id=o.id and f.feature_key=p.feature_key
      where p.active and coalesce(f.enabled,true)
    ) else 0 end),0)
  ) into v_summary
  from public.organizations o
  join public.organization_subscriptions s on s.organization_id=o.id;

  return jsonb_build_object('summary',v_summary,'feature_prices',v_prices,'organizations',v_orgs);
end;
$$;

create or replace function public.set_subscription_feature_price(p_feature_key text,p_monthly_price numeric)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
  if p_monthly_price < 0 then raise exception 'Monthly price cannot be negative'; end if;
  update public.subscription_feature_prices
  set monthly_price=round(p_monthly_price,2),updated_at=now(),updated_by=auth.uid()
  where feature_key=lower(trim(p_feature_key));
  if not found then raise exception 'Subscription feature not found'; end if;
  return true;
end;
$$;

create or replace function public.set_organization_subscription(
  p_organization_id uuid,
  p_status text,
  p_trial_ends_at timestamptz default null,
  p_next_billing_at timestamptz default null,
  p_notes text default null
)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
  if p_status not in ('trialing','active','past_due','suspended','cancelled') then raise exception 'Invalid subscription status'; end if;

  update public.organization_subscriptions
  set status=p_status,
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

alter table public.subscription_feature_prices enable row level security;
alter table public.organization_subscriptions enable row level security;

create policy "platform admins read subscription feature prices"
on public.subscription_feature_prices for select to authenticated
using(public.is_platform_admin());

create policy "platform admins read organization subscriptions"
on public.organization_subscriptions for select to authenticated
using(public.is_platform_admin());

commit;
