-- LabaFlow v0.24 configurable loyalty/member levels
begin;

create table if not exists public.loyalty_levels (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  minimum_points bigint not null default 0 check (minimum_points >= 0),
  active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,name),
  unique(organization_id,minimum_points)
);

create index if not exists loyalty_levels_org_idx on public.loyalty_levels(organization_id,active,minimum_points);
alter table public.loyalty_levels enable row level security;

drop policy if exists "members read loyalty levels" on public.loyalty_levels;
create policy "members read loyalty levels" on public.loyalty_levels
for select to authenticated using(public.is_organization_member(organization_id));

drop policy if exists "admins manage loyalty levels" on public.loyalty_levels;
create policy "admins manage loyalty levels" on public.loyalty_levels
for all to authenticated
using(public.is_organization_member(organization_id) and public.has_role_permission('manage_organization'))
with check(public.is_organization_member(organization_id) and public.has_role_permission('manage_organization'));

-- Seed sensible defaults only when an organization has not configured levels yet.
insert into public.loyalty_levels(organization_id,name,minimum_points,sort_order)
select o.id,v.name,v.minimum_points,v.sort_order
from public.organizations o
cross join (values ('Bronze',0::bigint,10),('Silver',1001::bigint,20),('Platinum',10001::bigint,30)) v(name,minimum_points,sort_order)
where not exists(select 1 from public.loyalty_levels l where l.organization_id=o.id)
on conflict do nothing;

create or replace function public.get_customer_loyalty_level(p_customer_id uuid)
returns jsonb
language plpgsql stable security definer set search_path=public as $$
declare v_org uuid; v_points bigint; v_level public.loyalty_levels%rowtype;
begin
  select organization_id,coalesce(lifetime_points,0) into v_org,v_points
  from public.customers where id=p_customer_id and active;
  if v_org is null or not public.is_organization_member(v_org) then raise exception 'Customer not found'; end if;
  select * into v_level from public.loyalty_levels
  where organization_id=v_org and active and minimum_points<=v_points
  order by minimum_points desc,sort_order desc limit 1;
  return jsonb_build_object('name',coalesce(v_level.name,'Member'),'minimum_points',coalesce(v_level.minimum_points,0),'cumulative_points',v_points);
end $$;

create or replace function public.save_loyalty_level(
  p_level_id uuid,
  p_name text,
  p_minimum_points bigint,
  p_active boolean default true,
  p_sort_order integer default 0
)
returns public.loyalty_levels
language plpgsql security definer set search_path=public as $$
declare v_org uuid; v_row public.loyalty_levels%rowtype;
begin
  select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
  if v_org is null or not public.has_role_permission('manage_organization') then raise exception 'Organization administration permission required'; end if;
  if nullif(trim(coalesce(p_name,'')),'') is null then raise exception 'Level name is required'; end if;
  if coalesce(p_minimum_points,-1)<0 then raise exception 'Minimum points must be zero or greater'; end if;

  if p_level_id is null then
    insert into public.loyalty_levels(organization_id,name,minimum_points,active,sort_order)
    values(v_org,trim(p_name),p_minimum_points,coalesce(p_active,true),coalesce(p_sort_order,0)) returning * into v_row;
  else
    update public.loyalty_levels set name=trim(p_name),minimum_points=p_minimum_points,active=coalesce(p_active,true),sort_order=coalesce(p_sort_order,0),updated_at=now()
    where id=p_level_id and organization_id=v_org returning * into v_row;
    if v_row.id is null then raise exception 'Loyalty level not found'; end if;
  end if;
  return v_row;
end $$;

create or replace function public.delete_loyalty_level(p_level_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
  if v_org is null or not public.has_role_permission('manage_organization') then raise exception 'Organization administration permission required'; end if;
  delete from public.loyalty_levels where id=p_level_id and organization_id=v_org;
end $$;

grant execute on function public.get_customer_loyalty_level(uuid) to authenticated;
grant execute on function public.save_loyalty_level(uuid,text,bigint,boolean,integer) to authenticated;
grant execute on function public.delete_loyalty_level(uuid) to authenticated;

commit;
