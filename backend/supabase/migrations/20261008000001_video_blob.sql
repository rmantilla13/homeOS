-- Videos live in a private Vercel Blob store so they don't fill the
-- family-media bucket. Photos stay in that bucket. See docs/PLATFORM_SPEC.md §1.9.
--
-- storage_path keeps the shape '<family_id>/<id>.<ext>' in either store.
-- Existing rows (photos and videos already in Supabase) stay 'supabase'.

alter table public.media_items
  add column file_store text not null default 'supabase';

alter table public.media_items
  add constraint media_items_file_store_check
  check (file_store in ('supabase', 'blob'));

alter table public.media_items
  add constraint media_items_blob_is_video
  check (file_store <> 'blob' or kind = 'video');

comment on column public.media_items.file_store is
  'supabase: object in the family-media bucket. blob: private Vercel Blob object (videos only).';
