-- LabaFlow: idempotent wrapper for offline order synchronization.
-- The client-generated operation UUID is stored before the order RPC is called,
-- so reconnect/retry cannot create the same order twice.

create table if not exists public.offline_sync_operations (
  id uuid primary key,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  operation_type text not null,
  result jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint offline_sync_operation_type_check check (operation_type in ('create_order'))
);

create index if not exists offline_sync_operations_org_idx
  on public.offline_sync_operations(organization_id,created_at desc);

alter table public.offline_sync_operations enable row level security;

drop policy if exists "members read own offline sync operations" on public.offline_sync_operations;
create policy "members read own offline sync operations"
on public.offline_sync_operations for select to authenticated
using (user_id=auth.uid() and public.is_organization_member(organization_id));

create or replace function public.sync_offline_order(
  p_operation_id uuid,
  p_branch_id uuid,
  p_customer_id uuid,
  p_items jsonb,
  p_discount numeric default 0,
  p_notes text default null,
  p_due_at timestamptz default null,
  p_delivery_addon_type public.delivery_addon_type default null,
  p_delivery_distance_rate_id uuid default null,
  p_loyalty_points_to_redeem integer default 0,
  p_promo_code text default null
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_org uuid;
  v_existing public.offline_sync_operations%rowtype;
  v_result jsonb;
begin
  if p_operation_id is null then raise exception 'Offline operation id is required'; end if;

  select organization_id into v_org
  from public.branches
  where id=p_branch_id and public.can_access_branch(id);
  if v_org is null then raise exception 'Branch access denied'; end if;

  select * into v_existing
  from public.offline_sync_operations
  where id=p_operation_id;

  if v_existing.id is not null then
    if v_existing.organization_id<>v_org or v_existing.user_id<>auth.uid() or v_existing.operation_type<>'create_order' then
      raise exception 'Offline operation id is already in use';
    end if;
    if v_existing.result is not null then return v_existing.result; end if;
  else
    insert into public.offline_sync_operations(id,organization_id,user_id,operation_type)
    values(p_operation_id,v_org,auth.uid(),'create_order');
  end if;

  v_result:=public.create_laundry_order(
    p_branch_id,p_customer_id,p_items,p_discount,p_notes,p_due_at,
    p_delivery_addon_type,p_delivery_distance_rate_id,p_loyalty_points_to_redeem,p_promo_code
  );

  update public.offline_sync_operations
  set result=v_result,completed_at=now()
  where id=p_operation_id;

  return v_result;
end;
$$;

grant select on public.offline_sync_operations to authenticated;
grant execute on function public.sync_offline_order(uuid,uuid,uuid,jsonb,numeric,text,timestamptz,public.delivery_addon_type,uuid,integer,text) to authenticated;
