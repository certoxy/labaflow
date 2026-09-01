-- Selective platform configuration restore points. No customer or operational data is captured.
begin;

create table if not exists public.system_restore_points (
 id uuid primary key default gen_random_uuid(),
 name text not null,
 notes text,
 kind text not null default 'manual' check(kind in ('manual','pre_restore')),
 snapshot jsonb not null,
 created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now(),
 restored_from_id uuid references public.system_restore_points(id),
 restored_at timestamptz,
 restored_by uuid references public.profiles(id)
);
create index if not exists system_restore_points_created_idx on public.system_restore_points(created_at desc);
alter table public.system_restore_points enable row level security;
create policy "platform admins read restore points" on public.system_restore_points for select to authenticated using(public.is_platform_admin());

create or replace function public.capture_system_configuration()
returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
 return jsonb_build_object(
  'schema_version',1,
  'captured_at',now(),
  'scope',jsonb_build_array('subscription_plans','subscription_feature_prices','organization_subscriptions','organization_feature_grants','organization_features'),
  'subscription_plans',coalesce((select jsonb_agg(jsonb_build_object('plan_key',plan_key,'display_name',display_name,'monthly_price',monthly_price,'branch_limit',branch_limit,'staff_limit',staff_limit,'transaction_limit',transaction_limit,'customer_limit',customer_limit,'capabilities',capabilities,'active',active,'sort_order',sort_order) order by sort_order) from public.subscription_plans),'[]'::jsonb),
  'subscription_feature_prices',coalesce((select jsonb_agg(jsonb_build_object('feature_key',feature_key,'display_name',display_name,'monthly_price',monthly_price,'active',active,'sort_order',sort_order) order by sort_order) from public.subscription_feature_prices),'[]'::jsonb),
  'organization_subscriptions',coalesce((select jsonb_agg(jsonb_build_object('organization_id',organization_id,'trial_started_at',trial_started_at,'trial_ends_at',trial_ends_at,'status',status,'billing_started_at',billing_started_at,'next_billing_at',next_billing_at,'notes',notes,'plan_key',plan_key,'custom_monthly_price',custom_monthly_price,'discount_percent',discount_percent,'promo_code',promo_code,'referral_name',referral_name,'referral_email',referral_email,'billing_cycle',billing_cycle)) from public.organization_subscriptions),'[]'::jsonb),
  'organization_feature_grants',coalesce((select jsonb_agg(jsonb_build_object('organization_id',organization_id,'feature_key',feature_key,'granted',granted)) from public.organization_feature_grants),'[]'::jsonb),
  'organization_features',coalesce((select jsonb_agg(jsonb_build_object('organization_id',organization_id,'feature_key',feature_key,'enabled',enabled)) from public.organization_features),'[]'::jsonb)
 );
end $$;

create or replace function public.create_system_restore_point(p_name text,p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;v_name text:=nullif(trim(coalesce(p_name,'')),'');
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
 if v_name is null then raise exception 'Restore point name is required'; end if;
 if length(v_name)>100 then raise exception 'Restore point name must be 100 characters or fewer'; end if;
 insert into public.system_restore_points(name,notes,snapshot,created_by) values(v_name,nullif(trim(coalesce(p_notes,'')),''),public.capture_system_configuration(),auth.uid()) returning id into v_id;
 return v_id;
end $$;

create or replace function public.get_system_restore_points()
returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'name',r.name,'notes',r.notes,'kind',r.kind,'created_at',r.created_at,'created_by_email',p.email,'restored_from_id',r.restored_from_id,'restored_at',r.restored_at,'restored_by_email',rp.email,'counts',jsonb_build_object('plans',jsonb_array_length(r.snapshot->'subscription_plans'),'feature_prices',jsonb_array_length(r.snapshot->'subscription_feature_prices'),'subscriptions',jsonb_array_length(r.snapshot->'organization_subscriptions'),'feature_grants',jsonb_array_length(r.snapshot->'organization_feature_grants'),'feature_toggles',jsonb_array_length(r.snapshot->'organization_features'))) order by r.created_at desc) from public.system_restore_points r left join public.profiles p on p.id=r.created_by left join public.profiles rp on rp.id=r.restored_by),'[]'::jsonb);
end $$;

create or replace function public.preview_system_restore_point(p_restore_point_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_snapshot jsonb;
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
 select snapshot into v_snapshot from public.system_restore_points where id=p_restore_point_id;
 if v_snapshot is null then raise exception 'Restore point not found'; end if;
 return jsonb_build_object('plans',jsonb_array_length(v_snapshot->'subscription_plans'),'feature_prices',jsonb_array_length(v_snapshot->'subscription_feature_prices'),'subscriptions',jsonb_array_length(v_snapshot->'organization_subscriptions'),'feature_grants',jsonb_array_length(v_snapshot->'organization_feature_grants'),'feature_toggles',jsonb_array_length(v_snapshot->'organization_features'),'excluded',jsonb_build_array('customers','laundry_orders','payments','products','inventory quantities','expenses','staff and memberships','files'),'note','Only matching configuration records are restored. New organizations and operational records remain untouched.');
end $$;

create or replace function public.restore_system_configuration(p_restore_point_id uuid,p_confirmation text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_snapshot jsonb;v_safety_id uuid;v_target_name text;
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
 if p_confirmation<>'RESTORE' then raise exception 'Type RESTORE to confirm'; end if;
 select snapshot,name into v_snapshot,v_target_name from public.system_restore_points where id=p_restore_point_id for update;
 if v_snapshot is null then raise exception 'Restore point not found'; end if;

 insert into public.system_restore_points(name,notes,kind,snapshot,created_by,restored_from_id)
 values('Safety snapshot before restore',concat('Automatically created before restoring: ',v_target_name),'pre_restore',public.capture_system_configuration(),auth.uid(),p_restore_point_id) returning id into v_safety_id;

 insert into public.subscription_plans(plan_key,display_name,monthly_price,branch_limit,staff_limit,transaction_limit,customer_limit,capabilities,active,sort_order,updated_at,updated_by)
 select x.plan_key,x.display_name,x.monthly_price,x.branch_limit,x.staff_limit,x.transaction_limit,x.customer_limit,x.capabilities,x.active,x.sort_order,now(),auth.uid()
 from jsonb_to_recordset(v_snapshot->'subscription_plans') as x(plan_key text,display_name text,monthly_price numeric,branch_limit integer,staff_limit integer,transaction_limit integer,customer_limit integer,capabilities jsonb,active boolean,sort_order integer)
 on conflict(plan_key) do update set display_name=excluded.display_name,monthly_price=excluded.monthly_price,branch_limit=excluded.branch_limit,staff_limit=excluded.staff_limit,transaction_limit=excluded.transaction_limit,customer_limit=excluded.customer_limit,capabilities=excluded.capabilities,active=excluded.active,sort_order=excluded.sort_order,updated_at=now(),updated_by=auth.uid();

 insert into public.subscription_feature_prices(feature_key,display_name,monthly_price,active,sort_order,updated_at,updated_by)
 select x.feature_key,x.display_name,x.monthly_price,x.active,x.sort_order,now(),auth.uid() from jsonb_to_recordset(v_snapshot->'subscription_feature_prices') as x(feature_key text,display_name text,monthly_price numeric,active boolean,sort_order integer)
 on conflict(feature_key) do update set display_name=excluded.display_name,monthly_price=excluded.monthly_price,active=excluded.active,sort_order=excluded.sort_order,updated_at=now(),updated_by=auth.uid();

 insert into public.organization_subscriptions(organization_id,trial_started_at,trial_ends_at,status,billing_started_at,next_billing_at,notes,plan_key,custom_monthly_price,discount_percent,promo_code,referral_name,referral_email,billing_cycle,updated_at,updated_by)
 select x.organization_id,x.trial_started_at,x.trial_ends_at,x.status,x.billing_started_at,x.next_billing_at,x.notes,x.plan_key,x.custom_monthly_price,x.discount_percent,x.promo_code,x.referral_name,x.referral_email,x.billing_cycle,now(),auth.uid()
 from jsonb_to_recordset(v_snapshot->'organization_subscriptions') as x(organization_id uuid,trial_started_at timestamptz,trial_ends_at timestamptz,status text,billing_started_at timestamptz,next_billing_at timestamptz,notes text,plan_key text,custom_monthly_price numeric,discount_percent numeric,promo_code text,referral_name text,referral_email text,billing_cycle text) join public.organizations o on o.id=x.organization_id
 on conflict(organization_id) do update set trial_started_at=excluded.trial_started_at,trial_ends_at=excluded.trial_ends_at,status=excluded.status,billing_started_at=excluded.billing_started_at,next_billing_at=excluded.next_billing_at,notes=excluded.notes,plan_key=excluded.plan_key,custom_monthly_price=excluded.custom_monthly_price,discount_percent=excluded.discount_percent,promo_code=excluded.promo_code,referral_name=excluded.referral_name,referral_email=excluded.referral_email,billing_cycle=excluded.billing_cycle,updated_at=now(),updated_by=auth.uid();

 insert into public.organization_feature_grants(organization_id,feature_key,granted,updated_at,updated_by)
 select x.organization_id,x.feature_key,x.granted,now(),auth.uid() from jsonb_to_recordset(v_snapshot->'organization_feature_grants') as x(organization_id uuid,feature_key text,granted boolean) join public.organizations o on o.id=x.organization_id
 on conflict(organization_id,feature_key) do update set granted=excluded.granted,updated_at=now(),updated_by=auth.uid();

 insert into public.organization_features(organization_id,feature_key,enabled,updated_at,updated_by)
 select x.organization_id,x.feature_key,x.enabled,now(),auth.uid() from jsonb_to_recordset(v_snapshot->'organization_features') as x(organization_id uuid,feature_key text,enabled boolean) join public.organizations o on o.id=x.organization_id
 on conflict(organization_id,feature_key) do update set enabled=excluded.enabled,updated_at=now(),updated_by=auth.uid();

 update public.system_restore_points set restored_at=now(),restored_by=auth.uid() where id=p_restore_point_id;
 return v_safety_id;
end $$;

revoke all on function public.capture_system_configuration() from public,anon,authenticated;
grant execute on function public.create_system_restore_point(text,text) to authenticated;
grant execute on function public.get_system_restore_points() to authenticated;
grant execute on function public.preview_system_restore_point(uuid) to authenticated;
grant execute on function public.restore_system_configuration(uuid,text) to authenticated;
commit;
