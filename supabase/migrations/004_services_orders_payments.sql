-- LabaFlow v0.2 services, pricing, laundry orders, payments, and automatic loyalty.

begin;

create type public.pricing_unit as enum ('kg','piece','load','package');
create type public.order_status as enum ('received','sorting','washing','drying','folding','ready','completed','cancelled','on_hold','out_for_delivery');
create type public.payment_method as enum ('cash','gcash','maya','card','bank_transfer');
create type public.payment_status as enum ('unpaid','partial','paid','refunded');

create table public.services (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  description text,
  pricing_unit public.pricing_unit not null default 'kg',
  default_price numeric(12,2) not null default 0 check(default_price >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,name)
);

create table public.branch_service_prices (
  branch_id uuid not null references public.branches(id) on delete cascade,
  service_id uuid not null references public.services(id) on delete cascade,
  price numeric(12,2) not null check(price >= 0),
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key(branch_id,service_id)
);

create sequence public.laundry_order_number_seq start 1001;

create table public.laundry_orders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null references public.branches(id),
  customer_id uuid references public.customers(id),
  order_number bigint not null default nextval('public.laundry_order_number_seq'),
  order_code text generated always as ('LF-O-' || lpad(order_number::text,8,'0')) stored,
  status public.order_status not null default 'received',
  payment_status public.payment_status not null default 'unpaid',
  subtotal numeric(12,2) not null default 0,
  discount numeric(12,2) not null default 0 check(discount >= 0),
  total numeric(12,2) not null default 0,
  amount_paid numeric(12,2) not null default 0,
  notes text,
  due_at timestamptz,
  completed_at timestamptz,
  loyalty_awarded boolean not null default false,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,order_number),
  unique(organization_id,order_code)
);

create table public.laundry_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.laundry_orders(id) on delete cascade,
  service_id uuid not null references public.services(id),
  quantity numeric(12,2) not null check(quantity > 0),
  unit_price numeric(12,2) not null check(unit_price >= 0),
  line_total numeric(12,2) generated always as (quantity * unit_price) stored,
  notes text,
  created_at timestamptz not null default now()
);

create table public.order_status_history (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.laundry_orders(id) on delete cascade,
  status public.order_status not null,
  notes text,
  changed_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null references public.branches(id),
  order_id uuid not null references public.laundry_orders(id) on delete cascade,
  amount numeric(12,2) not null check(amount > 0),
  method public.payment_method not null,
  reference text,
  received_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create index services_org_idx on public.services(organization_id,active,name);
create index orders_org_created_idx on public.laundry_orders(organization_id,created_at desc);
create index orders_branch_status_idx on public.laundry_orders(branch_id,status,created_at desc);
create index order_items_order_idx on public.laundry_order_items(order_id);
create index payments_order_idx on public.payments(order_id,created_at desc);

alter table public.services enable row level security;
alter table public.branch_service_prices enable row level security;
alter table public.laundry_orders enable row level security;
alter table public.laundry_order_items enable row level security;
alter table public.order_status_history enable row level security;
alter table public.payments enable row level security;

create policy "members read services" on public.services for select to authenticated using(public.is_organization_member(organization_id));
create policy "admins manage services" on public.services for all to authenticated using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));
create policy "members read branch service prices" on public.branch_service_prices for select to authenticated using(public.can_access_branch(branch_id));
create policy "admins manage branch service prices" on public.branch_service_prices for all to authenticated using(exists(select 1 from public.branches b where b.id=branch_id and public.is_organization_admin(b.organization_id))) with check(exists(select 1 from public.branches b join public.services s on s.id=service_id and s.organization_id=b.organization_id where b.id=branch_id and public.is_organization_admin(b.organization_id)));
create policy "members manage orders" on public.laundry_orders for all to authenticated using(public.is_organization_member(organization_id) and public.can_access_branch(branch_id)) with check(public.is_organization_member(organization_id) and public.can_access_branch(branch_id));
create policy "members manage order items" on public.laundry_order_items for all to authenticated using(exists(select 1 from public.laundry_orders o where o.id=order_id and public.is_organization_member(o.organization_id))) with check(exists(select 1 from public.laundry_orders o join public.services s on s.id=service_id and s.organization_id=o.organization_id where o.id=order_id and public.is_organization_member(o.organization_id)));
create policy "members read status history" on public.order_status_history for select to authenticated using(exists(select 1 from public.laundry_orders o where o.id=order_id and public.is_organization_member(o.organization_id)));
create policy "members manage payments" on public.payments for all to authenticated using(public.is_organization_member(organization_id) and public.can_access_branch(branch_id)) with check(public.is_organization_member(organization_id) and public.can_access_branch(branch_id));

create or replace function public.create_laundry_service(p_name text,p_description text,p_pricing_unit public.pricing_unit,p_default_price numeric)
returns public.services language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_service public.services%rowtype;
begin
  select organization_id into v_org from organization_memberships where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1;
  if v_org is null then raise exception 'Administrator access required'; end if;
  insert into services(organization_id,name,description,pricing_unit,default_price) values(v_org,trim(p_name),nullif(trim(coalesce(p_description,'')),''),p_pricing_unit,p_default_price) returning * into v_service;
  return v_service;
end $$;

create or replace function public.create_laundry_order(p_branch_id uuid,p_customer_id uuid,p_items jsonb,p_discount numeric default 0,p_notes text default null,p_due_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_order public.laundry_orders%rowtype;v_item jsonb;v_service public.services%rowtype;v_qty numeric;v_price numeric;v_subtotal numeric:=0;
begin
  select organization_id into v_org from branches where id=p_branch_id and public.can_access_branch(id);
  if v_org is null then raise exception 'Branch access denied'; end if;
  if p_customer_id is not null and not exists(select 1 from customers where id=p_customer_id and organization_id=v_org and active) then raise exception 'Customer is invalid'; end if;
  if jsonb_array_length(coalesce(p_items,'[]'::jsonb))=0 then raise exception 'Add at least one service'; end if;
  insert into laundry_orders(organization_id,branch_id,customer_id,discount,notes,due_at,created_by) values(v_org,p_branch_id,p_customer_id,greatest(coalesce(p_discount,0),0),p_notes,p_due_at,auth.uid()) returning * into v_order;
  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_service from services where id=(v_item->>'service_id')::uuid and organization_id=v_org and active;
    if v_service.id is null then raise exception 'Service is invalid'; end if;
    v_qty:=greatest((v_item->>'quantity')::numeric,0);
    if v_qty<=0 then raise exception 'Quantity must be greater than zero'; end if;
    select coalesce((select price from branch_service_prices where branch_id=p_branch_id and service_id=v_service.id and active),v_service.default_price) into v_price;
    insert into laundry_order_items(order_id,service_id,quantity,unit_price,notes) values(v_order.id,v_service.id,v_qty,v_price,v_item->>'notes');
    v_subtotal:=v_subtotal+(v_qty*v_price);
  end loop;
  update laundry_orders set subtotal=v_subtotal,total=greatest(v_subtotal-greatest(coalesce(p_discount,0),0),0),updated_at=now() where id=v_order.id returning * into v_order;
  insert into order_status_history(order_id,status,changed_by,notes) values(v_order.id,'received',auth.uid(),'Order created');
  return to_jsonb(v_order);
end $$;

create or replace function public.record_order_payment(p_order_id uuid,p_amount numeric,p_method public.payment_method,p_reference text default null)
returns public.laundry_orders language plpgsql security definer set search_path=public as $$
declare v_order public.laundry_orders%rowtype;v_new_paid numeric;
begin
  select * into v_order from laundry_orders where id=p_order_id and public.can_access_branch(branch_id) for update;
  if v_order.id is null then raise exception 'Order not found'; end if;
  if p_amount<=0 then raise exception 'Payment must be greater than zero'; end if;
  insert into payments(organization_id,branch_id,order_id,amount,method,reference,received_by) values(v_order.organization_id,v_order.branch_id,v_order.id,p_amount,p_method,p_reference,auth.uid());
  v_new_paid:=v_order.amount_paid+p_amount;
  update laundry_orders set amount_paid=v_new_paid,payment_status=case when v_new_paid>=total then 'paid'::payment_status when v_new_paid>0 then 'partial'::payment_status else 'unpaid'::payment_status end,updated_at=now() where id=v_order.id returning * into v_order;
  return v_order;
end $$;

create or replace function public.update_order_status(p_order_id uuid,p_status public.order_status,p_notes text default null)
returns public.laundry_orders language plpgsql security definer set search_path=public as $$
declare v_order public.laundry_orders%rowtype;v_program public.loyalty_programs%rowtype;v_points integer:=0;v_today_count integer:=0;
begin
  select * into v_order from laundry_orders where id=p_order_id and public.can_access_branch(branch_id) for update;
  if v_order.id is null then raise exception 'Order not found'; end if;
  update laundry_orders set status=p_status,completed_at=case when p_status='completed' then coalesce(completed_at,now()) else completed_at end,updated_at=now() where id=v_order.id returning * into v_order;
  insert into order_status_history(order_id,status,changed_by,notes) values(v_order.id,p_status,auth.uid(),p_notes);
  if p_status='completed' and v_order.customer_id is not null and not v_order.loyalty_awarded then
    select * into v_program from loyalty_programs where organization_id=v_order.organization_id and enabled;
    if v_program.id is not null and v_order.total>=v_program.minimum_order_amount then
      if v_program.earning_method='per_visit' then
        select count(*) into v_today_count from loyalty_transactions where customer_id=v_order.customer_id and transaction_type='earn' and reference_type='laundry_order' and created_at::date=current_date;
        if v_today_count<v_program.same_day_visit_limit then v_points:=v_program.points_per_visit; end if;
      elsif v_program.earning_method='per_spend' and coalesce(v_program.spend_amount_per_point,0)>0 then
        v_points:=floor(v_order.total/v_program.spend_amount_per_point)::integer;
      end if;
      if v_points>0 then
        insert into loyalty_transactions(organization_id,customer_id,branch_id,transaction_type,points,description,reference_type,reference_id,created_by) values(v_order.organization_id,v_order.customer_id,v_order.branch_id,'earn',v_points,'Points earned from completed laundry order','laundry_order',v_order.id,auth.uid());
        update customers set loyalty_points=loyalty_points+v_points,lifetime_points=lifetime_points+v_points,lifetime_visits=lifetime_visits+1,lifetime_spend=lifetime_spend+v_order.total,last_visit_at=now(),updated_at=now() where id=v_order.customer_id;
      else
        update customers set lifetime_visits=lifetime_visits+1,lifetime_spend=lifetime_spend+v_order.total,last_visit_at=now(),updated_at=now() where id=v_order.customer_id;
      end if;
      update laundry_orders set loyalty_awarded=true where id=v_order.id returning * into v_order;
    end if;
  end if;
  return v_order;
end $$;

grant execute on function public.create_laundry_service(text,text,public.pricing_unit,numeric) to authenticated;
grant execute on function public.create_laundry_order(uuid,uuid,jsonb,numeric,text,timestamptz) to authenticated;
grant execute on function public.record_order_payment(uuid,numeric,public.payment_method,text) to authenticated;
grant execute on function public.update_order_status(uuid,public.order_status,text) to authenticated;

commit;
