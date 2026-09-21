-- Award per-service loyalty points for every ordered pricing unit and keep an
-- immutable snapshot on each order line for accurate historical receipts.
begin;

alter table public.laundry_order_items
  add column if not exists loyalty_points_per_unit integer not null default 0 check (loyalty_points_per_unit >= 0),
  add column if not exists loyalty_points_earned integer not null default 0 check (loyalty_points_earned >= 0);

create or replace function public.set_order_item_loyalty_snapshot()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  if tg_op='INSERT' or new.service_id is distinct from old.service_id then
    select coalesce(s.loyalty_points,0)
    into new.loyalty_points_per_unit
    from public.services s
    where s.id=new.service_id;
  end if;

  new.loyalty_points_per_unit:=greatest(coalesce(new.loyalty_points_per_unit,0),0);
  new.loyalty_points_earned:=greatest(floor(coalesce(new.quantity,0)*new.loyalty_points_per_unit)::integer,0);
  return new;
end;
$$;

drop trigger if exists set_order_item_loyalty_snapshot_trigger on public.laundry_order_items;
create trigger set_order_item_loyalty_snapshot_trigger
before insert or update of service_id,quantity
on public.laundry_order_items
for each row execute function public.set_order_item_loyalty_snapshot();

-- Seed snapshots for existing lines. Future service-setting changes will not
-- rewrite these values, so historical receipts remain stable.
update public.laundry_order_items i
set loyalty_points_per_unit=coalesce(s.loyalty_points,0),
    loyalty_points_earned=greatest(floor(i.quantity*coalesce(s.loyalty_points,0))::integer,0)
from public.services s
where s.id=i.service_id;

create or replace function public.award_paid_order_loyalty(p_order_id uuid)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare
  v_order public.laundry_orders%rowtype;
  v_program public.loyalty_programs%rowtype;
  v_points integer := 0;
  v_today_count integer := 0;
begin
  select * into v_order from public.laundry_orders where id=p_order_id for update;
  if v_order.id is null then raise exception 'Order not found'; end if;
  if v_order.amount_paid < v_order.total then return 0; end if;

  if exists(select 1 from public.loyalty_transactions where reference_type='laundry_order' and reference_id=v_order.id and transaction_type='earn') then
    update public.laundry_orders set loyalty_awarded=true,updated_at=now() where id=v_order.id;
    return 0;
  end if;
  if v_order.customer_id is null then
    update public.laundry_orders set loyalty_awarded=true,updated_at=now() where id=v_order.id;
    return 0;
  end if;

  select * into v_program from public.loyalty_programs where organization_id=v_order.organization_id;
  if v_program.id is not null and v_program.enabled and v_order.total>=v_program.minimum_order_amount then
    if v_program.earning_method='per_visit' then
      select count(*) into v_today_count from public.loyalty_transactions
      where customer_id=v_order.customer_id and transaction_type='earn' and reference_type='laundry_order' and created_at::date=current_date;
      if v_today_count<v_program.same_day_visit_limit then v_points:=v_program.points_per_visit; end if;
    elsif v_program.earning_method='per_spend' and coalesce(v_program.spend_amount_per_point,0)>0 then
      v_points:=floor(v_order.total/v_program.spend_amount_per_point)::integer;
    elsif v_program.earning_method='per_service' then
      select coalesce(sum(i.loyalty_points_earned),0)::integer into v_points
      from public.laundry_order_items i where i.order_id=v_order.id;
    end if;
  end if;

  if v_points>0 then
    insert into public.loyalty_transactions(organization_id,customer_id,branch_id,transaction_type,points,description,reference_type,reference_id,created_by)
    values(v_order.organization_id,v_order.customer_id,v_order.branch_id,'earn',v_points,'Points earned from fully paid laundry order','laundry_order',v_order.id,auth.uid())
    on conflict do nothing;
    if found then
      update public.customers set loyalty_points=coalesce(loyalty_points,0)+v_points,lifetime_points=coalesce(lifetime_points,0)+v_points,
        lifetime_visits=coalesce(lifetime_visits,0)+1,lifetime_spend=coalesce(lifetime_spend,0)+v_order.total,last_visit_at=now(),updated_at=now()
      where id=v_order.customer_id;
    end if;
  else
    update public.customers set lifetime_visits=coalesce(lifetime_visits,0)+1,lifetime_spend=coalesce(lifetime_spend,0)+v_order.total,last_visit_at=now(),updated_at=now()
    where id=v_order.customer_id and not v_order.loyalty_awarded;
  end if;
  update public.laundry_orders set loyalty_awarded=true,updated_at=now() where id=v_order.id;
  return v_points;
end;
$$;

create or replace function public.update_order_status_local(p_token uuid,p_order_id uuid,p_status public.order_status,p_notes text default null)
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
      elsif v_program.earning_method='per_service' then
        select coalesce(sum(i.loyalty_points_earned),0)::integer into v_points from public.laundry_order_items i where i.order_id=v_order.id;
      end if;
      if v_points>0 then
        insert into public.loyalty_transactions(organization_id,customer_id,branch_id,transaction_type,points,description,reference_type,reference_id,created_by_local_staff)
        values(v_order.organization_id,v_order.customer_id,v_order.branch_id,'earn',v_points,'Points earned from completed laundry order','laundry_order',v_order.id,v_staff.id)
        on conflict do nothing;
        if found then
          update public.customers set loyalty_points=coalesce(loyalty_points,0)+v_points,lifetime_points=coalesce(lifetime_points,0)+v_points,lifetime_visits=coalesce(lifetime_visits,0)+1,lifetime_spend=coalesce(lifetime_spend,0)+v_order.total,last_visit_at=now(),updated_at=now() where id=v_order.customer_id;
        end if;
      else
        update public.customers set lifetime_visits=coalesce(lifetime_visits,0)+1,lifetime_spend=coalesce(lifetime_spend,0)+v_order.total,last_visit_at=now(),updated_at=now() where id=v_order.customer_id;
      end if;
      update public.laundry_orders set loyalty_awarded=true where id=v_order.id returning * into v_order;
    end if;
  end if;
  update public.local_staff_sessions set last_seen_at=now() where token=p_token;
  return v_order;
end;
$$;

create or replace function public.get_local_staff_order_checkout(p_token uuid,p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_session public.local_staff_sessions%rowtype;v_staff public.local_staff_accounts%rowtype;v_order public.laundry_orders%rowtype;v_customer public.customers%rowtype;v_branch public.branches%rowtype;v_points_earned integer:=0;v_points_used integer:=0;
begin
  select * into v_session from public.local_staff_sessions where token=p_token and revoked_at is null and expires_at>now();
  if v_session.token is null then raise exception 'Staff session is invalid or expired'; end if;
  select * into v_staff from public.local_staff_accounts where id=v_session.staff_id and active;
  if v_staff.id is null then raise exception 'Staff access is no longer active'; end if;
  select * into v_order from public.laundry_orders where id=p_order_id and organization_id=v_staff.organization_id and (v_staff.branch_id is null or branch_id=v_staff.branch_id);
  if v_order.id is null then raise exception 'Order not found in your current branch access'; end if;
  select * into v_customer from public.customers where id=v_order.customer_id;
  select * into v_branch from public.branches where id=v_order.branch_id;
  select coalesce(sum(case when transaction_type='earn' and points>0 then points else 0 end),0)::integer,coalesce(sum(case when transaction_type='redeem' and points<0 then abs(points) else 0 end),0)::integer
  into v_points_earned,v_points_used from public.loyalty_transactions where reference_type='laundry_order' and reference_id=v_order.id;
  update public.local_staff_sessions set last_seen_at=now() where token=p_token;
  return jsonb_build_object(
    'order',jsonb_build_object('id',v_order.id,'order_code',v_order.order_code,'branch_id',v_order.branch_id,'customer_id',v_order.customer_id,'status',v_order.status,'payment_status',v_order.payment_status,'subtotal',v_order.subtotal,'discount',v_order.discount,'total',v_order.total,'amount_paid',v_order.amount_paid,'loyalty_points_redeemed',v_order.loyalty_points_redeemed,'notes',v_order.notes,'created_at',v_order.created_at,
      'customers',case when v_customer.id is null then null else jsonb_build_object('full_name',v_customer.full_name,'customer_code',v_customer.customer_code,'loyalty_points',v_customer.loyalty_points) end,
      'branch',case when v_branch.id is null then null else jsonb_build_object('id',v_branch.id,'name',v_branch.name,'code',v_branch.code,'address',v_branch.address,'phone',v_branch.phone) end),
    'loyalty',jsonb_build_object('earned',v_points_earned,'used',greatest(v_points_used,coalesce(v_order.loyalty_points_redeemed,0)),'balance',coalesce(v_customer.loyalty_points,0)),
    'items',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'service_id',i.service_id,'service_name',s.name,'pricing_unit',s.pricing_unit,'quantity',i.quantity,'unit_price',i.unit_price,'line_total',i.line_total,'notes',i.notes,'loyalty_points_per_unit',i.loyalty_points_per_unit,'loyalty_points_earned',i.loyalty_points_earned) order by i.created_at) from public.laundry_order_items i join public.services s on s.id=i.service_id where i.order_id=v_order.id),'[]'::jsonb),
    'payments',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'amount',p.amount,'method',p.method,'reference',p.reference,'created_at',p.created_at) order by p.created_at) from public.payments p where p.order_id=v_order.id),'[]'::jsonb)
  );
end;
$$;

grant execute on function public.award_paid_order_loyalty(uuid) to authenticated;
grant execute on function public.update_order_status_local(uuid,uuid,public.order_status,text) to anon,authenticated;
revoke all on function public.get_local_staff_order_checkout(uuid,uuid) from public;
grant execute on function public.get_local_staff_order_checkout(uuid,uuid) to anon,authenticated;

commit;
