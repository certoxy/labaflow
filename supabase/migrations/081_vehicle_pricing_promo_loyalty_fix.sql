-- Correct Car Wash promo/loyalty calculations to use the selected vehicle price
-- and scope vehicle-pricing writes to the current organization.
begin;

drop policy if exists service_vehicle_prices_manage on public.service_vehicle_prices;
create policy service_vehicle_prices_manage on public.service_vehicle_prices
for all to authenticated
using (
 public.has_role_permission('manage_services')
 and exists (
  select 1 from public.organization_memberships m
  where m.organization_id=service_vehicle_prices.organization_id
    and m.user_id=auth.uid() and m.active
 )
)
with check (
 public.has_role_permission('manage_services')
 and exists (
  select 1 from public.organization_memberships m
  where m.organization_id=service_vehicle_prices.organization_id
    and m.user_id=auth.uid() and m.active
 )
);

create or replace function public.create_car_wash_order(
 p_branch_id uuid,p_customer_id uuid,p_items jsonb,p_vehicle_id uuid default null,p_plate_number text default null,p_vehicle_type text default 'car',p_make text default null,p_model text default null,p_color text default null,p_discount numeric default 0,p_notes text default null,p_due_at timestamptz default null,p_delivery_addon_type public.delivery_addon_type default null,p_delivery_distance_rate_id uuid default null,p_loyalty_points_to_redeem integer default 0,p_promo_code text default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
 v_org uuid;
 v_vehicle public.customer_vehicles;
 v_order jsonb;
 v_order_id uuid;
 v_new_subtotal numeric:=0;
 v_fee numeric:=0;
 v_before_loyalty numeric:=0;
 v_promo public.promo_codes%rowtype;
 v_promo_discount numeric:=0;
 v_customer public.customers%rowtype;
 v_redeem integer:=greatest(coalesce(p_loyalty_points_to_redeem,0),0);
begin
 select organization_id into v_org from public.branches where id=p_branch_id and public.can_access_branch(id);
 if v_org is null then raise exception 'Branch access denied'; end if;
 if (select business_type from public.organizations where id=v_org)<>'car_wash' then raise exception 'Car Wash organization required'; end if;
 if p_vehicle_type not in ('car','suv','van','pickup','motorcycle','other') then raise exception 'Invalid vehicle type'; end if;
 if nullif(trim(coalesce(p_plate_number,'')),'') is null and p_vehicle_id is null then raise exception 'Vehicle plate number is required'; end if;

 if p_vehicle_id is not null then
  select * into v_vehicle from public.customer_vehicles
  where id=p_vehicle_id and organization_id=v_org and active
    and (p_customer_id is null or customer_id=p_customer_id);
  if v_vehicle.id is null then raise exception 'Saved vehicle not found for this customer'; end if;
 end if;
 p_vehicle_type:=coalesce(v_vehicle.vehicle_type,lower(trim(coalesce(p_vehicle_type,'car'))));

 -- Create the base order without discounts; pricing, promo, and redemption are
 -- applied atomically below using the selected vehicle rate.
 v_order:=public.create_laundry_order(
  p_branch_id=>p_branch_id,p_customer_id=>p_customer_id,p_items=>p_items,
  p_discount=>0,p_notes=>p_notes,p_due_at=>p_due_at,
  p_delivery_addon_type=>p_delivery_addon_type,
  p_delivery_distance_rate_id=>p_delivery_distance_rate_id,
  p_loyalty_points_to_redeem=>0,p_promo_code=>null
 );
 v_order_id:=(v_order->>'id')::uuid;

 update public.laundry_order_items oi
 set unit_price=coalesce(vp.price,oi.unit_price)
 from public.services s
 left join public.service_vehicle_prices vp
   on vp.service_id=s.id and vp.vehicle_type=p_vehicle_type and vp.organization_id=v_org
 where oi.order_id=v_order_id and oi.service_id=s.id;

 select coalesce(sum(line_total),0) into v_new_subtotal
 from public.laundry_order_items where order_id=v_order_id;
 select coalesce(delivery_fee,0) into v_fee
 from public.laundry_orders where id=v_order_id;

 if nullif(trim(coalesce(p_promo_code,'')),'') is not null then
  select * into v_promo from public.promo_codes
  where organization_id=v_org and code=upper(trim(p_promo_code)) for update;
  if v_promo.id is null then raise exception 'Promo code not found'; end if;
  if not v_promo.active then raise exception 'Promo code is inactive'; end if;
  if v_promo.starts_at is not null and now()<v_promo.starts_at then raise exception 'Promo code is not active yet'; end if;
  if v_promo.expires_at is not null and now()>v_promo.expires_at then raise exception 'Promo code has expired'; end if;
  if v_promo.usage_limit is not null and v_promo.usage_count>=v_promo.usage_limit then raise exception 'Promo code usage limit has been reached'; end if;
  v_promo_discount:=case when v_promo.discount_type='percentage'
    then round((v_new_subtotal+v_fee)*v_promo.discount_value/100,2)
    else v_promo.discount_value end;
  v_promo_discount:=least(v_promo_discount,v_new_subtotal+v_fee);
 end if;

 v_before_loyalty:=greatest(v_new_subtotal+v_fee-v_promo_discount,0);
 if v_redeem>0 then
  if p_customer_id is null then raise exception 'Loyalty points require a registered customer'; end if;
  select * into v_customer from public.customers
  where id=p_customer_id and organization_id=v_org and active for update;
  if v_customer.id is null then raise exception 'Customer is invalid'; end if;
  if v_redeem>coalesce(v_customer.loyalty_points,0) then
   raise exception 'Customer only has % loyalty points available',coalesce(v_customer.loyalty_points,0);
  end if;
  if v_redeem>floor(v_before_loyalty)::integer then
   raise exception 'Loyalty redemption cannot exceed the current order value';
  end if;
  update public.customers set loyalty_points=loyalty_points-v_redeem,updated_at=now()
  where id=v_customer.id;
  insert into public.loyalty_transactions(
   organization_id,customer_id,branch_id,transaction_type,points,description,
   reference_type,reference_id,created_by
  ) values(
   v_org,v_customer.id,p_branch_id,'redeem',-v_redeem,
   'Loyalty points redeemed on car wash order (1 point = PHP 1)',
   'laundry_order',v_order_id,auth.uid()
  );
 end if;

 if v_promo.id is not null then
  update public.promo_codes set usage_count=usage_count+1,updated_at=now()
  where id=v_promo.id;
 end if;

 update public.laundry_orders set
  subtotal=v_new_subtotal,
  discount=v_promo_discount,
  promo_code_id=v_promo.id,
  promo_code=v_promo.code,
  promo_discount=v_promo_discount,
  loyalty_points_redeemed=v_redeem,
  loyalty_discount=v_redeem,
  total=greatest(v_before_loyalty-v_redeem,0),
  vehicle_id=v_vehicle.id,
  vehicle_plate_number=upper(trim(coalesce(v_vehicle.plate_number,p_plate_number))),
  vehicle_type=p_vehicle_type,
  vehicle_make=coalesce(v_vehicle.make,nullif(trim(coalesce(p_make,'')),'')),
  vehicle_model=coalesce(v_vehicle.model,nullif(trim(coalesce(p_model,'')),'')),
  vehicle_color=coalesce(v_vehicle.color,nullif(trim(coalesce(p_color,'')),'')),
  updated_at=now()
 where id=v_order_id returning to_jsonb(laundry_orders.*) into v_order;

 update public.order_status_history
 set notes=case when v_promo.id is not null then format('Order created with promo %s',v_promo.code) else notes end
 where order_id=v_order_id and status='received';

 return v_order;
end $$;

grant execute on function public.create_car_wash_order(uuid,uuid,jsonb,uuid,text,text,text,text,text,numeric,text,timestamptz,public.delivery_addon_type,uuid,integer,text) to authenticated;
commit;
