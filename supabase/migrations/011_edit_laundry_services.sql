-- LabaFlow v0.6 Service editing

begin;

create or replace function public.update_laundry_service(
  p_service_id uuid,
  p_name text,
  p_description text,
  p_pricing_unit public.pricing_unit,
  p_default_price numeric,
  p_loyalty_points integer,
  p_active boolean
)
returns public.services
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid;
  v_service public.services%rowtype;
begin
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid() and active
  order by created_at
  limit 1;

  if v_org is null or not public.has_role_permission('manage_services') then
    raise exception 'Service management permission required';
  end if;

  if nullif(trim(p_name),'') is null then
    raise exception 'Service name is required';
  end if;

  if p_default_price < 0 then
    raise exception 'Service price cannot be negative';
  end if;

  if p_loyalty_points < 0 then
    raise exception 'Reward points cannot be negative';
  end if;

  update public.services
  set name=trim(p_name),
      description=nullif(trim(coalesce(p_description,'')),''),
      pricing_unit=p_pricing_unit,
      default_price=p_default_price,
      loyalty_points=p_loyalty_points,
      active=p_active,
      updated_at=now()
  where id=p_service_id
    and organization_id=v_org
  returning * into v_service;

  if v_service.id is null then
    raise exception 'Service not found';
  end if;

  return v_service;
end;
$$;

grant execute on function public.update_laundry_service(uuid,text,text,public.pricing_unit,numeric,integer,boolean) to authenticated;

commit;
