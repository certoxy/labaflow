-- LabaFlow v0.37 organization-local staff accounts.
-- Local staff do not require Supabase Auth users. Privileged org admins create them.

begin;

create extension if not exists pgcrypto;

create table if not exists public.local_staff_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid references public.branches(id) on delete set null,
  full_name text not null,
  username text not null,
  pin_hash text not null,
  role public.staff_role not null,
  active boolean not null default true,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_login_at timestamptz,
  constraint local_staff_role_check check (role in ('manager','cashier','laundry_staff','delivery_staff','auditor')),
  constraint local_staff_username_format check (username ~ '^[a-z0-9][a-z0-9._-]{2,31}$'),
  unique (organization_id, username)
);

create index if not exists local_staff_accounts_org_idx
  on public.local_staff_accounts(organization_id, active, full_name);

create table if not exists public.local_staff_sessions (
  token uuid primary key default gen_random_uuid(),
  staff_id uuid not null references public.local_staff_accounts(id) on delete cascade,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid references public.branches(id) on delete set null,
  role public.staff_role not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '12 hours'),
  revoked_at timestamptz,
  last_seen_at timestamptz not null default now()
);

create index if not exists local_staff_sessions_staff_idx
  on public.local_staff_sessions(staff_id, expires_at desc);

alter table public.local_staff_accounts enable row level security;
alter table public.local_staff_sessions enable row level security;

create policy "org admins read local staff"
on public.local_staff_accounts for select to authenticated
using(public.is_organization_admin(organization_id));

create or replace function public.get_local_staff_accounts()
returns table(
  id uuid,
  full_name text,
  username text,
  role public.staff_role,
  branch_id uuid,
  branch_name text,
  active boolean,
  last_login_at timestamptz,
  created_at timestamptz
)
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

  return query
  select s.id,s.full_name,s.username,s.role,s.branch_id,b.name,s.active,s.last_login_at,s.created_at
  from public.local_staff_accounts s
  left join public.branches b on b.id=s.branch_id
  where s.organization_id=v_org
  order by s.full_name;
end;
$$;

create or replace function public.create_local_staff_account(
  p_full_name text,
  p_username text,
  p_pin text,
  p_role public.staff_role,
  p_branch_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare v_org uuid;v_id uuid;v_username text:=lower(trim(p_username));
begin
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid() and active and role in ('owner','admin')
  order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;
  if nullif(trim(p_full_name),'') is null then raise exception 'Staff name is required'; end if;
  if v_username !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then raise exception 'Username must be 3-32 characters using letters, numbers, dot, underscore, or hyphen'; end if;
  if p_pin !~ '^[0-9]{4,8}$' then raise exception 'PIN must contain 4 to 8 digits'; end if;
  if p_role not in ('manager','cashier','laundry_staff','delivery_staff','auditor') then raise exception 'Local staff role is not allowed'; end if;
  if p_branch_id is not null and not exists(select 1 from public.branches where id=p_branch_id and organization_id=v_org and active) then raise exception 'Invalid branch'; end if;

  insert into public.local_staff_accounts(organization_id,branch_id,full_name,username,pin_hash,role,created_by)
  values(v_org,p_branch_id,trim(p_full_name),v_username,crypt(p_pin,gen_salt('bf',10)),p_role,auth.uid())
  returning id into v_id;
  return v_id;
exception when unique_violation then
  raise exception 'That username is already used in this organization';
end;
$$;

create or replace function public.update_local_staff_account(
  p_staff_id uuid,
  p_full_name text,
  p_role public.staff_role,
  p_branch_id uuid,
  p_active boolean,
  p_new_pin text default null
)
returns boolean
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
  if p_role not in ('manager','cashier','laundry_staff','delivery_staff','auditor') then raise exception 'Local staff role is not allowed'; end if;
  if p_branch_id is not null and not exists(select 1 from public.branches where id=p_branch_id and organization_id=v_org and active) then raise exception 'Invalid branch'; end if;
  if p_new_pin is not null and p_new_pin !~ '^[0-9]{4,8}$' then raise exception 'PIN must contain 4 to 8 digits'; end if;

  update public.local_staff_accounts
  set full_name=trim(p_full_name),role=p_role,branch_id=p_branch_id,active=p_active,
      pin_hash=case when p_new_pin is null then pin_hash else crypt(p_new_pin,gen_salt('bf',10)) end,
      updated_at=now()
  where id=p_staff_id and organization_id=v_org;
  if not found then raise exception 'Local staff account not found'; end if;
  if not p_active then update public.local_staff_sessions set revoked_at=now() where staff_id=p_staff_id and revoked_at is null; end if;
  return true;
end;
$$;

create or replace function public.authenticate_local_staff(
  p_organization_slug text,
  p_username text,
  p_pin text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_staff public.local_staff_accounts%rowtype;v_org public.organizations%rowtype;v_branch public.branches%rowtype;v_token uuid;
begin
  select * into v_org from public.organizations where slug=lower(trim(p_organization_slug)) and active limit 1;
  if v_org.id is null then raise exception 'Invalid organization, username, or PIN'; end if;
  select * into v_staff from public.local_staff_accounts
  where organization_id=v_org.id and username=lower(trim(p_username)) and active limit 1;
  if v_staff.id is null or crypt(p_pin,v_staff.pin_hash)<>v_staff.pin_hash then raise exception 'Invalid organization, username, or PIN'; end if;
  if v_staff.branch_id is not null then select * into v_branch from public.branches where id=v_staff.branch_id and active; end if;

  insert into public.local_staff_sessions(staff_id,organization_id,branch_id,role)
  values(v_staff.id,v_staff.organization_id,v_staff.branch_id,v_staff.role)
  returning token into v_token;
  update public.local_staff_accounts set last_login_at=now(),updated_at=now() where id=v_staff.id;

  return jsonb_build_object(
    'token',v_token,
    'expires_at',now()+interval '12 hours',
    'staff',jsonb_build_object('id',v_staff.id,'full_name',v_staff.full_name,'username',v_staff.username,'role',v_staff.role),
    'organization',jsonb_build_object('id',v_org.id,'name',v_org.name,'slug',v_org.slug),
    'branch',case when v_branch.id is null then null else jsonb_build_object('id',v_branch.id,'name',v_branch.name,'code',v_branch.code) end
  );
end;
$$;

create or replace function public.get_local_staff_session(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_session public.local_staff_sessions%rowtype;v_staff public.local_staff_accounts%rowtype;v_org public.organizations%rowtype;v_branch public.branches%rowtype;
begin
  select * into v_session from public.local_staff_sessions where token=p_token and revoked_at is null and expires_at>now();
  if v_session.token is null then return null; end if;
  select * into v_staff from public.local_staff_accounts where id=v_session.staff_id and active;
  select * into v_org from public.organizations where id=v_session.organization_id and active;
  if v_staff.id is null or v_org.id is null then return null; end if;
  if v_session.branch_id is not null then select * into v_branch from public.branches where id=v_session.branch_id and active; end if;
  update public.local_staff_sessions set last_seen_at=now() where token=p_token;
  return jsonb_build_object(
    'token',v_session.token,'expires_at',v_session.expires_at,
    'staff',jsonb_build_object('id',v_staff.id,'full_name',v_staff.full_name,'username',v_staff.username,'role',v_staff.role),
    'organization',jsonb_build_object('id',v_org.id,'name',v_org.name,'slug',v_org.slug),
    'branch',case when v_branch.id is null then null else jsonb_build_object('id',v_branch.id,'name',v_branch.name,'code',v_branch.code) end
  );
end;
$$;

create or replace function public.logout_local_staff(p_token uuid)
returns boolean
language sql
security definer
set search_path=public
as $$ update public.local_staff_sessions set revoked_at=now() where token=p_token and revoked_at is null returning true $$;

grant execute on function public.get_local_staff_accounts() to authenticated;
grant execute on function public.create_local_staff_account(text,text,text,public.staff_role,uuid) to authenticated;
grant execute on function public.update_local_staff_account(uuid,text,public.staff_role,uuid,boolean,text) to authenticated;
grant execute on function public.authenticate_local_staff(text,text,text) to anon,authenticated;
grant execute on function public.get_local_staff_session(uuid) to anon,authenticated;
grant execute on function public.logout_local_staff(uuid) to anon,authenticated;

commit;
