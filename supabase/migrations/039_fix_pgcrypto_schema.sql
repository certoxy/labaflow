-- Supabase installs pgcrypto functions in the extensions schema.
-- Qualify crypt/gen_salt explicitly inside security-definer functions.

begin;

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
set search_path=public,extensions
as $$
declare v_org uuid;v_id uuid;v_username text:=lower(trim(p_username));
begin
  select m.organization_id into v_org
  from public.organization_memberships m
  where m.user_id=auth.uid() and m.active and m.role in ('owner','admin')
  order by m.created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;
  if nullif(trim(p_full_name),'') is null then raise exception 'Staff name is required'; end if;
  if v_username !~ '^[a-z0-9][a-z0-9._-]{2,31}$' then raise exception 'Username must be 3-32 characters using letters, numbers, dot, underscore, or hyphen'; end if;
  if p_pin !~ '^[0-9]{4,8}$' then raise exception 'PIN must contain 4 to 8 digits'; end if;
  if p_role not in ('manager','cashier','laundry_staff','delivery_staff','auditor') then raise exception 'Local staff role is not allowed'; end if;
  if p_branch_id is not null and not exists(select 1 from public.branches b where b.id=p_branch_id and b.organization_id=v_org and b.active) then raise exception 'Invalid branch'; end if;

  insert into public.local_staff_accounts(organization_id,branch_id,full_name,username,pin_hash,role,created_by)
  values(v_org,p_branch_id,trim(p_full_name),v_username,extensions.crypt(p_pin,extensions.gen_salt('bf',10)),p_role,auth.uid())
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
set search_path=public,extensions
as $$
declare v_org uuid;
begin
  select m.organization_id into v_org
  from public.organization_memberships m
  where m.user_id=auth.uid() and m.active and m.role in ('owner','admin')
  order by m.created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;
  if p_role not in ('manager','cashier','laundry_staff','delivery_staff','auditor') then raise exception 'Local staff role is not allowed'; end if;
  if p_branch_id is not null and not exists(select 1 from public.branches b where b.id=p_branch_id and b.organization_id=v_org and b.active) then raise exception 'Invalid branch'; end if;
  if p_new_pin is not null and p_new_pin !~ '^[0-9]{4,8}$' then raise exception 'PIN must contain 4 to 8 digits'; end if;

  update public.local_staff_accounts s
  set full_name=trim(p_full_name),role=p_role,branch_id=p_branch_id,active=p_active,
      pin_hash=case when p_new_pin is null then s.pin_hash else extensions.crypt(p_new_pin,extensions.gen_salt('bf',10)) end,
      updated_at=now()
  where s.id=p_staff_id and s.organization_id=v_org;
  if not found then raise exception 'Local staff account not found'; end if;
  if not p_active then update public.local_staff_sessions ls set revoked_at=now() where ls.staff_id=p_staff_id and ls.revoked_at is null; end if;
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
  select * into v_org from public.organizations o where o.slug=lower(trim(p_organization_slug)) and o.active limit 1;
  if v_org.id is null then raise exception 'Invalid organization, username, or PIN'; end if;
  select * into v_staff from public.local_staff_accounts s
  where s.organization_id=v_org.id and s.username=lower(trim(p_username)) and s.active limit 1;
  if v_staff.id is null or extensions.crypt(p_pin,v_staff.pin_hash)<>v_staff.pin_hash then raise exception 'Invalid organization, username, or PIN'; end if;
  if v_staff.branch_id is not null then select * into v_branch from public.branches b where b.id=v_staff.branch_id and b.active; end if;

  insert into public.local_staff_sessions(staff_id,organization_id,branch_id,role)
  values(v_staff.id,v_staff.organization_id,v_staff.branch_id,v_staff.role)
  returning token into v_token;
  update public.local_staff_accounts s set last_login_at=now(),updated_at=now() where s.id=v_staff.id;

  return jsonb_build_object(
    'token',v_token,
    'expires_at',now()+interval '12 hours',
    'staff',jsonb_build_object('id',v_staff.id,'full_name',v_staff.full_name,'username',v_staff.username,'role',v_staff.role),
    'organization',jsonb_build_object('id',v_org.id,'name',v_org.name,'slug',v_org.slug),
    'branch',case when v_branch.id is null then null else jsonb_build_object('id',v_branch.id,'name',v_branch.name,'code',v_branch.code) end
  );
end;
$$;

grant execute on function public.create_local_staff_account(text,text,text,public.staff_role,uuid) to authenticated;
grant execute on function public.update_local_staff_account(uuid,text,public.staff_role,uuid,boolean,text) to authenticated;
grant execute on function public.authenticate_local_staff(text,text,text) to anon,authenticated;

commit;
