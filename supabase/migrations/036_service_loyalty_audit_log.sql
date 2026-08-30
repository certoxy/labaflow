-- LabaFlow v0.9.2
-- Audit trail for service/pricing changes and manual loyalty adjustments.

begin;

create table if not exists public.management_audit_log (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  category text not null check (category in ('service','loyalty')),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  entity_name text,
  details jsonb not null default '{}'::jsonb,
  performed_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create index if not exists management_audit_log_org_created_idx on public.management_audit_log(organization_id,created_at desc);
create index if not exists management_audit_log_category_created_idx on public.management_audit_log(organization_id,category,created_at desc);

alter table public.management_audit_log enable row level security;
drop policy if exists "members read management audit log" on public.management_audit_log;
create policy "members read management audit log" on public.management_audit_log for select to authenticated using(public.is_organization_member(organization_id));

create or replace function public.create_laundry_service(
  p_name text,p_description text,p_pricing_unit public.pricing_unit,p_default_price numeric,p_loyalty_points integer default 0
) returns public.services language plpgsql security definer set search_path=public as $$
declare v_org uuid; v_service public.services%rowtype;
begin
 select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
 if v_org is null or not public.has_role_permission('manage_services') then raise exception 'Service management permission required'; end if;
 if nullif(trim(p_name),'') is null then raise exception 'Service name is required'; end if;
 if p_default_price<0 then raise exception 'Price cannot be negative'; end if;
 if coalesce(p_loyalty_points,0)<0 then raise exception 'Loyalty points cannot be negative'; end if;
 insert into public.services(organization_id,name,description,pricing_unit,default_price,loyalty_points) values(v_org,trim(p_name),nullif(trim(coalesce(p_description,'')),''),p_pricing_unit,p_default_price,coalesce(p_loyalty_points,0)) returning * into v_service;
 insert into public.management_audit_log(organization_id,category,action,entity_type,entity_id,entity_name,details,performed_by) values(v_org,'service','created','service',v_service.id,v_service.name,jsonb_build_object('price',v_service.default_price,'pricing_unit',v_service.pricing_unit,'loyalty_points',v_service.loyalty_points,'active',v_service.active),auth.uid());
 return v_service;
end;$$;

create or replace function public.update_laundry_service(
 p_service_id uuid,p_name text,p_description text,p_pricing_unit public.pricing_unit,p_default_price numeric,p_loyalty_points integer,p_active boolean
) returns public.services language plpgsql security definer set search_path=public as $$
declare v_org uuid; v_service public.services%rowtype; v_old public.services%rowtype;
begin
 select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
 if v_org is null or not public.has_role_permission('manage_services') then raise exception 'Service management permission required'; end if;
 if nullif(trim(p_name),'') is null then raise exception 'Service name is required'; end if;
 if p_default_price<0 then raise exception 'Service price cannot be negative'; end if;
 if p_loyalty_points<0 then raise exception 'Reward points cannot be negative'; end if;
 select * into v_old from public.services where id=p_service_id and organization_id=v_org for update;
 if v_old.id is null then raise exception 'Service not found'; end if;
 update public.services set name=trim(p_name),description=nullif(trim(coalesce(p_description,'')),''),pricing_unit=p_pricing_unit,default_price=p_default_price,loyalty_points=p_loyalty_points,active=p_active,updated_at=now() where id=p_service_id and organization_id=v_org returning * into v_service;
 insert into public.management_audit_log(organization_id,category,action,entity_type,entity_id,entity_name,details,performed_by) values(v_org,'service','updated','service',v_service.id,v_service.name,jsonb_build_object('before',jsonb_build_object('name',v_old.name,'price',v_old.default_price,'pricing_unit',v_old.pricing_unit,'loyalty_points',v_old.loyalty_points,'active',v_old.active),'after',jsonb_build_object('name',v_service.name,'price',v_service.default_price,'pricing_unit',v_service.pricing_unit,'loyalty_points',v_service.loyalty_points,'active',v_service.active)),auth.uid());
 return v_service;
end;$$;

create or replace function public.adjust_customer_loyalty(p_customer_id uuid,p_points integer,p_description text default null,p_branch_id uuid default null)
returns public.customers language plpgsql security definer set search_path=public as $$
declare v_customer public.customers%rowtype; v_before integer;
begin
 select * into v_customer from public.customers where id=p_customer_id for update;
 if v_customer.id is null then raise exception 'Customer not found'; end if;
 if not public.is_organization_member(v_customer.organization_id) or not public.has_role_permission('adjust_loyalty',p_branch_id) then raise exception 'Loyalty adjustment permission required'; end if;
 if p_points=0 then raise exception 'Adjustment cannot be zero'; end if;
 v_before:=v_customer.loyalty_points;
 if v_before+p_points<0 then raise exception 'Insufficient loyalty points'; end if;
 update public.customers set loyalty_points=loyalty_points+p_points,lifetime_points=case when p_points>0 then lifetime_points+p_points else lifetime_points end,updated_at=now() where id=v_customer.id returning * into v_customer;
 insert into public.loyalty_transactions(organization_id,customer_id,branch_id,transaction_type,points,description,reference_type,reference_id,created_by) values(v_customer.organization_id,v_customer.id,p_branch_id,'adjustment',p_points,coalesce(nullif(trim(p_description),''),'Manual loyalty adjustment'),'manual_adjustment',null,auth.uid());
 insert into public.management_audit_log(organization_id,category,action,entity_type,entity_id,entity_name,details,performed_by) values(v_customer.organization_id,'loyalty','adjusted','customer',v_customer.id,v_customer.full_name,jsonb_build_object('points',p_points,'balance_before',v_before,'balance_after',v_customer.loyalty_points,'description',coalesce(p_description,'Manual loyalty adjustment'),'branch_id',p_branch_id),auth.uid());
 return v_customer;
end;$$;

create or replace function public.get_management_audit_log(p_category text,p_limit integer default 50)
returns table(id uuid,category text,action text,entity_name text,details jsonb,performed_by_name text,performed_by_email text,created_at timestamptz)
language sql security definer set search_path=public as $$
 select l.id,l.category,l.action,l.entity_name,l.details,coalesce(p.full_name,p.email,'Unknown user'),p.email,l.created_at
 from public.management_audit_log l left join public.profiles p on p.id=l.performed_by
 where public.is_organization_member(l.organization_id) and (p_category is null or l.category=p_category)
 order by l.created_at desc limit least(greatest(coalesce(p_limit,50),1),200);
$$;

grant execute on function public.create_laundry_service(text,text,public.pricing_unit,numeric,integer) to authenticated;
grant execute on function public.update_laundry_service(uuid,text,text,public.pricing_unit,numeric,integer,boolean) to authenticated;
grant execute on function public.adjust_customer_loyalty(uuid,integer,text,uuid) to authenticated;
grant execute on function public.get_management_audit_log(text,integer) to authenticated;

commit;
