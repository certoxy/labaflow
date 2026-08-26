-- LabaFlow v0.3.1 platform-admin bootstrap status helper.
-- Allows an authenticated user to discover whether the initial platform-admin
-- bootstrap is still available without exposing platform-admin records.

begin;

create or replace function public.get_platform_admin_bootstrap_status()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_has_active_admin boolean;
  v_is_current_admin boolean;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select exists(
    select 1 from public.platform_admins where active
  ) into v_has_active_admin;

  select public.is_platform_admin() into v_is_current_admin;

  return jsonb_build_object(
    'bootstrap_available', not v_has_active_admin,
    'is_platform_admin', v_is_current_admin
  );
end;
$$;

grant execute on function public.get_platform_admin_bootstrap_status() to authenticated;

commit;
