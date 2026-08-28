-- LabaFlow: automatic payment gateway foundation
-- Stores tenant gateway mode/account reference only. Secret API keys belong in
-- Supabase Edge Function secrets and must never be stored in browser-readable tables.

create table if not exists public.payment_gateway_transactions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  order_id uuid not null references public.laundry_orders(id) on delete cascade,
  provider text not null default 'paymongo',
  provider_payment_intent_id text,
  provider_payment_id text,
  payment_method text not null default 'qrph',
  amount numeric(12,2) not null check (amount > 0),
  currency text not null default 'PHP',
  status text not null default 'pending',
  qr_image_data text,
  expires_at timestamptz,
  provider_event_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payment_gateway_provider_check check (provider in ('paymongo')),
  constraint payment_gateway_status_check check (status in ('pending','awaiting_payment','paid','failed','expired','cancelled')),
  unique(provider,provider_payment_intent_id),
  unique(provider,provider_event_id)
);

create index if not exists payment_gateway_transactions_order_idx on public.payment_gateway_transactions(order_id,created_at desc);
create index if not exists payment_gateway_transactions_org_idx on public.payment_gateway_transactions(organization_id,status);

alter table public.payment_gateway_transactions enable row level security;

drop policy if exists "organization members can read gateway transactions" on public.payment_gateway_transactions;
create policy "organization members can read gateway transactions"
on public.payment_gateway_transactions for select to authenticated
using (exists (
  select 1 from public.organization_memberships m
  where m.organization_id=payment_gateway_transactions.organization_id
    and m.user_id=auth.uid() and m.active
));

-- Add non-secret gateway configuration to organization payment accounts.
alter table public.organization_payment_accounts add column if not exists gateway_provider text;
alter table public.organization_payment_accounts add column if not exists gateway_account_reference text;

create or replace function public.get_order_gateway_transaction(p_order_id uuid)
returns public.payment_gateway_transactions
language plpgsql security definer set search_path=public
as $$
declare v_org uuid; v_row public.payment_gateway_transactions;
begin
  select organization_id into v_org from public.organization_memberships
  where user_id=auth.uid() and active order by created_at limit 1;
  if v_org is null then raise exception 'Organization membership required'; end if;
  select * into v_row from public.payment_gateway_transactions
  where order_id=p_order_id and organization_id=v_org
  order by created_at desc limit 1;
  return v_row;
end;
$$;

grant select on public.payment_gateway_transactions to authenticated;
grant execute on function public.get_order_gateway_transaction(uuid) to authenticated;
