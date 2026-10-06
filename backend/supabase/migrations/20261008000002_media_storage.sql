-- Supabase Storage half of the media quota. Skipped by the plain Postgres
-- test run (backend/tests/run.sh); storage_test applies it on top of
-- stub_storage.sql. The row checks live in 20261008000001.

-- Real file bytes, not the number the client writes on media_items. A
-- signed-in member of the family has to send a size and an allowed type,
-- and the upload has to fit the family's quota. Paths stay one folder
-- deep (`<family_id>/<file>`), which is also what the policies below allow.
-- Admins get no storage policy: the console lists rows through
-- admin_list_media and signs URLs in the admin function, so an admin's
-- phone still can't open another family's photos.
create function public.enforce_family_media_object()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  folder text;
  fid uuid;
  sz bigint;
  mime text;
  lim_bytes bigint;
  lim_items int;
  max_bytes bigint;
  used bigint;
  objects int;
begin
  if new.bucket_id is distinct from 'family-media' then
    return new;
  end if;
  if not public.is_signed_in_client() then
    return new;
  end if;

  folder := (storage.foldername(new.name))[1];
  if folder is null
     or array_length(storage.foldername(new.name), 1) is distinct from 1
     or folder !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return new; -- the policy rejects anything that isn't <family_id>/<file>
  end if;

  fid := folder::uuid;
  if not public.is_family_member(fid) then
    return new; -- row-level security reports the refusal, without quota details
  end if;
  if tg_op = 'UPDATE' then
    return new;
  end if;

  sz := case when (new.metadata->>'size') ~ '^[0-9]+$' then (new.metadata->>'size')::bigint else null end;
  mime := new.metadata->>'mimetype';
  if sz is null then
    raise exception 'file size required';
  end if;
  if mime is null or not public.media_type_allowed(mime) then
    raise exception 'file type not allowed';
  end if;

  perform public.lock_family_media(fid);
  lim_bytes := public.family_storage_limit(fid);
  lim_items := public.family_media_item_limit(fid);
  select s.media_max_bytes into max_bytes from public.platform_settings s;

  if sz > max_bytes then
    raise exception 'file is too large';
  end if;

  -- A photo and its thumbnail are two objects for one item.
  select count(*)::int into objects
  from storage.objects o
  where o.bucket_id = 'family-media' and split_part(o.name, '/', 1) = folder;
  if objects >= lim_items * 2 then
    raise exception 'media item limit reached';
  end if;

  select coalesce(sum(case when (o.metadata->>'size') ~ '^[0-9]+$'
                            then (o.metadata->>'size')::bigint else 0 end), 0)
    into used
  from storage.objects o
  where o.bucket_id = 'family-media' and split_part(o.name, '/', 1) = folder;
  if used + sz > lim_bytes then
    raise exception 'storage limit reached';
  end if;

  return new;
end $$;

create trigger family_media_object_guard
  before insert or update on storage.objects
  for each row execute function public.enforce_family_media_object();

revoke execute on function public.enforce_family_media_object() from public, anon, authenticated;

drop policy if exists "family media read" on storage.objects;
drop policy if exists "family media upload" on storage.objects;
drop policy if exists "family media delete" on storage.objects;

create policy "family media read" on storage.objects for select
  using (bucket_id = 'family-media'
         and array_length(storage.foldername(name), 1) = 1
         and (storage.foldername(name))[1] in (select public.my_family_ids()::text));

create policy "family media upload" on storage.objects for insert
  with check (bucket_id = 'family-media'
              and array_length(storage.foldername(name), 1) = 1
              and (storage.foldername(name))[1] in (select public.my_family_ids()::text));

create policy "family media delete" on storage.objects for delete
  using (bucket_id = 'family-media'
         and array_length(storage.foldername(name), 1) = 1
         and (storage.foldername(name))[1] in (select public.my_family_ids()::text));

update storage.buckets
   set file_size_limit = (select media_max_bytes from public.platform_settings),
       allowed_mime_types = public.allowed_media_types()
 where id = 'family-media';
