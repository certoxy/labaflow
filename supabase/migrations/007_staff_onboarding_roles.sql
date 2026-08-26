-- LabaFlow v0.4 staff onboarding and role permissions.

begin;

create or replace function public.get_invitation_details(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_inv public.organization_invitations%rowtype;v_org public.organizations%rowtype;v_branch public.branches%rowtype;
begin
  select * into v_inv from public.organization_invitations where token=p_token limit 1;
  if v_inv.id is null or v_inv.revoked_at is not null or v_inv.accepted_at is not null or v_inv.expires_at<=now() then
    raise exception 'Invitation is invalid or expired';
  end if;
  select * into v_org from public.organizations where id=v_inv.organization_id and active;
  if v_org.id is null then raise exception 'Organization is unavailable'; end if;
  if v_inv.branch_id is not null then select * into v_branch from public.branches where id=v_inv.branch_id; end if;
  return jsonb_build_object('email',v_inv.email,'role',v_inv.role,'organization',jsonb_build_object('id',v_org.id,'name',v_org.name,'slug',v_org.slug),'branch',case when v_branch.id is null then null else jsonb_build_object('id',v_branch.id,'name',v_branch.name,'code',v_branch.code) end,'expires_at',v_inv.expires_at);
end;
$$;

create or replace function public.get_current_access_context()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_org uuid;v_role public.staff_role;v_active boolean;v_org_active boolean;v_features jsonb;v_branches jsonb;
begin
  select m.organization_id,m.role,m.active,o.active into v_org,v_role,v_active,v_org_active
  from public.organization_memberships m join public.organizations o on o.id=m.organization_id
  where m.user_id=auth.uid() order by m.created_at limit 1;
  if v_org is null then
    return jsonb_build_object('has_membership',false,'is_platform_admin',public.is_platform_admin());
  end if;
  select coalesce(jsonb_object_agg(feature_key,enabled),'{}'::jsonb) into v_features from public.organization_features where organization_id=v_org;
  select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'name',b.name,'code',b.code) order by b.name),'[]'::jsonb) into v_branches
  from public.branches b where b.organization_id=v_org and b.active and (v_role in ('owner','admin') or exists(select 1 from public.staff_branch_assignments a where a.staff_id=auth.uid() and a.branch_id=b.id));
  return jsonb_build_object(
    'has_membership',true,
    'membership_active',v_active,
    'organization_active',v_org_active,
    'organization_id',v_org,
    'role',v_role,
    'branches',v_branches,
    'features',v_features,
    'is_platform_admin',public.is_platform_admin(),
    'permissions',jsonb_build_object(
      'manage_organization',v_role in ('owner','admin'),
      'manage_services',v_role in ('owner','admin','manager'),
      'manage_staff',v_role in ('owner','admin'),
      'manage_customers',v_role in ('owner','admin','manager','cashier'),
      'create_orders',v_role in ('owner','admin','manager','cashier'),
      'process_orders',v_role in ('owner','admin','manager','cashier','laundry_staff'),
      'record_payments',v_role in ('owner','admin','manager','cashier'),
      'delivery_access',v_role in ('owner','admin','manager','delivery_staff'),
      'view_reports',v_role in ('owner','admin','manager','auditor')
    )
  );
end;
$$;

create or replace function public.has_role_permission(p_permission text,p_branch_id uuid default null)
returns boolean
language plpgsql
stable
security definer
set search_path=public
as $$
declare v_org uuid;v_role public.staff_role;v_member_active boolean;v_org_active boolean;
begin
  select m.organization_id,m.role,m.active,o.active into v_org,v_role,v_member_active,v_org_active
  from public.organization_memberships m join public.organizations o on o.id=m.organization_id
  where m.user_id=auth.uid() order by m.created_at limit 1;
  if v_org is null or not coalesce(v_member_active,false) or not coalesce(v_org_active,false) then return false; end if;
  if p_branch_id is not null and v_role not in ('owner','admin') and not exists(select 1 from public.staff_branch_assignments where staff_id=auth.uid() and branch_id=p_branch_id) then return false; end if;
  return case p_permission
    when 'manage_organization' then v_role in ('owner','admin')
    when 'manage_services' then v_role in ('owner','admin','manager')
    when 'manage_staff' then v_role in ('owner','admin')
    when 'manage_customers' then v_role in ('owner','admin','manager','cashier')
    when 'create_orders' then v_role in ('owner','admin','manager','cashier')
    when 'process_orders' then v_role in ('owner','admin','manager','cashier','laundry_staff')
    when 'record_payments' then v_role in ('owner','admin','manager','cashier')
    when 'delivery_access' then v_role in ('owner','admin','manager','delivery_staff')
    when 'view_reports' then v_role in ('owner','admin','manager','auditor')
    else false end;
end;
$$;

-- Tighten customer writes: operational staff can read customers, but only customer-facing roles can modify them.
drop policy if exists "members manage customers" on public.customers;
create policy "members read customers" on public.customers for select to authenticated using(public.is_organization_member(organization_id));
create policy "customer roles insert customers" on public.customers for insert to authenticated with check(public.is_organization_member(organization_id) and public.has_role_permission('manage_customers',preferred_branch_id));
create policy "customer roles update customers" on public.customers for update to authenticated using(public.is_organization_member(organization_id) and public.has_role_permission('manage_customers',preferred_branch_id)) with check(public.is_organization_member(organization_id) and public.has_role_permission('manage_customers',preferred_branch_id));

-- Tighten order/payment mutation while retaining read visibility for assigned operational staff.
drop policy if exists "members manage orders" on public.laundry_orders;
create policy "assigned staff read orders" on public.laundry_orders for select to authenticated using(public.is_organization_member(organization_id) and public.can_access_branch(branch_id));
create policy "order creators insert orders" on public.laundry_orders for insert to authenticated with check(public.has_role_permission('create_orders',branch_id));
create policy "processors update orders" on public.laundry_orders for update to authenticated using(public.has_role_permission('process_orders',branch_id)) with check(public.has_role_permission('process_orders',branch_id));

drop policy if exists "members manage payments" on public.payments;
create policy "assigned staff read payments" on public.payments for select to authenticated using(public.is_organization_member(organization_id) and public.can_access_branch(branch_id));
create policy "payment roles insert payments" on public.payments for insert to authenticated with check(public.has_role_permission('record_payments',branch_id));

-- Apply permission checks inside privileged RPCs too.
create or replace function public.record_order_payment(p_order_id uuid,p_amount numeric,p_method public.payment_method,p_reference text default null)
returns public.laundry_orders language plpgsql security definer set search_path=public as $$
declare v_order public.laundry_orders%rowtype;v_new_paid numeric;
begin
  select * into v_order from laundry_orders where id=p_order_id and public.can_access_branch(branch_id) for update;
  if v_order.id is null then raise exception 'Order not found'; end if;
  if not public.has_role_permission('record_payments',v_order.branch_id) then raise exception 'Payment permission required'; end if;
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
  if not public.has_role_permission('process_orders',v_order.branch_id) then raise exception 'Order processing permission required'; end if;
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

grant execute on function public.get_invitation_details(uuid) to anon,authenticated;
grant execute on function public.get_current_access_context() to authenticated;
grant execute on function public.has_role_permission(text,uuid) to authenticated;

commit;
