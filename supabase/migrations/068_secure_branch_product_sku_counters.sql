-- Secure the internal product SKU counter from direct PostgREST access.
-- SKU allocation continues through the security-definer save_product_v2 function.
begin;

alter table public.branch_product_sku_counters enable row level security;

-- This is an internal implementation table. No client role should query or
-- mutate counters directly, so it intentionally has no RLS policies.
revoke all on table public.branch_product_sku_counters from public, anon, authenticated;

-- Prevent callers from bypassing save_product_v2 and incrementing counters for
-- arbitrary branches. The function owner can still call it from save_product_v2.
revoke execute on function public.next_product_sku(uuid) from public, anon, authenticated;

comment on table public.branch_product_sku_counters is
  'Internal per-branch product SKU sequence; accessible only through trusted database functions.';

commit;
