-- Sell Product & Inventory as an optional subscription add-on.
begin;
alter table public.subscription_upgrade_requests add column if not exists product_inventory_addon boolean not null default false;

create or replace function public.request_subscription_change_v3(p_request_type text,p_plan_key text default null,p_extension_days integer default null,p_billing_contact text default null,p_billing_email text default null,p_payment_method text default 'manual',p_notes text default null,p_billing_cycle text default 'monthly',p_product_inventory_addon boolean default false)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_role public.staff_role;v_id uuid;
begin
 select organization_id,role into v_org,v_role from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
 if v_org is null or v_role not in ('owner','admin') then raise exception 'Organization administrator access required'; end if;
 if p_request_type='plan_upgrade' and not exists(select 1 from public.subscription_plans where plan_key=p_plan_key and active) then raise exception 'Select a valid plan'; end if;
 if p_request_type='trial_extension' and coalesce(p_extension_days,0) not between 1 and 30 then raise exception 'Extension must be between 1 and 30 days'; end if;
 if p_billing_cycle not in ('monthly','yearly') then raise exception 'Select monthly or yearly billing'; end if;
 insert into public.subscription_upgrade_requests(organization_id,request_type,requested_plan_key,requested_extension_days,billing_contact,billing_email,payment_method,notes,requested_by,billing_cycle,product_inventory_addon) values(v_org,p_request_type,p_plan_key,p_extension_days,nullif(trim(coalesce(p_billing_contact,'')),''),nullif(trim(coalesce(p_billing_email,'')),''),p_payment_method,nullif(trim(coalesce(p_notes,'')),''),auth.uid(),case when p_request_type='plan_upgrade' then p_billing_cycle else 'monthly' end,case when p_request_type='plan_upgrade' then p_product_inventory_addon else false end) returning id into v_id;
 return v_id;
exception when unique_violation then raise exception 'A pending request of this type already exists';
end $$;

create or replace function public.review_subscription_request(p_request_id uuid,p_approve boolean,p_review_notes text default null)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_req public.subscription_upgrade_requests%rowtype;
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
 select * into v_req from public.subscription_upgrade_requests where id=p_request_id and status='pending' for update;
 if v_req.id is null then raise exception 'Pending request not found'; end if;
 if p_approve and v_req.request_type='plan_upgrade' then
  update public.organization_subscriptions set plan_key=v_req.requested_plan_key,billing_cycle=v_req.billing_cycle,status='active',billing_started_at=coalesce(billing_started_at,now()),next_billing_at=case when v_req.billing_cycle='yearly' then now()+interval '1 year' else now()+interval '1 month' end,updated_at=now(),updated_by=auth.uid() where organization_id=v_req.organization_id;
  if v_req.product_inventory_addon then
   insert into public.organization_feature_grants(organization_id,feature_key,granted,updated_by) values(v_req.organization_id,'inventory',true,auth.uid()) on conflict(organization_id,feature_key) do update set granted=true,updated_at=now(),updated_by=auth.uid();
   insert into public.organization_features(organization_id,feature_key,enabled,updated_by) values(v_req.organization_id,'inventory',true,auth.uid()) on conflict(organization_id,feature_key) do update set enabled=true,updated_at=now(),updated_by=auth.uid();
  end if;
 end if;
 if p_approve and v_req.request_type='trial_extension' then update public.organization_subscriptions set trial_ends_at=greatest(trial_ends_at,now())+make_interval(days=>v_req.requested_extension_days),status='trialing',updated_at=now(),updated_by=auth.uid() where organization_id=v_req.organization_id; end if;
 update public.subscription_upgrade_requests set status=case when p_approve then 'approved' else 'declined' end,reviewed_by=auth.uid(),reviewed_at=now(),review_notes=nullif(trim(coalesce(p_review_notes,'')),'') where id=v_req.id;
 return true;
end $$;
grant execute on function public.request_subscription_change_v3(text,text,integer,text,text,text,text,text,boolean) to authenticated;
commit;
