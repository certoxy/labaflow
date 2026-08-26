-- LabaFlow v0.3 multi-tenant administration.
-- Platform admins, organization features, branches, invitations, staff roles, and tenant guards.

begin;

create table public.platform_admins (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  active boolean not null default true,
  granted_at timestamptz not null default now(),
  granted_by uuid references public.profiles(id)
);

create table public.organization_features (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  feature_key text not null,
  enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id),
  primary key (organization_id,feature_key)
);

create table public.organization_invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  email text not null,
  role public.staff_role not null default 'laundry_staff',
  branch_id uuid references public.branches(id) on delete set null,
  token uuid not null default gen_random_uuid() unique,
  expires_at timestamptz not null default (now() + interval '7 days'),
  accepted_at timestamptz,
  revoked_at timestamptz,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create index organization_invitations_org_idx on public.organization_invitations(organization_id,created_at desc);
create index organization_invitations_email_idx on public.organization_invitations(lower(email),accepted_at,revoked_at);

create or replace function public.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path=public
as $$
  select exists(
    select 1 from public.platform_admins
    where user_id=auth.uid() and active
  );
$$;

create or replace function public.bootstrap_first_platform_admin()
returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if exists(select 1 from public.platform_admins where active) then
    raise exception 'A platform administrator already exists';
  end if;
  insert into public.platform_admins(user_id,granted_by)
  values(auth.uid(),auth.uid());
  return true;
end;
$$;

create or replace function public.get_platform_admin_context()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
  return jsonb_build_object(
    'organizations',coalesce((select jsonb_agg(to_jsonb(o) order by o.created_at desc) from public.organizations o),'[]'::jsonb),
    'platform_admins',coalesce((select jsonb_agg(jsonb_build_object('user_id',p.user_id,'email',pr.email,'full_name',pr.full_name,'active',p.active,'granted_at',p.granted_at) order by p.granted_at) from public.platform_admins p join public.profiles pr on pr.id=p.user_id),'[]'::jsonb)
  );
end;
$$;

create or replace function public.set_organization_active(p_organization_id uuid,p_active boolean)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
  update public.organizations set active=p_active,updated_at=now() where id=p_organization_id;
  if not found then raise exception 'Organization not found'; end if;
  return true;
end;
$$;

create or replace function public.grant_platform_admin(p_email text)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare v_user uuid;
begin
  if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
  select id into v_user from public.profiles where lower(email)=lower(trim(p_email)) limit 1;
  if v_user is null then raise exception 'User must already have a LabaFlow account'; end if;
  insert into public.platform_admins(user_id,active,granted_by)
  values(v_user,true,auth.uid())
  on conflict(user_id) do update set active=true,granted_at=now(),granted_by=auth.uid();
  return true;
end;
$$;

create or replace function public.get_organization_admin_context()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_org uuid;
begin
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid() and active and role in ('owner','admin')
  order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;
  return jsonb_build_object(
    'organization',(select to_jsonb(o) from public.organizations o where o.id=v_org),
    'branches',coalesce((select jsonb_agg(to_jsonb(b) order by b.name) from public.branches b where b.organization_id=v_org),'[]'::jsonb),
    'members',coalesce((select jsonb_agg(jsonb_build_object('user_id',m.user_id,'email',p.email,'full_name',p.full_name,'role',m.role,'active',m.active) order by p.email) from public.organization_memberships m join public.profiles p on p.id=m.user_id where m.organization_id=v_org),'[]'::jsonb),
    'features',coalesce((select jsonb_object_agg(f.feature_key,f.enabled) from public.organization_features f where f.organization_id=v_org),'{}'::jsonb),
    'invitations',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'email',i.email,'role',i.role,'branch_id',i.branch_id,'token',i.token,'expires_at',i.expires_at,'accepted_at',i.accepted_at,'revoked_at',i.revoked_at) order by i.created_at desc) from public.organization_invitations i where i.organization_id=v_org),'[]'::jsonb)
  );
end;
$$;

create or replace function public.create_branch(p_code text,p_name text,p_address text default null,p_phone text default null)
returns public.branches
language plpgsql
security definer
set search_path=public
as $$
declare v_org uuid;v_branch public.branches%rowtype;
begin
  select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;
  insert into public.branches(organization_id,code,name,address,phone)
  values(v_org,upper(trim(p_code)),trim(p_name),nullif(trim(coalesce(p_address,'')),''),nullif(trim(coalesce(p_phone,'')),'')) returning * into v_branch;
  return v_branch;
end;
$$;

create or replace function public.set_organization_feature(p_feature_key text,p_enabled boolean)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;
  insert into public.organization_features(organization_id,feature_key,enabled,updated_by)
  values(v_org,lower(trim(p_feature_key)),p_enabled,auth.uid())
  on conflict(organization_id,feature_key) do update set enabled=excluded.enabled,updated_at=now(),updated_by=auth.uid();
  return true;
end;
$$;

create or replace function public.invite_organization_user(p_email text,p_role public.staff_role,p_branch_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_org uuid;v_inv public.organization_invitations%rowtype;
begin
  select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;
  if p_role='owner' then raise exception 'Owner role cannot be invited'; end if;
  if p_branch_id is not null and not exists(select 1 from public.branches where id=p_branch_id and organization_id=v_org) then raise exception 'Branch is invalid'; end if;
  insert into public.organization_invitations(organization_id,email,role,branch_id,created_by)
  values(v_org,lower(trim(p_email)),p_role,p_branch_id,auth.uid()) returning * into v_inv;
  return to_jsonb(v_inv);
end;
$$;

create or replace function public.accept_organization_invitation(p_token uuid)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare v_inv public.organization_invitations%rowtype;v_email text;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  select email into v_email from public.profiles where id=auth.uid();
  select * into v_inv from public.organization_invitations where token=p_token and accepted_at is null and revoked_at is null and expires_at>now() for update;
  if v_inv.id is null then raise exception 'Invitation is invalid or expired'; end if;
  if lower(v_email)<>lower(v_inv.email) then raise exception 'Invitation email does not match signed-in user'; end if;
  insert into public.organization_memberships(organization_id,user_id,role,active)
  values(v_inv.organization_id,auth.uid(),v_inv.role,true)
  on conflict(organization_id,user_id) do update set role=excluded.role,active=true,updated_at=now();
  if v_inv.branch_id is not null then
    insert into public.staff_branch_assignments(staff_id,branch_id) values(auth.uid(),v_inv.branch_id) on conflict do nothing;
  end if;
  update public.organization_invitations set accepted_at=now() where id=v_inv.id;
  return true;
end;
$$;

create or replace function public.set_member_role(p_user_id uuid,p_role public.staff_role,p_active boolean default true)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare v_org uuid;v_current public.staff_role;
begin
  select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;
  select role into v_current from public.organization_memberships where organization_id=v_org and user_id=p_user_id;
  if v_current is null then raise exception 'Member not found'; end if;
  if v_current='owner' then raise exception 'Owner membership cannot be changed here'; end if;
  if p_role='owner' then raise exception 'Owner role cannot be assigned here'; end if;
  update public.organization_memberships set role=p_role,active=p_active,updated_at=now() where organization_id=v_org and user_id=p_user_id;
  return true;
end;
$$;

alter table public.platform_admins enable row level security;
alter table public.organization_features enable row level security;
alter table public.organization_invitations enable row level security;

create policy "platform admins read platform admins" on public.platform_admins for select to authenticated using(public.is_platform_admin());
create policy "members read organization features" on public.organization_features for select to authenticated using(public.is_organization_member(organization_id));
create policy "admins manage organization features" on public.organization_features for all to authenticated using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));
create policy "admins manage organization invitations" on public.organization_invitations for all to authenticated using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));

create or replace function public.guard_customer_branch_tenant()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.preferred_branch_id is not null and not exists(select 1 from public.branches b where b.id=new.preferred_branch_id and b.organization_id=new.organization_id) then
    raise exception 'Preferred branch must belong to customer organization';
  end if;
  return new;
end $$;

create trigger guard_customer_branch before insert or update on public.customers for each row execute function public.guard_customer_branch_tenant();

create or replace function public.guard_order_tenant()
returns trigger language plpgsql set search_path=public as $$
begin
  if not exists(select 1 from public.branches b where b.id=new.branch_id and b.organization_id=new.organization_id) then raise exception 'Order branch must belong to organization'; end if;
  if new.customer_id is not null and not exists(select 1 from public.customers c where c.id=new.customer_id and c.organization_id=new.organization_id) then raise exception 'Order customer must belong to organization'; end if;
  return new;
end $$;

create trigger guard_laundry_order_tenant before insert or update on public.laundry_orders for each row execute function public.guard_order_tenant();

create or replace function public.guard_payment_tenant()
returns trigger language plpgsql set search_path=public as $$
begin
  if not exists(select 1 from public.laundry_orders o where o.id=new.order_id and o.organization_id=new.organization_id and o.branch_id=new.branch_id) then raise exception 'Payment must match order organization and branch'; end if;
  return new;
end $$;

create trigger guard_payment_tenant before insert or update on public.payments for each row execute function public.guard_payment_tenant();

grant execute on function public.bootstrap_first_platform_admin() to authenticated;
grant execute on function public.get_platform_admin_context() to authenticated;
grant execute on function public.set_organization_active(uuid,boolean) to authenticated;
grant execute on function public.grant_platform_admin(text) to authenticated;
grant execute on function public.get_organization_admin_context() to authenticated;
grant execute on function public.create_branch(text,text,text,text) to authenticated;
grant execute on function public.set_organization_feature(text,boolean) to authenticated;
grant execute on function public.invite_organization_user(text,public.staff_role,uuid) to authenticated;
grant execute on function public.accept_organization_invitation(uuid) to authenticated;
grant execute on function public.set_member_role(uuid,public.staff_role,boolean) to authenticated;

commit;
