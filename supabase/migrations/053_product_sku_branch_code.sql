-- Branch-based product SKU generation and immutable branch codes.
begin;

alter table public.products add column if not exists created_branch_id uuid references public.branches(id);

create table if not exists public.branch_product_sku_counters (
  branch_id uuid primary key references public.branches(id) on delete cascade,
  last_number bigint not null default 0
);

create or replace function public.next_product_sku(p_branch_id uuid)
returns text language plpgsql security definer set search_path=public as $$
declare v_code text;v_next bigint;
begin
  select upper(trim(code)) into v_code from public.branches where id=p_branch_id;
  if v_code is null or v_code='' then raise exception 'Branch code is required'; end if;
  insert into public.branch_product_sku_counters(branch_id,last_number) values(p_branch_id,1)
  on conflict(branch_id) do update set last_number=public.branch_product_sku_counters.last_number+1
  returning last_number into v_next;
  return v_code||'-'||lpad(v_next::text,5,'0');
end $$;

grant execute on function public.next_product_sku(uuid) to authenticated;

create or replace function public.save_product_v2(
 p_product_id uuid default null,
 p_branch_id uuid default null,
 p_name text default null,
 p_barcode text default null,
 p_cost_price numeric default 0,
 p_selling_price numeric default 0,
 p_loyalty_points integer default 0,
 p_active boolean default true
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_role public.staff_role;v_id uuid;v_sku text;
begin
 select organization_id,role into v_org,v_role from public.organization_memberships where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1;
 if v_org is null then raise exception 'Organization administrator access required'; end if;
 if nullif(trim(coalesce(p_name,'')),'') is null then raise exception 'Product name is required'; end if;
 if coalesce(p_cost_price,0)<0 or coalesce(p_selling_price,0)<0 then raise exception 'Prices cannot be negative'; end if;
 if p_product_id is null then
  if p_branch_id is null then raise exception 'Branch is required'; end if;
  if not exists(select 1 from public.branches where id=p_branch_id and organization_id=v_org and active) then raise exception 'Branch is invalid'; end if;
  v_sku:=public.next_product_sku(p_branch_id);
  insert into public.products(organization_id,created_branch_id,name,sku,barcode,cost_price,selling_price,loyalty_points,active)
  values(v_org,p_branch_id,trim(p_name),v_sku,nullif(trim(coalesce(p_barcode,'')),''),coalesce(p_cost_price,0),coalesce(p_selling_price,0),greatest(coalesce(p_loyalty_points,0),0),coalesce(p_active,true)) returning id into v_id;
 else
  update public.products set name=trim(p_name),barcode=nullif(trim(coalesce(p_barcode,'')),''),cost_price=coalesce(p_cost_price,0),selling_price=coalesce(p_selling_price,0),loyalty_points=greatest(coalesce(p_loyalty_points,0),0),active=coalesce(p_active,true),updated_at=now() where id=p_product_id and organization_id=v_org returning id into v_id;
  if v_id is null then raise exception 'Product not found'; end if;
 end if;
 return v_id;
end $$;

grant execute on function public.save_product_v2(uuid,uuid,text,text,numeric,numeric,integer,boolean) to authenticated;

create or replace function public.prevent_branch_code_change()
returns trigger language plpgsql as $$
begin
  if new.code is distinct from old.code then
    raise exception 'Branch code cannot be changed after the branch is created';
  end if;
  return new;
end $$;

drop trigger if exists branches_code_immutable on public.branches;
create trigger branches_code_immutable before update on public.branches for each row execute function public.prevent_branch_code_change();

commit;
