-- PayMongo hosted checkout for organization subscriptions.
begin;

create table if not exists public.subscription_payment_transactions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  requested_by uuid not null references public.profiles(id),
  upgrade_request_id uuid references public.subscription_upgrade_requests(id) on delete set null,
  plan_key text not null references public.subscription_plans(plan_key),
  billing_cycle text not null check (billing_cycle in ('monthly','yearly')),
  product_inventory_addon boolean not null default false,
  amount numeric(12,2) not null check (amount > 0),
  currency text not null default 'PHP' check (currency = 'PHP'),
  provider text not null default 'paymongo' check (provider = 'paymongo'),
  provider_checkout_id text unique,
  provider_payment_id text,
  checkout_url text,
  status text not null default 'creating' check (status in ('creating','awaiting_payment','paid','expired','cancelled','failed')),
  billing_contact text,
  billing_email text,
  notes text,
  provider_payload jsonb not null default '{}'::jsonb,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists subscription_payment_transactions_org_idx
  on public.subscription_payment_transactions(organization_id,created_at desc);

alter table public.subscription_payment_transactions enable row level security;

drop policy if exists "organization admins read subscription payments" on public.subscription_payment_transactions;
create policy "organization admins read subscription payments"
on public.subscription_payment_transactions for select to authenticated
using (public.is_organization_admin(organization_id));

drop policy if exists "platform admins read subscription payments" on public.subscription_payment_transactions;
create policy "platform admins read subscription payments"
on public.subscription_payment_transactions for select to authenticated
using (public.is_platform_admin());

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

create or replace function public.attach_subscription_checkout(p_transaction_id uuid,p_provider_checkout_id text,p_checkout_url text)
returns boolean language plpgsql security definer set search_path=public as $$
begin
 update public.subscription_payment_transactions t set provider_checkout_id=p_provider_checkout_id,checkout_url=p_checkout_url,status='awaiting_payment',updated_at=now()
 where t.id=p_transaction_id and t.requested_by=auth.uid() and t.status='creating';
 if not found then raise exception 'Subscription checkout not found'; end if;
 return true;
end $$;

create or replace function public.fail_subscription_checkout(p_transaction_id uuid,p_error text)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_request uuid;
begin
 update public.subscription_payment_transactions t set status='failed',provider_payload=jsonb_build_object('error',left(coalesce(p_error,'Checkout creation failed'),1000)),updated_at=now()
 where t.id=p_transaction_id and t.requested_by=auth.uid() and t.status='creating' returning upgrade_request_id into v_request;
 if v_request is not null then update public.subscription_upgrade_requests set status='declined',review_notes='PayMongo checkout could not be created',reviewed_at=now() where id=v_request; end if;
 return found;
end $$;

grant execute on function public.attach_subscription_checkout(uuid,text,text) to authenticated;
grant execute on function public.fail_subscription_checkout(uuid,text) to authenticated;

commit;
