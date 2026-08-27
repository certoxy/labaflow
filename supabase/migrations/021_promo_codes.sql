-- LabaFlow v0.8 - tenant promo codes
begin;

create type public.promo_discount_type as enum ('amount','percentage');

create table public.promo_codes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  code text not null,
  name text,
  discount_type public.promo_discount_type not null,
  discount_value numeric(12,2) not null check(discount_value > 0),
  starts_at timestamptz,
  expires_at timestamptz,
  usage_limit integer check(usage_limit is null or usage_limit > 0),
  usage_count integer not null default 0 check(usage_count >= 0),
  active boolean not null default true,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,code),
  check(discount_type <> 'percentage' or discount_value <= 100),
  check(expires_at is null or starts_at is null or expires_at > starts_at)
);

alter table public.promo_codes enable row level security;
create policy "members read promo codes" on public.promo_codes for select to authenticated using(public.is_organization_member(organization_id));
create policy "admins manage promo codes" on public.promo_codes for all to authenticated using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));

alter table public.laundry_orders
  add column if not exists promo_code_id uuid references public.promo_codes(id),
  add column if not exists promo_code text,
  add column if not exists promo_discount numeric(12,2) not null default 0 check(promo_discount >= 0);

create or replace function public.create_promo_code(
  p_code text,
  p_name text,
  p_discount_type public.promo_discount_type,
  p_discount_value numeric,
  p_starts_at timestamptz default null,
  p_expires_at timestamptz default null,
  p_usage_limit integer default null
)
returns public.promo_codes
language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_row public.promo_codes%rowtype;v_code text:=upper(trim(p_code));
begin
  select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;
  if v_code='' then raise exception 'Promo code is required'; end if;
  if p_discount_value<=0 then raise exception 'Discount value must be greater than zero'; end if;
  if p_discount_type='percentage' and p_discount_value>100 then raise exception 'Percentage cannot exceed 100'; end if;
  if p_usage_limit is not null and p_usage_limit<=0 then raise exception 'Usage limit must be greater than zero'; end if;
  if p_starts_at is not null and p_expires_at is not null and p_expires_at<=p_starts_at then raise exception 'Expiration must be after start date'; end if;
  insert into public.promo_codes(organization_id,code,name,discount_type,discount_value,starts_at,expires_at,usage_limit,created_by)
  values(v_org,v_code,nullif(trim(coalesce(p_name,'')),''),p_discount_type,p_discount_value,p_starts_at,p_expires_at,p_usage_limit,auth.uid())
  returning * into v_row;
  return v_row;
end $$;

create or replace function public.set_promo_code_active(p_promo_id uuid,p_active boolean)
returns public.promo_codes language plpgsql security definer set search_path=public as $$
declare v_row public.promo_codes%rowtype;
begin
  select * into v_row from public.promo_codes where id=p_promo_id;
  if v_row.id is null or not public.is_organization_admin(v_row.organization_id) then raise exception 'Promo code not found or access denied'; end if;
  update public.promo_codes set active=p_active,updated_at=now() where id=p_promo_id returning * into v_row;
  return v_row;
end $$;

create or replace function public.validate_promo_code(p_code text,p_order_amount numeric)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_promo public.promo_codes%rowtype;v_discount numeric:=0;v_amount numeric:=greatest(coalesce(p_order_amount,0),0);
begin
  select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
  if v_org is null then raise exception 'Active organization membership required'; end if;
  select * into v_promo from public.promo_codes where organization_id=v_org and code=upper(trim(p_code));
  if v_promo.id is null then raise exception 'Promo code not found'; end if;
  if not v_promo.active then raise exception 'Promo code is inactive'; end if;
  if v_promo.starts_at is not null and now()<v_promo.starts_at then raise exception 'Promo code is not active yet'; end if;
  if v_promo.expires_at is not null and now()>v_promo.expires_at then raise exception 'Promo code has expired'; end if;
  if v_promo.usage_limit is not null and v_promo.usage_count>=v_promo.usage_limit then raise exception 'Promo code usage limit has been reached'; end if;
  v_discount:=case when v_promo.discount_type='percentage' then round(v_amount*v_promo.discount_value/100,2) else v_promo.discount_value end;
  v_discount:=least(v_discount,v_amount);
  return jsonb_build_object('id',v_promo.id,'code',v_promo.code,'name',v_promo.name,'discount_type',v_promo.discount_type,'discount_value',v_promo.discount_value,'discount_amount',v_discount,'usage_count',v_promo.usage_count,'usage_limit',v_promo.usage_limit,'starts_at',v_promo.starts_at,'expires_at',v_promo.expires_at);
end $$;

-- Replace the 9-argument loyalty-aware signature with promo-aware signature.
drop function if exists public.create_laundry_order(uuid,uuid,jsonb,numeric,text,timestamptz,public.delivery_addon_type,uuid,integer);

create or replace function public.create_laundry_order(
  p_branch_id uuid,
  p_customer_id uuid,
  p_items jsonb,
  p_discount numeric default 0,
  p_notes text default null,
  p_due_at timestamptz default null,
  p_delivery_addon_type public.delivery_addon_type default null,
  p_delivery_distance_rate_id uuid default null,
  p_loyalty_points_to_redeem integer default 0,
  p_promo_code text default null
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_org uuid;v_order public.laundry_orders%rowtype;v_item jsonb;v_service public.services%rowtype;
  v_qty numeric;v_price numeric;v_subtotal numeric:=0;v_fee numeric:=0;v_rate public.delivery_distance_rates%rowtype;
  v_address public.customer_addresses%rowtype;v_customer public.customers%rowtype;v_promo public.promo_codes%rowtype;
  v_redeem integer:=greatest(coalesce(p_loyalty_points_to_redeem,0),0);v_promo_discount numeric:=0;v_before_loyalty numeric:=0;
begin
  select organization_id into v_org from branches where id=p_branch_id and public.can_access_branch(id);
  if v_org is null then raise exception 'Branch access denied'; end if;
  if not public.has_role_permission('create_orders',p_branch_id) then raise exception 'Order creation permission required'; end if;
  if p_customer_id is not null and not exists(select 1 from customers where id=p_customer_id and organization_id=v_org and active) then raise exception 'Customer is invalid'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'Add at least one service'; end if;
  if v_redeem>0 and p_customer_id is null then raise exception 'Loyalty points require a registered customer'; end if;

  if p_delivery_addon_type is not null then
    if p_customer_id is null then raise exception 'Pickup/Delivery requires a registered customer'; end if;
    if p_delivery_distance_rate_id is null then raise exception 'Select a delivery distance'; end if;
    select * into v_rate from public.delivery_distance_rates where id=p_delivery_distance_rate_id and organization_id=v_org and addon_type=p_delivery_addon_type and active;
    if v_rate.id is null then raise exception 'Distance rate does not match the selected add-on type'; end if;
    v_fee:=v_rate.price;
    select * into v_address from public.customer_addresses where organization_id=v_org and customer_id=p_customer_id and active order by is_default desc,updated_at desc,created_at desc limit 1;
    if v_address.id is null then raise exception 'Pickup/Delivery requires an active customer address. Add an address first.'; end if;
  end if;

  -- Build subtotal before applying promo.
  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_service from services where id=(v_item->>'service_id')::uuid and organization_id=v_org and active;
    if v_service.id is null then raise exception 'Service is invalid'; end if;
    v_qty:=greatest((v_item->>'quantity')::numeric,0);if v_qty<=0 then raise exception 'Quantity must be greater than zero'; end if;
    select coalesce((select price from branch_service_prices where branch_id=p_branch_id and service_id=v_service.id and active),v_service.default_price) into v_price;
    v_subtotal:=v_subtotal+(v_qty*v_price);
  end loop;

  if nullif(trim(coalesce(p_promo_code,'')),'') is not null then
    select * into v_promo from public.promo_codes where organization_id=v_org and code=upper(trim(p_promo_code)) for update;
    if v_promo.id is null then raise exception 'Promo code not found'; end if;
    if not v_promo.active then raise exception 'Promo code is inactive'; end if;
    if v_promo.starts_at is not null and now()<v_promo.starts_at then raise exception 'Promo code is not active yet'; end if;
    if v_promo.expires_at is not null and now()>v_promo.expires_at then raise exception 'Promo code has expired'; end if;
    if v_promo.usage_limit is not null and v_promo.usage_count>=v_promo.usage_limit then raise exception 'Promo code usage limit has been reached'; end if;
    v_promo_discount:=case when v_promo.discount_type='percentage' then round((v_subtotal+v_fee)*v_promo.discount_value/100,2) else v_promo.discount_value end;
    v_promo_discount:=least(v_promo_discount,v_subtotal+v_fee);
  end if;

  insert into laundry_orders(organization_id,branch_id,customer_id,discount,notes,due_at,created_by,delivery_addon_type,delivery_distance_rate_id,delivery_distance_label,delivery_fee,loyalty_points_redeemed,loyalty_discount,promo_code_id,promo_code,promo_discount)
  values(v_org,p_branch_id,p_customer_id,v_promo_discount,p_notes,p_due_at,auth.uid(),p_delivery_addon_type,v_rate.id,v_rate.label,v_fee,0,0,v_promo.id,v_promo.code,v_promo_discount)
  returning * into v_order;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_service from services where id=(v_item->>'service_id')::uuid and organization_id=v_org and active;
    v_qty:=greatest((v_item->>'quantity')::numeric,0);
    select coalesce((select price from branch_service_prices where branch_id=p_branch_id and service_id=v_service.id and active),v_service.default_price) into v_price;
    insert into laundry_order_items(order_id,service_id,quantity,unit_price,notes) values(v_order.id,v_service.id,v_qty,v_price,v_item->>'notes');
  end loop;

  v_before_loyalty:=greatest(v_subtotal+v_fee-v_promo_discount,0);
  if v_redeem>0 then
    select * into v_customer from public.customers where id=p_customer_id and organization_id=v_org and active for update;
    if v_redeem>coalesce(v_customer.loyalty_points,0) then raise exception 'Customer only has % loyalty points available',coalesce(v_customer.loyalty_points,0); end if;
    if v_redeem>floor(v_before_loyalty)::integer then raise exception 'Loyalty redemption cannot exceed the current order value'; end if;
    update public.customers set loyalty_points=loyalty_points-v_redeem,updated_at=now() where id=v_customer.id;
    insert into public.loyalty_transactions(organization_id,customer_id,branch_id,transaction_type,points,description,reference_type,reference_id,created_by)
    values(v_org,v_customer.id,p_branch_id,'redeem',-v_redeem,'Loyalty points redeemed on laundry order (1 point = PHP 1)','laundry_order',v_order.id,auth.uid());
  end if;

  update laundry_orders set subtotal=v_subtotal,discount=v_promo_discount,loyalty_points_redeemed=v_redeem,loyalty_discount=v_redeem,total=greatest(v_before_loyalty-v_redeem,0),updated_at=now() where id=v_order.id returning * into v_order;
  if v_promo.id is not null then update public.promo_codes set usage_count=usage_count+1,updated_at=now() where id=v_promo.id; end if;
  insert into order_status_history(order_id,status,changed_by,notes) values(v_order.id,'received',auth.uid(),case when v_promo.id is not null then format('Order created with promo %s',v_promo.code) else 'Order created' end);

  if p_delivery_addon_type='pickup' then
    insert into public.delivery_jobs(organization_id,branch_id,customer_id,order_id,address_id,job_type,status,scheduled_at,delivery_fee,contact_name,contact_mobile,notes,created_by)
    select v_org,p_branch_id,p_customer_id,v_order.id,v_address.id,'pickup','scheduled',now(),v_fee,c.full_name,c.mobile,'Created automatically from order add-on',auth.uid() from public.customers c where c.id=p_customer_id;
  elsif p_delivery_addon_type='delivery' then
    insert into public.delivery_jobs(organization_id,branch_id,customer_id,order_id,address_id,job_type,status,scheduled_at,delivery_fee,contact_name,contact_mobile,notes,created_by)
    select v_org,p_branch_id,p_customer_id,v_order.id,v_address.id,'delivery','scheduled',coalesce(p_due_at,now()),v_fee,c.full_name,c.mobile,'Created automatically from order add-on',auth.uid() from public.customers c where c.id=p_customer_id;
  elsif p_delivery_addon_type='pickup_delivery' then
    insert into public.delivery_jobs(organization_id,branch_id,customer_id,order_id,address_id,job_type,status,scheduled_at,delivery_fee,contact_name,contact_mobile,notes,created_by)
    select v_org,p_branch_id,p_customer_id,v_order.id,v_address.id,'pickup','scheduled',now(),0,c.full_name,c.mobile,'Pickup leg created automatically from order add-on',auth.uid() from public.customers c where c.id=p_customer_id;
    insert into public.delivery_jobs(organization_id,branch_id,customer_id,order_id,address_id,job_type,status,scheduled_at,delivery_fee,contact_name,contact_mobile,notes,created_by)
    select v_org,p_branch_id,p_customer_id,v_order.id,v_address.id,'delivery','scheduled',coalesce(p_due_at,now()),v_fee,c.full_name,c.mobile,'Delivery leg created automatically from order add-on',auth.uid() from public.customers c where c.id=p_customer_id;
  end if;
  return to_jsonb(v_order);
end $$;

grant execute on function public.create_promo_code(text,text,public.promo_discount_type,numeric,timestamptz,timestamptz,integer) to authenticated;
grant execute on function public.set_promo_code_active(uuid,boolean) to authenticated;
grant execute on function public.validate_promo_code(text,numeric) to authenticated;
grant execute on function public.create_laundry_order(uuid,uuid,jsonb,numeric,text,timestamptz,public.delivery_addon_type,uuid,integer,text) to authenticated;

commit;
