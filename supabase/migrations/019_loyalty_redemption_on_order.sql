-- LabaFlow v0.7.5 - redeem loyalty points directly on a new order
-- 1 loyalty point = PHP 1. Redemption is atomic with order creation.
begin;

alter table public.laundry_orders
  add column if not exists loyalty_points_redeemed integer not null default 0 check (loyalty_points_redeemed >= 0),
  add column if not exists loyalty_discount numeric(12,2) not null default 0 check (loyalty_discount >= 0);

create or replace function public.create_laundry_order(
  p_branch_id uuid,
  p_customer_id uuid,
  p_items jsonb,
  p_discount numeric default 0,
  p_notes text default null,
  p_due_at timestamptz default null,
  p_delivery_addon_type public.delivery_addon_type default null,
  p_delivery_distance_rate_id uuid default null,
  p_loyalty_points_to_redeem integer default 0
)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_org uuid;v_order public.laundry_orders%rowtype;v_item jsonb;v_service public.services%rowtype;
  v_qty numeric;v_price numeric;v_subtotal numeric:=0;v_fee numeric:=0;v_rate public.delivery_distance_rates%rowtype;
  v_address public.customer_addresses%rowtype;v_customer public.customers%rowtype;
  v_redeem integer:=greatest(coalesce(p_loyalty_points_to_redeem,0),0);
  v_before_loyalty numeric:=0;
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
    select * into v_rate
    from public.delivery_distance_rates
    where id=p_delivery_distance_rate_id and organization_id=v_org and addon_type=p_delivery_addon_type and active;
    if v_rate.id is null then raise exception 'Distance rate does not match the selected add-on type'; end if;
    v_fee:=v_rate.price;

    select * into v_address
    from public.customer_addresses
    where organization_id=v_org and customer_id=p_customer_id and active
    order by is_default desc,updated_at desc,created_at desc limit 1;
    if v_address.id is null then raise exception 'Pickup/Delivery requires an active customer address. Add an address first.'; end if;
  end if;

  insert into laundry_orders(organization_id,branch_id,customer_id,discount,notes,due_at,created_by,delivery_addon_type,delivery_distance_rate_id,delivery_distance_label,delivery_fee,loyalty_points_redeemed,loyalty_discount)
  values(v_org,p_branch_id,p_customer_id,greatest(coalesce(p_discount,0),0),p_notes,p_due_at,auth.uid(),p_delivery_addon_type,v_rate.id,v_rate.label,v_fee,0,0)
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

  v_before_loyalty:=greatest(v_subtotal+v_fee-greatest(coalesce(p_discount,0),0),0);

  if v_redeem>0 then
    select * into v_customer
    from public.customers
    where id=p_customer_id and organization_id=v_org and active
    for update;
    if v_customer.id is null then raise exception 'Customer is invalid'; end if;
    if v_redeem>coalesce(v_customer.loyalty_points,0) then raise exception 'Customer only has % loyalty points available',coalesce(v_customer.loyalty_points,0); end if;
    if v_redeem>floor(v_before_loyalty)::integer then raise exception 'Loyalty redemption cannot exceed the current order value'; end if;

    update public.customers
    set loyalty_points=loyalty_points-v_redeem,updated_at=now()
    where id=v_customer.id;

    insert into public.loyalty_transactions(
      organization_id,customer_id,branch_id,transaction_type,points,description,reference_type,reference_id,created_by
    ) values(
      v_org,v_customer.id,p_branch_id,'redeem',-v_redeem,
      'Loyalty points redeemed on laundry order (1 point = PHP 1)','laundry_order',v_order.id,auth.uid()
    );
  end if;

  update laundry_orders
  set subtotal=v_subtotal,
      loyalty_points_redeemed=v_redeem,
      loyalty_discount=v_redeem,
      total=greatest(v_before_loyalty-v_redeem,0),
      updated_at=now()
  where id=v_order.id returning * into v_order;

  insert into order_status_history(order_id,status,changed_by,notes)
  values(v_order.id,'received',auth.uid(),case when v_redeem>0 then format('Order created; %s loyalty points redeemed',v_redeem) else 'Order created' end);

  if p_delivery_addon_type='pickup' then
    insert into public.delivery_jobs(organization_id,branch_id,customer_id,order_id,address_id,job_type,status,scheduled_at,delivery_fee,contact_name,contact_mobile,notes,created_by)
    select v_org,p_branch_id,p_customer_id,v_order.id,v_address.id,'pickup','scheduled',now(),v_fee,c.full_name,c.mobile,'Created automatically from order add-on',auth.uid()
    from public.customers c where c.id=p_customer_id;
  elsif p_delivery_addon_type='delivery' then
    insert into public.delivery_jobs(organization_id,branch_id,customer_id,order_id,address_id,job_type,status,scheduled_at,delivery_fee,contact_name,contact_mobile,notes,created_by)
    select v_org,p_branch_id,p_customer_id,v_order.id,v_address.id,'delivery','scheduled',coalesce(p_due_at,now()),v_fee,c.full_name,c.mobile,'Created automatically from order add-on',auth.uid()
    from public.customers c where c.id=p_customer_id;
  elsif p_delivery_addon_type='pickup_delivery' then
    insert into public.delivery_jobs(organization_id,branch_id,customer_id,order_id,address_id,job_type,status,scheduled_at,delivery_fee,contact_name,contact_mobile,notes,created_by)
    select v_org,p_branch_id,p_customer_id,v_order.id,v_address.id,'pickup','scheduled',now(),0,c.full_name,c.mobile,'Pickup leg created automatically from order add-on',auth.uid()
    from public.customers c where c.id=p_customer_id;
    insert into public.delivery_jobs(organization_id,branch_id,customer_id,order_id,address_id,job_type,status,scheduled_at,delivery_fee,contact_name,contact_mobile,notes,created_by)
    select v_org,p_branch_id,p_customer_id,v_order.id,v_address.id,'delivery','scheduled',coalesce(p_due_at,now()),v_fee,c.full_name,c.mobile,'Delivery leg created automatically from order add-on',auth.uid()
    from public.customers c where c.id=p_customer_id;
  end if;

  return to_jsonb(v_order);
end $$;

grant execute on function public.create_laundry_order(uuid,uuid,jsonb,numeric,text,timestamptz,public.delivery_addon_type,uuid,integer) to authenticated;

commit;
