-- Expand Platform Admin grants to every organization feature.
begin;
insert into public.organization_feature_grants(organization_id,feature_key,granted)
select o.id,k.feature_key,k.default_granted from public.organizations o cross join (values
 ('customer_loyalty',true),('pickup_delivery',true),('inventory',false),('expenses',true),('order_workflow',true),('qr_customer_id',true)
) as k(feature_key,default_granted) on conflict(organization_id,feature_key) do nothing;

create or replace function public.is_organization_feature_enabled(p_organization_id uuid,p_feature_key text)
returns boolean language sql stable security definer set search_path=public as $$
 select coalesce((select granted from public.organization_feature_grants where organization_id=p_organization_id and feature_key=lower(trim(p_feature_key))),lower(trim(p_feature_key))<>'inventory')
 and coalesce((select enabled from public.organization_features where organization_id=p_organization_id and feature_key=lower(trim(p_feature_key))),lower(trim(p_feature_key))<>'inventory');
$$;

create or replace function public.set_platform_organization_feature_grant(p_organization_id uuid,p_feature_key text,p_granted boolean)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_key text:=lower(trim(p_feature_key));
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
 if v_key not in ('customer_loyalty','pickup_delivery','inventory','expenses','order_workflow','qr_customer_id') then raise exception 'Unsupported platform-controlled feature'; end if;
 if not exists(select 1 from public.organizations where id=p_organization_id) then raise exception 'Organization not found'; end if;
 insert into public.organization_feature_grants(organization_id,feature_key,granted,updated_by) values(p_organization_id,v_key,p_granted,auth.uid())
 on conflict(organization_id,feature_key) do update set granted=excluded.granted,updated_at=now(),updated_by=auth.uid();
 if not p_granted then
  insert into public.organization_features(organization_id,feature_key,enabled,updated_by) values(p_organization_id,v_key,false,auth.uid())
  on conflict(organization_id,feature_key) do update set enabled=false,updated_at=now(),updated_by=auth.uid();
 end if;
 return true;
end $$;

create or replace function public.set_organization_feature(p_feature_key text,p_enabled boolean)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_key text:=lower(trim(p_feature_key));
begin
 select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1;
 if v_org is null then raise exception 'Organization administrator access required'; end if;
 if p_enabled and not coalesce((select granted from public.organization_feature_grants where organization_id=v_org and feature_key=v_key),v_key<>'inventory') then
  raise exception '% must first be granted by a Platform Administrator',initcap(replace(v_key,'_',' '));
 end if;
 insert into public.organization_features(organization_id,feature_key,enabled,updated_by) values(v_org,v_key,p_enabled,auth.uid())
 on conflict(organization_id,feature_key) do update set enabled=excluded.enabled,updated_at=now(),updated_by=auth.uid();
 return true;
end $$;

create or replace function public.get_platform_admin_context()
returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
 return jsonb_build_object(
  'organizations',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('inventory_granted',coalesce((select granted from public.organization_feature_grants where organization_id=o.id and feature_key='inventory'),false),'feature_grants',(select jsonb_object_agg(k.feature_key,coalesce(g.granted,k.default_granted)) from (values ('customer_loyalty',true),('pickup_delivery',true),('inventory',false),('expenses',true),('order_workflow',true),('qr_customer_id',true)) as k(feature_key,default_granted) left join public.organization_feature_grants g on g.organization_id=o.id and g.feature_key=k.feature_key)) order by o.created_at desc) from public.organizations o),'[]'::jsonb),
  'platform_admins',coalesce((select jsonb_agg(jsonb_build_object('user_id',p.user_id,'email',pr.email,'full_name',pr.full_name,'active',p.active,'granted_at',p.granted_at) order by p.granted_at) from public.platform_admins p join public.profiles pr on pr.id=p.user_id),'[]'::jsonb));
end $$;

create or replace function public.get_organization_admin_context()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid;
begin
 select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1;
 if v_org is null then raise exception 'Organization administrator access required'; end if;
 return jsonb_build_object(
  'organization',(select to_jsonb(o) from public.organizations o where o.id=v_org),
  'branches',coalesce((select jsonb_agg(to_jsonb(b) order by b.name) from public.branches b where b.organization_id=v_org),'[]'::jsonb),
  'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'email',p.email,'full_name',p.full_name,'role',m.role,'active',m.active) order by p.email) from public.organization_memberships m join public.profiles p on p.id=m.user_id where m.organization_id=v_org),'[]'::jsonb),
  'features',coalesce((select jsonb_object_agg(feature_key,enabled) from public.organization_features where organization_id=v_org),'{}'::jsonb),
  'granted_features',(select jsonb_object_agg(k.feature_key,coalesce(g.granted,k.default_granted)) from (values ('customer_loyalty',true),('pickup_delivery',true),('inventory',false),('expenses',true),('order_workflow',true),('qr_customer_id',true)) as k(feature_key,default_granted) left join public.organization_feature_grants g on g.organization_id=v_org and g.feature_key=k.feature_key),
  'invitations',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'email',i.email,'role',i.role,'branch_id',i.branch_id,'token',i.token,'expires_at',i.expires_at,'accepted_at',i.accepted_at,'revoked_at',i.revoked_at) order by i.created_at desc) from public.organization_invitations i where i.organization_id=v_org),'[]'::jsonb));
end $$;
commit;
