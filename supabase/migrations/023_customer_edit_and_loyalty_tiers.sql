-- LabaFlow v0.23 Customer editing + loyalty tiers
-- Reuse existing customers.lifetime_points as cumulative earned points.
begin;

-- Reconcile lifetime_points from actual earn transactions without reducing any
-- already-higher historical value. Redemptions do not affect loyalty tier.
update public.customers c
set lifetime_points = greatest(
  coalesce(c.lifetime_points,0),
  coalesce((
    select sum(lt.points)
    from public.loyalty_transactions lt
    where lt.customer_id=c.id
      and lt.transaction_type='earn'
      and lt.points>0
  ),0)
);

create or replace function public.customer_loyalty_tier(p_points bigint)
returns text
language sql
immutable
as $$
  select case
    when coalesce(p_points,0) >= 10001 then 'Platinum'
    when coalesce(p_points,0) >= 1001 then 'Silver'
    else 'Bronze'
  end;
$$;

create or replace function public.update_customer_profile(
  p_customer_id uuid,
  p_full_name text,
  p_mobile text default null,
  p_email text default null,
  p_preferred_branch_id uuid default null
)
returns public.customers
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid;
  v_row public.customers%rowtype;
begin
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid() and active
  order by created_at limit 1;

  if v_org is null or not public.has_role_permission('manage_customers') then
    raise exception 'Customer management permission required';
  end if;
  if nullif(trim(coalesce(p_full_name,'')),'') is null then
    raise exception 'Customer name is required';
  end if;
  if p_preferred_branch_id is not null and not exists(
    select 1 from public.branches
    where id=p_preferred_branch_id and organization_id=v_org and active
  ) then
    raise exception 'Preferred branch is invalid';
  end if;

  update public.customers
  set full_name=trim(p_full_name),
      mobile=nullif(trim(coalesce(p_mobile,'')),''),
      email=nullif(trim(coalesce(p_email,'')),''),
      preferred_branch_id=p_preferred_branch_id,
      updated_at=now()
  where id=p_customer_id and organization_id=v_org and active
  returning * into v_row;

  if v_row.id is null then raise exception 'Customer not found'; end if;
  return v_row;
end;
$$;

create or replace function public.update_customer_address(
  p_address_id uuid,
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
  v_customer uuid;
  v_row public.customer_addresses%rowtype;
begin
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid() and active
  order by created_at limit 1;

  if v_org is null or not public.has_role_permission('manage_customers') then
    raise exception 'Customer management permission required';
  end if;

  select customer_id into v_customer
  from public.customer_addresses
  where id=p_address_id and organization_id=v_org and active;

  if v_customer is null then raise exception 'Customer address not found'; end if;
  if nullif(trim(coalesce(p_address_line,'')),'') is null then
    raise exception 'Address is required';
  end if;

  if p_is_default then
    update public.customer_addresses
    set is_default=false,updated_at=now()
    where organization_id=v_org and customer_id=v_customer and id<>p_address_id;
  end if;

  update public.customer_addresses
  set label=coalesce(nullif(trim(coalesce(p_label,'')),''),'Home'),
      address_line=trim(p_address_line),
      barangay=nullif(trim(coalesce(p_barangay,'')),''),
      city=nullif(trim(coalesce(p_city,'')),''),
      province=nullif(trim(coalesce(p_province,'')),''),
      postal_code=nullif(trim(coalesce(p_postal_code,'')),''),
      landmark=nullif(trim(coalesce(p_landmark,'')),''),
      is_default=p_is_default,
      updated_at=now()
  where id=p_address_id
  returning * into v_row;

  return v_row;
end;
$$;

grant execute on function public.customer_loyalty_tier(bigint) to authenticated;
grant execute on function public.update_customer_profile(uuid,text,text,text,uuid) to authenticated;
grant execute on function public.update_customer_address(uuid,text,text,text,text,text,text,text,boolean) to authenticated;

commit;
