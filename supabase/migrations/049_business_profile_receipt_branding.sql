-- Editable business identity and complete receipt branding.
begin;

alter table public.organizations add column if not exists contact_person text;
alter table public.organizations add column if not exists phone text;
alter table public.organizations add column if not exists email text;
alter table public.organizations add column if not exists address text;
alter table public.organizations add column if not exists website text;
alter table public.organizations add column if not exists receipt_footer text;

create or replace function public.update_organization_business_profile(
  p_name text,
  p_contact_person text default null,
  p_phone text default null,
  p_email text default null,
  p_address text default null,
  p_website text default null,
  p_receipt_footer text default null
)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_role public.staff_role;
begin
  select organization_id,role into v_org,v_role from public.organization_memberships
  where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1;
  if v_org is null then raise exception 'Organization administrator access required'; end if;
  if nullif(trim(coalesce(p_name,'')),'') is null then raise exception 'Business name is required'; end if;
  update public.organizations set
    name=trim(p_name),contact_person=nullif(trim(coalesce(p_contact_person,'')),''),
    phone=nullif(trim(coalesce(p_phone,'')),''),email=nullif(trim(coalesce(p_email,'')),''),
    address=nullif(trim(coalesce(p_address,'')),''),website=nullif(trim(coalesce(p_website,'')),''),
    receipt_footer=nullif(trim(coalesce(p_receipt_footer,'')),''),updated_at=now()
  where id=v_org;
  return true;
end $$;

grant execute on function public.update_organization_business_profile(text,text,text,text,text,text,text) to authenticated;

-- Extend receipt branding so every receipt surface has one canonical source.
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
  return (
    select jsonb_build_object(
      'organization_id',o.id,'organization_name',o.name,'organization_logo_url',o.logo_url,
      'business_contact_person',o.contact_person,'business_phone',o.phone,'business_email',o.email,
      'business_address',o.address,'business_website',o.website,'receipt_footer',o.receipt_footer,
      'branch_id',b.id,'branch_name',b.name,'branch_logo_url',b.logo_url,
      'branch_phone',b.phone,'branch_address',b.address
    ) from public.organizations o join public.branches b on b.id=v_order.branch_id where o.id=v_order.organization_id
  );
end $$;

grant execute on function public.get_receipt_branding(uuid,uuid) to anon,authenticated;

commit;
