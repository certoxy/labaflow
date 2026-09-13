-- Allow Platform Admins to disable or reactivate other Platform Admins safely.
begin;

create or replace function public.set_platform_admin_active(
  p_user_id uuid,
  p_active boolean
)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_current_active boolean;
  v_target_active boolean;
  v_active_count integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select active into v_current_active
  from public.platform_admins
  where user_id=auth.uid();

  if coalesce(v_current_active,false) is not true then
    raise exception 'Platform administrator access required';
  end if;

  select active into v_target_active
  from public.platform_admins
  where user_id=p_user_id
  for update;

  if not found then
    raise exception 'Platform administrator not found';
  end if;

  if p_active=false and p_user_id=auth.uid() then
    raise exception 'You cannot disable your own Platform Admin access';
  end if;

  if p_active=false and v_target_active=true then
    select count(*) into v_active_count
    from public.platform_admins
    where active=true;

    if v_active_count<=1 then
      raise exception 'The last active Platform Admin cannot be disabled';
    end if;
  end if;

  update public.platform_admins
  set active=p_active,
      granted_at=case when p_active and not v_target_active then now() else granted_at end,
      granted_by=case when p_active and not v_target_active then auth.uid() else granted_by end
  where user_id=p_user_id;

  if p_active=false then
    update public.platform_support_sessions
    set ended_at=coalesce(ended_at,now()),
        end_reason=case when ended_at is null then 'platform_admin_disabled' else end_reason end
    where platform_admin_id=p_user_id
      and ended_at is null;
  end if;

  return true;
end;
$$;

revoke all on function public.set_platform_admin_active(uuid,boolean) from public;
grant execute on function public.set_platform_admin_active(uuid,boolean) to authenticated;

commit;
