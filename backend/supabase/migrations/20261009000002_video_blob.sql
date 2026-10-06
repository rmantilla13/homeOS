-- Videos live in a private Vercel Blob store so they don't fill the
-- family-media bucket. Photos stay in that bucket. See docs/PLATFORM_SPEC.md §1.9.
--
-- storage_path keeps the shape '<family_id>/<id>.<ext>' in either store.
-- Existing rows (photos and videos already in Supabase) stay 'supabase'.
--
-- Was 20261008000001_video_blob, which shared its version with
-- media_platform. Safe to run again on a database where it (or the next two
-- Blob migrations) was already pasted into the SQL editor.

alter table public.media_items
  add column if not exists file_store text not null default 'supabase';

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.media_items'::regclass
                    and conname = 'media_items_file_store_check') then
    alter table public.media_items
      add constraint media_items_file_store_check
      check (file_store in ('supabase', 'blob'));
  end if;
  -- 20261009000003_blob_photos replaces this check. Once it has, adding it
  -- back would reject the Blob photos already stored.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.media_items'::regclass
                    and conname in ('media_items_blob_is_video', 'media_items_blob_matches_kind')) then
    alter table public.media_items
      add constraint media_items_blob_is_video
      check (file_store <> 'blob' or kind = 'video');
  end if;
end $$;

comment on column public.media_items.file_store is
  'supabase: object in the family-media bucket. blob: private Vercel Blob object (videos only).';
