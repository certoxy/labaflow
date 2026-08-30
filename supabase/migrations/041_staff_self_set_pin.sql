-- LabaFlow v0.41 secure local staff PIN enrollment.
-- Organization admins create/reset staff access using a one-time setup code.
-- Staff choose their own permanent PIN; admins never need to know it.

begin;

alter table public.local_staff_accounts
  alter column pin_hash drop not null;

alter table public.local_staff_accounts
  add column if not exists setup_code_hash text,
  add column if not exists setup_code_expires_at timestamptz,
  add column if not exists pin_set_at timestamptz;

-- Existing accounts already have a PIN, so mark them as enrolled.
update public.local_staff_accounts
set pin_set_at=coalesce(pin_set_at,created_at)
where pin_hash is not null and pin_set_at is null;

create or replace function public.create_local_staff_account_v2(
  p_full_name text,
  p_username text,
  p_role public.staff_role,
  p_branch_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_org uuid;
  v_id uuid;
  v_username text:=lower(trim(p_username));
  v_setup_code text:=upper(substr(encode(extensions.gen_random_bytes(8),'hex'),1,10));
  v_expires timestamptz:=now()+interval '24 hours';
begin
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid() and active and role in ('owner','admin')
  order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;
  if nullif(trim(p_full_name),'') is null then raise exception 'Staff name is required'; end if;
  if v_username !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then raise exception 'Username must be 3-32 characters using letters, numbers, dot, underscore, or hyphen'; end if;
  if p_role not in ('manager','cashier','laundry_staff','delivery_staff','auditor') then raise exception 'Local staff role is not allowed'; end if;
  if p_branch_id is not null and not exists(select 1 from public.branches where id=p_branch_id and organization_id=v_org and active) then raise exception 'Invalid branch'; end if;

  insert into public.local_staff_accounts(
    organization_id,branch_id,full_name,username,pin_hash,role,created_by,
    setup_code_hash,setup_code_expires_at,pin_set_at
  ) values(
    v_org,p_branch_id,trim(p_full_name),v_username,null,p_role,auth.uid(),
    extensions.crypt(v_setup_code,extensions.gen_salt('bf',10)),v_expires,null
  ) returning id into v_id;

  return jsonb_build_object('id',v_id,'setup_code',v_setup_code,'setup_code_expires_at',v_expires);
exception when unique_violation then
  raise exception 'That username is already used in this organization';
end;
$$;

create or replace function public.issue_local_staff_pin_setup_code(p_staff_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_org uuid;
  v_setup_code text:=upper(substr(encode(extensions.gen_random_bytes(8),'hex'),1,10));
  v_expires timestamptz:=now()+interval '24 hours';
begin
  select organization_id into v_org
  from public.organization_memberships
  where user_id=auth.uid() and active and role in ('owner','admin')
  order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;

  update public.local_staff_accounts
  set setup_code_hash=extensions.crypt(v_setup_code,extensions.gen_salt('bf',10)),
      setup_code_expires_at=v_expires,
      pin_hash=null,
      pin_set_at=null,
      updated_at=now()
  where id=p_staff_id and organization_id=v_org;
  if not found then raise exception 'Local staff account not found'; end if;

  update public.local_staff_sessions
  set revoked_at=now()
  where staff_id=p_staff_id and revoked_at is null;

  return jsonb_build_object('setup_code',v_setup_code,'setup_code_expires_at',v_expires);
end;
$$;

create or replace function public.set_local_staff_pin(
  p_organization_slug text,
  p_username text,
  p_setup_code text,
  p_new_pin text
)
returns boolean
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
  v_org_id uuid;
  v_staff public.local_staff_accounts%rowtype;
begin
  if p_new_pin !~ '^[0-9]{4,8}$' then raise exception 'PIN must contain 4 to 8 digits'; end if;

  select id into v_org_id
  from public.organizations
  where slug=lower(trim(p_organization_slug)) and active
  limit 1;
  if v_org_id is null then raise exception 'Invalid organization, username, or setup code'; end if;

  select * into v_staff
  from public.local_staff_accounts
  where organization_id=v_org_id
    and username=lower(trim(p_username))
    and active
  limit 1;

  if v_staff.id is null
     or v_staff.setup_code_hash is null
     or v_staff.setup_code_expires_at is null
     or v_staff.setup_code_expires_at<=now()
     or extensions.crypt(upper(trim(p_setup_code)),v_staff.setup_code_hash)<>v_staff.setup_code_hash
  then
    raise exception 'Invalid or expired setup code';
  end if;

  update public.local_staff_accounts
  set pin_hash=extensions.crypt(p_new_pin,extensions.gen_salt('bf',10)),
      pin_set_at=now(),
      setup_code_hash=null,
      setup_code_expires_at=null,
      updated_at=now()
  where id=v_staff.id;

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
set search_path=public,extensions
as $$
declare v_staff public.local_staff_accounts%rowtype;v_org public.organizations%rowtype;v_branch public.branches%rowtype;v_token uuid;
begin
  select * into v_org from public.organizations where slug=lower(trim(p_organization_slug)) and active limit 1;
  if v_org.id is null then raise exception 'Invalid organization, username, or PIN'; end if;
  select * into v_staff from public.local_staff_accounts
  where organization_id=v_org.id and username=lower(trim(p_username)) and active limit 1;
  if v_staff.id is null then raise exception 'Invalid organization, username, or PIN'; end if;
  if v_staff.pin_hash is null then raise exception 'PIN setup required. Use your one-time setup code to create your PIN.'; end if;
  if extensions.crypt(p_pin,v_staff.pin_hash)<>v_staff.pin_hash then raise exception 'Invalid organization, username, or PIN'; end if;
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
  created_at timestamptz,
  pin_configured boolean
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
  select s.id,s.full_name,s.username,s.role,s.branch_id,b.name,s.active,s.last_login_at,s.created_at,(s.pin_hash is not null)
  from public.local_staff_accounts s
  left join public.branches b on b.id=s.branch_id
  where s.organization_id=v_org
  order by s.full_name;
end;
$$;

grant execute on function public.create_local_staff_account_v2(text,text,public.staff_role,uuid) to authenticated;
grant execute on function public.issue_local_staff_pin_setup_code(uuid) to authenticated;
grant execute on function public.set_local_staff_pin(text,text,text,text) to anon,authenticated;

commit;
