-- Per-service Car Wash pricing by vehicle type.
begin;

create table if not exists public.service_vehicle_prices (
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references public.organizations(id) on delete cascade,
 service_id uuid not null references public.services(id) on delete cascade,
 vehicle_type text not null check (vehicle_type in ('car','suv','van','pickup','motorcycle','other')),
 price numeric(12,2) not null check (price >= 0),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 unique(service_id,vehicle_type)
);
create index if not exists service_vehicle_prices_org_idx on public.service_vehicle_prices(organization_id);
alter table public.service_vehicle_prices enable row level security;

do $$ begin
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='service_vehicle_prices' and policyname='service_vehicle_prices_select') then
  create policy service_vehicle_prices_select on public.service_vehicle_prices for select to authenticated
  using (exists(select 1 from public.organization_memberships m where m.organization_id=service_vehicle_prices.organization_id and m.user_id=auth.uid() and m.active));
 end if;
 if not exists(select 1 from pg_policies where schemaname='public' and tablename='service_vehicle_prices' and policyname='service_vehicle_prices_manage') then
  create policy service_vehicle_prices_manage on public.service_vehicle_prices for all to authenticated
  using (public.has_role_permission('manage_services'))
  with check (public.has_role_permission('manage_services'));
 end if;
end $$;

insert into public.service_vehicle_prices(organization_id,service_id,vehicle_type,price)
select s.organization_id,s.id,v.vehicle_type,
 case s.name
  when 'Basic Wash' then case v.vehicle_type when 'car' then 200 when 'suv' then 250 when 'van' then 300 when 'pickup' then 300 when 'motorcycle' then 120 else s.default_price end
  when 'Wash & Vacuum' then case v.vehicle_type when 'car' then 350 when 'suv' then 450 when 'van' then 550 when 'pickup' then 550 when 'motorcycle' then 180 else s.default_price end
  when 'Full Detailing' then case v.vehicle_type when 'car' then 1500 when 'suv' then 2000 when 'van' then 2500 when 'pickup' then 2500 when 'motorcycle' then 800 else s.default_price end
  when 'Engine Wash' then case v.vehicle_type when 'car' then 500 when 'suv' then 650 when 'van' then 800 when 'pickup' then 800 when 'motorcycle' then 300 else s.default_price end
  else s.default_price
 end
from public.services s
join public.organizations o on o.id=s.organization_id and o.business_type='car_wash'
cross join (values('car'),('suv'),('van'),('pickup'),('motorcycle'),('other')) v(vehicle_type)
on conflict(service_id,vehicle_type) do nothing;

create or replace function public.get_service_vehicle_prices()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_org uuid;
begin
 select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
 if v_org is null then raise exception 'Organization access required'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('service_id',p.service_id,'vehicle_type',p.vehicle_type,'price',p.price) order by p.service_id,p.vehicle_type) from public.service_vehicle_prices p where p.organization_id=v_org),'[]'::jsonb);
end $$;

create or replace function public.save_service_vehicle_prices(p_service_id uuid,p_prices jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_type text;v_price numeric;
begin
 select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
 if v_org is null or not public.has_role_permission('manage_services') then raise exception 'Service management permission required'; end if;
 if (select business_type from public.organizations where id=v_org)<>'car_wash' then raise exception 'Vehicle pricing is only available for Car Wash organizations'; end if;
 if not exists(select 1 from public.services where id=p_service_id and organization_id=v_org) then raise exception 'Service not found'; end if;
 foreach v_type in array array['car','suv','van','pickup','motorcycle','other'] loop
  if not (p_prices ? v_type) then raise exception 'Missing price for vehicle type %',v_type; end if;
  v_price:=(p_prices->>v_type)::numeric;
  if v_price<0 then raise exception 'Price cannot be negative'; end if;
  insert into public.service_vehicle_prices(organization_id,service_id,vehicle_type,price)
  values(v_org,p_service_id,v_type,v_price)
  on conflict(service_id,vehicle_type) do update set price=excluded.price,organization_id=excluded.organization_id,updated_at=now();
 end loop;
 return jsonb_build_object('saved',true);
end $$;

create or replace function public.create_car_wash_order(
 p_branch_id uuid,p_customer_id uuid,p_items jsonb,p_vehicle_id uuid default null,p_plate_number text default null,p_vehicle_type text default 'car',p_make text default null,p_model text default null,p_color text default null,p_discount numeric default 0,p_notes text default null,p_due_at timestamptz default null,p_delivery_addon_type public.delivery_addon_type default null,p_delivery_distance_rate_id uuid default null,p_loyalty_points_to_redeem integer default 0,p_promo_code text default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_vehicle public.customer_vehicles;v_order jsonb;v_order_id uuid;v_old_subtotal numeric;v_new_subtotal numeric;
begin
 select organization_id into v_org from public.branches where id=p_branch_id and public.can_access_branch(id);
 if v_org is null then raise exception 'Branch access denied'; end if;
 if (select business_type from public.organizations where id=v_org)<>'car_wash' then raise exception 'Car Wash organization required'; end if;
 if p_vehicle_type not in ('car','suv','van','pickup','motorcycle','other') then raise exception 'Invalid vehicle type'; end if;
 if nullif(trim(coalesce(p_plate_number,'')),'') is null and p_vehicle_id is null then raise exception 'Vehicle plate number is required'; end if;
 if p_vehicle_id is not null then
  select * into v_vehicle from public.customer_vehicles where id=p_vehicle_id and organization_id=v_org and active and (p_customer_id is null or customer_id=p_customer_id);
  if v_vehicle.id is null then raise exception 'Saved vehicle not found for this customer'; end if;
 end if;
 p_vehicle_type:=coalesce(v_vehicle.vehicle_type,lower(trim(coalesce(p_vehicle_type,'car'))));
 v_order:=public.create_laundry_order(p_branch_id=>p_branch_id,p_customer_id=>p_customer_id,p_items=>p_items,p_discount=>p_discount,p_notes=>p_notes,p_due_at=>p_due_at,p_delivery_addon_type=>p_delivery_addon_type,p_delivery_distance_rate_id=>p_delivery_distance_rate_id,p_loyalty_points_to_redeem=>p_loyalty_points_to_redeem,p_promo_code=>p_promo_code);
 v_order_id:=(v_order->>'id')::uuid;
 select subtotal into v_old_subtotal from public.laundry_orders where id=v_order_id;
 update public.laundry_order_items oi set unit_price=coalesce(vp.price,oi.unit_price)
 from public.services s left join public.service_vehicle_prices vp on vp.service_id=s.id and vp.vehicle_type=p_vehicle_type and vp.organization_id=v_org
 where oi.order_id=v_order_id and oi.service_id=s.id;
 select coalesce(sum(line_total),0) into v_new_subtotal from public.laundry_order_items where order_id=v_order_id;
 update public.laundry_orders set
  subtotal=v_new_subtotal,
  total=greatest(total+(v_new_subtotal-v_old_subtotal),0),
  vehicle_id=v_vehicle.id,
  vehicle_plate_number=upper(trim(coalesce(v_vehicle.plate_number,p_plate_number))),
  vehicle_type=p_vehicle_type,
  vehicle_make=coalesce(v_vehicle.make,nullif(trim(coalesce(p_make,'')),'')),
  vehicle_model=coalesce(v_vehicle.model,nullif(trim(coalesce(p_model,'')),'')),
  vehicle_color=coalesce(v_vehicle.color,nullif(trim(coalesce(p_color,'')),'')),
  updated_at=now()
 where id=v_order_id returning to_jsonb(laundry_orders.*) into v_order;
 return v_order;
end $$;

grant select on public.service_vehicle_prices to authenticated;
grant execute on function public.get_service_vehicle_prices() to authenticated;
grant execute on function public.save_service_vehicle_prices(uuid,jsonb) to authenticated;
grant execute on function public.create_car_wash_order(uuid,uuid,jsonb,uuid,text,text,text,text,text,numeric,text,timestamptz,public.delivery_addon_type,uuid,integer,text) to authenticated;
commit;
