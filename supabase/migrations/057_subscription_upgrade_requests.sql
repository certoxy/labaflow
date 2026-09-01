-- Managed plan upgrades and trial-extension requests.
begin;
create table public.subscription_upgrade_requests (
 id uuid primary key default gen_random_uuid(),organization_id uuid not null references public.organizations(id) on delete cascade,
 request_type text not null check(request_type in ('plan_upgrade','trial_extension')),requested_plan_key text references public.subscription_plans(plan_key),
 requested_extension_days integer check(requested_extension_days between 1 and 30),billing_contact text,billing_email text,payment_method text,
 notes text,status text not null default 'pending' check(status in ('pending','approved','declined')),requested_by uuid not null references public.profiles(id),
 reviewed_by uuid references public.profiles(id),reviewed_at timestamptz,review_notes text,created_at timestamptz not null default now()
);
create unique index subscription_upgrade_one_pending on public.subscription_upgrade_requests(organization_id,request_type) where status='pending';
alter table public.subscription_upgrade_requests enable row level security;
create policy "organization admins read upgrade requests" on public.subscription_upgrade_requests for select to authenticated using(public.is_organization_admin(organization_id));
create policy "platform admins read upgrade requests" on public.subscription_upgrade_requests for select to authenticated using(public.is_platform_admin());

create or replace function public.get_my_subscription_portal_context()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_role public.staff_role;
begin
 select organization_id,role into v_org,v_role from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
 if v_org is null or v_role not in ('owner','admin') then raise exception 'Organization administrator access required'; end if;
 return jsonb_build_object(
  'organization',(select jsonb_build_object('id',id,'name',name) from public.organizations where id=v_org),
  'subscription',(select jsonb_build_object('status',s.status,'plan_key',s.plan_key,'trial_ends_at',s.trial_ends_at,'plan_name',p.display_name,'monthly_price',coalesce(s.custom_monthly_price,p.monthly_price),'discount_percent',s.discount_percent) from public.organization_subscriptions s join public.subscription_plans p on p.plan_key=s.plan_key where s.organization_id=v_org),
  'usage',jsonb_build_object('branches',(select count(*) from public.branches where organization_id=v_org and active),'staff',(select count(*) from public.organization_memberships where organization_id=v_org and active),'customers',(select count(*) from public.customers where organization_id=v_org and active),'transactions',(select count(*) from public.laundry_orders where organization_id=v_org and created_at>=date_trunc('month',now()))),
  'plans',coalesce((select jsonb_agg(jsonb_build_object('plan_key',plan_key,'display_name',display_name,'monthly_price',monthly_price,'branch_limit',branch_limit,'staff_limit',staff_limit,'transaction_limit',transaction_limit,'customer_limit',customer_limit,'capabilities',capabilities) order by sort_order) from public.subscription_plans where active),'[]'::jsonb),
  'requests',coalesce((select jsonb_agg(to_jsonb(r) order by created_at desc) from public.subscription_upgrade_requests r where organization_id=v_org),'[]'::jsonb));
end $$;

create or replace function public.request_subscription_change(p_request_type text,p_plan_key text default null,p_extension_days integer default null,p_billing_contact text default null,p_billing_email text default null,p_payment_method text default 'manual',p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_role public.staff_role;v_id uuid;
begin
 select organization_id,role into v_org,v_role from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
 if v_org is null or v_role not in ('owner','admin') then raise exception 'Organization administrator access required'; end if;
 if p_request_type='plan_upgrade' and not exists(select 1 from public.subscription_plans where plan_key=p_plan_key and active) then raise exception 'Select a valid plan'; end if;
 if p_request_type='trial_extension' and coalesce(p_extension_days,0) not between 1 and 30 then raise exception 'Extension must be between 1 and 30 days'; end if;
 insert into public.subscription_upgrade_requests(organization_id,request_type,requested_plan_key,requested_extension_days,billing_contact,billing_email,payment_method,notes,requested_by)
 values(v_org,p_request_type,p_plan_key,p_extension_days,nullif(trim(coalesce(p_billing_contact,'')),''),nullif(trim(coalesce(p_billing_email,'')),''),p_payment_method,nullif(trim(coalesce(p_notes,'')),''),auth.uid()) returning id into v_id;
 return v_id;
exception when unique_violation then raise exception 'A pending request of this type already exists';
end $$;

create or replace function public.get_platform_upgrade_requests()
returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
 return coalesce((select jsonb_agg(to_jsonb(r)||jsonb_build_object('organization_name',o.name,'requester_email',p.email,'requested_plan_name',sp.display_name) order by r.created_at desc) from public.subscription_upgrade_requests r join public.organizations o on o.id=r.organization_id join public.profiles p on p.id=r.requested_by left join public.subscription_plans sp on sp.plan_key=r.requested_plan_key),'[]'::jsonb);
end $$;

create or replace function public.review_subscription_request(p_request_id uuid,p_approve boolean,p_review_notes text default null)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_req public.subscription_upgrade_requests%rowtype;
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
 select * into v_req from public.subscription_upgrade_requests where id=p_request_id and status='pending' for update;
 if v_req.id is null then raise exception 'Pending request not found'; end if;
 if p_approve and v_req.request_type='plan_upgrade' then update public.organization_subscriptions set plan_key=v_req.requested_plan_key,status='active',billing_started_at=coalesce(billing_started_at,now()),updated_at=now(),updated_by=auth.uid() where organization_id=v_req.organization_id; end if;
 if p_approve and v_req.request_type='trial_extension' then update public.organization_subscriptions set trial_ends_at=greatest(trial_ends_at,now())+make_interval(days=>v_req.requested_extension_days),status='trialing',updated_at=now(),updated_by=auth.uid() where organization_id=v_req.organization_id; end if;
 update public.subscription_upgrade_requests set status=case when p_approve then 'approved' else 'declined' end,reviewed_by=auth.uid(),reviewed_at=now(),review_notes=nullif(trim(coalesce(p_review_notes,'')),'') where id=v_req.id;
 return true;
end $$;
grant execute on function public.get_my_subscription_portal_context() to authenticated;
grant execute on function public.request_subscription_change(text,text,integer,text,text,text,text) to authenticated;
grant execute on function public.get_platform_upgrade_requests() to authenticated;
grant execute on function public.review_subscription_request(uuid,boolean,text) to authenticated;
commit;
