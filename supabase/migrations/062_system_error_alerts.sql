-- Centralized, tenant-aware application error monitoring for Platform Admins.
begin;

create table public.system_error_events (
 id uuid primary key default gen_random_uuid(),
 fingerprint text not null,
 organization_id uuid references public.organizations(id) on delete set null,
 user_id uuid references public.profiles(id) on delete set null,
 severity text not null default 'medium' check(severity in ('low','medium','high','critical')),
 source text not null default 'client' check(source in ('client','server','edge')),
 error_code text,
 message text not null,
 route text,
 stack text,
 user_agent text,
 details jsonb not null default '{}'::jsonb,
 status text not null default 'new' check(status in ('new','investigating','resolved','ignored')),
 occurrence_count integer not null default 1,
 first_occurred_at timestamptz not null default now(),
 last_occurred_at timestamptz not null default now(),
 notified_at timestamptz,
 acknowledged_by uuid references public.profiles(id),
 acknowledged_at timestamptz,
 resolution_notes text,
 resolved_by uuid references public.profiles(id),
 resolved_at timestamptz
);
create index system_error_status_time_idx on public.system_error_events(status,last_occurred_at desc);
create index system_error_org_time_idx on public.system_error_events(organization_id,last_occurred_at desc);
create index system_error_fingerprint_idx on public.system_error_events(fingerprint,last_occurred_at desc);
alter table public.system_error_events enable row level security;
create policy "platform admins read system errors" on public.system_error_events for select to authenticated using(public.is_platform_admin());

create or replace function public.report_system_error(p_message text,p_route text default null,p_error_code text default null,p_stack text default null,p_severity text default 'medium',p_source text default 'client',p_user_agent text default null,p_details jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid:=public.active_support_organization_id();v_user uuid:=auth.uid();v_fingerprint text;v_event public.system_error_events%rowtype;v_severity text:=lower(coalesce(p_severity,'medium'));v_source text:=lower(coalesce(p_source,'client'));
begin
 if v_user is null then raise exception 'Authentication required'; end if;
 if v_org is null then select organization_id into v_org from public.organization_memberships where user_id=v_user and active order by created_at limit 1; end if;
 if v_severity not in ('low','medium','high','critical') then v_severity:='medium'; end if;
 if v_source not in ('client','server','edge') then v_source:='client'; end if;
 if nullif(trim(coalesce(p_message,'')),'') is null then raise exception 'Error message is required'; end if;
 v_fingerprint:=md5(coalesce(left(p_error_code,100),'')||'|'||coalesce(left(p_route,300),'')||'|'||left(trim(p_message),500));
 select * into v_event from public.system_error_events where fingerprint=v_fingerprint and organization_id is not distinct from v_org and status in ('new','investigating') and last_occurred_at>now()-interval '24 hours' order by last_occurred_at desc limit 1 for update;
 if v_event.id is null then
  insert into public.system_error_events(fingerprint,organization_id,user_id,severity,source,error_code,message,route,stack,user_agent,details) values(v_fingerprint,v_org,v_user,v_severity,v_source,nullif(left(trim(coalesce(p_error_code,'')),100),''),left(trim(p_message),1000),nullif(left(trim(coalesce(p_route,'')),500),''),nullif(left(p_stack,6000),''),nullif(left(p_user_agent,1000),''),coalesce(p_details,'{}'::jsonb)-'password'-'token'-'authorization'-'cookie') returning * into v_event;
 else
  update public.system_error_events set occurrence_count=occurrence_count+1,last_occurred_at=now(),user_id=v_user,severity=case when v_severity='critical' or (v_severity='high' and severity not in ('critical')) then v_severity else severity end,stack=coalesce(nullif(left(p_stack,6000),''),stack),user_agent=coalesce(nullif(left(p_user_agent,1000),''),user_agent) where id=v_event.id returning * into v_event;
 end if;
 return jsonb_build_object('event_id',v_event.id,'fingerprint',v_event.fingerprint,'occurrence_count',v_event.occurrence_count,'should_notify',v_event.severity in ('high','critical') and (v_event.notified_at is null or v_event.notified_at<now()-interval '15 minutes'));
end $$;

create or replace function public.get_platform_system_alerts(p_status text default null,p_severity text default null,p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'severity',e.severity,'source',e.source,'error_code',e.error_code,'message',e.message,'route',e.route,'stack',e.stack,'details',e.details,'status',e.status,'occurrence_count',e.occurrence_count,'first_occurred_at',e.first_occurred_at,'last_occurred_at',e.last_occurred_at,'notified_at',e.notified_at,'organization_id',e.organization_id,'organization_name',o.name,'user_email',p.email,'user_name',p.full_name,'user_agent',e.user_agent,'acknowledged_at',e.acknowledged_at,'resolution_notes',e.resolution_notes,'resolved_at',e.resolved_at) order by case e.severity when 'critical' then 1 when 'high' then 2 when 'medium' then 3 else 4 end,e.last_occurred_at desc) from (select * from public.system_error_events where (p_status is null or status=p_status) and (p_severity is null or severity=p_severity) order by last_occurred_at desc limit least(greatest(coalesce(p_limit,100),1),500)) e left join public.organizations o on o.id=e.organization_id left join public.profiles p on p.id=e.user_id),'[]'::jsonb);
end $$;

create or replace function public.set_system_alert_status(p_event_id uuid,p_status text,p_notes text default null)
returns boolean language plpgsql security definer set search_path=public as $$
begin
 if not public.is_platform_admin() then raise exception 'Platform administrator access required'; end if;
 if p_status not in ('new','investigating','resolved','ignored') then raise exception 'Invalid alert status'; end if;
 update public.system_error_events set status=p_status,acknowledged_by=case when p_status in ('investigating','resolved','ignored') then auth.uid() else acknowledged_by end,acknowledged_at=case when p_status in ('investigating','resolved','ignored') then coalesce(acknowledged_at,now()) else acknowledged_at end,resolution_notes=case when p_status in ('resolved','ignored') then nullif(trim(coalesce(p_notes,'')),'') else resolution_notes end,resolved_by=case when p_status in ('resolved','ignored') then auth.uid() else null end,resolved_at=case when p_status in ('resolved','ignored') then now() else null end where id=p_event_id;
 if not found then raise exception 'System alert not found'; end if;
 return true;
end $$;

grant execute on function public.report_system_error(text,text,text,text,text,text,text,jsonb) to authenticated;
grant execute on function public.get_platform_system_alerts(text,text,integer) to authenticated;
grant execute on function public.set_system_alert_status(uuid,text,text) to authenticated;
commit;
