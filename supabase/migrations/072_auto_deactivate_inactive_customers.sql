-- Archive active customers after 30 days without a non-cancelled order.
-- Customers with no orders are archived 30 days after profile creation.

create or replace function public.deactivate_inactive_customers()
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare v_count integer;
begin
  with inactive as (
    select c.id
    from public.customers c
    where c.active
      and coalesce((
        select max(o.created_at)
        from public.laundry_orders o
        where o.customer_id=c.id
          and o.organization_id=c.organization_id
          and o.status<>'cancelled'
      ),c.created_at)<now()-interval '30 days'
  )
  update public.customers c
  set active=false,updated_at=now()
  from inactive i
  where c.id=i.id;

  get diagnostics v_count=row_count;
  return v_count;
end;
$$;

revoke all on function public.deactivate_inactive_customers() from public,anon,authenticated;

create extension if not exists pg_cron with schema extensions;

do $$
declare v_job_id bigint;
begin
  select jobid into v_job_id
  from cron.job
  where jobname='deactivate-inactive-customers-daily';

  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;

  perform cron.schedule(
    'deactivate-inactive-customers-daily',
    '15 2 * * *',
    'select public.deactivate_inactive_customers();'
  );
end;
$$;
