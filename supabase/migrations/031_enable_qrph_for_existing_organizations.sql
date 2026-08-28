-- LabaFlow: ensure QR Ph is enabled for existing organizations.
-- Migration 029 allows qrph as a valid payment method. This migration updates
-- existing payment_methods settings so Organization Admin immediately reflects it.

begin;

-- Ensure enum is present even if migration 029 was only partially applied.
alter type public.payment_method add value if not exists 'qrph';

-- Add qrph to every existing organization's payment_methods setting without
-- removing or reordering any methods they already configured.
update public.organization_settings
set setting_value = jsonb_set(
      coalesce(setting_value, '{"methods":[]}'::jsonb),
      '{methods}',
      coalesce(setting_value->'methods', '[]'::jsonb) || '"qrph"'::jsonb,
      true
    ),
    updated_at = now()
where setting_key = 'payment_methods'
  and not (coalesce(setting_value->'methods','[]'::jsonb) ? 'qrph');

-- Organizations that do not yet have a payment_methods row get the standard set
-- including QR Ph.
insert into public.organization_settings(organization_id, setting_key, setting_value, updated_at)
select o.id,
       'payment_methods',
       '{"methods":["cash","gcash","maya","card","bank_transfer","qrph"]}'::jsonb,
       now()
from public.organizations o
where not exists (
  select 1
  from public.organization_settings s
  where s.organization_id=o.id and s.setting_key='payment_methods'
)
on conflict (organization_id,setting_key) do nothing;

commit;
