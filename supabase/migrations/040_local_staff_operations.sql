-- LabaFlow v0.40 local staff operational RPCs and audit attribution.
-- Local staff authenticate with a short-lived opaque session token instead of Supabase Auth.

begin;

alter table public.laundry_orders add column if not exists created_by_local_staff uuid references public.local_staff_accounts(id) on delete set null;
alter table public.order_status_history add column if not exists changed_by_local_staff uuid references public.local_staff_accounts(id) on delete set null;
alter table public.payments add column if not exists received_by_local_staff uuid references public.local_staff_accounts(id) on delete set null;
alter table public.loyalty_transactions add column if not exists created_by_local_staff uuid references public.local_staff_accounts(id) on delete set null;

create or replace function public.get_local_staff_operational_context(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_session public.local_staff_sessions%rowtype;
  v_staff public.local_staff_accounts%rowtype;
  v_org public.organizations%rowtype;
  v_permissions jsonb;
begin
  select * into v_session
  from public.local_staff_sessions
  where token=p_token and revoked_at is null and expires_at>now();
  if v_session.token is null then raise exception 'Staff session is invalid or expired'; end if;

  select * into v_staff from public.local_staff_accounts where id=v_session.staff_id and active;
  select * into v_org from public.organizations where id=v_session.organization_id and active;
  if v_staff.id is null or v_org.id is null or v_staff.organization_id<>v_org.id then raise exception 'Staff access is no longer active'; end if;

  v_permissions:=jsonb_build_object(
    'manage_customers',v_staff.role in ('manager','cashier'),
    'adjust_loyalty',v_staff.role='manager',
    'create_orders',v_staff.role in ('manager','cashier'),
    'process_orders',v_staff.role in ('manager','cashier','laundry_staff'),
    'record_payments',v_staff.role in ('manager','cashier'),
    'delivery_access',v_staff.role in ('manager','delivery_staff'),
    'view_reports',v_staff.role in ('manager','auditor')
  );

  update public.local_staff_sessions set last_seen_at=now() where token=p_token;

  return jsonb_build_object(
    'staff',jsonb_build_object('id',v_staff.id,'full_name',v_staff.full_name,'username',v_staff.username,'role',v_staff.role),
    'organization',jsonb_build_object('id',v_org.id,'name',v_org.name,'slug',v_org.slug),
    'branch',case when v_staff.branch_id is null then null else (select jsonb_build_object('id',b.id,'name',b.name,'code',b.code) from public.branches b where b.id=v_staff.branch_id and b.active) end,
    'permissions',v_permissions,
    'features',coalesce((select jsonb_object_agg(f.feature_key,f.enabled) from public.organization_features f where f.organization_id=v_org.id),'{}'::jsonb),
    'settings',coalesce((select jsonb_object_agg(s.setting_key,s.setting_value) from public.organization_settings s where s.organization_id=v_org.id),'{}'::jsonb),
    'branches',coalesce((select jsonb_agg(jsonb_build_object('id',b.id,'name',b.name,'code',b.code,'address',b.address) order by b.name) from public.branches b where b.organization_id=v_org.id and b.active and (v_staff.branch_id is null or b.id=v_staff.branch_id)),'[]'::jsonb),
    'customers',coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'customer_code',c.customer_code,'full_name',c.full_name,'mobile',c.mobile,'email',c.email,'preferred_branch_id',c.preferred_branch_id,'loyalty_points',c.loyalty_points,'lifetime_points',c.lifetime_points,'lifetime_visits',c.lifetime_visits,'lifetime_spend',c.lifetime_spend) order by c.full_name) from public.customers c where c.organization_id=v_org.id and c.active),'[]'::jsonb),
    'loyalty_levels',coalesce((select jsonb_agg(jsonb_build_object('id',l.id,'name',l.name,'minimum_points',l.minimum_points,'active',l.active) order by l.minimum_points) from public.loyalty_levels l where l.organization_id=v_org.id and l.active),'[]'::jsonb),
    'services',coalesce((select jsonb_agg(jsonb_build_object('id',s.id,'name',s.name,'pricing_unit',s.pricing_unit,'default_price',s.default_price,'loyalty_points',coalesce(s.loyalty_points,0)) order by s.name) from public.services s where s.organization_id=v_org.id and s.active),'[]'::jsonb),
    'orders',coalesce((select jsonb_agg(x.obj order by x.created_at desc) from (
      select o.created_at,jsonb_build_object('id',o.id,'order_code',o.order_code,'branch_id',o.branch_id,'customer_id',o.customer_id,'status',o.status,'payment_status',o.payment_status,'subtotal',o.subtotal,'discount',o.discount,'total',o.total,'amount_paid',o.amount_paid,'created_at',o.created_at,'customers',case when c.id is null then null else jsonb_build_object('full_name',c.full_name,'customer_code',c.customer_code) end) obj
      from public.laundry_orders o left join public.customers c on c.id=o.customer_id
      where o.organization_id=v_org.id and (v_staff.branch_id is null or o.branch_id=v_staff.branch_id)
      order by o.created_at desc limit 200
    ) x),'[]'::jsonb)
  );
end;
$$;

create or replace function public.create_customer_local(
  p_token uuid,
  p_full_name text,
  p_mobile text default null,
  p_email text default null,
  p_preferred_branch_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_session public.local_staff_sessions%rowtype;v_staff public.local_staff_accounts%rowtype;v_customer public.customers%rowtype;v_qr public.customer_qr_tokens%rowtype;
begin
  select * into v_session from public.local_staff_sessions where token=p_token and revoked_at is null and expires_at>now();
  if v_session.token is null then raise exception 'Staff session is invalid or expired'; end if;
  select * into v_staff from public.local_staff_accounts where id=v_session.staff_id and active;
  if v_staff.id is null or v_staff.role not in ('manager','cashier') then raise exception 'Customer management permission required'; end if;
  if nullif(trim(p_full_name),'') is null then raise exception 'Customer name is required'; end if;
  if p_preferred_branch_id is not null and not exists(select 1 from public.branches b where b.id=p_preferred_branch_id and b.organization_id=v_staff.organization_id and b.active and (v_staff.branch_id is null or b.id=v_staff.branch_id)) then raise exception 'Invalid branch'; end if;
  insert into public.customers(organization_id,full_name,mobile,email,preferred_branch_id)
  values(v_staff.organization_id,trim(p_full_name),nullif(trim(coalesce(p_mobile,'')),''),nullif(lower(trim(coalesce(p_email,''))),''),p_preferred_branch_id)
  returning * into v_customer;
  insert into public.customer_qr_tokens(organization_id,customer_id) values(v_staff.organization_id,v_customer.id) returning * into v_qr;
  update public.local_staff_sessions set last_seen_at=now() where token=p_token;
  return jsonb_build_object('customer',to_jsonb(v_customer),'qr_token',v_qr.token);
end;
$$;

create or replace function public.create_laundry_order_local(
  p_token uuid,
  p_branch_id uuid,
  p_customer_id uuid,
  p_items jsonb,
  p_discount numeric default 0,
  p_notes text default null,
  p_due_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_session public.local_staff_sessions%rowtype;v_staff public.local_staff_accounts%rowtype;v_order public.laundry_orders%rowtype;v_item jsonb;v_service public.services%rowtype;v_qty numeric;v_price numeric;v_subtotal numeric:=0;
begin
  select * into v_session from public.local_staff_sessions where token=p_token and revoked_at is null and expires_at>now();
  if v_session.token is null then raise exception 'Staff session is invalid or expired'; end if;
  select * into v_staff from public.local_staff_accounts where id=v_session.staff_id and active;
  if v_staff.id is null or v_staff.role not in ('manager','cashier') then raise exception 'Order creation permission required'; end if;
  if not exists(select 1 from public.branches b where b.id=p_branch_id and b.organization_id=v_staff.organization_id and b.active and (v_staff.branch_id is null or b.id=v_staff.branch_id)) then raise exception 'Branch access denied'; end if;
  if p_customer_id is not null and not exists(select 1 from public.customers c where c.id=p_customer_id and c.organization_id=v_staff.organization_id and c.active) then raise exception 'Customer is invalid'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'Add at least one service'; end if;

  insert into public.laundry_orders(organization_id,branch_id,customer_id,discount,notes,due_at,created_by_local_staff)
  values(v_staff.organization_id,p_branch_id,p_customer_id,greatest(coalesce(p_discount,0),0),p_notes,p_due_at,v_staff.id)
  returning * into v_order;

  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_service from public.services where id=(v_item->>'service_id')::uuid and organization_id=v_staff.organization_id and active;
    if v_service.id is null then raise exception 'Service is invalid'; end if;
    v_qty:=greatest((v_item->>'quantity')::numeric,0);
    if v_qty<=0 then raise exception 'Quantity must be greater than zero'; end if;
    select coalesce((select bp.price from public.branch_service_prices bp where bp.branch_id=p_branch_id and bp.service_id=v_service.id and bp.active),v_service.default_price) into v_price;
    insert into public.laundry_order_items(order_id,service_id,quantity,unit_price,notes) values(v_order.id,v_service.id,v_qty,v_price,v_item->>'notes');
    v_subtotal:=v_subtotal+(v_qty*v_price);
  end loop;

  update public.laundry_orders set subtotal=v_subtotal,total=greatest(v_subtotal-greatest(coalesce(p_discount,0),0),0),updated_at=now() where id=v_order.id returning * into v_order;
  insert into public.order_status_history(order_id,status,changed_by_local_staff,notes) values(v_order.id,'received',v_staff.id,'Order created by local staff');
  update public.local_staff_sessions set last_seen_at=now() where token=p_token;
  return to_jsonb(v_order);
end;
$$;

create or replace function public.record_order_payment_local(
  p_token uuid,
  p_order_id uuid,
  p_amount numeric,
  p_method public.payment_method,
  p_reference text default null
)
returns public.laundry_orders
language plpgsql
security definer
set search_path=public
as $$
declare v_session public.local_staff_sessions%rowtype;v_staff public.local_staff_accounts%rowtype;v_order public.laundry_orders%rowtype;v_new_paid numeric;
begin
  select * into v_session from public.local_staff_sessions where token=p_token and revoked_at is null and expires_at>now();
  if v_session.token is null then raise exception 'Staff session is invalid or expired'; end if;
  select * into v_staff from public.local_staff_accounts where id=v_session.staff_id and active;
  if v_staff.id is null or v_staff.role not in ('manager','cashier') then raise exception 'Payment recording permission required'; end if;
  select * into v_order from public.laundry_orders where id=p_order_id and organization_id=v_staff.organization_id and (v_staff.branch_id is null or branch_id=v_staff.branch_id) for update;
  if v_order.id is null then raise exception 'Order not found'; end if;
  if p_amount<=0 then raise exception 'Payment must be greater than zero'; end if;
  if v_order.amount_paid+p_amount>v_order.total then raise exception 'Payment exceeds remaining balance'; end if;
  insert into public.payments(organization_id,branch_id,order_id,amount,method,reference,received_by_local_staff)
  values(v_order.organization_id,v_order.branch_id,v_order.id,p_amount,p_method,p_reference,v_staff.id);
  v_new_paid:=v_order.amount_paid+p_amount;
  update public.laundry_orders set amount_paid=v_new_paid,payment_status=case when v_new_paid>=total then 'paid'::public.payment_status when v_new_paid>0 then 'partial'::public.payment_status else 'unpaid'::public.payment_status end,updated_at=now() where id=v_order.id returning * into v_order;
  update public.local_staff_sessions set last_seen_at=now() where token=p_token;
  return v_order;
end;
$$;

create or replace function public.update_order_status_local(
  p_token uuid,
  p_order_id uuid,
  p_status public.order_status,
  p_notes text default null
)
returns public.laundry_orders
language plpgsql
security definer
set search_path=public
as $$
declare v_session public.local_staff_sessions%rowtype;v_staff public.local_staff_accounts%rowtype;v_order public.laundry_orders%rowtype;v_program public.loyalty_programs%rowtype;v_points integer:=0;v_today_count integer:=0;
begin
  select * into v_session from public.local_staff_sessions where token=p_token and revoked_at is null and expires_at>now();
  if v_session.token is null then raise exception 'Staff session is invalid or expired'; end if;
  select * into v_staff from public.local_staff_accounts where id=v_session.staff_id and active;
  if v_staff.id is null or v_staff.role not in ('manager','cashier','laundry_staff') then raise exception 'Order processing permission required'; end if;
  select * into v_order from public.laundry_orders where id=p_order_id and organization_id=v_staff.organization_id and (v_staff.branch_id is null or branch_id=v_staff.branch_id) for update;
  if v_order.id is null then raise exception 'Order not found'; end if;

  update public.laundry_orders set status=p_status,completed_at=case when p_status='completed' then coalesce(completed_at,now()) else completed_at end,updated_at=now() where id=v_order.id returning * into v_order;
  insert into public.order_status_history(order_id,status,changed_by_local_staff,notes) values(v_order.id,p_status,v_staff.id,p_notes);

  if p_status='completed' and v_order.customer_id is not null and not v_order.loyalty_awarded then
    select * into v_program from public.loyalty_programs where organization_id=v_order.organization_id and enabled;
    if v_program.id is not null and v_order.total>=v_program.minimum_order_amount then
      if v_program.earning_method='per_visit' then
        select count(*) into v_today_count from public.loyalty_transactions where customer_id=v_order.customer_id and transaction_type='earn' and reference_type='laundry_order' and created_at::date=current_date;
        if v_today_count<v_program.same_day_visit_limit then v_points:=v_program.points_per_visit; end if;
      elsif v_program.earning_method='per_spend' and coalesce(v_program.spend_amount_per_point,0)>0 then
        v_points:=floor(v_order.total/v_program.spend_amount_per_point)::integer;
      end if;
      if v_points>0 then
        insert into public.loyalty_transactions(organization_id,customer_id,branch_id,transaction_type,points,description,reference_type,reference_id,created_by_local_staff)
        values(v_order.organization_id,v_order.customer_id,v_order.branch_id,'earn',v_points,'Points earned from completed laundry order','laundry_order',v_order.id,v_staff.id);
        update public.customers set loyalty_points=loyalty_points+v_points,lifetime_points=lifetime_points+v_points,lifetime_visits=lifetime_visits+1,lifetime_spend=lifetime_spend+v_order.total,last_visit_at=now(),updated_at=now() where id=v_order.customer_id;
      else
        update public.customers set lifetime_visits=lifetime_visits+1,lifetime_spend=lifetime_spend+v_order.total,last_visit_at=now(),updated_at=now() where id=v_order.customer_id;
      end if;
      update public.laundry_orders set loyalty_awarded=true where id=v_order.id returning * into v_order;
    end if;
  end if;
  update public.local_staff_sessions set last_seen_at=now() where token=p_token;
  return v_order;
end;
$$;

grant execute on function public.get_local_staff_operational_context(uuid) to anon,authenticated;
grant execute on function public.create_customer_local(uuid,text,text,text,uuid) to anon,authenticated;
grant execute on function public.create_laundry_order_local(uuid,uuid,uuid,jsonb,numeric,text,timestamptz) to anon,authenticated;
grant execute on function public.record_order_payment_local(uuid,uuid,numeric,public.payment_method,text) to anon,authenticated;
grant execute on function public.update_order_status_local(uuid,uuid,public.order_status,text) to anon,authenticated;

commit;
