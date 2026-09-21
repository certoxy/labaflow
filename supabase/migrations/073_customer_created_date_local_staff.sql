-- Include customer creation date in the local-staff operational context while
-- preserving the current function implementation and permissions.

do $$
declare
  v_definition text;
  v_updated text;
begin
  select pg_get_functiondef('public.get_local_staff_operational_context(uuid)'::regprocedure)
  into v_definition;

  v_updated:=replace(
    v_definition,
    '''lifetime_spend'',c.lifetime_spend)',
    '''lifetime_spend'',c.lifetime_spend,''created_at'',c.created_at)'
  );

  if v_updated=v_definition then
    raise exception 'Unable to locate the local-staff customer payload';
  end if;

  execute v_updated;
end;
$$;
