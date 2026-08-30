-- LabaFlow customer portal: organization enrollment QR, customer self-registration, and customer dashboard.
begin;

create table if not exists public.organization_customer_portals (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  enrollment_token uuid not null default gen_random_uuid() unique,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.customer_portal_access (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete cascade,
  access_token uuid not null default gen_random_uuid() unique,
  active boolean not null default true,
  last_access_at timestamptz,
  created_at timestamptz not null default now(),
  unique(organization_id,customer_id)
);

alter table public.organization_customer_portals enable row level security;
alter table public.customer_portal_access enable row level security;

create policy "members read customer portal settings" on public.organization_customer_portals
for select to authenticated using(public.is_organization_member(organization_id));
create policy "admins manage customer portal settings" on public.organization_customer_portals
for all to authenticated using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));
create policy "members read customer portal access" on public.customer_portal_access
for select to authenticated using(public.is_organization_member(organization_id));

create or replace function public.get_organization_customer_qr()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_name text;v_token uuid;
begin
  select m.organization_id,o.name into v_org,v_name from organization_memberships m join organizations o on o.id=m.organization_id
  where m.user_id=auth.uid() and m.active order by m.created_at limit 1;
  if v_org is null then raise exception 'Organization access required'; end if;
  insert into organization_customer_portals(organization_id) values(v_org)
  on conflict(organization_id) do update set updated_at=now()
  returning enrollment_token into v_token;
  return jsonb_build_object('organization_id',v_org,'organization_name',v_name,'enrollment_token',v_token);
end $$;

grant execute on function public.get_organization_customer_qr() to authenticated;

create or replace function public.get_customer_enrollment_org(p_token uuid)
returns jsonb language sql security definer set search_path=public as $$
  select jsonb_build_object('organization_id',o.id,'organization_name',o.name,'slug',o.slug)
  from organization_customer_portals p join organizations o on o.id=p.organization_id
  where p.enrollment_token=p_token and p.enabled and o.active limit 1;
$$;
grant execute on function public.get_customer_enrollment_org(uuid) to anon,authenticated;

create or replace function public.enroll_customer_portal(p_token uuid,p_full_name text,p_mobile text default null,p_email text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_org_name text;v_customer customers%rowtype;v_access uuid;
begin
  select o.id,o.name into v_org,v_org_name from organization_customer_portals p join organizations o on o.id=p.organization_id
  where p.enrollment_token=p_token and p.enabled and o.active;
  if v_org is null then raise exception 'This customer enrollment QR is invalid or inactive'; end if;
  if nullif(trim(coalesce(p_full_name,'')),'') is null then raise exception 'Full name is required'; end if;
  if nullif(trim(coalesce(p_mobile,'')),'') is null and nullif(trim(coalesce(p_email,'')),'') is null then raise exception 'Enter a mobile number or email address'; end if;

  select * into v_customer from customers c where c.organization_id=v_org and c.active and (
    (nullif(trim(coalesce(p_mobile,'')),'') is not null and lower(trim(coalesce(c.mobile,'')))=lower(trim(p_mobile))) or
    (nullif(trim(coalesce(p_email,'')),'') is not null and lower(trim(coalesce(c.email,'')))=lower(trim(p_email)))
  ) order by c.created_at limit 1;

  if v_customer.id is null then
    insert into customers(organization_id,full_name,mobile,email)
    values(v_org,trim(p_full_name),nullif(trim(coalesce(p_mobile,'')),''),nullif(lower(trim(coalesce(p_email,''))),'')) returning * into v_customer;
  else
    update customers set full_name=trim(p_full_name),mobile=coalesce(nullif(trim(coalesce(p_mobile,'')),''),mobile),email=coalesce(nullif(lower(trim(coalesce(p_email,''))),''),email),updated_at=now()
    where id=v_customer.id returning * into v_customer;
  end if;

  insert into customer_portal_access(organization_id,customer_id) values(v_org,v_customer.id)
  on conflict(organization_id,customer_id) do update set active=true,last_access_at=now()
  returning access_token into v_access;

  return jsonb_build_object('organization_name',v_org_name,'customer_id',v_customer.id,'customer_code',v_customer.customer_code,'access_token',v_access);
end $$;
grant execute on function public.enroll_customer_portal(uuid,text,text,text) to anon,authenticated;

create or replace function public.get_customer_portal_dashboard(p_access_token uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_access customer_portal_access%rowtype;v_customer customers%rowtype;v_org_name text;v_orders jsonb;v_loyalty jsonb;
begin
  select * into v_access from customer_portal_access where access_token=p_access_token and active;
  if v_access.id is null then raise exception 'Customer portal access is invalid'; end if;
  select * into v_customer from customers where id=v_access.customer_id and organization_id=v_access.organization_id and active;
  if v_customer.id is null then raise exception 'Customer is inactive or unavailable'; end if;
  select name into v_org_name from organizations where id=v_access.organization_id;
  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_orders from (
    select o.id,o.order_code,o.status,o.payment_status,o.total,o.amount_paid,o.created_at,o.due_at,b.name branch_name
    from laundry_orders o join branches b on b.id=o.branch_id
    where o.organization_id=v_access.organization_id and o.customer_id=v_customer.id and o.status<>'cancelled'
    order by o.created_at desc limit 30
  ) x;
  select coalesce(jsonb_agg(x order by x.created_at desc),'[]'::jsonb) into v_loyalty from (
    select transaction_type,points,description,created_at from loyalty_transactions
    where organization_id=v_access.organization_id and customer_id=v_customer.id order by created_at desc limit 20
  ) x;
  update customer_portal_access set last_access_at=now() where id=v_access.id;
  return jsonb_build_object('organization_name',v_org_name,'customer',jsonb_build_object('id',v_customer.id,'customer_code',v_customer.customer_code,'full_name',v_customer.full_name,'mobile',v_customer.mobile,'email',v_customer.email,'loyalty_points',v_customer.loyalty_points,'lifetime_points',v_customer.lifetime_points,'lifetime_visits',v_customer.lifetime_visits,'lifetime_spend',v_customer.lifetime_spend),'orders',v_orders,'loyalty_history',v_loyalty);
end $$;
grant execute on function public.get_customer_portal_dashboard(uuid) to anon,authenticated;

commit;