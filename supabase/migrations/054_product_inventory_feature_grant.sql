-- Gate Product & Inventory behind a Platform Admin grant and an organization toggle.
begin;

create table if not exists public.organization_feature_grants (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  feature_key text not null,
  granted boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id),
  primary key (organization_id,feature_key)
);
alter table public.organization_feature_grants enable row level security;
create policy "platform admins manage feature grants" on public.organization_feature_grants for all to authenticated using (public.is_platform_admin()) with check (public.is_platform_admin());
create policy "organization admins read feature grants" on public.organization_feature_grants for select to authenticated using (public.is_organization_admin(organization_id));

-- Existing and future tenants start with the module switched off.
insert into public.organization_features(organization_id,feature_key,enabled)
select id,'inventory',false from public.organizations
on conflict(organization_id,feature_key) do update set enabled=false,updated_at=now();

create or replace function public.is_organization_feature_enabled(p_organization_id uuid,p_feature_key text)
returns boolean language sql stable security definer set search_path=public as $$
  select case when lower(trim(p_feature_key))='inventory' then
    coalesce((select granted from public.organization_feature_grants where organization_id=p_organization_id and feature_key='inventory'),false)
    and coalesce((select enabled from public.organization_features where organization_id=p_organization_id and feature_key='inventory'),false)
  else coalesce((select enabled from public.organization_features where organization_id=p_organization_id and feature_key=lower(trim(p_feature_key))),true) end;
$$;

create or replace function public.set_platform_organization_feature_grant(p_organization_id uuid,p_feature_key text,p_granted boolean)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_key text:=lower(trim(p_feature_key));
begin
  if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
  if v_key<>'inventory' then raise exception 'Unsupported platform-controlled feature'; end if;
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
  if v_key='inventory' and p_enabled and not coalesce((select granted from public.organization_feature_grants where organization_id=v_org and feature_key=v_key),false) then
    raise exception 'Product & Inventory must first be granted by a Platform Administrator';
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
    'organizations',coalesce((select jsonb_agg(to_jsonb(o)||jsonb_build_object('inventory_granted',coalesce(g.granted,false)) order by o.created_at desc) from public.organizations o left join public.organization_feature_grants g on g.organization_id=o.id and g.feature_key='inventory'),'[]'::jsonb),
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
    'granted_features',jsonb_build_object('inventory',coalesce((select granted from public.organization_feature_grants where organization_id=v_org and feature_key='inventory'),false)),
    'invitations',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'email',i.email,'role',i.role,'branch_id',i.branch_id,'token',i.token,'expires_at',i.expires_at,'accepted_at',i.accepted_at,'revoked_at',i.revoked_at) order by i.created_at desc) from public.organization_invitations i where i.organization_id=v_org),'[]'::jsonb));
end $$;

-- Block the inventory data API unless both controls are on.
create or replace function public.get_products_inventory()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
  if v_org is null then raise exception 'Organization access required'; end if;
  if not public.is_organization_feature_enabled(v_org,'inventory') then raise exception 'Product & Inventory is not enabled for this organization'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',p.name,'sku',p.sku,'barcode',p.barcode,'cost_price',p.cost_price,'selling_price',p.selling_price,'loyalty_points',p.loyalty_points,'active',p.active,'created_branch_id',p.created_branch_id,'branch_id',b.id,'branch_name',b.name,'branch_code',b.code,'quantity',coalesce(i.quantity,0),'low_stock_level',coalesce(i.low_stock_level,0)) order by b.name,p.name)
    from public.products p cross join public.branches b left join public.branch_product_inventory i on i.product_id=p.id and i.branch_id=b.id
    where p.organization_id=v_org and b.organization_id=v_org and b.active),'[]'::jsonb);
end $$;

create or replace function public.guard_inventory_feature()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_org uuid:=case when tg_op='DELETE' then old.organization_id else new.organization_id end;
begin
  if not public.is_organization_feature_enabled(v_org,'inventory') then raise exception 'Product & Inventory is not enabled for this organization'; end if;
  if tg_op='DELETE' then return old; else return new; end if;
end $$;
drop trigger if exists products_feature_guard on public.products;
create trigger products_feature_guard before insert or update or delete on public.products for each row execute function public.guard_inventory_feature();
drop trigger if exists branch_inventory_feature_guard on public.branch_product_inventory;
create trigger branch_inventory_feature_guard before insert or update or delete on public.branch_product_inventory for each row execute function public.guard_inventory_feature();
drop trigger if exists order_products_feature_guard on public.order_product_items;
create trigger order_products_feature_guard before insert or update or delete on public.order_product_items for each row execute function public.guard_inventory_feature();

grant select on public.organization_feature_grants to authenticated;
grant execute on function public.is_organization_feature_enabled(uuid,text) to authenticated;
grant execute on function public.set_platform_organization_feature_grant(uuid,text,boolean) to authenticated;
grant execute on function public.get_products_inventory() to authenticated;
commit;
