-- LabaFlow organization and branch branding.
begin;

alter table public.organizations add column if not exists logo_url text;
alter table public.branches add column if not exists logo_url text;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('business-logos','business-logos',true,2097152,array['image/png','image/jpeg','image/webp'])
on conflict(id) do update set public=true,file_size_limit=2097152,allowed_mime_types=array['image/png','image/jpeg','image/webp'];

create policy "organization admins upload business logos" on storage.objects
for insert to authenticated
with check(
  bucket_id='business-logos' and
  exists(
    select 1 from public.organization_memberships m
    where m.user_id=auth.uid() and m.active and m.role in ('owner','admin')
      and m.organization_id::text=(storage.foldername(name))[1]
  )
);

create policy "organization admins update business logos" on storage.objects
for update to authenticated
using(
  bucket_id='business-logos' and
  exists(
    select 1 from public.organization_memberships m
    where m.user_id=auth.uid() and m.active and m.role in ('owner','admin')
      and m.organization_id::text=(storage.foldername(name))[1]
  )
)
with check(
  bucket_id='business-logos' and
  exists(
    select 1 from public.organization_memberships m
    where m.user_id=auth.uid() and m.active and m.role in ('owner','admin')
      and m.organization_id::text=(storage.foldername(name))[1]
  )
);

create policy "organization admins delete business logos" on storage.objects
for delete to authenticated
using(
  bucket_id='business-logos' and
  exists(
    select 1 from public.organization_memberships m
    where m.user_id=auth.uid() and m.active and m.role in ('owner','admin')
      and m.organization_id::text=(storage.foldername(name))[1]
  )
);

create or replace function public.set_organization_logo(p_logo_url text)
returns text language plpgsql security definer set search_path=public as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.organization_memberships
  where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;
  update public.organizations set logo_url=nullif(trim(coalesce(p_logo_url,'')),''),updated_at=now() where id=v_org;
  return (select logo_url from public.organizations where id=v_org);
end $$;

create or replace function public.set_branch_logo(p_branch_id uuid,p_logo_url text)
returns text language plpgsql security definer set search_path=public as $$
declare v_org uuid;
begin
  select organization_id into v_org from public.organization_memberships
  where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;
  update public.branches set logo_url=nullif(trim(coalesce(p_logo_url,'')),''),updated_at=now()
  where id=p_branch_id and organization_id=v_org;
  if not found then raise exception 'Branch not found'; end if;
  return (select logo_url from public.branches where id=p_branch_id);
end $$;

create or replace function public.get_my_branding_context()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_branch uuid;
begin
  select organization_id into v_org from public.organization_memberships
  where user_id=auth.uid() and active order by created_at limit 1;
  if v_org is null then return null; end if;
  select a.branch_id into v_branch from public.staff_branch_assignments a
  join public.branches b on b.id=a.branch_id and b.organization_id=v_org and b.active
  where a.staff_id=auth.uid() order by b.name limit 1;
  return jsonb_build_object(
    'organization_id',v_org,
    'organization_name',(select name from public.organizations where id=v_org),
    'organization_logo_url',(select logo_url from public.organizations where id=v_org),
    'branch_id',v_branch,
    'branch_name',(select name from public.branches where id=v_branch),
    'branch_logo_url',(select logo_url from public.branches where id=v_branch)
  );
end $$;

create or replace function public.get_local_staff_branding(p_token uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_session public.local_staff_sessions%rowtype;v_staff public.local_staff_accounts%rowtype;
begin
  select * into v_session from public.local_staff_sessions where token=p_token and revoked_at is null and expires_at>now();
  if v_session.token is null then raise exception 'Staff session is invalid or expired'; end if;
  select * into v_staff from public.local_staff_accounts where id=v_session.staff_id and active;
  if v_staff.id is null then raise exception 'Staff access is no longer active'; end if;
  return jsonb_build_object(
    'organization_id',v_session.organization_id,
    'organization_name',(select name from public.organizations where id=v_session.organization_id),
    'organization_logo_url',(select logo_url from public.organizations where id=v_session.organization_id),
    'branch_id',v_staff.branch_id,
    'branch_name',(select name from public.branches where id=v_staff.branch_id),
    'branch_logo_url',(select logo_url from public.branches where id=v_staff.branch_id)
  );
end $$;

create or replace function public.get_customer_branding(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_access public.customer_portal_access%rowtype;v_branch uuid;
begin
  select * into v_access from public.customer_portal_access where access_token=p_access_token and active;
  if v_access.id is null then raise exception 'Customer portal access is invalid'; end if;
  select o.branch_id into v_branch from public.laundry_orders o
  where o.organization_id=v_access.organization_id and o.customer_id=v_access.customer_id
  order by o.created_at desc limit 1;
  return jsonb_build_object(
    'organization_id',v_access.organization_id,
    'organization_name',(select name from public.organizations where id=v_access.organization_id),
    'organization_logo_url',(select logo_url from public.organizations where id=v_access.organization_id),
    'branch_id',v_branch,
    'branch_name',(select name from public.branches where id=v_branch),
    'branch_logo_url',(select logo_url from public.branches where id=v_branch)
  );
end $$;

create or replace function public.get_enrollment_branding(p_token uuid)
returns jsonb language sql security definer set search_path=public as $$
  select jsonb_build_object(
    'organization_id',o.id,
    'organization_name',o.name,
    'organization_logo_url',o.logo_url,
    'branch_id',null,
    'branch_name',null,
    'branch_logo_url',null
  )
  from public.organization_customer_portals p join public.organizations o on o.id=p.organization_id
  where p.enrollment_token=p_token and p.enabled and o.active limit 1;
$$;

create or replace function public.get_receipt_branding(p_order_id uuid,p_staff_token uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_order public.laundry_orders%rowtype;v_allowed boolean:=false;v_session public.local_staff_sessions%rowtype;
begin
  select * into v_order from public.laundry_orders where id=p_order_id;
  if v_order.id is null then raise exception 'Order not found'; end if;
  if auth.uid() is not null and public.is_organization_member(v_order.organization_id) then v_allowed:=true; end if;
  if not v_allowed and p_staff_token is not null then
    select * into v_session from public.local_staff_sessions where token=p_staff_token and revoked_at is null and expires_at>now();
    if v_session.token is not null and v_session.organization_id=v_order.organization_id then v_allowed:=true; end if;
  end if;
  if not v_allowed then raise exception 'Receipt access denied'; end if;
  return jsonb_build_object(
    'organization_id',v_order.organization_id,
    'organization_name',(select name from public.organizations where id=v_order.organization_id),
    'organization_logo_url',(select logo_url from public.organizations where id=v_order.organization_id),
    'branch_id',v_order.branch_id,
    'branch_name',(select name from public.branches where id=v_order.branch_id),
    'branch_logo_url',(select logo_url from public.branches where id=v_order.branch_id)
  );
end $$;

grant execute on function public.set_organization_logo(text) to authenticated;
grant execute on function public.set_branch_logo(uuid,text) to authenticated;
grant execute on function public.get_my_branding_context() to authenticated;
grant execute on function public.get_local_staff_branding(uuid) to anon,authenticated;
grant execute on function public.get_customer_branding(uuid) to anon,authenticated;
grant execute on function public.get_enrollment_branding(uuid) to anon,authenticated;
grant execute on function public.get_receipt_branding(uuid,uuid) to anon,authenticated;

commit;
