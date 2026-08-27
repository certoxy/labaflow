-- LabaFlow v0.7 delivery distance pricing + order add-ons
begin;

create type public.delivery_addon_type as enum ('pickup','delivery','pickup_delivery');

create table public.delivery_distance_rates (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  label text not null,
  min_km numeric(8,2) not null default 0 check(min_km >= 0),
  max_km numeric(8,2) check(max_km is null or max_km >= min_km),
  price numeric(12,2) not null default 0 check(price >= 0),
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,label)
);

alter table public.delivery_distance_rates enable row level security;
create policy "members read delivery rates" on public.delivery_distance_rates for select to authenticated using(public.is_organization_member(organization_id));
create policy "admins manage delivery rates" on public.delivery_distance_rates for all to authenticated using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));

alter table public.laundry_orders
  add column if not exists delivery_addon_type public.delivery_addon_type,
  add column if not exists delivery_distance_rate_id uuid references public.delivery_distance_rates(id),
  add column if not exists delivery_distance_label text,
  add column if not exists delivery_fee numeric(12,2) not null default 0 check(delivery_fee >= 0);

create or replace function public.get_delivery_distance_rates()
returns setof public.delivery_distance_rates
language sql
security definer
set search_path=public
as $$
  select r.* from public.delivery_distance_rates r
  where public.is_organization_member(r.organization_id) and r.active
  order by r.sort_order,r.min_km,r.price;
$$;

create or replace function public.upsert_delivery_distance_rate(
  p_id uuid,
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
  select organization_id into v_org from public.organization_memberships
  where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;
  if trim(coalesce(p_label,''))='' then raise exception 'Distance label is required'; end if;
  if coalesce(p_min_km,0)<0 or (p_max_km is not null and p_max_km<p_min_km) then raise exception 'Invalid distance range'; end if;
  if coalesce(p_price,0)<0 then raise exception 'Price cannot be negative'; end if;

  if p_id is null then
    insert into public.delivery_distance_rates(organization_id,label,min_km,max_km,price,active,sort_order)
    values(v_org,trim(p_label),coalesce(p_min_km,0),p_max_km,coalesce(p_price,0),coalesce(p_active,true),coalesce(p_sort_order,0)) returning * into v_row;
  else
    update public.delivery_distance_rates set label=trim(p_label),min_km=coalesce(p_min_km,0),max_km=p_max_km,price=coalesce(p_price,0),active=coalesce(p_active,true),sort_order=coalesce(p_sort_order,0),updated_at=now()
    where id=p_id and organization_id=v_org returning * into v_row;
    if v_row.id is null then raise exception 'Distance rate not found'; end if;
  end if;
  return v_row;
end $$;

-- Replace current order creation with optional Pickup/Delivery add-on.
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
    select * into v_rate from public.delivery_distance_rates where id=p_delivery_distance_rate_id and organization_id=v_org and active;
    if v_rate.id is null then raise exception 'Delivery distance rate is invalid'; end if;
    v_fee:=v_rate.price;
  end if;

  insert into laundry_orders(organization_id,branch_id,customer_id,discount,notes,due_at,created_by,delivery_addon_type,delivery_distance_rate_id,delivery_distance_label,delivery_fee)
  values(v_org,p_branch_id,p_customer_id,greatest(coalesce(p_discount,0),0),p_notes,p_due_at,auth.uid(),p_delivery_addon_type,v_rate.id,v_rate.label,v_fee) returning * into v_order;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_service from services where id=(v_item->>'service_id')::uuid and organization_id=v_org and active;
    if v_service.id is null then raise exception 'Service is invalid'; end if;
    v_qty:=greatest((v_item->>'quantity')::numeric,0);
    if v_qty<=0 then raise exception 'Quantity must be greater than zero'; end if;
    select coalesce((select price from branch_service_prices where branch_id=p_branch_id and service_id=v_service.id and active),v_service.default_price) into v_price;
    insert into laundry_order_items(order_id,service_id,quantity,unit_price,notes) values(v_order.id,v_service.id,v_qty,v_price,v_item->>'notes');
    v_subtotal:=v_subtotal+(v_qty*v_price);
  end loop;

  update laundry_orders set subtotal=v_subtotal,total=greatest(v_subtotal+v_fee-greatest(coalesce(p_discount,0),0),0),updated_at=now()
  where id=v_order.id returning * into v_order;
  insert into order_status_history(order_id,status,changed_by,notes) values(v_order.id,'received',auth.uid(),'Order created');
  return to_jsonb(v_order);
end $$;

grant execute on function public.get_delivery_distance_rates() to authenticated;
grant execute on function public.upsert_delivery_distance_rate(uuid,text,numeric,numeric,numeric,boolean,integer) to authenticated;
grant execute on function public.create_laundry_order(uuid,uuid,jsonb,numeric,text,timestamptz,public.delivery_addon_type,uuid) to authenticated;

commit;
