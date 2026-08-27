-- LabaFlow v0.8.2 - branch-aware customer address distance and automatic delivery pricing
begin;

create table if not exists public.customer_address_branch_distances (
  address_id uuid not null references public.customer_addresses(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  distance_km numeric(8,2) not null check(distance_km >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(address_id,branch_id)
);

create index if not exists customer_address_branch_distances_org_idx
  on public.customer_address_branch_distances(organization_id,branch_id);

alter table public.customer_address_branch_distances enable row level security;

drop policy if exists "members read address distances" on public.customer_address_branch_distances;
create policy "members read address distances" on public.customer_address_branch_distances
for select to authenticated
using(public.is_organization_member(organization_id) and public.can_access_branch(branch_id));

drop policy if exists "customer roles manage address distances" on public.customer_address_branch_distances;
create policy "customer roles manage address distances" on public.customer_address_branch_distances
for all to authenticated
using(public.is_organization_member(organization_id) and public.can_access_branch(branch_id) and public.has_role_permission('manage_customers',branch_id))
with check(public.is_organization_member(organization_id) and public.can_access_branch(branch_id) and public.has_role_permission('manage_customers',branch_id));

-- Preserve the existing function for older clients, while adding a branch-aware version.
create or replace function public.create_customer_address(
  p_customer_id uuid,
  p_label text,
  p_address_line text,
  p_barangay text default null,
  p_city text default null,
  p_province text default null,
  p_postal_code text default null,
  p_landmark text default null,
  p_is_default boolean default false,
  p_branch_id uuid default null,
  p_distance_km numeric default null
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
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid() and active
  order by created_at limit 1;

  if v_org is null or not public.has_role_permission('manage_customers') then
    raise exception 'Customer management permission required';
  end if;
  if not exists(select 1 from public.customers where id=p_customer_id and organization_id=v_org and active) then
    raise exception 'Customer not found';
  end if;
  if nullif(trim(p_address_line),'') is null then raise exception 'Address is required'; end if;

  if p_branch_id is not null then
    if not exists(select 1 from public.branches where id=p_branch_id and organization_id=v_org and active and public.can_access_branch(id)) then
      raise exception 'Branch is invalid';
    end if;
    if p_distance_km is null or p_distance_km < 0 then
      raise exception 'Distance from branch is required';
    end if;
  end if;

  if p_is_default then
    update public.customer_addresses
    set is_default=false,updated_at=now()
    where organization_id=v_org and customer_id=p_customer_id;
  end if;

  insert into public.customer_addresses(organization_id,customer_id,label,address_line,barangay,city,province,postal_code,landmark,is_default)
  values(v_org,p_customer_id,coalesce(nullif(trim(p_label),''),'Home'),trim(p_address_line),nullif(trim(coalesce(p_barangay,'')),''),nullif(trim(coalesce(p_city,'')),''),nullif(trim(coalesce(p_province,'')),''),nullif(trim(coalesce(p_postal_code,'')),''),nullif(trim(coalesce(p_landmark,'')),''),p_is_default)
  returning * into v_row;

  if p_branch_id is not null then
    insert into public.customer_address_branch_distances(address_id,branch_id,organization_id,distance_km)
    values(v_row.id,p_branch_id,v_org,p_distance_km)
    on conflict(address_id,branch_id) do update
      set distance_km=excluded.distance_km,updated_at=now();
  end if;

  return v_row;
end $$;

create or replace function public.set_customer_address_distance(
  p_address_id uuid,
  p_branch_id uuid,
  p_distance_km numeric
)
returns public.customer_address_branch_distances
language plpgsql security definer set search_path=public as $$
declare
  v_org uuid;
  v_row public.customer_address_branch_distances%rowtype;
begin
  select a.organization_id into v_org
  from public.customer_addresses a
  join public.branches b on b.organization_id=a.organization_id
  where a.id=p_address_id and b.id=p_branch_id and a.active and b.active and public.can_access_branch(b.id);
  if v_org is null then raise exception 'Address or branch is invalid'; end if;
  if not public.has_role_permission('manage_customers',p_branch_id) then raise exception 'Customer management permission required'; end if;
  if p_distance_km is null or p_distance_km < 0 then raise exception 'Distance must be zero or greater'; end if;

  insert into public.customer_address_branch_distances(address_id,branch_id,organization_id,distance_km)
  values(p_address_id,p_branch_id,v_org,p_distance_km)
  on conflict(address_id,branch_id) do update set distance_km=excluded.distance_km,updated_at=now()
  returning * into v_row;
  return v_row;
end $$;

create or replace function public.get_customer_delivery_quote(
  p_customer_id uuid,
  p_branch_id uuid,
  p_addon_type public.delivery_addon_type
)
returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare
  v_org uuid;
  v_address public.customer_addresses%rowtype;
  v_distance numeric;
  v_rate public.delivery_distance_rates%rowtype;
begin
  select organization_id into v_org from public.branches where id=p_branch_id and active and public.can_access_branch(id);
  if v_org is null then raise exception 'Branch access denied'; end if;
  if not exists(select 1 from public.customers where id=p_customer_id and organization_id=v_org and active) then raise exception 'Customer is invalid'; end if;

  select * into v_address
  from public.customer_addresses
  where organization_id=v_org and customer_id=p_customer_id and active
  order by is_default desc,updated_at desc,created_at desc limit 1;
  if v_address.id is null then raise exception 'Customer has no active address'; end if;

  select distance_km into v_distance
  from public.customer_address_branch_distances
  where address_id=v_address.id and branch_id=p_branch_id;
  if v_distance is null then raise exception 'No distance is configured for this customer address and branch'; end if;

  select * into v_rate
  from public.delivery_distance_rates
  where organization_id=v_org
    and addon_type=p_addon_type
    and active
    and v_distance >= min_km
    and (max_km is null or v_distance <= max_km)
  order by min_km desc,sort_order,id
  limit 1;
  if v_rate.id is null then raise exception 'No configured delivery rate covers % km',v_distance; end if;

  return jsonb_build_object(
    'address_id',v_address.id,
    'address_label',v_address.label,
    'address_line',v_address.address_line,
    'distance_km',v_distance,
    'rate_id',v_rate.id,
    'rate_label',v_rate.label,
    'price',v_rate.price,
    'addon_type',v_rate.addon_type
  );
end $$;

grant execute on function public.create_customer_address(uuid,text,text,text,text,text,text,text,boolean,uuid,numeric) to authenticated;
grant execute on function public.set_customer_address_distance(uuid,uuid,numeric) to authenticated;
grant execute on function public.get_customer_delivery_quote(uuid,uuid,public.delivery_addon_type) to authenticated;

commit;
