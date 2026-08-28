-- LabaFlow: tenant-safe storage for organization GCash QR images.

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('organization-payment-qrs','organization-payment-qrs',true,5242880,array['image/png','image/jpeg','image/webp'])
on conflict (id) do update set
  public=excluded.public,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

-- Folder convention: <organization_id>/gcash/<filename>

drop policy if exists "organization admins can upload payment qrs" on storage.objects;
create policy "organization admins can upload payment qrs"
on storage.objects for insert
to authenticated
with check (
  bucket_id='organization-payment-qrs'
  and exists (
    select 1
    from public.organization_memberships m
    where m.user_id=auth.uid()
      and m.active
      and m.role in ('owner','admin')
      and m.organization_id::text=(storage.foldername(name))[1]
  )
);

drop policy if exists "organization admins can update payment qrs" on storage.objects;
create policy "organization admins can update payment qrs"
on storage.objects for update
to authenticated
using (
  bucket_id='organization-payment-qrs'
  and exists (
    select 1
    from public.organization_memberships m
    where m.user_id=auth.uid()
      and m.active
      and m.role in ('owner','admin')
      and m.organization_id::text=(storage.foldername(name))[1]
  )
)
with check (
  bucket_id='organization-payment-qrs'
  and exists (
    select 1
    from public.organization_memberships m
    where m.user_id=auth.uid()
      and m.active
      and m.role in ('owner','admin')
      and m.organization_id::text=(storage.foldername(name))[1]
  )
);

drop policy if exists "organization admins can delete payment qrs" on storage.objects;
create policy "organization admins can delete payment qrs"
on storage.objects for delete
to authenticated
using (
  bucket_id='organization-payment-qrs'
  and exists (
    select 1
    from public.organization_memberships m
    where m.user_id=auth.uid()
      and m.active
      and m.role in ('owner','admin')
      and m.organization_id::text=(storage.foldername(name))[1]
  )
);
