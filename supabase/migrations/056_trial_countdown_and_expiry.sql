-- Member-visible trial status and transaction lock after trial expiry.
begin;
create or replace function public.get_my_subscription_status()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid;v_role public.staff_role;v_sub public.organization_subscriptions%rowtype;v_plan text;
begin
 select organization_id,role into v_org,v_role from public.organization_memberships where user_id=auth.uid() and active order by created_at limit 1;
 if v_org is null then return null; end if;
 select * into v_sub from public.organization_subscriptions where organization_id=v_org;
 if v_sub.organization_id is null then return null; end if;
 select display_name into v_plan from public.subscription_plans where plan_key=v_sub.plan_key;
 return jsonb_build_object('organization_id',v_org,'status',v_sub.status,'plan_key',v_sub.plan_key,'plan_name',v_plan,'trial_started_at',v_sub.trial_started_at,'trial_ends_at',v_sub.trial_ends_at,'in_trial',v_sub.status='trialing' and now()<v_sub.trial_ends_at,'trial_expired',v_sub.status='trialing' and now()>=v_sub.trial_ends_at,'can_manage_subscription',v_role in ('owner','admin'));
end $$;
create or replace function public.guard_subscription_transactions()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_sub public.organization_subscriptions%rowtype;
begin
 select * into v_sub from public.organization_subscriptions where organization_id=new.organization_id;
 if v_sub.status in ('suspended','cancelled') or (v_sub.status='trialing' and now()>=v_sub.trial_ends_at) then raise exception 'The organization trial has expired. Existing records remain available, but new transactions require an active subscription.'; end if;
 return new;
end $$;
drop trigger if exists laundry_orders_subscription_guard on public.laundry_orders;
create trigger laundry_orders_subscription_guard before insert on public.laundry_orders for each row execute function public.guard_subscription_transactions();
grant execute on function public.get_my_subscription_status() to authenticated;
commit;
