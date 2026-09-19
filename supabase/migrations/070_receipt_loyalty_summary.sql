-- Include order-specific loyalty activity and the customer's current balance
-- in local-staff receipt data.
begin;

create or replace function public.get_local_staff_order_checkout(
  p_token uuid,
  p_order_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_session public.local_staff_sessions%rowtype;
  v_staff public.local_staff_accounts%rowtype;
  v_order public.laundry_orders%rowtype;
  v_customer public.customers%rowtype;
  v_branch public.branches%rowtype;
  v_points_earned integer := 0;
  v_points_used integer := 0;
begin
  select * into v_session
  from public.local_staff_sessions
  where token=p_token and revoked_at is null and expires_at>now();

  if v_session.token is null then raise exception 'Staff session is invalid or expired'; end if;

  select * into v_staff
  from public.local_staff_accounts
  where id=v_session.staff_id and active;

  if v_staff.id is null then raise exception 'Staff access is no longer active'; end if;

  select * into v_order
  from public.laundry_orders
  where id=p_order_id
    and organization_id=v_staff.organization_id
    and (v_staff.branch_id is null or branch_id=v_staff.branch_id);

  if v_order.id is null then raise exception 'Order not found in your current branch access'; end if;

  select * into v_customer from public.customers where id=v_order.customer_id;
  select * into v_branch from public.branches where id=v_order.branch_id;

  select
    coalesce(sum(case when transaction_type='earn' and points>0 then points else 0 end),0)::integer,
    coalesce(sum(case when transaction_type='redeem' and points<0 then abs(points) else 0 end),0)::integer
  into v_points_earned,v_points_used
  from public.loyalty_transactions
  where reference_type='laundry_order' and reference_id=v_order.id;

  update public.local_staff_sessions set last_seen_at=now() where token=p_token;

  return jsonb_build_object(
    'order',jsonb_build_object(
      'id',v_order.id,'order_code',v_order.order_code,'branch_id',v_order.branch_id,
      'customer_id',v_order.customer_id,'status',v_order.status,'payment_status',v_order.payment_status,
      'subtotal',v_order.subtotal,'discount',v_order.discount,'total',v_order.total,
      'amount_paid',v_order.amount_paid,'loyalty_points_redeemed',v_order.loyalty_points_redeemed,
      'notes',v_order.notes,'created_at',v_order.created_at,
      'customers',case when v_customer.id is null then null else jsonb_build_object(
        'full_name',v_customer.full_name,'customer_code',v_customer.customer_code,
        'loyalty_points',v_customer.loyalty_points
      ) end,
      'branch',case when v_branch.id is null then null else jsonb_build_object(
        'id',v_branch.id,'name',v_branch.name,'code',v_branch.code,
        'address',v_branch.address,'phone',v_branch.phone
      ) end
    ),
    'loyalty',jsonb_build_object(
      'earned',v_points_earned,
      'used',greatest(v_points_used,coalesce(v_order.loyalty_points_redeemed,0)),
      'balance',coalesce(v_customer.loyalty_points,0)
    ),
    'items',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',i.id,'service_id',i.service_id,'service_name',s.name,'pricing_unit',s.pricing_unit,
        'quantity',i.quantity,'unit_price',i.unit_price,'line_total',i.line_total,'notes',i.notes
      ) order by i.created_at)
      from public.laundry_order_items i join public.services s on s.id=i.service_id
      where i.order_id=v_order.id
    ),'[]'::jsonb),
    'payments',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',p.id,'amount',p.amount,'method',p.method,'reference',p.reference,'created_at',p.created_at
      ) order by p.created_at)
      from public.payments p where p.order_id=v_order.id
    ),'[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_local_staff_order_checkout(uuid,uuid) from public;
grant execute on function public.get_local_staff_order_checkout(uuid,uuid) to anon,authenticated;

commit;
