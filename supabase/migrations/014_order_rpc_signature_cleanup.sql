-- Remove the legacy six-parameter order RPC so PostgREST resolves the new add-on-aware function unambiguously.
begin;
drop function if exists public.create_laundry_order(uuid,uuid,jsonb,numeric,text,timestamptz);
commit;
