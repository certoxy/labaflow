-- Customer activation/archive controls. Order status continues through the existing audited status RPCs.
begin;

alter table public.customers alter column active set default true;
update public.customers set active=true where active is null;

create or replace function public.set_customer_active(p_customer_id uuid,p_active boolean)
returns public.customers language plpgsql security definer set search_path=public as $$
declare v_customer public.customers%rowtype;
begin
  select * into v_customer from public.customers where id=p_customer_id for update;
  if v_customer.id is null or not public.is_organization_member(v_customer.organization_id) then raise exception 'Customer not found'; end if;
  if not public.has_role_permission('manage_customers',v_customer.preferred_branch_id) then raise exception 'Customer management permission required'; end if;
  update public.customers set active=coalesce(p_active,false),updated_at=now() where id=v_customer.id returning * into v_customer;
  update public.customer_qr_tokens set active=coalesce(p_active,false) where customer_id=v_customer.id and organization_id=v_customer.organization_id;
  update public.customer_portal_access set active=coalesce(p_active,false) where customer_id=v_customer.id and organization_id=v_customer.organization_id;
  return v_customer;
end $$;

create or replace function public.list_inactive_customers_local(p_token uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_session public.local_staff_sessions%rowtype;v_staff public.local_staff_accounts%rowtype;
begin
  select * into v_session from public.local_staff_sessions where token=p_token and revoked_at is null and expires_at>now();
  if v_session.id is null then raise exception 'Staff session is invalid or expired'; end if;
  select * into v_staff from public.local_staff_accounts where id=v_session.staff_id and active;
  if v_staff.id is null or v_staff.role not in ('manager','cashier') then raise exception 'Customer management permission required'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',c.id,'customer_code',c.customer_code,'full_name',c.full_name,'mobile',c.mobile,'email',c.email,'loyalty_points',c.loyalty_points,'lifetime_points',c.lifetime_points,'lifetime_visits',c.lifetime_visits,'lifetime_spend',c.lifetime_spend) order by c.full_name) from public.customers c where c.organization_id=v_staff.organization_id and not c.active),'[]'::jsonb);
end $$;

create or replace function public.set_customer_active_local(p_token uuid,p_customer_id uuid,p_active boolean)
returns public.customers language plpgsql security definer set search_path=public as $$
declare v_session public.local_staff_sessions%rowtype;v_staff public.local_staff_accounts%rowtype;v_customer public.customers%rowtype;
begin
  select * into v_session from public.local_staff_sessions where token=p_token and revoked_at is null and expires_at>now();
  if v_session.id is null then raise exception 'Staff session is invalid or expired'; end if;
  select * into v_staff from public.local_staff_accounts where id=v_session.staff_id and active;
  if v_staff.id is null or v_staff.role not in ('manager','cashier') then raise exception 'Customer management permission required'; end if;
  update public.customers set active=coalesce(p_active,false),updated_at=now() where id=p_customer_id and organization_id=v_staff.organization_id returning * into v_customer;
  if v_customer.id is null then raise exception 'Customer not found'; end if;
  update public.customer_qr_tokens set active=coalesce(p_active,false) where customer_id=v_customer.id and organization_id=v_staff.organization_id;
  update public.customer_portal_access set active=coalesce(p_active,false) where customer_id=v_customer.id and organization_id=v_staff.organization_id;
  update public.local_staff_sessions set last_seen_at=now() where id=v_session.id;
  return v_customer;
end $$;

grant execute on function public.set_customer_active(uuid,boolean) to authenticated;
grant execute on function public.list_inactive_customers_local(uuid) to anon,authenticated;
grant execute on function public.set_customer_active_local(uuid,uuid,boolean) to anon,authenticated;

commit;
