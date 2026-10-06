-- Photos join videos in the private Blob store. 20261008000001 only allowed
-- blob rows when kind = 'video'. The extension now has to match the kind, so
-- a photo cannot point at a video object (and the reverse). Files already in
-- the family-media bucket stay file_store = 'supabase'.

alter table public.media_items drop constraint media_items_blob_is_video;

alter table public.media_items
  add constraint media_items_blob_matches_kind
  check (
    file_store <> 'blob'
    or (kind = 'photo' and storage_path ~* '\.(jpg|jpeg|png|webp|heic|gif)$')
    or (kind = 'video' and storage_path ~* '\.(mp4|mov|m4v|webm|mkv|3gp|3g2)$')
  );

comment on column public.media_items.file_store is
  'supabase: object still in the family-media bucket. blob: private Vercel Blob object (photos and videos).';
