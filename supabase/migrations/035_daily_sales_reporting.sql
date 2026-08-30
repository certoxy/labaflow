begin;

create or replace function public.get_daily_sales_report(p_date date,p_branch_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare
 v_org uuid;v_start timestamptz;v_end timestamptz;v_result jsonb;
begin
 select organization_id into v_org from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
 if v_org is null then raise exception 'Active organization membership required'; end if;
 if p_branch_id is not null and not exists(select 1 from public.branches where id=p_branch_id and organization_id=v_org and public.can_access_branch(id)) then raise exception 'Branch access denied'; end if;
 v_start:=p_date::timestamp at time zone 'Asia/Manila';v_end:=(p_date+1)::timestamp at time zone 'Asia/Manila';
 with ord as (
  select o.* from public.laundry_orders o where o.organization_id=v_org and o.created_at>=v_start and o.created_at<v_end and (p_branch_id is null or o.branch_id=p_branch_id) and public.can_access_branch(o.branch_id)
 ), pay as (
  select p.* from public.payments p where p.organization_id=v_org and p.created_at>=v_start and p.created_at<v_end and (p_branch_id is null or p.branch_id=p_branch_id) and public.can_access_branch(p.branch_id)
 ), svc as (
  select s.id,s.name,sum(i.quantity) quantity,sum(i.line_total) sales from ord o join public.laundry_order_items i on i.order_id=o.id join public.services s on s.id=i.service_id group by s.id,s.name
 ), cashier as (
  select coalesce(pr.full_name,pr.email,'Unknown') cashier,p.method,sum(p.amount) amount,count(*) transactions from pay p left join public.profiles pr on pr.id=p.received_by group by coalesce(pr.full_name,pr.email,'Unknown'),p.method
 )
 select jsonb_build_object(
  'summary',jsonb_build_object('gross_sales',coalesce((select sum(subtotal) from ord),0),'discounts',coalesce((select sum(discount) from ord),0),'net_sales',coalesce((select sum(total) from ord),0),'amount_collected',coalesce((select sum(amount) from pay),0),'outstanding',coalesce((select sum(greatest(total-amount_paid,0)) from ord),0),'orders',(select count(*) from ord),'paid_orders',(select count(*) from ord where payment_status='paid' or amount_paid>=total),'customers',(select count(distinct customer_id) from ord where customer_id is not null),'walkins',(select count(*) from ord where customer_id is null)),
  'services',coalesce((select jsonb_agg(to_jsonb(svc) order by sales desc) from svc),'[]'::jsonb),
  'cashiers',coalesce((select jsonb_agg(to_jsonb(cashier) order by cashier,method) from cashier),'[]'::jsonb),
  'branches',coalesce((select jsonb_agg(x) from (select b.id,b.name,coalesce(sum(o.total),0) net_sales,count(o.id) orders from public.branches b left join ord o on o.branch_id=b.id where b.organization_id=v_org and public.can_access_branch(b.id) group by b.id,b.name order by b.name)x),'[]'::jsonb),
  'discounts',coalesce((select jsonb_agg(x) from (select order_code,discount,total from ord where discount>0 order by discount desc)x),'[]'::jsonb)
 ) into v_result;
 return v_result;
end $$;
grant execute on function public.get_daily_sales_report(date,uuid) to authenticated;

commit;
