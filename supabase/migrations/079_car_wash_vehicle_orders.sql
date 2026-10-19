-- Car Wash vehicle registration, order linkage, and immutable receipt snapshots.
begin;
alter table public.laundry_orders
  add column if not exists vehicle_plate_number text,
  add column if not exists vehicle_type text,
  add column if not exists vehicle_make text,
  add column if not exists vehicle_model text,
  add column if not exists vehicle_color text;

create or replace function public.get_customer_vehicles(p_customer_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_org uuid;
begin
 select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
 if v_org is null then raise exception 'Organization access required'; end if;
 if not exists(select 1 from public.customers where id=p_customer_id and organization_id=v_org) then raise exception 'Customer not found'; end if;
 return coalesce((select jsonb_agg(to_jsonb(v) order by v.updated_at desc,v.created_at desc) from public.customer_vehicles v where v.organization_id=v_org and v.customer_id=p_customer_id and v.active),'[]'::jsonb);
end $$;

create or replace function public.create_customer_vehicle(p_customer_id uuid,p_plate_number text,p_vehicle_type text default 'car',p_make text default null,p_model text default null,p_color text default null,p_notes text default null)
returns public.customer_vehicles language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_vehicle public.customer_vehicles;
begin
 select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
 if v_org is null or not public.has_role_permission('manage_customers') then raise exception 'Customer management permission required'; end if;
 if (select business_type from public.organizations where id=v_org)<>'car_wash' then raise exception 'Vehicle registration is only available for Car Wash organizations'; end if;
 if not exists(select 1 from public.customers where id=p_customer_id and organization_id=v_org and active) then raise exception 'Customer not found'; end if;
 if nullif(trim(p_plate_number),'') is null then raise exception 'Plate number is required'; end if;
 insert into public.customer_vehicles(organization_id,customer_id,plate_number,vehicle_type,make,model,color,notes)
 values(v_org,p_customer_id,upper(trim(p_plate_number)),lower(trim(coalesce(p_vehicle_type,'car'))),nullif(trim(coalesce(p_make,'')),''),nullif(trim(coalesce(p_model,'')),''),nullif(trim(coalesce(p_color,'')),''),nullif(trim(coalesce(p_notes,'')),''))
 on conflict (organization_id,plate_number) do update set customer_id=excluded.customer_id,vehicle_type=excluded.vehicle_type,make=excluded.make,model=excluded.model,color=excluded.color,notes=excluded.notes,active=true,updated_at=now()
 returning * into v_vehicle;
 return v_vehicle;
end $$;

create or replace function public.create_car_wash_order(
 p_branch_id uuid,p_customer_id uuid,p_items jsonb,p_vehicle_id uuid default null,p_plate_number text default null,p_vehicle_type text default 'car',p_make text default null,p_model text default null,p_color text default null,p_discount numeric default 0,p_notes text default null,p_due_at timestamptz default null,p_delivery_addon_type public.delivery_addon_type default null,p_delivery_distance_rate_id uuid default null,p_loyalty_points_to_redeem integer default 0,p_promo_code text default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_vehicle public.customer_vehicles;v_order jsonb;v_order_id uuid;
begin
 select organization_id into v_org from public.branches where id=p_branch_id and public.can_access_branch(id);
 if v_org is null then raise exception 'Branch access denied'; end if;
 if (select business_type from public.organizations where id=v_org)<>'car_wash' then raise exception 'Car Wash organization required'; end if;
 if nullif(trim(coalesce(p_plate_number,'')),'') is null and p_vehicle_id is null then raise exception 'Vehicle plate number is required'; end if;
 if p_vehicle_id is not null then
  select * into v_vehicle from public.customer_vehicles where id=p_vehicle_id and organization_id=v_org and active and (p_customer_id is null or customer_id=p_customer_id);
  if v_vehicle.id is null then raise exception 'Saved vehicle not found for this customer'; end if;
 end if;
 v_order:=public.create_laundry_order(p_branch_id=>p_branch_id,p_customer_id=>p_customer_id,p_items=>p_items,p_discount=>p_discount,p_notes=>p_notes,p_due_at=>p_due_at,p_delivery_addon_type=>p_delivery_addon_type,p_delivery_distance_rate_id=>p_delivery_distance_rate_id,p_loyalty_points_to_redeem=>p_loyalty_points_to_redeem,p_promo_code=>p_promo_code);
 v_order_id:=(v_order->>'id')::uuid;
 update public.laundry_orders set vehicle_id=v_vehicle.id,vehicle_plate_number=upper(trim(coalesce(v_vehicle.plate_number,p_plate_number))),vehicle_type=coalesce(v_vehicle.vehicle_type,lower(trim(coalesce(p_vehicle_type,'car')))),vehicle_make=coalesce(v_vehicle.make,nullif(trim(coalesce(p_make,'')),'')),vehicle_model=coalesce(v_vehicle.model,nullif(trim(coalesce(p_model,'')),'')),vehicle_color=coalesce(v_vehicle.color,nullif(trim(coalesce(p_color,'')),'')),updated_at=now() where id=v_order_id returning to_jsonb(laundry_orders.*) into v_order;
 return v_order;
end $$;

grant execute on function public.get_customer_vehicles(uuid) to authenticated;
grant execute on function public.create_customer_vehicle(uuid,text,text,text,text,text,text) to authenticated;
grant execute on function public.create_car_wash_order(uuid,uuid,jsonb,uuid,text,text,text,text,text,numeric,text,timestamptz,public.delivery_addon_type,uuid,integer,text) to authenticated;
commit;
