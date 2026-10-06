-- The Blob migrations moved to 20261009000002-4 because their old versions
-- collided with media_platform and media_storage. A hosted database may
-- already have them from the SQL editor, so `supabase db push` runs them
-- again. That must succeed and leave the same schema and settings.
\set ON_ERROR_STOP 1
\set fam '00000000-0000-0000-0000-00000000f001'

create temp view media_state as
  select 'constraint ' || conname || ' ' || pg_get_constraintdef(oid) as item
    from pg_constraint where conrelid = 'public.media_items'::regclass
  union all
  select 'column ' || column_name || ' ' || data_type || ' ' || is_nullable || ' ' || coalesce(column_default, '')
    from information_schema.columns
   where table_schema = 'public' and table_name = 'media_items'
  union all
  select 'function ' || p.proname || ' ' || md5(pg_get_functiondef(p.oid))
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.proname in ('allowed_media_types', 'media_items_guard')
  union all
  select 'setting ' || media_max_bytes::text from public.platform_settings
  union all
  select 'comment ' || col_description('public.media_items'::regclass,
           (select attnum from pg_attribute
             where attrelid = 'public.media_items'::regclass and attname = 'file_store'));

create temp table fresh as select item from media_state;

create function pg_temp.drift() returns int language sql as $$
  select count(*)::int from (
    (select item from media_state except select item from fresh)
    union all
    (select item from fresh except select item from media_state)
  ) d
$$;

-- A Blob photo is already stored. The first, videos-only check would reject
-- it, so a re-run must not put that check back.
insert into media_items (family_id, storage_path, kind, file_store)
values (:'fam', :'fam' || '/shot.jpg', 'photo', 'blob');

\ir ../supabase/migrations/20261009000002_video_blob.sql
\ir ../supabase/migrations/20261009000003_blob_photos.sql
\ir ../supabase/migrations/20261009000004_blob_limits.sql
select tests.eq(pg_temp.drift(), 0, 'running the Blob migrations again changes nothing');

\ir ../supabase/migrations/20261009000002_video_blob.sql
\ir ../supabase/migrations/20261009000003_blob_photos.sql
\ir ../supabase/migrations/20261009000004_blob_limits.sql
select tests.eq(pg_temp.drift(), 0, 'and a third run changes nothing either');

-- Only video_blob was pasted by hand: the videos-only check is in place and
-- no Blob photo exists yet. The push then brings the rest.
delete from media_items where storage_path = :'fam' || '/shot.jpg';
alter table public.media_items drop constraint media_items_blob_matches_kind;
alter table public.media_items
  add constraint media_items_blob_is_video check (file_store <> 'blob' or kind = 'video');
\ir ../supabase/migrations/20261009000002_video_blob.sql
\ir ../supabase/migrations/20261009000003_blob_photos.sql
\ir ../supabase/migrations/20261009000004_blob_limits.sql
select tests.eq(pg_temp.drift(), 0, 'a partly applied database ends in the same state');
