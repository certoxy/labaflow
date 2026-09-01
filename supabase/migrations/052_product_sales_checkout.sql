-- Add retail products to laundry order checkout with atomic inventory deduction.
begin;

create or replace function public.add_products_to_order(p_order_id uuid,p_products jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
 v_order public.laundry_orders%rowtype;v_item jsonb;v_product public.products%rowtype;
 v_qty numeric;v_stock numeric;v_product_total numeric:=0;v_existing_products numeric:=0;v_new_subtotal numeric;
begin
 select * into v_order from public.laundry_orders where id=p_order_id and public.can_access_branch(branch_id) for update;
 if v_order.id is null then raise exception 'Order not found or access denied'; end if;
 if v_order.payment_status<>'unpaid' then raise exception 'Products can only be added before payment is recorded'; end if;
 if coalesce(jsonb_array_length(coalesce(p_products,'[]'::jsonb)),0)=0 then return to_jsonb(v_order); end if;
 if exists(select 1 from public.order_product_items where order_id=v_order.id) then raise exception 'Products have already been added to this order'; end if;

 for v_item in select * from jsonb_array_elements(p_products) loop
  select * into v_product from public.products where id=(v_item->>'product_id')::uuid and organization_id=v_order.organization_id and active;
  if v_product.id is null then raise exception 'Product is invalid'; end if;
  v_qty:=coalesce((v_item->>'quantity')::numeric,0);
  if v_qty<=0 then raise exception 'Product quantity must be greater than zero'; end if;
  insert into public.branch_product_inventory(organization_id,branch_id,product_id,quantity)
   values(v_order.organization_id,v_order.branch_id,v_product.id,0) on conflict(branch_id,product_id) do nothing;
  select quantity into v_stock from public.branch_product_inventory where branch_id=v_order.branch_id and product_id=v_product.id for update;
  if v_stock<v_qty then raise exception 'Insufficient stock for % (available: %)',v_product.name,v_stock; end if;
  v_stock:=v_stock-v_qty;
  update public.branch_product_inventory set quantity=v_stock,updated_at=now() where branch_id=v_order.branch_id and product_id=v_product.id;
  insert into public.order_product_items(organization_id,order_id,branch_id,product_id,product_name,unit_price,quantity)
   values(v_order.organization_id,v_order.id,v_order.branch_id,v_product.id,v_product.name,v_product.selling_price,v_qty);
  insert into public.product_stock_movements(organization_id,branch_id,product_id,order_id,movement_type,quantity_change,balance_after,notes)
   values(v_order.organization_id,v_order.branch_id,v_product.id,v_order.id,'sale',-v_qty,v_stock,'Sold with '||v_order.order_code);
  v_product_total:=v_product_total+round(v_product.selling_price*v_qty,2);
 end loop;

 select coalesce(sum(line_total),0) into v_existing_products from public.order_product_items where order_id=v_order.id;
 -- Existing subtotal contains laundry service lines. Product rows are new, so add their total once.
 v_new_subtotal:=v_order.subtotal+v_product_total;
 update public.laundry_orders set subtotal=v_new_subtotal,total=greatest(v_new_subtotal-discount,0),updated_at=now() where id=v_order.id returning * into v_order;
 return to_jsonb(v_order);
end $$;

grant execute on function public.add_products_to_order(uuid,jsonb) to authenticated;

create or replace function public.get_order_product_items(p_order_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_order public.laundry_orders%rowtype;
begin
 select * into v_order from public.laundry_orders where id=p_order_id and public.can_access_branch(branch_id);
 if v_order.id is null then raise exception 'Order not found or access denied'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'product_id',i.product_id,'product_name',i.product_name,'quantity',i.quantity,'unit_price',i.unit_price,'line_total',i.line_total) order by i.created_at) from public.order_product_items i where i.order_id=p_order_id),'[]'::jsonb);
end $$;

grant execute on function public.get_order_product_items(uuid) to authenticated;

commit;
