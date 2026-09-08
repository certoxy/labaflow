-- A signed-in customer owns every active customer-app workspace whose active
-- customer record exactly matches their authenticated email. This also repairs
-- stale links left behind when an account was recreated with the same email.
begin;

create or replace function public.link_my_customer_portals_by_email()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_email text;
begin
  v_email:=lower(trim(coalesce(auth.jwt()->>'email','')));
  if auth.uid() is null or v_email='' then
    raise exception 'Customer sign in required';
  end if;

  insert into customer_portal_access(organization_id,customer_id,user_id,active,last_access_at)
  select c.organization_id,c.id,auth.uid(),true,now()
  from customers c
  join organizations o on o.id=c.organization_id and o.active
  where c.active and lower(trim(coalesce(c.email,'')))=v_email
  on conflict(organization_id,customer_id) do update
    set user_id=auth.uid(),active=true,last_access_at=now();

  return public.get_my_customer_portal_workspaces();
end $$;

grant execute on function public.link_my_customer_portals_by_email() to authenticated;

commit;
