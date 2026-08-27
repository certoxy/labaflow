-- LabaFlow v0.6 Pickup & Delivery v1
-- Customer addresses, pickup/delivery jobs, driver assignment, scheduling, fees, and tenant-safe RBAC.

begin;

create type public.delivery_job_type as enum ('pickup','delivery');
create type public.delivery_job_status as enum ('scheduled','assigned','en_route','arrived','picked_up','out_for_delivery','delivered','cancelled');

create table public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  label text not null default 'Home',
  address_line text not null,
  barangay text,
  city text,
  province text,
  postal_code text,
  landmark text,
  latitude numeric(10,7),
  longitude numeric(10,7),
  is_default boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.delivery_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null references public.branches(id),
  customer_id uuid not null references public.customers(id),
  order_id uuid references public.laundry_orders(id) on delete set null,
  address_id uuid not null references public.customer_addresses(id),
  job_type public.delivery_job_type not null,
  status public.delivery_job_status not null default 'scheduled',
  scheduled_at timestamptz not null,
  delivery_fee numeric(12,2) not null default 0 check(delivery_fee >= 0),
  assigned_to uuid references public.profiles(id),
  contact_name text,
  contact_mobile text,
  notes text,
  completed_at timestamptz,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index customer_addresses_org_customer_idx on public.customer_addresses(organization_id,customer_id,active);
create index delivery_jobs_branch_status_idx on public.delivery_jobs(branch_id,status,scheduled_at);
create index delivery_jobs_assignee_idx on public.delivery_jobs(assigned_to,status,scheduled_at);

alter table public.customer_addresses enable row level security;
alter table public.delivery_jobs enable row level security;

create policy "members read customer addresses" on public.customer_addresses for select to authenticated
using(public.is_organization_member(organization_id));

create policy "customer roles manage addresses" on public.customer_addresses for all to authenticated
using(public.is_organization_member(organization_id) and public.has_role_permission('manage_customers'))
with check(public.is_organization_member(organization_id) and public.has_role_permission('manage_customers'));

create policy "delivery staff read jobs" on public.delivery_jobs for select to authenticated
using(
  public.is_organization_member(organization_id)
  and public.can_access_branch(branch_id)
  and (
    public.has_role_permission('delivery_access',branch_id)
    or public.has_role_permission('create_orders',branch_id)
    or public.has_role_permission('view_reports',branch_id)
  )
);

create policy "delivery managers create jobs" on public.delivery_jobs for insert to authenticated
with check(
  public.is_organization_member(organization_id)
  and public.can_access_branch(branch_id)
  and (public.has_role_permission('create_orders',branch_id) or public.has_role_permission('delivery_access',branch_id))
);

create policy "delivery staff update jobs" on public.delivery_jobs for update to authenticated
using(
  public.is_organization_member(organization_id)
  and public.can_access_branch(branch_id)
  and public.has_role_permission('delivery_access',branch_id)
)
with check(
  public.is_organization_member(organization_id)
  and public.can_access_branch(branch_id)
  and public.has_role_permission('delivery_access',branch_id)
);

create or replace function public.create_customer_address(
  p_customer_id uuid,
  p_label text,
  p_address_line text,
  p_barangay text default null,
  p_city text default null,
  p_province text default null,
  p_postal_code text default null,
  p_landmark text default null,
  p_is_default boolean default false
)
returns public.customer_addresses
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid;
  v_row public.customer_addresses%rowtype;
begin
  select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
  if v_org is null or not public.has_role_permission('manage_customers') then raise exception 'Customer management permission required'; end if;
  if not exists(select 1 from public.customers where id=p_customer_id and organization_id=v_org and active) then raise exception 'Customer not found'; end if;
  if nullif(trim(p_address_line),'') is null then raise exception 'Address is required'; end if;
  if p_is_default then update public.customer_addresses set is_default=false,updated_at=now() where organization_id=v_org and customer_id=p_customer_id; end if;
  insert into public.customer_addresses(organization_id,customer_id,label,address_line,barangay,city,province,postal_code,landmark,is_default)
  values(v_org,p_customer_id,coalesce(nullif(trim(p_label),''),'Home'),trim(p_address_line),nullif(trim(coalesce(p_barangay,'')),''),nullif(trim(coalesce(p_city,'')),''),nullif(trim(coalesce(p_province,'')),''),nullif(trim(coalesce(p_postal_code,'')),''),nullif(trim(coalesce(p_landmark,'')),''),p_is_default)
  returning * into v_row;
  return v_row;
end $$;

create or replace function public.create_delivery_job(
  p_branch_id uuid,
  p_customer_id uuid,
  p_order_id uuid,
  p_address_id uuid,
  p_job_type public.delivery_job_type,
  p_scheduled_at timestamptz,
  p_delivery_fee numeric default 0,
  p_assigned_to uuid default null,
  p_contact_name text default null,
  p_contact_mobile text default null,
  p_notes text default null
)
returns public.delivery_jobs
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid;
  v_job public.delivery_jobs%rowtype;
  v_role public.staff_role;
begin
  select organization_id into v_org from public.branches where id=p_branch_id and public.can_access_branch(id);
  if v_org is null then raise exception 'Branch access denied'; end if;
  if not (public.has_role_permission('create_orders',p_branch_id) or public.has_role_permission('delivery_access',p_branch_id)) then raise exception 'Pickup and delivery access required'; end if;
  if not exists(select 1 from public.customers where id=p_customer_id and organization_id=v_org and active) then raise exception 'Customer is invalid'; end if;
  if not exists(select 1 from public.customer_addresses where id=p_address_id and organization_id=v_org and customer_id=p_customer_id and active) then raise exception 'Address is invalid'; end if;
  if p_order_id is not null and not exists(select 1 from public.laundry_orders where id=p_order_id and organization_id=v_org and customer_id=p_customer_id) then raise exception 'Order is invalid'; end if;
  if p_assigned_to is not null then
    select role into v_role from public.organization_memberships where organization_id=v_org and user_id=p_assigned_to and active;
    if v_role is null or v_role not in ('owner','admin','manager','delivery_staff') then raise exception 'Assigned driver is invalid'; end if;
    if v_role not in ('owner','admin') and not exists(select 1 from public.staff_branch_assignments where staff_id=p_assigned_to and branch_id=p_branch_id) then raise exception 'Assigned driver is not assigned to this branch'; end if;
  end if;
  insert into public.delivery_jobs(organization_id,branch_id,customer_id,order_id,address_id,job_type,status,scheduled_at,delivery_fee,assigned_to,contact_name,contact_mobile,notes,created_by)
  values(v_org,p_branch_id,p_customer_id,p_order_id,p_address_id,p_job_type,case when p_assigned_to is null then 'scheduled'::public.delivery_job_status else 'assigned'::public.delivery_job_status end,p_scheduled_at,greatest(coalesce(p_delivery_fee,0),0),p_assigned_to,p_contact_name,p_contact_mobile,p_notes,auth.uid())
  returning * into v_job;
  return v_job;
end $$;

create or replace function public.assign_delivery_job(p_job_id uuid,p_assigned_to uuid)
returns public.delivery_jobs
language plpgsql security definer set search_path=public as $$
declare v_job public.delivery_jobs%rowtype;v_role public.staff_role;
begin
  select * into v_job from public.delivery_jobs where id=p_job_id and public.can_access_branch(branch_id) for update;
  if v_job.id is null then raise exception 'Delivery job not found'; end if;
  if not public.has_role_permission('delivery_access',v_job.branch_id) then raise exception 'Delivery management permission required'; end if;
  select role into v_role from public.organization_memberships where organization_id=v_job.organization_id and user_id=p_assigned_to and active;
  if v_role is null or v_role not in ('owner','admin','manager','delivery_staff') then raise exception 'Assigned driver is invalid'; end if;
  if v_role not in ('owner','admin') and not exists(select 1 from public.staff_branch_assignments where staff_id=p_assigned_to and branch_id=v_job.branch_id) then raise exception 'Assigned driver is not assigned to this branch'; end if;
  update public.delivery_jobs set assigned_to=p_assigned_to,status=case when status='scheduled' then 'assigned'::public.delivery_job_status else status end,updated_at=now() where id=p_job_id returning * into v_job;
  return v_job;
end $$;

create or replace function public.update_delivery_job_status(p_job_id uuid,p_status public.delivery_job_status,p_notes text default null)
returns public.delivery_jobs
language plpgsql security definer set search_path=public as $$
declare v_job public.delivery_jobs%rowtype;v_role public.staff_role;
begin
  select * into v_job from public.delivery_jobs where id=p_job_id and public.can_access_branch(branch_id) for update;
  if v_job.id is null then raise exception 'Delivery job not found'; end if;
  if not public.has_role_permission('delivery_access',v_job.branch_id) then raise exception 'Delivery access required'; end if;
  select role into v_role from public.organization_memberships where organization_id=v_job.organization_id and user_id=auth.uid() and active;
  if v_role='delivery_staff' and v_job.assigned_to is distinct from auth.uid() then raise exception 'This job is assigned to another driver'; end if;
  update public.delivery_jobs set status=p_status,notes=coalesce(nullif(trim(coalesce(p_notes,'')),''),notes),completed_at=case when p_status in ('delivered','picked_up') then now() else completed_at end,updated_at=now() where id=p_job_id returning * into v_job;
  if v_job.order_id is not null and p_status='out_for_delivery' then
    update public.laundry_orders set status='out_for_delivery',updated_at=now() where id=v_job.order_id and organization_id=v_job.organization_id;
  elsif v_job.order_id is not null and p_status='delivered' then
    update public.laundry_orders set status='completed',completed_at=coalesce(completed_at,now()),updated_at=now() where id=v_job.order_id and organization_id=v_job.organization_id;
  end if;
  return v_job;
end $$;

create or replace function public.get_delivery_staff(p_branch_id uuid)
returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('user_id',m.user_id,'name',coalesce(p.full_name,p.email),'email',p.email,'role',m.role) order by coalesce(p.full_name,p.email)),'[]'::jsonb)
  from public.organization_memberships m
  join public.profiles p on p.id=m.user_id
  join public.branches b on b.organization_id=m.organization_id
  where b.id=p_branch_id and public.can_access_branch(b.id) and m.active and m.role in ('owner','admin','manager','delivery_staff')
    and (m.role in ('owner','admin') or exists(select 1 from public.staff_branch_assignments a where a.staff_id=m.user_id and a.branch_id=b.id));
$$;

grant execute on function public.create_customer_address(uuid,text,text,text,text,text,text,text,boolean) to authenticated;
grant execute on function public.create_delivery_job(uuid,uuid,uuid,uuid,public.delivery_job_type,timestamptz,numeric,uuid,text,text,text) to authenticated;
grant execute on function public.assign_delivery_job(uuid,uuid) to authenticated;
grant execute on function public.update_delivery_job_status(uuid,public.delivery_job_status,text) to authenticated;
grant execute on function public.get_delivery_staff(uuid) to authenticated;

commit;
