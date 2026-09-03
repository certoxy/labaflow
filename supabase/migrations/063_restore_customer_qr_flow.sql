-- Restore customer QR display in My LabaFlow and QR lookup for local staff ordering.
begin;

create or replace function public.get_customer_portal_qr(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_access public.customer_portal_access%rowtype;v_customer public.customers%rowtype;v_qr_token uuid;
begin
  select * into v_access from public.customer_portal_access where access_token=p_access_token and active;
  if v_access.id is null then raise exception 'Customer portal access is invalid'; end if;
  select * into v_customer from public.customers where id=v_access.customer_id and organization_id=v_access.organization_id and active;
  if v_customer.id is null then raise exception 'Customer is inactive or unavailable'; end if;
  select token into v_qr_token from public.customer_qr_tokens where customer_id=v_customer.id and organization_id=v_access.organization_id and active order by created_at desc limit 1;
  if v_qr_token is null then
    insert into public.customer_qr_tokens(organization_id,customer_id) values(v_access.organization_id,v_customer.id) returning token into v_qr_token;
  end if;
  return jsonb_build_object('customer_code',v_customer.customer_code,'qr_token',v_qr_token);
end $$;

create or replace function public.lookup_customer_by_qr_local(p_token uuid,p_qr_token uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_session public.local_staff_sessions%rowtype;v_staff public.local_staff_accounts%rowtype;v_customer public.customers%rowtype;
begin
  select * into v_session from public.local_staff_sessions where token=p_token and revoked_at is null and expires_at>now();
  if v_session.id is null then raise exception 'Staff session is invalid or expired'; end if;
  select * into v_staff from public.local_staff_accounts where id=v_session.staff_id and active;
  if v_staff.id is null then raise exception 'Staff account is inactive'; end if;
  select c.* into v_customer from public.customer_qr_tokens q join public.customers c on c.id=q.customer_id
  where q.token=p_qr_token and q.active and c.active and c.organization_id=v_staff.organization_id and q.organization_id=v_staff.organization_id limit 1;
  if v_customer.id is null then raise exception 'QR code is invalid, inactive, or belongs to another organization'; end if;
  return to_jsonb(v_customer);
end $$;

grant execute on function public.get_customer_portal_qr(uuid) to anon,authenticated;
grant execute on function public.lookup_customer_by_qr_local(uuid,uuid) to anon,authenticated;

commit;
