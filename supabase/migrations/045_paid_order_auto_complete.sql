-- LabaFlow: a fully paid order is automatically completed.
-- Centralized as a database trigger so authenticated, local-staff, and future payment paths behave consistently.
begin;

create or replace function public.complete_fully_paid_order()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  if new.payment_status='paid'::public.payment_status
     and new.status not in ('completed'::public.order_status,'cancelled'::public.order_status) then
    new.status:='completed'::public.order_status;
    new.completed_at:=coalesce(new.completed_at,now());
  end if;
  return new;
end;
$$;

drop trigger if exists laundry_orders_complete_when_paid on public.laundry_orders;
create trigger laundry_orders_complete_when_paid
before insert or update of payment_status on public.laundry_orders
for each row
execute function public.complete_fully_paid_order();

-- Keep the audit trail in sync when payment causes automatic completion.
create or replace function public.log_paid_order_auto_completion()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  if new.status='completed'::public.order_status
     and new.payment_status='paid'::public.payment_status
     and old.status is distinct from new.status then
    insert into public.order_status_history(order_id,status,changed_by,changed_by_local_staff,notes)
    values(
      new.id,
      'completed'::public.order_status,
      case when auth.uid() is not null then auth.uid() else null end,
      null,
      'Automatically completed when payment became fully paid'
    );
  end if;
  return new;
end;
$$;

drop trigger if exists laundry_orders_log_paid_completion on public.laundry_orders;
create trigger laundry_orders_log_paid_completion
after update of payment_status on public.laundry_orders
for each row
when (new.payment_status='paid'::public.payment_status and old.payment_status is distinct from new.payment_status)
execute function public.log_paid_order_auto_completion();

-- Align existing paid orders that are still open. Cancelled orders remain cancelled.
update public.laundry_orders
set status='completed'::public.order_status,
    completed_at=coalesce(completed_at,now()),
    updated_at=now()
where payment_status='paid'::public.payment_status
  and status not in ('completed'::public.order_status,'cancelled'::public.order_status);

commit;
