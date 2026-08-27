-- LabaFlow v0.5 Organization Settings v2
-- Configurable loyalty, payment methods, order workflow, and completion rules.

begin;

create or replace function public.get_organization_business_settings()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid;
  v_loyalty jsonb;
  v_payments jsonb;
  v_workflow jsonb;
  v_completion jsonb;
begin
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid() and active and role in ('owner','admin')
  order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;

  select jsonb_build_object(
    'enabled',lp.enabled,
    'earning_method',lp.earning_method,
    'points_per_visit',lp.points_per_visit,
    'spend_amount_per_point',lp.spend_amount_per_point,
    'minimum_order_amount',lp.minimum_order_amount,
    'same_day_visit_limit',lp.same_day_visit_limit,
    'points_expiry_months',lp.points_expiry_months
  ) into v_loyalty
  from public.loyalty_programs lp where lp.organization_id=v_org;

  select coalesce(setting_value,'{"methods":["cash","gcash","maya","card","bank_transfer"]}'::jsonb)
  into v_payments from public.organization_settings where organization_id=v_org and setting_key='payment_methods';
  if v_payments is null then v_payments:='{"methods":["cash","gcash","maya","card","bank_transfer"]}'::jsonb; end if;

  select coalesce(setting_value,'{"stages":["received","sorting","washing","drying","folding","ready","completed"]}'::jsonb)
  into v_workflow from public.organization_settings where organization_id=v_org and setting_key='order_workflow';
  if v_workflow is null then v_workflow:='{"stages":["received","sorting","washing","drying","folding","ready","completed"]}'::jsonb; end if;

  select coalesce(setting_value,'{"require_full_payment_before_completion":false}'::jsonb)
  into v_completion from public.organization_settings where organization_id=v_org and setting_key='completion_rules';
  if v_completion is null then v_completion:='{"require_full_payment_before_completion":false}'::jsonb; end if;

  return jsonb_build_object('loyalty',coalesce(v_loyalty,'{}'::jsonb),'payments',v_payments,'workflow',v_workflow,'completion',v_completion);
end;
$$;

create or replace function public.save_organization_business_settings(
  p_loyalty jsonb,
  p_payment_methods jsonb,
  p_workflow_stages jsonb,
  p_completion_rules jsonb
)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid;
  v_method text;
  v_stage text;
begin
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid() and active and role in ('owner','admin')
  order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;

  if jsonb_array_length(coalesce(p_payment_methods->'methods','[]'::jsonb))=0 then
    raise exception 'At least one payment method is required';
  end if;
  for v_method in select jsonb_array_elements_text(p_payment_methods->'methods') loop
    if v_method not in ('cash','gcash','maya','card','bank_transfer') then raise exception 'Invalid payment method: %',v_method; end if;
  end loop;

  if jsonb_array_length(coalesce(p_workflow_stages->'stages','[]'::jsonb))<2 then
    raise exception 'Workflow must contain at least two stages';
  end if;
  if not (p_workflow_stages->'stages' ? 'received') or not (p_workflow_stages->'stages' ? 'completed') then
    raise exception 'Workflow must include received and completed';
  end if;
  for v_stage in select jsonb_array_elements_text(p_workflow_stages->'stages') loop
    if v_stage not in ('received','sorting','washing','drying','folding','ready','out_for_delivery','completed','on_hold','cancelled') then raise exception 'Invalid workflow stage: %',v_stage; end if;
  end loop;

  update public.loyalty_programs set
    enabled=coalesce((p_loyalty->>'enabled')::boolean,true),
    earning_method=coalesce(p_loyalty->>'earning_method','per_visit'),
    points_per_visit=greatest(coalesce((p_loyalty->>'points_per_visit')::integer,10),0),
    spend_amount_per_point=nullif((p_loyalty->>'spend_amount_per_point')::numeric,0),
    minimum_order_amount=greatest(coalesce((p_loyalty->>'minimum_order_amount')::numeric,0),0),
    same_day_visit_limit=greatest(coalesce((p_loyalty->>'same_day_visit_limit')::integer,1),0),
    points_expiry_months=nullif((p_loyalty->>'points_expiry_months')::integer,0),
    updated_at=now()
  where organization_id=v_org;

  insert into public.organization_settings(organization_id,setting_key,setting_value,updated_at)
  values
    (v_org,'payment_methods',p_payment_methods,now()),
    (v_org,'order_workflow',p_workflow_stages,now()),
    (v_org,'completion_rules',p_completion_rules,now())
  on conflict(organization_id,setting_key) do update set setting_value=excluded.setting_value,updated_at=now();

  return true;
end;
$$;

create or replace function public.get_current_access_context()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_org uuid;v_role public.staff_role;v_active boolean;v_org_active boolean;v_features jsonb;v_branches jsonb;v_settings jsonb;
begin
  select m.organization_id,m.role,m.active,o.active into v_org,v_role,v_active,v_org_active
  from public.organization_memberships m join public.organizations o on o.id=m.organization_id
  where m.user_id=auth.uid() order by m.created_at limit 1;
  if v_org is null then return jsonb_build_object('has_membership',false,'is_platform_admin',public.is_platform_admin()); end if;
  select coalesce(jsonb_object_agg(feature_key,enabled),'{}'::jsonb) into v_features from public.organization_features where organization_id=v_org;
  select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'name',b.name,'code',b.code,'address',b.address) order by b.name),'[]'::jsonb) into v_branches
  from public.branches b where b.organization_id=v_org and b.active and (v_role in ('owner','admin') or exists(select 1 from public.staff_branch_assignments a where a.staff_id=auth.uid() and a.branch_id=b.id));
  select coalesce(jsonb_object_agg(setting_key,setting_value),'{}'::jsonb) into v_settings from public.organization_settings where organization_id=v_org;
  return jsonb_build_object(
    'has_membership',true,'membership_active',v_active,'organization_active',v_org_active,'organization_id',v_org,'role',v_role,
    'branches',v_branches,'features',v_features,'settings',v_settings,'is_platform_admin',public.is_platform_admin(),
    'permissions',jsonb_build_object(
      'manage_organization',v_role in ('owner','admin'),'manage_services',v_role in ('owner','admin','manager'),'manage_staff',v_role in ('owner','admin'),
      'manage_customers',v_role in ('owner','admin','manager','cashier'),'adjust_loyalty',v_role in ('owner','admin','manager'),
      'create_orders',v_role in ('owner','admin','manager','cashier'),'process_orders',v_role in ('owner','admin','manager','cashier','laundry_staff'),
      'record_payments',v_role in ('owner','admin','manager','cashier'),'delivery_access',v_role in ('owner','admin','manager','delivery_staff'),
      'view_reports',v_role in ('owner','admin','manager','auditor')
    )
  );
end;
$$;

create or replace function public.record_order_payment(p_order_id uuid,p_amount numeric,p_method public.payment_method,p_reference text default null)
returns public.laundry_orders language plpgsql security definer set search_path=public as $$
declare v_order public.laundry_orders%rowtype;v_new_paid numeric;v_methods jsonb;
begin
  select * into v_order from laundry_orders where id=p_order_id and public.can_access_branch(branch_id) for update;
  if v_order.id is null then raise exception 'Order not found'; end if;
  if not public.has_role_permission('record_payments',v_order.branch_id) then raise exception 'Payment permission required'; end if;
  select setting_value into v_methods from organization_settings where organization_id=v_order.organization_id and setting_key='payment_methods';
  if v_methods is not null and not (v_methods->'methods' ? p_method::text) then raise exception 'Payment method is disabled for this organization'; end if;
  if p_amount<=0 then raise exception 'Payment must be greater than zero'; end if;
  insert into payments(organization_id,branch_id,order_id,amount,method,reference,received_by) values(v_order.organization_id,v_order.branch_id,v_order.id,p_amount,p_method,p_reference,auth.uid());
  v_new_paid:=v_order.amount_paid+p_amount;
  update laundry_orders set amount_paid=v_new_paid,payment_status=case when v_new_paid>=total then 'paid'::payment_status when v_new_paid>0 then 'partial'::payment_status else 'unpaid'::payment_status end,updated_at=now() where id=v_order.id returning * into v_order;
  return v_order;
end $$;

create or replace function public.update_order_status(p_order_id uuid,p_status public.order_status,p_notes text default null)
returns public.laundry_orders language plpgsql security definer set search_path=public as $$
declare v_order public.laundry_orders%rowtype;v_program public.loyalty_programs%rowtype;v_points integer:=0;v_today_count integer:=0;v_workflow jsonb;v_completion jsonb;
begin
  select * into v_order from laundry_orders where id=p_order_id and public.can_access_branch(branch_id) for update;
  if v_order.id is null then raise exception 'Order not found'; end if;
  if not public.has_role_permission('process_orders',v_order.branch_id) then raise exception 'Order processing permission required'; end if;
  select setting_value into v_workflow from organization_settings where organization_id=v_order.organization_id and setting_key='order_workflow';
  if v_workflow is not null and not (v_workflow->'stages' ? p_status::text) and p_status not in ('cancelled','on_hold') then raise exception 'Order status is disabled for this organization'; end if;
  select setting_value into v_completion from organization_settings where organization_id=v_order.organization_id and setting_key='completion_rules';
  if p_status='completed' and coalesce((v_completion->>'require_full_payment_before_completion')::boolean,false) and v_order.amount_paid<v_order.total then
    raise exception 'Full payment is required before completing this order';
  end if;
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
        insert into loyalty_transactions(organization_id,customer_id,branch_id,transaction_type,points,description,reference_type,reference_id,created_by)
        values(v_order.organization_id,v_order.customer_id,v_order.branch_id,'earn',v_points,'Points earned from completed laundry order','laundry_order',v_order.id,auth.uid());
        update customers set loyalty_points=loyalty_points+v_points,lifetime_points=lifetime_points+v_points,lifetime_visits=lifetime_visits+1,lifetime_spend=lifetime_spend+v_order.total,last_visit_at=now(),updated_at=now() where id=v_order.customer_id;
      else
        update customers set lifetime_visits=lifetime_visits+1,lifetime_spend=lifetime_spend+v_order.total,last_visit_at=now(),updated_at=now() where id=v_order.customer_id;
      end if;
      update laundry_orders set loyalty_awarded=true where id=v_order.id returning * into v_order;
    end if;
  end if;
  return v_order;
end $$;

grant execute on function public.get_organization_business_settings() to authenticated;
grant execute on function public.save_organization_business_settings(jsonb,jsonb,jsonb,jsonb) to authenticated;
grant execute on function public.get_current_access_context() to authenticated;

commit;
