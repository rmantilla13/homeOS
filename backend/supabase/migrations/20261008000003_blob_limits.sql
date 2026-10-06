-- Blob uploads accept a 2 GiB video and a few containers the first media
-- allowlist left out. The per-file cap was 512 MiB, which would reject a
-- video the media API already accepted after the bytes were stored.
-- Raise the platform default only when it is still that original value.

create or replace function public.allowed_media_types()
returns text[]
language sql immutable as $$
  select array[
    'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'image/gif',
    'video/mp4', 'video/quicktime', 'video/webm', 'video/m4v', 'video/x-m4v',
    'video/x-matroska', 'video/mkv', 'video/3gpp', 'video/3gp', 'video/3gpp2', 'video/3g2'
  ]::text[]
$$;

alter table public.platform_settings
  alter column media_max_bytes set default 2147483648;

update public.platform_settings
  set media_max_bytes = 2147483648
  where media_max_bytes = 536870912;

-- A signed-in client still may change only the caption and the frame.
-- file_store arrived after media_items_guard, so include it in that freeze.
create or replace function public.media_items_guard()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  lim_bytes bigint;
  lim_items int;
  max_bytes bigint;
  used bigint;
  items int;
  client boolean := public.is_signed_in_client();
begin
  if tg_op = 'UPDATE'
     and (new.id, new.family_id, new.storage_path, new.thumbnail_path, new.kind,
          new.byte_size, new.content_type, new.uploaded_by, new.width, new.height,
          new.duration_seconds, new.taken_at, new.created_at, new.file_store)
         is distinct from
         (old.id, old.family_id, old.storage_path, old.thumbnail_path, old.kind,
          old.byte_size, old.content_type, old.uploaded_by, old.width, old.height,
          old.duration_seconds, old.taken_at, old.created_at, old.file_store) then
    if client then
      raise exception 'only a caption or the frame can be changed';
    end if;
  end if;

  if tg_op = 'INSERT' then
    if new.uploaded_by is not null
       and not exists (select 1 from public.members m
                        where m.id = new.uploaded_by and m.family_id = new.family_id) then
      raise exception 'that person isn''t in this family';
    end if;
  elsif new.uploaded_by is distinct from old.uploaded_by
        or new.family_id is distinct from old.family_id then
    if new.uploaded_by is not null
       and not exists (select 1 from public.members m
                        where m.id = new.uploaded_by and m.family_id = new.family_id) then
      raise exception 'that person isn''t in this family';
    end if;
  end if;

  if new.content_type is not null and not public.media_type_allowed(new.content_type) then
    raise exception 'file type not allowed';
  end if;

  if tg_op = 'UPDATE' or not client then
    return new;
  end if;

  perform public.lock_family_media(new.family_id);
  lim_bytes := public.family_storage_limit(new.family_id);
  lim_items := public.family_media_item_limit(new.family_id);
  select s.media_max_bytes into max_bytes from public.platform_settings s;

  if new.byte_size is not null and new.byte_size > max_bytes then
    raise exception 'file is too large';
  end if;

  select count(*)::int into items from public.media_items m where m.family_id = new.family_id;
  if items >= lim_items then
    raise exception 'media item limit reached';
  end if;

  if new.byte_size is not null then
    select coalesce(sum(m.byte_size), 0) into used
    from public.media_items m where m.family_id = new.family_id;
    if used + new.byte_size > lim_bytes then
      raise exception 'storage limit reached';
    end if;
  end if;

  return new;
end $$;

-- Keep the Storage bucket in step when this database has Storage.
do $$
begin
  if to_regclass('storage.buckets') is not null then
    update storage.buckets
       set file_size_limit = (select media_max_bytes from public.platform_settings),
           allowed_mime_types = public.allowed_media_types()
     where id = 'family-media';
  end if;
end $$;
