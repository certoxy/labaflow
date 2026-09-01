-- Fix receipt branding authorization and make organization membership lookup explicit.
begin;

create or replace function public.get_receipt_branding(p_order_id uuid,p_staff_token uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_order public.laundry_orders%rowtype;
  v_allowed boolean:=false;
  v_session public.local_staff_sessions%rowtype;
begin
  select * into v_order from public.laundry_orders where id=p_order_id;
  if v_order.id is null then raise exception 'Order not found'; end if;

  if auth.uid() is not null and exists (
    select 1 from public.organization_memberships m
    where m.user_id=auth.uid() and m.organization_id=v_order.organization_id and m.active
  ) then
    v_allowed:=true;
  end if;

  if not v_allowed and p_staff_token is not null then
    select * into v_session from public.local_staff_sessions
    where token=p_staff_token and revoked_at is null and expires_at>now();
    if v_session.token is not null and v_session.organization_id=v_order.organization_id then v_allowed:=true; end if;
  end if;

  if not v_allowed then raise exception 'Receipt access denied'; end if;

  return (
    select jsonb_build_object(
      'organization_id',o.id,
      'organization_name',o.name,
      'organization_logo_url',o.logo_url,
      'business_contact_person',o.contact_person,
      'business_phone',o.phone,
      'business_email',o.email,
      'business_address',o.address,
      'business_website',o.website,
      'receipt_footer',o.receipt_footer,
      'branch_id',b.id,
      'branch_name',b.name,
      'branch_logo_url',b.logo_url,
      'branch_phone',b.phone,
      'branch_address',b.address
    )
    from public.organizations o
    join public.branches b on b.id=v_order.branch_id and b.organization_id=o.id
    where o.id=v_order.organization_id
  );
end $$;

grant execute on function public.get_receipt_branding(uuid,uuid) to anon,authenticated;

commit;
