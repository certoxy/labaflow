-- LabaFlow: enable QR Ph as a first-class payment method.

alter type public.payment_method add value if not exists 'qrph';

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
    if v_method not in ('cash','gcash','maya','card','bank_transfer','qrph') then
      raise exception 'Invalid payment method: %',v_method;
    end if;
  end loop;

  if jsonb_array_length(coalesce(p_workflow_stages->'stages','[]'::jsonb))<2 then
    raise exception 'Workflow must contain at least two stages';
  end if;
  if not (p_workflow_stages->'stages' ? 'received') or not (p_workflow_stages->'stages' ? 'completed') then
    raise exception 'Workflow must include received and completed';
  end if;
  for v_stage in select jsonb_array_elements_text(p_workflow_stages->'stages') loop
    if v_stage not in ('received','sorting','washing','drying','folding','ready','out_for_delivery','completed','on_hold','cancelled') then
      raise exception 'Invalid workflow stage: %',v_stage;
    end if;
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
  on conflict(organization_id,setting_key)
  do update set setting_value=excluded.setting_value,updated_at=now();

  return true;
end;
$$;

grant execute on function public.save_organization_business_settings(jsonb,jsonb,jsonb,jsonb) to authenticated;
