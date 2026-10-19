-- Multi-service organization foundation: Laundry remains the default; new tenants may choose Car Wash.
begin;

alter table public.organizations
  add column if not exists business_type text not null default 'laundry';

alter table public.organizations drop constraint if exists organizations_business_type_check;
alter table public.organizations
  add constraint organizations_business_type_check check (business_type in ('laundry','car_wash'));

alter type public.order_status add value if not exists 'queued';
alter type public.order_status add value if not exists 'detailing';
alter type public.order_status add value if not exists 'quality_check';

create table if not exists public.customer_vehicles (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  plate_number text not null,
  vehicle_type text not null default 'car',
  make text,
  model text,
  color text,
  notes text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id, plate_number)
);

alter table public.customer_vehicles enable row level security;
drop policy if exists "members manage customer vehicles" on public.customer_vehicles;
create policy "members manage customer vehicles" on public.customer_vehicles
  for all to authenticated
  using (public.is_organization_member(organization_id))
  with check (
    public.is_organization_member(organization_id)
    and exists (
      select 1 from public.customers c
      where c.id=customer_id and c.organization_id=customer_vehicles.organization_id
    )
  );

create index if not exists customer_vehicles_customer_idx
  on public.customer_vehicles(customer_id, active, created_at desc);

alter table public.laundry_orders
  add column if not exists vehicle_id uuid references public.customer_vehicles(id);

create index if not exists laundry_orders_vehicle_idx
  on public.laundry_orders(vehicle_id) where vehicle_id is not null;

create or replace function public.create_organization_with_main_branch(
  p_name text,
  p_slug text,
  p_branch_name text default 'Main Branch',
  p_branch_code text default 'MAIN',
  p_business_type text default 'laundry'
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_user uuid := auth.uid();
  v_org public.organizations;
  v_branch public.branches;
  v_business_type text := lower(trim(coalesce(p_business_type,'laundry')));
  v_workflow jsonb;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if exists(select 1 from public.organization_memberships where user_id=v_user and active) then
    raise exception 'User already belongs to an organization';
  end if;
  if nullif(trim(p_name),'') is null then raise exception 'Organization name is required'; end if;
  if p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception 'Invalid organization slug'; end if;
  if v_business_type not in ('laundry','car_wash') then raise exception 'Invalid business type'; end if;

  insert into public.organizations(name,slug,created_by,business_type)
  values(trim(p_name),p_slug,v_user,v_business_type)
  returning * into v_org;

  insert into public.organization_memberships(organization_id,user_id,role,active)
  values(v_org.id,v_user,'owner',true);

  insert into public.branches(organization_id,code,name)
  values(v_org.id,upper(trim(p_branch_code)),trim(p_branch_name))
  returning * into v_branch;

  insert into public.staff_branch_assignments(staff_id,branch_id)
  values(v_user,v_branch.id);

  insert into public.loyalty_programs(organization_id) values(v_org.id);

  v_workflow := case when v_business_type='car_wash'
    then '{"stages":["received","queued","washing","detailing","quality_check","ready","completed"]}'::jsonb
    else '{"stages":["received","sorting","washing","drying","folding","ready","completed"]}'::jsonb end;

  insert into public.organization_settings(organization_id,setting_key,setting_value)
  values
    (v_org.id,'features',jsonb_build_object('loyalty',true,'pickup_delivery',v_business_type='laundry','inventory',true,'expenses',true)),
    (v_org.id,'order_workflow',v_workflow);

  if v_business_type='car_wash' then
    insert into public.services(organization_id,name,description,pricing_unit,default_price,loyalty_points)
    values
      (v_org.id,'Basic Wash','Exterior hand wash','package',200,2),
      (v_org.id,'Wash & Vacuum','Exterior wash with interior vacuum','package',350,4),
      (v_org.id,'Full Detailing','Complete interior and exterior detailing','package',1500,10),
      (v_org.id,'Engine Wash','Engine bay cleaning','package',500,5)
    on conflict (organization_id,name) do nothing;
  end if;

  return jsonb_build_object('organization',to_jsonb(v_org),'branch',to_jsonb(v_branch));
end $$;

grant execute on function public.create_organization_with_main_branch(text,text,text,text,text) to authenticated;

-- Expose business type to lightweight access consumers without forcing a second context query.
create or replace function public.get_organization_business_type()
returns text
language sql
stable
security definer
set search_path=public
as $$
  select coalesce(o.business_type,'laundry')
  from public.organizations o
  where o.id=coalesce(
    public.active_support_organization_id(),
    (select m.organization_id from public.organization_memberships m where m.user_id=auth.uid() and m.active order by m.created_at limit 1)
  )
$$;
grant execute on function public.get_organization_business_type() to authenticated;

commit;
