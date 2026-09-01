-- Time-limited, audited, read-only Platform Admin support sessions.
begin;

create table public.platform_support_sessions (
 id uuid primary key default gen_random_uuid(),
 platform_admin_id uuid not null references public.profiles(id),
 organization_id uuid not null references public.organizations(id),
 started_at timestamptz not null default now(),
 expires_at timestamptz not null default (now()+interval '30 minutes'),
 ended_at timestamptz,
 end_reason text,
 constraint support_session_window check(expires_at>started_at)
);
create unique index platform_support_one_open_session on public.platform_support_sessions(platform_admin_id) where ended_at is null;
create index platform_support_org_time_idx on public.platform_support_sessions(organization_id,started_at desc);
alter table public.platform_support_sessions enable row level security;

create table public.platform_support_audit (
 id bigint generated always as identity primary key,
 session_id uuid not null references public.platform_support_sessions(id) on delete cascade,
 platform_admin_id uuid not null references public.profiles(id),
 organization_id uuid not null references public.organizations(id),
 action text not null,
 details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
create index platform_support_audit_session_idx on public.platform_support_audit(session_id,created_at desc);
alter table public.platform_support_audit enable row level security;

create or replace function public.active_support_organization_id()
returns uuid language sql stable security definer set search_path=public as $$
 select organization_id from public.platform_support_sessions where platform_admin_id=auth.uid() and ended_at is null and expires_at>now() order by started_at desc limit 1;
$$;

create or replace function public.is_platform_support_mode()
returns boolean language sql stable security definer set search_path=public as $$
 select public.active_support_organization_id() is not null;
$$;

-- Platform-only controls are deliberately unavailable during a support session.
create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.platform_admins where user_id=auth.uid() and active)
 and public.active_support_organization_id() is null;
$$;

create or replace function public.is_organization_member(p_organization_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.organization_memberships where organization_id=p_organization_id and user_id=auth.uid() and active)
 or public.active_support_organization_id()=p_organization_id;
$$;

create or replace function public.is_organization_admin(p_organization_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.organization_memberships where organization_id=p_organization_id and user_id=auth.uid() and active and role in ('owner','admin'));
$$;

create or replace function public.can_access_branch(p_branch_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.branches b where b.id=p_branch_id and b.active and (public.active_support_organization_id()=b.organization_id or exists(select 1 from public.organization_memberships m where m.organization_id=b.organization_id and m.user_id=auth.uid() and m.active and (m.role in ('owner','admin') or exists(select 1 from public.staff_branch_assignments a where a.staff_id=auth.uid() and a.branch_id=b.id)))));
$$;

create or replace function public.has_role_permission(p_permission text,p_branch_id uuid default null)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare v_org uuid;v_role public.staff_role;v_member_active boolean;v_org_active boolean;
begin
 if public.active_support_organization_id() is not null then return false; end if;
 select m.organization_id,m.role,m.active,o.active into v_org,v_role,v_member_active,v_org_active from public.organization_memberships m join public.organizations o on o.id=m.organization_id where m.user_id=auth.uid() order by m.created_at limit 1;
 if v_org is null or not coalesce(v_member_active,false) or not coalesce(v_org_active,false) then return false; end if;
 if p_branch_id is not null and v_role not in ('owner','admin') and not exists(select 1 from public.staff_branch_assignments where staff_id=auth.uid() and branch_id=p_branch_id) then return false; end if;
 return case p_permission when 'manage_organization' then v_role in ('owner','admin') when 'manage_services' then v_role in ('owner','admin','manager') when 'manage_staff' then v_role in ('owner','admin') when 'manage_customers' then v_role in ('owner','admin','manager','cashier') when 'adjust_loyalty' then v_role in ('owner','admin','manager') when 'create_orders' then v_role in ('owner','admin','manager','cashier') when 'process_orders' then v_role in ('owner','admin','manager','cashier','laundry_staff') when 'record_payments' then v_role in ('owner','admin','manager','cashier') when 'delivery_access' then v_role in ('owner','admin','manager','delivery_staff') when 'view_reports' then v_role in ('owner','admin','manager','auditor') else false end;
end $$;

create or replace function public.start_platform_support_session(p_organization_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_session public.platform_support_sessions%rowtype;v_org public.organizations%rowtype;
begin
 if not exists(select 1 from public.platform_admins where user_id=auth.uid() and active) then raise exception 'Platform administrator access required'; end if;
 select * into v_org from public.organizations where id=p_organization_id and active;
 if v_org.id is null then raise exception 'Active organization not found'; end if;
 update public.platform_support_sessions set ended_at=now(),end_reason='replaced' where platform_admin_id=auth.uid() and ended_at is null;
 insert into public.platform_support_sessions(platform_admin_id,organization_id) values(auth.uid(),p_organization_id) returning * into v_session;
 insert into public.platform_support_audit(session_id,platform_admin_id,organization_id,action,details) values(v_session.id,auth.uid(),p_organization_id,'started',jsonb_build_object('organization_name',v_org.name,'expires_at',v_session.expires_at));
 return jsonb_build_object('id',v_session.id,'organization_id',p_organization_id,'organization_name',v_org.name,'expires_at',v_session.expires_at,'support_mode',true);
end $$;

create or replace function public.get_active_platform_support_session()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_session public.platform_support_sessions%rowtype;
begin
 if not exists(select 1 from public.platform_admins where user_id=auth.uid() and active) then return null; end if;
 select * into v_session from public.platform_support_sessions where platform_admin_id=auth.uid() and ended_at is null and expires_at>now() order by started_at desc limit 1;
 if v_session.id is null then return null; end if;
 return jsonb_build_object('id',v_session.id,'organization_id',v_session.organization_id,'organization_name',(select name from public.organizations where id=v_session.organization_id),'started_at',v_session.started_at,'expires_at',v_session.expires_at,'support_mode',true);
end $$;

create or replace function public.log_platform_support_activity(p_path text)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_session public.platform_support_sessions%rowtype;
begin
 select * into v_session from public.platform_support_sessions where platform_admin_id=auth.uid() and ended_at is null and expires_at>now() order by started_at desc limit 1;
 if v_session.id is null then return false; end if;
 if not exists(select 1 from public.platform_support_audit where session_id=v_session.id and action='viewed' and details->>'path'=left(p_path,200) and created_at>now()-interval '1 minute') then insert into public.platform_support_audit(session_id,platform_admin_id,organization_id,action,details) values(v_session.id,auth.uid(),v_session.organization_id,'viewed',jsonb_build_object('path',left(p_path,200))); end if;
 return true;
end $$;

create or replace function public.end_platform_support_session()
returns boolean language plpgsql security definer set search_path=public as $$
declare v_session public.platform_support_sessions%rowtype;
begin
 if not exists(select 1 from public.platform_admins where user_id=auth.uid() and active) then raise exception 'Platform administrator access required'; end if;
 select * into v_session from public.platform_support_sessions where platform_admin_id=auth.uid() and ended_at is null order by started_at desc limit 1 for update;
 if v_session.id is null then return false; end if;
 update public.platform_support_sessions set ended_at=now(),end_reason=case when expires_at<=now() then 'expired' else 'ended_by_admin' end where id=v_session.id;
 insert into public.platform_support_audit(session_id,platform_admin_id,organization_id,action,details) values(v_session.id,auth.uid(),v_session.organization_id,'ended',jsonb_build_object('reason',case when v_session.expires_at<=now() then 'expired' else 'ended_by_admin' end));
 return true;
end $$;

-- Defense in depth: even direct API calls and security-definer RPCs cannot mutate tenant data in Support Mode.
create or replace function public.block_platform_support_writes()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 if public.is_platform_support_mode() then raise exception 'This action is unavailable in read-only Platform Support Mode'; end if;
 if tg_op='DELETE' then return old; else return new; end if;
end $$;

do $$
declare v_table text;
begin
 foreach v_table in array array['organizations','organization_memberships','branches','staff_branch_assignments','organization_settings','organization_features','organization_feature_grants','organization_invitations','organization_payment_accounts','organization_subscriptions','customers','customer_qr_tokens','customer_portal_access','organization_customer_portals','customer_addresses','customer_address_branch_distances','loyalty_programs','loyalty_levels','loyalty_transactions','services','branch_service_prices','laundry_orders','laundry_order_items','order_product_items','order_status_history','payments','delivery_distance_rates','delivery_jobs','promo_codes','products','branch_product_inventory','branch_product_sku_counters','product_stock_movements','management_audit_log','offline_sync_operations','local_staff_accounts','local_staff_sessions','payment_gateway_transactions','subscription_upgrade_requests'] loop
  if to_regclass('public.'||v_table) is not null then
   execute format('drop trigger if exists platform_support_read_only on public.%I',v_table);
   execute format('create trigger platform_support_read_only before insert or update or delete on public.%I for each statement execute function public.block_platform_support_writes()',v_table);
  end if;
 end loop;
end $$;

create or replace function public.get_current_access_context()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid:=public.active_support_organization_id();v_role public.staff_role;v_active boolean;v_org_active boolean;v_features jsonb;v_branches jsonb;v_settings jsonb;
begin
 if v_org is not null then
  select active into v_org_active from public.organizations where id=v_org;
  select coalesce(jsonb_object_agg(feature_key,enabled),'{}'::jsonb) into v_features from public.organization_features where organization_id=v_org;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',name,'code',code,'address',address) order by name),'[]'::jsonb) into v_branches from public.branches where organization_id=v_org and active;
  select coalesce(jsonb_object_agg(setting_key,setting_value),'{}'::jsonb) into v_settings from public.organization_settings where organization_id=v_org;
  return jsonb_build_object('has_membership',true,'membership_active',true,'organization_active',v_org_active,'organization_id',v_org,'role','support','branches',v_branches,'features',v_features,'settings',v_settings,'is_platform_admin',false,'support_mode',true,'permissions',jsonb_build_object('manage_organization',true,'manage_services',true,'manage_staff',false,'manage_customers',true,'adjust_loyalty',false,'create_orders',false,'process_orders',false,'record_payments',false,'delivery_access',true,'view_reports',true));
 end if;
 select m.organization_id,m.role,m.active,o.active into v_org,v_role,v_active,v_org_active from public.organization_memberships m join public.organizations o on o.id=m.organization_id where m.user_id=auth.uid() order by m.created_at limit 1;
 if v_org is null then return jsonb_build_object('has_membership',false,'is_platform_admin',public.is_platform_admin()); end if;
 select coalesce(jsonb_object_agg(feature_key,enabled),'{}'::jsonb) into v_features from public.organization_features where organization_id=v_org;
 select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'name',b.name,'code',b.code,'address',b.address) order by b.name),'[]'::jsonb) into v_branches from public.branches b where b.organization_id=v_org and b.active and (v_role in ('owner','admin') or exists(select 1 from public.staff_branch_assignments a where a.staff_id=auth.uid() and a.branch_id=b.id));
 select coalesce(jsonb_object_agg(setting_key,setting_value),'{}'::jsonb) into v_settings from public.organization_settings where organization_id=v_org;
 return jsonb_build_object('has_membership',true,'membership_active',v_active,'organization_active',v_org_active,'organization_id',v_org,'role',v_role,'branches',v_branches,'features',v_features,'settings',v_settings,'is_platform_admin',public.is_platform_admin(),'support_mode',false,'permissions',jsonb_build_object('manage_organization',v_role in ('owner','admin'),'manage_services',v_role in ('owner','admin','manager'),'manage_staff',v_role in ('owner','admin'),'manage_customers',v_role in ('owner','admin','manager','cashier'),'adjust_loyalty',v_role in ('owner','admin','manager'),'create_orders',v_role in ('owner','admin','manager','cashier'),'process_orders',v_role in ('owner','admin','manager','cashier','laundry_staff'),'record_payments',v_role in ('owner','admin','manager','cashier'),'delivery_access',v_role in ('owner','admin','manager','delivery_staff'),'view_reports',v_role in ('owner','admin','manager','auditor')));
end $$;

create or replace function public.get_my_labaflow_context()
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_org uuid:=public.active_support_organization_id();
begin
 if v_org is not null then return jsonb_build_object('profile',(select to_jsonb(p) from public.profiles p where p.id=auth.uid()),'organization',(select to_jsonb(o) from public.organizations o where o.id=v_org),'membership',jsonb_build_object('organization_id',v_org,'user_id',auth.uid(),'role','support','active',true),'branches',coalesce((select jsonb_agg(to_jsonb(b) order by b.name) from public.branches b where b.organization_id=v_org and b.active),'[]'::jsonb),'loyalty_program',(select to_jsonb(lp) from public.loyalty_programs lp where lp.organization_id=v_org),'settings',coalesce((select jsonb_object_agg(s.setting_key,s.setting_value) from public.organization_settings s where s.organization_id=v_org),'{}'::jsonb),'support_mode',true); end if;
 return coalesce((select jsonb_build_object('profile',to_jsonb(p),'organization',to_jsonb(o),'membership',to_jsonb(m),'branches',coalesce((select jsonb_agg(to_jsonb(b) order by b.name) from public.branches b where b.organization_id=o.id and b.active),'[]'::jsonb),'loyalty_program',(select to_jsonb(lp) from public.loyalty_programs lp where lp.organization_id=o.id),'settings',coalesce((select jsonb_object_agg(s.setting_key,s.setting_value) from public.organization_settings s where s.organization_id=o.id),'{}'::jsonb),'support_mode',false) from public.profiles p left join public.organization_memberships m on m.user_id=p.id and m.active left join public.organizations o on o.id=m.organization_id where p.id=auth.uid() limit 1),'{}'::jsonb);
end $$;

create or replace function public.get_organization_admin_context()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid:=public.active_support_organization_id();
begin
 if v_org is null then select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1; end if;
 if v_org is null then raise exception 'Organization administrator access required'; end if;
 return jsonb_build_object('organization',(select to_jsonb(o) from public.organizations o where o.id=v_org),'branches',coalesce((select jsonb_agg(to_jsonb(b) order by b.name) from public.branches b where b.organization_id=v_org),'[]'::jsonb),'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'email',p.email,'full_name',p.full_name,'role',m.role,'active',m.active) order by p.email) from public.organization_memberships m join public.profiles p on p.id=m.user_id where m.organization_id=v_org),'[]'::jsonb),'features',coalesce((select jsonb_object_agg(feature_key,enabled) from public.organization_features where organization_id=v_org),'{}'::jsonb),'granted_features',(select jsonb_object_agg(k.feature_key,coalesce(g.granted,k.default_granted)) from (values ('customer_loyalty',true),('pickup_delivery',true),('inventory',false),('expenses',true),('order_workflow',true),('qr_customer_id',true)) as k(feature_key,default_granted) left join public.organization_feature_grants g on g.organization_id=v_org and g.feature_key=k.feature_key),'invitations',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'email',i.email,'role',i.role,'branch_id',i.branch_id,'token',i.token,'expires_at',i.expires_at,'accepted_at',i.accepted_at,'revoked_at',i.revoked_at) order by i.created_at desc) from public.organization_invitations i where i.organization_id=v_org),'[]'::jsonb),'support_mode',public.is_platform_support_mode());
end $$;

create or replace function public.get_products_inventory()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid:=public.active_support_organization_id();
begin
 if v_org is null then select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1; end if;
 if v_org is null then raise exception 'Organization access required'; end if;
 if not public.is_organization_feature_enabled(v_org,'inventory') then raise exception 'Product & Inventory is not enabled for this organization'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'barcode',p.barcode,'cost_price',p.cost_price,'selling_price',p.selling_price,'loyalty_points',p.loyalty_points,'active',p.active,'created_branch_id',p.created_branch_id,'branch_id',b.id,'branch_name',b.name,'branch_code',b.code,'quantity',coalesce(i.quantity,0),'low_stock_level',coalesce(i.low_stock_level,0)) order by b.name,p.name) from public.products p cross join public.branches b left join public.branch_product_inventory i on i.product_id=p.id and i.branch_id=b.id where p.organization_id=v_org and b.organization_id=v_org and b.active),'[]'::jsonb);
end $$;

grant execute on function public.start_platform_support_session(uuid) to authenticated;
grant execute on function public.get_active_platform_support_session() to authenticated;
grant execute on function public.log_platform_support_activity(text) to authenticated;
grant execute on function public.end_platform_support_session() to authenticated;
commit;
