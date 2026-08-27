-- LabaFlow v0.7.1 - separate distance pricing by order add-on type
begin;

alter table public.delivery_distance_rates
  add column if not exists addon_type public.delivery_addon_type;

-- Preserve any existing generic rates by treating them as Pickup + Delivery first.
update public.delivery_distance_rates
set addon_type='pickup_delivery'
where addon_type is null;

alter table public.delivery_distance_rates
  alter column addon_type set not null;

-- Existing unique(org,label) is too restrictive once each add-on has its own rates.
alter table public.delivery_distance_rates
  drop constraint if exists delivery_distance_rates_organization_id_label_key;

create unique index if not exists delivery_distance_rates_org_type_label_uidx
on public.delivery_distance_rates(organization_id,addon_type,label);

-- Copy existing Pickup + Delivery rates to Pickup and Delivery if those types do not yet exist.
insert into public.delivery_distance_rates(organization_id,addon_type,label,min_km,max_km,price,active,sort_order)
select r.organization_id,'pickup'::public.delivery_addon_type,r.label,r.min_km,r.max_km,r.price,r.active,r.sort_order
from public.delivery_distance_rates r
where r.addon_type='pickup_delivery'
  and not exists (
    select 1 from public.delivery_distance_rates x
    where x.organization_id=r.organization_id and x.addon_type='pickup' and x.label=r.label
  );

insert into public.delivery_distance_rates(organization_id,addon_type,label,min_km,max_km,price,active,sort_order)
select r.organization_id,'delivery'::public.delivery_addon_type,r.label,r.min_km,r.max_km,r.price,r.active,r.sort_order
from public.delivery_distance_rates r
where r.addon_type='pickup_delivery'
  and not exists (
    select 1 from public.delivery_distance_rates x
    where x.organization_id=r.organization_id and x.addon_type='delivery' and x.label=r.label
  );

create or replace function public.get_delivery_distance_rates(p_addon_type public.delivery_addon_type default null)
returns setof public.delivery_distance_rates
language sql
security definer
set search_path=public
as $$
  select r.*
  from public.delivery_distance_rates r
  where public.is_organization_member(r.organization_id)
    and r.active
    and (p_addon_type is null or r.addon_type=p_addon_type)
  order by r.addon_type,r.sort_order,r.min_km,r.price;
$$;

create or replace function public.upsert_delivery_distance_rate(
  p_id uuid,
  p_addon_type public.delivery_addon_type,
  p_label text,
  p_min_km numeric,
  p_max_km numeric,
  p_price numeric,
  p_active boolean default true,
  p_sort_order integer default 0
)
returns public.delivery_distance_rates
language plpgsql
security definer
set search_path=public
as $$
declare v_org uuid;v_row public.delivery_distance_rates%rowtype;
begin
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid() and active and role in ('owner','admin')
  order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;
  if p_addon_type is null then raise exception 'Add-on type is required'; end if;
  if trim(coalesce(p_label,''))='' then raise exception 'Distance label is required'; end if;
  if coalesce(p_min_km,0)<0 or (p_max_km is not null and p_max_km<p_min_km) then raise exception 'Invalid distance range'; end if;
  if coalesce(p_price,0)<0 then raise exception 'Price cannot be negative'; end if;

  if p_id is null then
    insert into public.delivery_distance_rates(organization_id,addon_type,label,min_km,max_km,price,active,sort_order)
    values(v_org,p_addon_type,trim(p_label),coalesce(p_min_km,0),p_max_km,coalesce(p_price,0),coalesce(p_active,true),coalesce(p_sort_order,0))
    returning * into v_row;
  else
    update public.delivery_distance_rates
    set addon_type=p_addon_type,
        label=trim(p_label),
        min_km=coalesce(p_min_km,0),
        max_km=p_max_km,
        price=coalesce(p_price,0),
        active=coalesce(p_active,true),
        sort_order=coalesce(p_sort_order,0),
        updated_at=now()
    where id=p_id and organization_id=v_org
    returning * into v_row;
    if v_row.id is null then raise exception 'Distance rate not found'; end if;
  end if;
  return v_row;
end $$;

-- Validate that the selected rate belongs to the chosen add-on type.
create or replace function public.create_laundry_order(
  p_branch_id uuid,
  p_customer_id uuid,
  p_items jsonb,
  p_discount numeric default 0,
  p_notes text default null,
  p_due_at timestamptz default null,
  p_delivery_addon_type public.delivery_addon_type default null,
  p_delivery_distance_rate_id uuid default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_org uuid;v_order public.laundry_orders%rowtype;v_item jsonb;v_service public.services%rowtype;
  v_qty numeric;v_price numeric;v_subtotal numeric:=0;v_fee numeric:=0;v_rate public.delivery_distance_rates%rowtype;
begin
  select organization_id into v_org from branches where id=p_branch_id and public.can_access_branch(id);
  if v_org is null then raise exception 'Branch access denied'; end if;
  if not public.has_role_permission('create_orders',p_branch_id) then raise exception 'Order creation permission required'; end if;
  if p_customer_id is not null and not exists(select 1 from customers where id=p_customer_id and organization_id=v_org and active) then raise exception 'Customer is invalid'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'Add at least one service'; end if;

  if p_delivery_addon_type is not null then
    if p_customer_id is null then raise exception 'Pickup/Delivery requires a registered customer'; end if;
    if p_delivery_distance_rate_id is null then raise exception 'Select a delivery distance'; end if;
    select * into v_rate
    from public.delivery_distance_rates
    where id=p_delivery_distance_rate_id
      and organization_id=v_org
      and addon_type=p_delivery_addon_type
      and active;
    if v_rate.id is null then raise exception 'Distance rate does not match the selected add-on type'; end if;
    v_fee:=v_rate.price;
  end if;

  insert into laundry_orders(organization_id,branch_id,customer_id,discount,notes,due_at,created_by,delivery_addon_type,delivery_distance_rate_id,delivery_distance_label,delivery_fee)
  values(v_org,p_branch_id,p_customer_id,greatest(coalesce(p_discount,0),0),p_notes,p_due_at,auth.uid(),p_delivery_addon_type,v_rate.id,v_rate.label,v_fee)
  returning * into v_order;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_service from services where id=(v_item->>'service_id')::uuid and organization_id=v_org and active;
    if v_service.id is null then raise exception 'Service is invalid'; end if;
    v_qty:=greatest((v_item->>'quantity')::numeric,0);
    if v_qty<=0 then raise exception 'Quantity must be greater than zero'; end if;
    select coalesce((select price from branch_service_prices where branch_id=p_branch_id and service_id=v_service.id and active),v_service.default_price) into v_price;
    insert into laundry_order_items(order_id,service_id,quantity,unit_price,notes)
    values(v_order.id,v_service.id,v_qty,v_price,v_item->>'notes');
    v_subtotal:=v_subtotal+(v_qty*v_price);
  end loop;

  update laundry_orders
  set subtotal=v_subtotal,
      total=greatest(v_subtotal+v_fee-greatest(coalesce(p_discount,0),0),0),
      updated_at=now()
  where id=v_order.id returning * into v_order;

  insert into order_status_history(order_id,status,changed_by,notes)
  values(v_order.id,'received',auth.uid(),'Order created');
  return to_jsonb(v_order);
end $$;

grant execute on function public.get_delivery_distance_rates(public.delivery_addon_type) to authenticated;
grant execute on function public.upsert_delivery_distance_rate(uuid,public.delivery_addon_type,text,numeric,numeric,numeric,boolean,integer) to authenticated;

commit;
