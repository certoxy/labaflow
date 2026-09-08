-- Create one customer-app workspace for every active customer record that
-- matches the authenticated user's verified email, across organizations.
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
  where c.active
    and lower(trim(coalesce(c.email,'')))=v_email
  on conflict(organization_id,customer_id) do update
    set user_id=case
      when customer_portal_access.user_id is null
        or customer_portal_access.user_id=auth.uid()
      then auth.uid()
      else customer_portal_access.user_id
    end,
    active=case
      when customer_portal_access.user_id is null
        or customer_portal_access.user_id=auth.uid()
      then true
      else customer_portal_access.active
    end,
    last_access_at=case
      when customer_portal_access.user_id is null
        or customer_portal_access.user_id=auth.uid()
      then now()
      else customer_portal_access.last_access_at
    end;

  return public.get_my_customer_portal_workspaces();
end $$;

grant execute on function public.link_my_customer_portals_by_email() to authenticated;

commit;
