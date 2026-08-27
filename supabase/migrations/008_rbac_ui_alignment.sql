-- LabaFlow v0.4.1 RBAC alignment for role-aware UI and privileged actions.

begin;

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
  select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'name',b.name,'code',b.code,'address',b.address) order by b.name),'[]'::jsonb) into v_branches
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
      'adjust_loyalty',v_role in ('owner','admin','manager'),
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
    when 'adjust_loyalty' then v_role in ('owner','admin','manager')
    when 'create_orders' then v_role in ('owner','admin','manager','cashier')
    when 'process_orders' then v_role in ('owner','admin','manager','cashier','laundry_staff')
    when 'record_payments' then v_role in ('owner','admin','manager','cashier')
    when 'delivery_access' then v_role in ('owner','admin','manager','delivery_staff')
    when 'view_reports' then v_role in ('owner','admin','manager','auditor')
    else false end;
end;
$$;

-- Managers can maintain the service catalog as defined by the permission matrix.
drop policy if exists "admins manage services" on public.services;
create policy "service managers insert services" on public.services for insert to authenticated
  with check(public.is_organization_member(organization_id) and public.has_role_permission('manage_services'));
create policy "service managers update services" on public.services for update to authenticated
  using(public.is_organization_member(organization_id) and public.has_role_permission('manage_services'))
  with check(public.is_organization_member(organization_id) and public.has_role_permission('manage_services'));
create policy "service managers delete services" on public.services for delete to authenticated
  using(public.is_organization_member(organization_id) and public.has_role_permission('manage_services'));

create or replace function public.create_laundry_service(p_name text,p_description text,p_pricing_unit public.pricing_unit,p_default_price numeric)
returns public.services language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_service public.services%rowtype;
begin
  select organization_id into v_org from organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
  if v_org is null or not public.has_role_permission('manage_services') then raise exception 'Service management permission required'; end if;
  insert into services(organization_id,name,description,pricing_unit,default_price)
  values(v_org,trim(p_name),nullif(trim(coalesce(p_description,'')),''),p_pricing_unit,p_default_price)
  returning * into v_service;
  return v_service;
end $$;

create or replace function public.adjust_customer_loyalty(
  p_customer_id uuid,
  p_points integer,
  p_description text default null,
  p_branch_id uuid default null
)
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare v_org uuid;v_new_balance integer;v_type public.loyalty_transaction_type;
begin
  select organization_id into v_org from organization_memberships where user_id=auth.uid() and active limit 1;
  if v_org is null then raise exception 'Active organization membership required'; end if;
  if not public.has_role_permission('adjust_loyalty',p_branch_id) then raise exception 'Loyalty adjustment permission required'; end if;
  if not exists(select 1 from customers where id=p_customer_id and organization_id=v_org) then raise exception 'Customer not found'; end if;
  if p_branch_id is not null and not exists(select 1 from branches where id=p_branch_id and organization_id=v_org) then raise exception 'Invalid branch'; end if;
  update customers set loyalty_points=loyalty_points+p_points,lifetime_points=lifetime_points+greatest(p_points,0),updated_at=now()
  where id=p_customer_id and organization_id=v_org and loyalty_points+p_points>=0
  returning loyalty_points into v_new_balance;
  if v_new_balance is null then raise exception 'Insufficient loyalty points'; end if;
  v_type:=case when p_points>=0 then 'adjustment'::public.loyalty_transaction_type else 'redeem'::public.loyalty_transaction_type end;
  insert into loyalty_transactions(organization_id,customer_id,branch_id,transaction_type,points,description,created_by)
  values(v_org,p_customer_id,p_branch_id,v_type,p_points,p_description,auth.uid());
  return v_new_balance;
end $$;

grant execute on function public.get_current_access_context() to authenticated;
grant execute on function public.has_role_permission(text,uuid) to authenticated;
grant execute on function public.create_laundry_service(text,text,public.pricing_unit,numeric) to authenticated;
grant execute on function public.adjust_customer_loyalty(uuid,integer,text,uuid) to authenticated;

commit;
