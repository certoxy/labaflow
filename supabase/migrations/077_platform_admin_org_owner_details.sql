-- Include organization owner details in the Platform Admin tenant context.
begin;

create or replace function public.get_platform_admin_context()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
begin
  if not public.is_platform_admin() then
    raise exception 'Platform administrator access required';
  end if;

  return jsonb_build_object(
    'organizations',
    coalesce((
      select jsonb_agg(
        to_jsonb(o) ||
        jsonb_build_object(
          'inventory_granted',
          coalesce((
            select granted
            from public.organization_feature_grants
            where organization_id=o.id
              and feature_key='inventory'
          ), false),
          'feature_grants',
          (
            select jsonb_object_agg(k.feature_key, coalesce(g.granted, k.default_granted))
            from (
              values
                ('customer_loyalty', true),
                ('pickup_delivery', true),
                ('inventory', false),
                ('expenses', true),
                ('order_workflow', true),
                ('qr_customer_id', true)
            ) as k(feature_key, default_granted)
            left join public.organization_feature_grants g
              on g.organization_id=o.id
             and g.feature_key=k.feature_key
          ),
          'owners',
          coalesce((
            select jsonb_agg(
              jsonb_build_object(
                'user_id', m.user_id,
                'email', p.email,
                'full_name', p.full_name,
                'active', m.active and p.active,
                'membership_created_at', m.created_at
              )
              order by m.created_at
            )
            from public.organization_memberships m
            join public.profiles p on p.id=m.user_id
            where m.organization_id=o.id
              and m.role='owner'
          ), '[]'::jsonb)
        )
        order by o.created_at desc
      )
      from public.organizations o
    ), '[]'::jsonb),
    'platform_admins',
    coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'user_id', pa.user_id,
          'email', pr.email,
          'full_name', pr.full_name,
          'active', pa.active,
          'granted_at', pa.granted_at
        )
        order by pa.granted_at
      )
      from public.platform_admins pa
      join public.profiles pr on pr.id=pa.user_id
    ), '[]'::jsonb)
  );
end
$$;

commit;
