-- LabaFlow v0.1.1 customer QR lookup and customer identity helpers.

begin;

create or replace function public.get_customer_qr(p_customer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_customer public.customers%rowtype;
  v_token uuid;
begin
  select * into v_customer
  from public.customers
  where id=p_customer_id
    and active
    and public.is_organization_member(organization_id);

  if v_customer.id is null then
    raise exception 'Customer not found';
  end if;

  select token into v_token
  from public.customer_qr_tokens
  where customer_id=v_customer.id and active
  order by created_at desc
  limit 1;

  if v_token is null then
    insert into public.customer_qr_tokens(organization_id,customer_id)
    values(v_customer.organization_id,v_customer.id)
    returning token into v_token;
  end if;

  return jsonb_build_object(
    'customer',to_jsonb(v_customer),
    'qr_token',v_token::text
  );
end;
$$;

create or replace function public.lookup_customer_by_qr(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_customer public.customers%rowtype;
begin
  select c.* into v_customer
  from public.customer_qr_tokens q
  join public.customers c on c.id=q.customer_id
  where q.token=p_token
    and q.active
    and c.active
    and public.is_organization_member(c.organization_id)
  limit 1;

  if v_customer.id is null then
    raise exception 'QR code is invalid, inactive, or belongs to another organization';
  end if;

  return to_jsonb(v_customer);
end;
$$;

grant execute on function public.get_customer_qr(uuid) to authenticated;
grant execute on function public.lookup_customer_by_qr(uuid) to authenticated;

commit;
