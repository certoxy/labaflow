-- LabaFlow v0.2 onboarding and customer creation RPCs

begin;

create or replace function public.create_organization_with_main_branch(
  p_name text,
  p_slug text,
  p_branch_name text default 'Main Branch',
  p_branch_code text default 'MAIN'
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_user uuid := auth.uid();
  v_org public.organizations;
  v_branch public.branches;
begin
  if v_user is null then raise exception 'Authentication required'; end if;
  if exists(select 1 from public.organization_memberships where user_id=v_user and active) then
    raise exception 'User already belongs to an organization';
  end if;
  if nullif(trim(p_name),'') is null then raise exception 'Organization name is required'; end if;
  if p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception 'Invalid organization slug'; end if;

  insert into public.organizations(name,slug,created_by)
  values(trim(p_name),p_slug,v_user)
  returning * into v_org;

  insert into public.organization_memberships(organization_id,user_id,role,active)
  values(v_org.id,v_user,'owner',true);

  insert into public.branches(organization_id,code,name)
  values(v_org.id,upper(trim(p_branch_code)),trim(p_branch_name))
  returning * into v_branch;

  insert into public.staff_branch_assignments(staff_id,branch_id)
  values(v_user,v_branch.id);

  insert into public.loyalty_programs(organization_id)
  values(v_org.id);

  insert into public.organization_settings(organization_id,setting_key,setting_value)
  values
    (v_org.id,'features','{"loyalty":true,"pickup_delivery":true,"inventory":true,"expenses":true}'::jsonb),
    (v_org.id,'order_workflow','{"stages":["received","sorting","washing","drying","folding","ready","completed"]}'::jsonb);

  return jsonb_build_object('organization',to_jsonb(v_org),'branch',to_jsonb(v_branch));
end $$;

grant execute on function public.create_organization_with_main_branch(text,text,text,text) to authenticated;

create or replace function public.get_my_labaflow_context()
returns jsonb
language sql
stable
security definer
set search_path=public
as $$
  select coalesce((
    select jsonb_build_object(
      'profile',to_jsonb(p),
      'organization',to_jsonb(o),
      'membership',to_jsonb(m),
      'branches',coalesce((select jsonb_agg(to_jsonb(b) order by b.name) from branches b where b.organization_id=o.id and b.active),'[]'::jsonb),
      'loyalty_program',(select to_jsonb(lp) from loyalty_programs lp where lp.organization_id=o.id),
      'settings',coalesce((select jsonb_object_agg(s.setting_key,s.setting_value) from organization_settings s where s.organization_id=o.id),'{}'::jsonb)
    )
    from profiles p
    left join organization_memberships m on m.user_id=p.id and m.active
    left join organizations o on o.id=m.organization_id
    where p.id=auth.uid()
    limit 1
  ), '{}'::jsonb);
$$;

grant execute on function public.get_my_labaflow_context() to authenticated;

create or replace function public.create_customer_with_qr(
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
declare
  v_org uuid;
  v_customer public.customers;
  v_token public.customer_qr_tokens;
begin
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid() and active
  limit 1;
  if v_org is null then raise exception 'Active organization membership required'; end if;
  if nullif(trim(p_full_name),'') is null then raise exception 'Customer name is required'; end if;
  if p_preferred_branch_id is not null and not exists(
    select 1 from public.branches where id=p_preferred_branch_id and organization_id=v_org and active
  ) then raise exception 'Invalid branch'; end if;

  insert into public.customers(organization_id,full_name,mobile,email,preferred_branch_id)
  values(v_org,trim(p_full_name),nullif(trim(p_mobile),''),nullif(lower(trim(p_email)),''),p_preferred_branch_id)
  returning * into v_customer;

  insert into public.customer_qr_tokens(organization_id,customer_id)
  values(v_org,v_customer.id)
  returning * into v_token;

  return jsonb_build_object('customer',to_jsonb(v_customer),'qr_token',v_token.token);
end $$;

grant execute on function public.create_customer_with_qr(text,text,text,uuid) to authenticated;

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
declare
  v_org uuid;
  v_new_balance integer;
  v_type public.loyalty_transaction_type;
begin
  select organization_id into v_org from organization_memberships where user_id=auth.uid() and active limit 1;
  if v_org is null then raise exception 'Active organization membership required'; end if;
  if not exists(select 1 from customers where id=p_customer_id and organization_id=v_org) then raise exception 'Customer not found'; end if;
  if p_branch_id is not null and not exists(select 1 from branches where id=p_branch_id and organization_id=v_org) then raise exception 'Invalid branch'; end if;

  update customers
  set loyalty_points=loyalty_points+p_points,
      lifetime_points=lifetime_points+greatest(p_points,0),
      updated_at=now()
  where id=p_customer_id and organization_id=v_org and loyalty_points+p_points>=0
  returning loyalty_points into v_new_balance;
  if v_new_balance is null then raise exception 'Insufficient loyalty points'; end if;

  v_type := case when p_points >= 0 then 'adjustment'::public.loyalty_transaction_type else 'redeem'::public.loyalty_transaction_type end;
  insert into loyalty_transactions(organization_id,customer_id,branch_id,transaction_type,points,description,created_by)
  values(v_org,p_customer_id,p_branch_id,v_type,p_points,p_description,auth.uid());
  return v_new_balance;
end $$;

grant execute on function public.adjust_customer_loyalty(uuid,integer,text,uuid) to authenticated;

commit;
