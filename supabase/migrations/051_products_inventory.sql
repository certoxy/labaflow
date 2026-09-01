-- Products & Inventory for self-service retail sales.
begin;

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  sku text,
  barcode text,
  cost_price numeric(12,2) not null default 0 check (cost_price >= 0),
  selling_price numeric(12,2) not null default 0 check (selling_price >= 0),
  loyalty_points integer not null default 0 check (loyalty_points >= 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, sku),
  unique (organization_id, barcode)
);

create table if not exists public.branch_product_inventory (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  quantity numeric(12,3) not null default 0 check (quantity >= 0),
  low_stock_level numeric(12,3) not null default 0 check (low_stock_level >= 0),
  updated_at timestamptz not null default now(),
  unique (branch_id, product_id)
);

create table if not exists public.order_product_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  order_id uuid not null references public.laundry_orders(id) on delete cascade,
  branch_id uuid not null references public.branches(id),
  product_id uuid not null references public.products(id),
  product_name text not null,
  unit_price numeric(12,2) not null check (unit_price >= 0),
  quantity numeric(12,3) not null check (quantity > 0),
  line_total numeric(12,2) generated always as (round(unit_price * quantity,2)) stored,
  created_at timestamptz not null default now()
);

create table if not exists public.product_stock_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  branch_id uuid not null references public.branches(id),
  product_id uuid not null references public.products(id),
  order_id uuid references public.laundry_orders(id) on delete set null,
  movement_type text not null check (movement_type in ('opening','restock','sale','adjustment_add','adjustment_remove','correction')),
  quantity_change numeric(12,3) not null check (quantity_change <> 0),
  balance_after numeric(12,3) not null check (balance_after >= 0),
  notes text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create index if not exists products_org_idx on public.products(organization_id,name);
create index if not exists branch_product_inventory_branch_idx on public.branch_product_inventory(branch_id,product_id);
create index if not exists order_product_items_order_idx on public.order_product_items(order_id);
create index if not exists product_stock_movements_product_idx on public.product_stock_movements(product_id,created_at desc);

alter table public.products enable row level security;
alter table public.branch_product_inventory enable row level security;
alter table public.order_product_items enable row level security;
alter table public.product_stock_movements enable row level security;

create policy "members read products" on public.products for select to authenticated using (public.is_organization_member(organization_id));
create policy "members read inventory" on public.branch_product_inventory for select to authenticated using (public.is_organization_member(organization_id));
create policy "members read product order items" on public.order_product_items for select to authenticated using (public.is_organization_member(organization_id));
create policy "members read stock movements" on public.product_stock_movements for select to authenticated using (public.is_organization_member(organization_id));

create or replace function public.get_products_inventory()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid;
begin
 select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
 if v_org is null then raise exception 'Organization access required'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object(
   'id',p.id,'name',p.name,'sku',p.sku,'barcode',p.barcode,'cost_price',p.cost_price,'selling_price',p.selling_price,
   'loyalty_points',p.loyalty_points,'active',p.active,'branch_id',b.id,'branch_name',b.name,
   'quantity',coalesce(i.quantity,0),'low_stock_level',coalesce(i.low_stock_level,0)
 ) order by p.name,b.name)
 from public.products p cross join public.branches b
 left join public.branch_product_inventory i on i.product_id=p.id and i.branch_id=b.id
 where p.organization_id=v_org and b.organization_id=v_org and b.active), '[]'::jsonb);
end $$;

grant execute on function public.get_products_inventory() to authenticated;

create or replace function public.save_product(
 p_product_id uuid default null,p_name text default null,p_sku text default null,p_barcode text default null,
 p_cost_price numeric default 0,p_selling_price numeric default 0,p_loyalty_points integer default 0,p_active boolean default true
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_role public.staff_role;v_id uuid;
begin
 select organization_id,role into v_org,v_role from public.organization_memberships where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1;
 if v_org is null then raise exception 'Organization administrator access required'; end if;
 if nullif(trim(coalesce(p_name,'')),'') is null then raise exception 'Product name is required'; end if;
 if coalesce(p_cost_price,0)<0 or coalesce(p_selling_price,0)<0 then raise exception 'Prices cannot be negative'; end if;
 if p_product_id is null then
  insert into public.products(organization_id,name,sku,barcode,cost_price,selling_price,loyalty_points,active)
  values(v_org,trim(p_name),nullif(trim(coalesce(p_sku,'')),''),nullif(trim(coalesce(p_barcode,'')),''),coalesce(p_cost_price,0),coalesce(p_selling_price,0),greatest(coalesce(p_loyalty_points,0),0),coalesce(p_active,true)) returning id into v_id;
 else
  update public.products set name=trim(p_name),sku=nullif(trim(coalesce(p_sku,'')),''),barcode=nullif(trim(coalesce(p_barcode,'')),''),cost_price=coalesce(p_cost_price,0),selling_price=coalesce(p_selling_price,0),loyalty_points=greatest(coalesce(p_loyalty_points,0),0),active=coalesce(p_active,true),updated_at=now() where id=p_product_id and organization_id=v_org returning id into v_id;
  if v_id is null then raise exception 'Product not found'; end if;
 end if;
 return v_id;
end $$;

grant execute on function public.save_product(uuid,text,text,text,numeric,numeric,integer,boolean) to authenticated;

create or replace function public.adjust_product_stock(p_product_id uuid,p_branch_id uuid,p_quantity_change numeric,p_notes text default null)
returns numeric language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_role public.staff_role;v_current numeric;v_new numeric;v_type text;
begin
 select organization_id,role into v_org,v_role from public.organization_memberships where user_id=auth.uid() and active and role in ('owner','admin') order by created_at limit 1;
 if v_org is null then raise exception 'Organization administrator access required'; end if;
 if coalesce(p_quantity_change,0)=0 then raise exception 'Stock adjustment cannot be zero'; end if;
 if not exists(select 1 from public.products where id=p_product_id and organization_id=v_org) then raise exception 'Product not found'; end if;
 if not exists(select 1 from public.branches where id=p_branch_id and organization_id=v_org) then raise exception 'Branch not found'; end if;
 insert into public.branch_product_inventory(organization_id,branch_id,product_id,quantity) values(v_org,p_branch_id,p_product_id,0) on conflict(branch_id,product_id) do nothing;
 select quantity into v_current from public.branch_product_inventory where branch_id=p_branch_id and product_id=p_product_id for update;
 v_new:=v_current+p_quantity_change;
 if v_new<0 then raise exception 'Insufficient stock'; end if;
 update public.branch_product_inventory set quantity=v_new,updated_at=now() where branch_id=p_branch_id and product_id=p_product_id;
 v_type:=case when p_quantity_change>0 then 'adjustment_add' else 'adjustment_remove' end;
 insert into public.product_stock_movements(organization_id,branch_id,product_id,movement_type,quantity_change,balance_after,notes) values(v_org,p_branch_id,p_product_id,v_type,p_quantity_change,v_new,p_notes);
 return v_new;
end $$;

grant execute on function public.adjust_product_stock(uuid,uuid,numeric,text) to authenticated;

commit;
