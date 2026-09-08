-- Unified Android customer access with one account across multiple organizations.
begin;

alter table public.customer_portal_access
  add column if not exists user_id uuid references auth.users(id) on delete set null;

create index if not exists customer_portal_access_user_idx
  on public.customer_portal_access(user_id, active);

create or replace function public.get_my_customer_portal_workspaces()
returns jsonb language sql security definer set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'organization_id',a.organization_id,'organization_name',o.name,
    'customer_id',c.id,'customer_name',c.full_name,'customer_code',c.customer_code,
    'access_token',a.access_token
  ) order by o.name),'[]'::jsonb)
  from customer_portal_access a
  join customers c on c.id=a.customer_id and c.organization_id=a.organization_id
  join organizations o on o.id=a.organization_id
  where a.user_id=auth.uid() and a.active and c.active and o.active;
$$;
grant execute on function public.get_my_customer_portal_workspaces() to authenticated;

create or replace function public.link_my_customer_portals_by_email()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_email text;
begin
  v_email:=lower(trim(coalesce(auth.jwt()->>'email','')));
  if auth.uid() is null or v_email='' then raise exception 'Customer sign in required'; end if;
  update customer_portal_access a set user_id=auth.uid(),last_access_at=now()
  from customers c where c.id=a.customer_id and c.organization_id=a.organization_id
    and c.active and a.active and lower(trim(coalesce(c.email,'')))=v_email
    and (a.user_id is null or a.user_id=auth.uid());
  return public.get_my_customer_portal_workspaces();
end $$;
grant execute on function public.link_my_customer_portals_by_email() to authenticated;

create or replace function public.enroll_my_customer_portal(p_token uuid,p_full_name text,p_mobile text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_email text;v_result jsonb;v_access_token uuid;
begin
  v_email:=lower(trim(coalesce(auth.jwt()->>'email','')));
  if auth.uid() is null or v_email='' then raise exception 'Customer sign in required'; end if;
  v_result:=public.enroll_customer_portal(p_token,p_full_name,p_mobile,v_email);
  v_access_token:=(v_result->>'access_token')::uuid;
  update customer_portal_access set user_id=auth.uid(),active=true,last_access_at=now()
  where access_token=v_access_token and (user_id is null or user_id=auth.uid());
  if not found then raise exception 'This customer profile is already linked to another account'; end if;
  return v_result;
end $$;
grant execute on function public.enroll_my_customer_portal(uuid,text,text) to authenticated;

commit;
