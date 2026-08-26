-- LabaFlow v0.1 foundation
-- Multi-tenant organizations, branches, staff, customers, QR identity, and loyalty.

begin;

create extension if not exists pgcrypto;

create type public.staff_role as enum ('owner','admin','manager','cashier','laundry_staff','delivery_staff','auditor');
create type public.loyalty_transaction_type as enum ('earn','redeem','adjustment','expire');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique check(slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.organization_memberships (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.staff_role not null default 'laundry_staff',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (organization_id,user_id)
);

create table public.organization_settings (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  setting_key text not null,
  setting_value jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (organization_id,setting_key)
);

create table public.branches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  code text not null,
  name text not null,
  address text,
  phone text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id,code)
);

create table public.staff_branch_assignments (
  staff_id uuid not null references public.profiles(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (staff_id,branch_id)
);

create sequence public.customer_number_seq start 1001;

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  customer_number bigint not null default nextval('public.customer_number_seq'),
  customer_code text generated always as ('LF-C-' || lpad(customer_number::text,8,'0')) stored,
  full_name text not null,
  mobile text,
  email text,
  preferred_branch_id uuid references public.branches(id),
  loyalty_points integer not null default 0 check(loyalty_points >= 0),
  lifetime_points integer not null default 0 check(lifetime_points >= 0),
  lifetime_visits integer not null default 0 check(lifetime_visits >= 0),
  lifetime_spend numeric(12,2) not null default 0 check(lifetime_spend >= 0),
  last_visit_at timestamptz,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id,customer_number),
  unique (organization_id,customer_code)
);

create table public.customer_qr_tokens (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  token uuid not null default gen_random_uuid() unique,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique(customer_id)
);

create table public.loyalty_programs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade unique,
  enabled boolean not null default true,
  earning_method text not null default 'per_visit' check(earning_method in ('per_visit','per_spend','per_service')),
  points_per_visit integer not null default 10 check(points_per_visit >= 0),
  spend_amount_per_point numeric(12,2),
  minimum_order_amount numeric(12,2) not null default 0,
  same_day_visit_limit integer not null default 1 check(same_day_visit_limit >= 0),
  points_expiry_months integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.loyalty_transactions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  branch_id uuid references public.branches(id),
  transaction_type public.loyalty_transaction_type not null,
  points integer not null,
  description text,
  reference_type text,
  reference_id uuid,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create index memberships_user_idx on public.organization_memberships(user_id,active);
create index branches_org_idx on public.branches(organization_id,active,name);
create index customers_org_name_idx on public.customers(organization_id,active,full_name);
create index customers_org_mobile_idx on public.customers(organization_id,mobile);
create index loyalty_customer_created_idx on public.loyalty_transactions(customer_id,created_at desc);

create or replace function public.is_organization_member(p_organization_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from organization_memberships where organization_id=p_organization_id and user_id=auth.uid() and active);
$$;

create or replace function public.is_organization_admin(p_organization_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from organization_memberships where organization_id=p_organization_id and user_id=auth.uid() and active and role in ('owner','admin'));
$$;

create or replace function public.can_access_branch(p_branch_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1 from branches b join organization_memberships m on m.organization_id=b.organization_id
    where b.id=p_branch_id and b.active and m.user_id=auth.uid() and m.active
      and (m.role in ('owner','admin') or exists(select 1 from staff_branch_assignments a where a.staff_id=auth.uid() and a.branch_id=b.id))
  );
$$;

alter table public.profiles enable row level security;
alter table public.organizations enable row level security;
alter table public.organization_memberships enable row level security;
alter table public.organization_settings enable row level security;
alter table public.branches enable row level security;
alter table public.staff_branch_assignments enable row level security;
alter table public.customers enable row level security;
alter table public.customer_qr_tokens enable row level security;
alter table public.loyalty_programs enable row level security;
alter table public.loyalty_transactions enable row level security;

create policy "read own profile" on public.profiles for select to authenticated using(id=auth.uid());
create policy "members read organizations" on public.organizations for select to authenticated using(public.is_organization_member(id));
create policy "members read memberships" on public.organization_memberships for select to authenticated using(user_id=auth.uid() or public.is_organization_admin(organization_id));
create policy "admins manage memberships" on public.organization_memberships for all to authenticated using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));
create policy "members read settings" on public.organization_settings for select to authenticated using(public.is_organization_member(organization_id));
create policy "admins manage settings" on public.organization_settings for all to authenticated using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));
create policy "members read branches" on public.branches for select to authenticated using(public.can_access_branch(id));
create policy "admins manage branches" on public.branches for all to authenticated using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));
create policy "staff read assignments" on public.staff_branch_assignments for select to authenticated using(staff_id=auth.uid() or public.can_access_branch(branch_id));
create policy "members manage customers" on public.customers for all to authenticated using(public.is_organization_member(organization_id)) with check(public.is_organization_member(organization_id));
create policy "members manage qr tokens" on public.customer_qr_tokens for all to authenticated using(public.is_organization_member(organization_id)) with check(public.is_organization_member(organization_id));
create policy "members read loyalty program" on public.loyalty_programs for select to authenticated using(public.is_organization_member(organization_id));
create policy "admins manage loyalty program" on public.loyalty_programs for all to authenticated using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));
create policy "members manage loyalty transactions" on public.loyalty_transactions for all to authenticated using(public.is_organization_member(organization_id)) with check(public.is_organization_member(organization_id));

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into profiles(id,email,full_name) values(new.id,coalesce(new.email,''),new.raw_user_meta_data->>'full_name') on conflict(id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

commit;
