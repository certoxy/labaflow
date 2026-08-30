-- Fix PL/pgSQL ambiguity between RETURNS TABLE output column `active`
-- and table columns named `active` in get_local_staff_accounts().

begin;

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
  select m.organization_id into v_org
  from public.organization_memberships m
  where m.user_id=auth.uid()
    and m.active=true
    and m.role in ('owner','admin')
  order by m.created_at
  limit 1;

  if v_org is null then
    raise exception 'Organization administrator access required';
  end if;

  return query
  select
    s.id,
    s.full_name,
    s.username,
    s.role,
    s.branch_id,
    b.name as branch_name,
    s.active,
    s.last_login_at,
    s.created_at
  from public.local_staff_accounts s
  left join public.branches b on b.id=s.branch_id
  where s.organization_id=v_org
  order by s.full_name;
end;
$$;

grant execute on function public.get_local_staff_accounts() to authenticated;

commit;
