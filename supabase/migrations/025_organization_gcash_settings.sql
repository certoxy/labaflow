-- LabaFlow: organization-owned GCash configuration
-- Phase 1 supports each tenant's own manual GCash / QRPH merchant QR.
-- Uses organization_memberships directly, consistent with existing LabaFlow migrations.

create table if not exists public.organization_payment_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  payment_method text not null,
  integration_type text not null default 'manual_qr',
  merchant_name text,
  account_number text,
  qr_image_url text,
  instructions text,
  auto_confirm boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, payment_method),
  constraint organization_payment_accounts_method_check check (payment_method in ('gcash')),
  constraint organization_payment_accounts_integration_check check (integration_type in ('manual_qr','gateway'))
);

alter table public.organization_payment_accounts enable row level security;

-- Policies use the same membership model as the rest of LabaFlow.
drop policy if exists "organization members can read payment accounts" on public.organization_payment_accounts;
create policy "organization members can read payment accounts"
on public.organization_payment_accounts for select
to authenticated
using (
  exists (
    select 1 from public.organization_memberships m
    where m.organization_id=organization_payment_accounts.organization_id
      and m.user_id=auth.uid()
      and m.active
  )
);

drop policy if exists "organization admins can manage payment accounts" on public.organization_payment_accounts;
create policy "organization admins can manage payment accounts"
on public.organization_payment_accounts for all
to authenticated
using (
  exists (
    select 1 from public.organization_memberships m
    where m.organization_id=organization_payment_accounts.organization_id
      and m.user_id=auth.uid()
      and m.active
      and m.role in ('owner','admin')
  )
)
with check (
  exists (
    select 1 from public.organization_memberships m
    where m.organization_id=organization_payment_accounts.organization_id
      and m.user_id=auth.uid()
      and m.active
      and m.role in ('owner','admin')
  )
);

create or replace function public.get_organization_payment_account(p_payment_method text)
returns public.organization_payment_accounts
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid;
  v_row public.organization_payment_accounts;
begin
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid() and active
  order by created_at limit 1;

  if v_org is null then
    return null;
  end if;

  select * into v_row
  from public.organization_payment_accounts
  where organization_id=v_org
    and payment_method=lower(p_payment_method)
    and active=true
  limit 1;

  return v_row;
end;
$$;

create or replace function public.save_organization_gcash_settings(
  p_integration_type text,
  p_merchant_name text,
  p_account_number text,
  p_qr_image_url text,
  p_instructions text,
  p_active boolean default true
)
returns public.organization_payment_accounts
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid;
  v_row public.organization_payment_accounts;
begin
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid()
    and active
    and role in ('owner','admin')
  order by created_at limit 1;

  if v_org is null then
    raise exception 'Organization administrator access required';
  end if;

  if p_integration_type not in ('manual_qr','gateway') then
    raise exception 'Invalid GCash integration type';
  end if;

  insert into public.organization_payment_accounts(
    organization_id,payment_method,integration_type,merchant_name,account_number,
    qr_image_url,instructions,auto_confirm,active,updated_at
  ) values (
    v_org,'gcash',p_integration_type,nullif(trim(p_merchant_name),''),nullif(trim(p_account_number),''),
    nullif(trim(p_qr_image_url),''),nullif(trim(p_instructions),''),false,p_active,now()
  )
  on conflict (organization_id,payment_method) do update set
    integration_type=excluded.integration_type,
    merchant_name=excluded.merchant_name,
    account_number=excluded.account_number,
    qr_image_url=excluded.qr_image_url,
    instructions=excluded.instructions,
    auto_confirm=false,
    active=excluded.active,
    updated_at=now()
  returning * into v_row;

  return v_row;
end;
$$;

grant select on public.organization_payment_accounts to authenticated;
grant execute on function public.get_organization_payment_account(text) to authenticated;
grant execute on function public.save_organization_gcash_settings(text,text,text,text,text,boolean) to authenticated;
