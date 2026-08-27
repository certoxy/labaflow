-- Remove the pre-loyalty-redemption order RPC signature so PostgREST has one clear callable version.
begin;

drop function if exists public.create_laundry_order(
  uuid,uuid,jsonb,numeric,text,timestamptz,public.delivery_addon_type,uuid
);

commit;
