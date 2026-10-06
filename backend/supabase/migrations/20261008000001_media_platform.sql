-- Media at platform scale, and the tenancy holes that showed up while
-- opening homeOS to more than one family.
--
-- 1. Each family has a storage quota and an item cap (its own, or the
--    platform default). Signed-in clients can't insert a media row that
--    would pass either one. The bytes on the object itself are checked in
--    20261008000002, which needs Supabase Storage.
-- 2. A media row's file has to live at `<family_id>/<file>`. A row in
--    family A can no longer point at family B's object.
-- 3. A paired display could update its own devices row, including
--    family_id, and RLS would then treat it as a member of that other
--    family. Identity columns are frozen, and a suspended family can't
--    gain a display.
-- 4. event guests, chore assignees and "added by" could name a person
--    from another family. Those writes are refused.
-- 5. Admins can list and remove media, set a family's limits, and revoke
--    a display. Removal of the files themselves is the admin edge function
--    (SQL can't see Storage).

-- ───────────────────────────── Limits ─────────────────────────────

-- 5 GiB per family, 512 MiB per file, 5,000 items. A null on the family
-- means "use the platform default". 0 is a real limit: nothing new.
alter table public.platform_settings
  add column storage_limit_bytes bigint not null default 5368709120
    check (storage_limit_bytes >= 0 and storage_limit_bytes <= 1099511627776),
  add column media_max_bytes bigint not null default 536870912
    check (media_max_bytes >= 1 and media_max_bytes <= 5368709120),
  add column media_item_limit int not null default 5000
    check (media_item_limit >= 0 and media_item_limit <= 1000000);

alter table public.families
  add column storage_limit_bytes bigint
    check (storage_limit_bytes is null or (storage_limit_bytes >= 0 and storage_limit_bytes <= 1099511627776)),
  add column media_item_limit int
    check (media_item_limit is null or (media_item_limit >= 0 and media_item_limit <= 1000000));

-- Parents rename the family. Quotas join status and the assistant limit
-- as admin-only columns.
create or replace function public.families_guard()
returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is null or current_user not in ('authenticated', 'anon') or public.is_platform_admin() then
    return new;
  end if;
  if (new.status, new.suspended_at, new.suspended_reason, new.assistant_daily_limit,
      new.storage_limit_bytes, new.media_item_limit)
     is distinct from
     (old.status, old.suspended_at, old.suspended_reason, old.assistant_daily_limit,
      old.storage_limit_bytes, old.media_item_limit) then
    raise exception 'only a platform admin can change that';
  end if;
  return new;
end $$;

-- ───────────────────────────── Media rows ─────────────────────────────

alter table public.media_items
  add column byte_size bigint,
  add column content_type text,
  add column thumbnail_path text,
  add constraint media_items_byte_size_nonneg check (byte_size is null or byte_size >= 0),
  add constraint media_items_content_type_len check (content_type is null or char_length(content_type) <= 100);

-- `<family_id>/<file>` in the canonical lowercase uuid form, one path
-- segment, no `..`. Thumbnails use the same shape and a different name.
create function public.media_path_in_family(fid uuid, path text)
returns boolean
language sql immutable as $$
  select path is not null
     and path = lower(fid::text) || '/' || split_part(path, '/', 2)
     and split_part(path, '/', 2) <> ''
     and split_part(path, '/', 3) = ''
     and char_length(split_part(path, '/', 2)) <= 200
     and split_part(path, '/', 2) !~ '\.\.'
     and split_part(path, '/', 2) !~ '^\.'
$$;

alter table public.media_items
  add constraint media_items_path_in_family check (public.media_path_in_family(family_id, storage_path)),
  add constraint media_items_thumb_in_family check (
    thumbnail_path is null
    or (public.media_path_in_family(family_id, thumbnail_path) and thumbnail_path <> storage_path));

-- What the iOS app uploads. Kept in one place so the storage bucket's
-- allowed_mime_types (20261008000002) can't drift from the row check.
create function public.allowed_media_types()
returns text[]
language sql immutable as $$
  select array[
    'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'image/gif',
    'video/mp4', 'video/quicktime', 'video/webm', 'video/m4v', 'video/x-m4v'
  ]::text[]
$$;

create function public.media_type_allowed(t text)
returns boolean
language sql immutable as $$
  select t is null or t = any (public.allowed_media_types())
$$;

create function public.family_storage_limit(fid uuid)
returns bigint
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select f.storage_limit_bytes from public.families f where f.id = fid),
    (select s.storage_limit_bytes from public.platform_settings s))
$$;

create function public.family_media_item_limit(fid uuid)
returns int
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select f.media_item_limit from public.families f where f.id = fid),
    (select s.media_item_limit from public.platform_settings s))
$$;

-- Bytes to bill the family. Object sizes win when Storage is present and
-- larger (a file uploaded by an older app has no byte_size on the row).
-- Plain Postgres, where this test suite runs, only has the rows.
create function public.family_storage_bytes(fid uuid)
returns bigint
language plpgsql stable security definer set search_path = public as $$
declare
  from_rows bigint;
  from_objects bigint;
begin
  select coalesce(sum(m.byte_size), 0) into from_rows
  from public.media_items m where m.family_id = fid;

  if to_regclass('storage.objects') is null then
    return from_rows;
  end if;

  execute $q$
    select coalesce(sum(case when (o.metadata->>'size') ~ '^[0-9]+$'
                              then (o.metadata->>'size')::bigint else 0 end), 0)
    from storage.objects o
    where o.bucket_id = 'family-media' and split_part(o.name, '/', 1) = $1
  $q$ into from_objects using fid::text;

  return greatest(from_rows, coalesce(from_objects, 0));
end $$;

create function public.platform_storage_bytes()
returns bigint
language plpgsql stable security definer set search_path = public as $$
declare
  from_rows bigint;
  from_objects bigint;
begin
  select coalesce(sum(byte_size), 0) into from_rows from public.media_items;
  if to_regclass('storage.objects') is null then
    return from_rows;
  end if;
  execute $q$
    select coalesce(sum(case when (o.metadata->>'size') ~ '^[0-9]+$'
                              then (o.metadata->>'size')::bigint else 0 end), 0)
    from storage.objects o
    where o.bucket_id = 'family-media'
  $q$ into from_objects;
  return greatest(from_rows, coalesce(from_objects, 0));
end $$;

-- True for a signed-in PostgREST caller. Trigger functions that are
-- security definer can't trust current_user (that becomes the owner),
-- so they read the role claim the tests and PostgREST set.
create function public.is_signed_in_client()
returns boolean
language sql stable as $$
  select auth.uid() is not null
     and coalesce(current_setting('request.jwt.claim.role', true), '') in ('authenticated', 'anon')
$$;

-- Same lock for the row trigger and the storage trigger, so two uploads
-- at once can't both slip under the quota.
create function public.lock_family_media(fid uuid)
returns void
language sql volatile security definer set search_path = public as $$
  select pg_advisory_xact_lock(481516234, hashtext(fid::text))
$$;

create function public.media_items_guard()
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
          new.duration_seconds, new.taken_at, new.created_at)
         is distinct from
         (old.id, old.family_id, old.storage_path, old.thumbnail_path, old.kind,
          old.byte_size, old.content_type, old.uploaded_by, old.width, old.height,
          old.duration_seconds, old.taken_at, old.created_at) then
    -- Migrations and the service role may repair a row. A signed-in client
    -- may change the caption and whether it shows on the frame.
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

  -- Quotas bind signed-in clients. Older apps omit byte_size; the file's
  -- real size is still counted by the storage trigger when Storage exists.
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

create trigger media_items_guard
  before insert or update on public.media_items
  for each row execute function public.media_items_guard();

-- ───────────────────────────── Displays ─────────────────────────────

-- devices_touch lets a display update its own row so it can record
-- last_seen_at. Nothing stopped it from also setting family_id, after
-- which my_family_ids() handed it the other family's data.
create function public.devices_guard()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  st text;
begin
  if tg_op = 'INSERT' then
    select f.status into st from public.families f where f.id = new.family_id;
    if st is null then
      raise exception 'family not found';
    elsif st <> 'active' then
      raise exception 'this family is suspended';
    end if;
    return new;
  end if;

  if (new.id, new.family_id, new.user_id) is distinct from (old.id, old.family_id, old.user_id) then
    raise exception 'a display can''t move to another family';
  end if;
  if public.is_signed_in_client()
     and not public.is_platform_admin()
     and new.created_at is distinct from old.created_at then
    raise exception 'a display can''t move to another family';
  end if;
  return new;
end $$;

create trigger devices_guard
  before insert or update on public.devices
  for each row execute function public.devices_guard();

-- ───────────────────── Cross-family references ─────────────────────

-- A person id written onto a family row has to belong to that family.
-- Checked when the column is set or changed, not on every later edit, so
-- moving an account-less member (members_guard allows that) doesn't make
-- old chores uneditable.
create or replace function public.tasks_guard()
returns trigger
language plpgsql set search_path = public as $$
declare
  check_assignee boolean := tg_op = 'INSERT';
  check_creator boolean := tg_op = 'INSERT';
begin
  -- OLD isn't assigned on insert, and PL/pgSQL doesn't skip the other side
  -- of OR, so the "did this column change?" test stays in the update branch.
  if tg_op = 'UPDATE' then
    check_assignee := new.assignee_id is distinct from old.assignee_id
                      or new.family_id is distinct from old.family_id;
    check_creator := new.created_by is distinct from old.created_by;
  end if;
  if check_assignee and new.assignee_id is not null
     and not exists (select 1 from public.members m
                      where m.id = new.assignee_id and m.family_id = new.family_id) then
    raise exception 'that person isn''t in this family';
  end if;
  if check_creator and new.created_by is not null
     and not exists (select 1 from public.members m
                      where m.id = new.created_by and m.family_id = new.family_id) then
    raise exception 'that person isn''t in this family';
  end if;

  if auth.uid() is null or current_user not in ('authenticated', 'anon') or public.is_platform_admin() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if public.is_family_parent(new.family_id) then
      return new;
    end if;
    if new.points > 0 and not new.requires_approval then
      raise exception 'only a parent can add points that skip approval';
    end if;
    return new;
  end if;
  if public.is_family_parent(new.family_id) and public.is_family_parent(old.family_id) then
    return new;
  end if;
  if (new.points, new.requires_approval, new.family_id)
     is distinct from (old.points, old.requires_approval, old.family_id) then
    raise exception 'only a parent can change a chore''s points or approval';
  end if;
  return new;
end $$;

create function public.events_guard()
returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    if new.created_by is not distinct from old.created_by
       and new.family_id is not distinct from old.family_id then
      return new;
    end if;
  end if;
  if new.created_by is not null
     and not exists (select 1 from public.members m
                      where m.id = new.created_by and m.family_id = new.family_id) then
    raise exception 'that person isn''t in this family';
  end if;
  return new;
end $$;

create trigger events_guard
  before insert or update on public.events
  for each row execute function public.events_guard();

create function public.event_members_guard()
returns trigger
language plpgsql set search_path = public as $$
declare
  fid uuid;
begin
  select e.family_id into fid from public.events e where e.id = new.event_id;
  if fid is null
     or not exists (select 1 from public.members m where m.id = new.member_id and m.family_id = fid) then
    raise exception 'that person isn''t in this family';
  end if;
  return new;
end $$;

create trigger event_members_guard
  before insert or update on public.event_members
  for each row execute function public.event_members_guard();

create function public.list_items_guard()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  fid uuid;
begin
  if tg_op = 'UPDATE'
     and new.added_by is not distinct from old.added_by
     and new.list_id is not distinct from old.list_id then
    return new;
  end if;
  if new.added_by is null then
    return new;
  end if;
  select l.family_id into fid from public.lists l where l.id = new.list_id;
  if fid is null
     or not exists (select 1 from public.members m
                     where m.id = new.added_by and m.family_id = fid) then
    raise exception 'that person isn''t in this family';
  end if;
  return new;
end $$;

create trigger list_items_guard
  before insert or update on public.list_items
  for each row execute function public.list_items_guard();

-- list_items_guard reads the list and the member past RLS, so a hidden
-- foreign id can't be mistaken for "no such person" in the other direction:
-- it still has to be a member of THIS list's family. The function is not
-- an API.
revoke execute on function public.media_items_guard() from public, anon, authenticated;
revoke execute on function public.devices_guard() from public, anon, authenticated;
revoke execute on function public.events_guard() from public, anon, authenticated;
revoke execute on function public.event_members_guard() from public, anon, authenticated;
revoke execute on function public.list_items_guard() from public, anon, authenticated;
revoke execute on function public.family_storage_limit(uuid) from public, anon, authenticated;
revoke execute on function public.family_media_item_limit(uuid) from public, anon, authenticated;
revoke execute on function public.family_storage_bytes(uuid) from public, anon, authenticated;
revoke execute on function public.platform_storage_bytes() from public, anon, authenticated;
revoke execute on function public.is_signed_in_client() from public, anon, authenticated;
revoke execute on function public.lock_family_media(uuid) from public, anon, authenticated;
revoke execute on function public.allowed_media_types() from public, anon, authenticated;
revoke execute on function public.media_type_allowed(text) from public, anon, authenticated;

-- ───────────────────────────── Admin reads ─────────────────────────────

create or replace function public.admin_overview()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  return jsonb_build_object(
    'families',              (select count(*) from public.families),
    'families_active_7d',    (select count(*) from public.families f
                              where public.family_last_activity(f.id) >= now() - interval '7 days'),
    'suspended_families',    (select count(*) from public.families where status = 'suspended'),
    'users',                 (select count(*) from auth.users u
                              where coalesce(u.raw_app_meta_data->>'kind', '') <> 'device'),
    'devices',               (select count(*) from public.devices),
    'devices_seen_24h',      (select count(*) from public.devices d
                              where d.last_seen_at >= now() - interval '24 hours'
                                and d.last_seen_at <= now() + interval '10 minutes'),
    'members',               (select count(*) from public.members),
    'open_platform_invites', (select count(*) from public.platform_invites i
                              where public.platform_invite_status(i) = 'active'),
    'assistant_requests_7d', (select count(*) from public.assistant_usage
                              where created_at >= now() - interval '7 days'),
    'assistant_tokens_7d',   (select coalesce(sum(input_tokens::bigint + output_tokens), 0) from public.assistant_usage
                              where created_at >= now() - interval '7 days'),
    'assistant_enabled',     (select s.assistant_enabled from public.platform_settings s),
    'media_items',           (select count(*) from public.media_items),
    'storage_bytes',         public.platform_storage_bytes(),
    'families_over_quota',   (select count(*) from public.families f
                              where public.family_storage_bytes(f.id) > public.family_storage_limit(f.id)
                                 or (select count(*) from public.media_items m where m.family_id = f.id)
                                    > public.family_media_item_limit(f.id)));
end $$;

drop function public.admin_list_families(text, int, int);

create function public.admin_list_families(search text default null, lim int default 50, off int default 0)
returns table (id uuid, name text, status text, created_at timestamptz, member_count int, parent_count int,
               device_count int, assistant_requests_30d int, last_activity timestamptz,
               media_count int, storage_bytes bigint, storage_limit_bytes bigint)
language plpgsql stable security definer set search_path = public as $$
declare
  q text := lower(nullif(btrim(search), ''));
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  return query
    select f.id, f.name, f.status, f.created_at,
           (select count(*)::int from public.members m where m.family_id = f.id),
           (select count(*)::int from public.members m where m.family_id = f.id and m.role = 'parent'),
           (select count(*)::int from public.devices d where d.family_id = f.id),
           (select count(*)::int from public.assistant_usage u
             where u.family_id = f.id and u.created_at >= now() - interval '30 days'),
           public.family_last_activity(f.id),
           (select count(*)::int from public.media_items mi where mi.family_id = f.id),
           public.family_storage_bytes(f.id),
           public.family_storage_limit(f.id)
    from public.families f
    where q is null or strpos(lower(f.name), q) > 0 or f.id::text = q
    order by f.created_at desc, f.id
    limit greatest(least(coalesce(lim, 50), 500), 1) offset greatest(coalesce(off, 0), 0);
end $$;

create or replace function public.admin_family_detail(family uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  f public.families;
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  select * into f from public.families x where x.id = family;
  if not found then raise exception 'family not found'; end if;

  return jsonb_build_object(
    'family', to_jsonb(f) || jsonb_build_object(
       'assistant_daily_limit_effective',
       coalesce(f.assistant_daily_limit, (select s.assistant_daily_limit from public.platform_settings s)),
       'last_activity', public.family_last_activity(f.id),
       'storage_bytes', public.family_storage_bytes(f.id),
       'storage_limit_effective', public.family_storage_limit(f.id),
       'media_count', (select count(*) from public.media_items m where m.family_id = f.id),
       'media_item_limit_effective', public.family_media_item_limit(f.id)),
    'members', coalesce((
      select jsonb_agg(to_jsonb(m) || jsonb_build_object('email', u.email, 'profile_name', p.display_name)
                       order by m.sort_order, m.created_at)
      from public.members m
      left join auth.users u on u.id = m.user_id
      left join public.profiles p on p.id = m.user_id
      where m.family_id = f.id), '[]'),
    'devices', coalesce((
      select jsonb_agg(to_jsonb(d) order by d.created_at)
      from public.devices d where d.family_id = f.id), '[]'),
    'invites', coalesce((
      select jsonb_agg(to_jsonb(i) || jsonb_build_object(
               'code', public.format_invite_code(i.code),
               'invited_by_email', u.email,
               'status', case when i.accepted_at is not null then 'accepted'
                              when i.revoked_at is not null then 'revoked'
                              when i.expires_at <= now() then 'expired'
                              else 'active' end)
             order by i.created_at desc)
      from public.family_invites i
      left join auth.users u on u.id = i.invited_by
      where i.family_id = f.id), '[]'),
    'usage_by_day', (
      select jsonb_agg(jsonb_build_object('day', d.day, 'requests', coalesce(x.requests, 0),
                                          'input_tokens', coalesce(x.input_tokens, 0),
                                          'output_tokens', coalesce(x.output_tokens, 0))
                       order by d.day)
      from generate_series(((now() at time zone 'UTC')::date - 29)::timestamp,
                           (now() at time zone 'UTC')::date::timestamp, interval '1 day') as d(day)
      left join (select (u.created_at at time zone 'UTC')::date as day, count(*) as requests,
                        sum(u.input_tokens) as input_tokens, sum(u.output_tokens) as output_tokens
                 from public.assistant_usage u
                 where u.family_id = f.id and u.created_at >= now() - interval '31 days'
                 group by 1) x on x.day = d.day::date));
end $$;

create function public.admin_list_media(family uuid, only_kind text default null, lim int default 60, off int default 0)
returns table (id uuid, kind text, storage_path text, thumbnail_path text, content_type text, byte_size bigint,
               width int, height int, duration_seconds numeric, caption text, taken_at timestamptz,
               created_at timestamptz, show_on_frame boolean, uploaded_by_name text)
language plpgsql stable security definer set search_path = public as $$
declare
  want text := nullif(lower(btrim(only_kind)), '');
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  if not exists (select 1 from public.families f where f.id = family) then
    raise exception 'family not found';
  end if;
  if want is not null and want not in ('photo', 'video') then
    raise exception 'kind must be photo or video';
  end if;
  return query
    select m.id, m.kind::text, m.storage_path, m.thumbnail_path, m.content_type, m.byte_size,
           m.width, m.height, m.duration_seconds, m.caption, m.taken_at, m.created_at, m.show_on_frame,
           u.display_name
    from public.media_items m
    left join public.members u on u.id = m.uploaded_by
    where m.family_id = family
      and (want is null or m.kind::text = want)
    order by m.taken_at desc nulls last, m.created_at desc, m.id
    limit greatest(least(coalesce(lim, 60), 100), 1) offset greatest(coalesce(off, 0), 0);
end $$;

-- ─────────────────────────── Admin writes ───────────────────────────

create function public.admin_delete_media(item uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  m public.media_items;
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  select * into m from public.media_items x where x.id = item for update;
  if not found then raise exception 'media not found'; end if;
  delete from public.media_items x where x.id = item;
  perform public.log_admin_action('delete_media', 'media', item::text,
    jsonb_build_object('family_id', m.family_id, 'storage_path', m.storage_path,
                       'thumbnail_path', m.thumbnail_path, 'byte_size', m.byte_size, 'kind', m.kind));
  return jsonb_build_object('id', m.id, 'family_id', m.family_id, 'storage_path', m.storage_path,
                            'thumbnail_path', m.thumbnail_path, 'byte_size', m.byte_size, 'kind', m.kind);
end $$;

-- Drops the devices row and, when this role may, the display's auth user
-- so its refresh token dies. The admin function finishes the auth deletion
-- if SQL can't (same pattern as admin_delete_family).
create function public.admin_revoke_device(device uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  d public.devices;
  removed boolean := false;
  n int;
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  select * into d from public.devices x where x.id = device for update;
  if not found then raise exception 'device not found'; end if;
  delete from public.devices x where x.id = device;
  begin
    delete from auth.users u where u.id = d.user_id;
    get diagnostics n = row_count;
    removed := n > 0;
  exception when insufficient_privilege then
    removed := false;
  end;
  perform public.log_admin_action('revoke_device', 'device', device::text,
    jsonb_build_object('family_id', d.family_id, 'name', d.name, 'user_id', d.user_id,
                       'auth_user_removed', removed));
  return jsonb_build_object('id', d.id, 'family_id', d.family_id, 'name', d.name,
                            'user_id', d.user_id, 'auth_user_removed', removed);
end $$;

-- Null numeric arguments leave that limit alone. A use_platform_* flag
-- clears the family's override so the platform default applies again.
create function public.admin_set_family_limits(
  family uuid,
  assistant_daily_limit int default null,
  storage_limit_bytes bigint default null,
  media_item_limit int default null,
  use_platform_assistant_limit boolean default false,
  use_platform_storage_limit boolean default false,
  use_platform_media_item_limit boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  f public.families;
  new_assistant int;
  new_storage bigint;
  new_items int;
  changes jsonb;
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  select * into f from public.families x where x.id = family for update;
  if not found then raise exception 'family not found'; end if;

  if coalesce(use_platform_assistant_limit, false) then
    new_assistant := null;
  elsif admin_set_family_limits.assistant_daily_limit is not null then
    if admin_set_family_limits.assistant_daily_limit < 0
       or admin_set_family_limits.assistant_daily_limit > 1000000 then
      raise exception 'assistant_daily_limit must be between 0 and 1000000';
    end if;
    new_assistant := admin_set_family_limits.assistant_daily_limit;
  else
    new_assistant := f.assistant_daily_limit;
  end if;

  if coalesce(use_platform_storage_limit, false) then
    new_storage := null;
  elsif admin_set_family_limits.storage_limit_bytes is not null then
    if admin_set_family_limits.storage_limit_bytes < 0
       or admin_set_family_limits.storage_limit_bytes > 1099511627776 then
      raise exception 'storage_limit_bytes must be between 0 and 1099511627776';
    end if;
    new_storage := admin_set_family_limits.storage_limit_bytes;
  else
    new_storage := f.storage_limit_bytes;
  end if;

  if coalesce(use_platform_media_item_limit, false) then
    new_items := null;
  elsif admin_set_family_limits.media_item_limit is not null then
    if admin_set_family_limits.media_item_limit < 0
       or admin_set_family_limits.media_item_limit > 1000000 then
      raise exception 'media_item_limit must be between 0 and 1000000';
    end if;
    new_items := admin_set_family_limits.media_item_limit;
  else
    new_items := f.media_item_limit;
  end if;

  update public.families x
     set assistant_daily_limit = new_assistant,
         storage_limit_bytes = new_storage,
         media_item_limit = new_items
   where x.id = family;

  changes := jsonb_strip_nulls(jsonb_build_object(
    'assistant_daily_limit', case when new_assistant is distinct from f.assistant_daily_limit then new_assistant end,
    'storage_limit_bytes', case when new_storage is distinct from f.storage_limit_bytes then new_storage end,
    'media_item_limit', case when new_items is distinct from f.media_item_limit then new_items end));
  -- Clearing an override stores null, which strip_nulls would drop. Say so
  -- explicitly so the audit log shows the reset.
  if new_assistant is null and f.assistant_daily_limit is not null then
    changes := changes || jsonb_build_object('assistant_daily_limit', null);
  end if;
  if new_storage is null and f.storage_limit_bytes is not null then
    changes := changes || jsonb_build_object('storage_limit_bytes', null);
  end if;
  if new_items is null and f.media_item_limit is not null then
    changes := changes || jsonb_build_object('media_item_limit', null);
  end if;
  if changes <> '{}'::jsonb then
    perform public.log_admin_action('set_family_limits', 'family', family::text, changes);
  end if;

  return jsonb_build_object(
    'assistant_daily_limit', new_assistant,
    'assistant_daily_limit_effective', coalesce(new_assistant, (select s.assistant_daily_limit from public.platform_settings s)),
    'storage_limit_bytes', new_storage,
    'storage_limit_effective', coalesce(new_storage, (select s.storage_limit_bytes from public.platform_settings s)),
    'media_item_limit', new_items,
    'media_item_limit_effective', coalesce(new_items, (select s.media_item_limit from public.platform_settings s)));
end $$;

drop function public.admin_update_settings(boolean, boolean, int);

create function public.admin_update_settings(
  invite_only boolean default null,
  assistant_enabled boolean default null,
  assistant_daily_limit int default null,
  storage_limit_bytes bigint default null,
  media_max_bytes bigint default null,
  media_item_limit int default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  changes jsonb := jsonb_strip_nulls(jsonb_build_object(
    'invite_only', admin_update_settings.invite_only,
    'assistant_enabled', admin_update_settings.assistant_enabled,
    'assistant_daily_limit', admin_update_settings.assistant_daily_limit,
    'storage_limit_bytes', admin_update_settings.storage_limit_bytes,
    'media_max_bytes', admin_update_settings.media_max_bytes,
    'media_item_limit', admin_update_settings.media_item_limit));
  result jsonb;
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  if admin_update_settings.assistant_daily_limit < 0 then
    raise exception 'assistant_daily_limit must be 0 or more';
  end if;
  if admin_update_settings.assistant_daily_limit > 1000000 then
    raise exception 'assistant_daily_limit must be at most 1000000';
  end if;
  if admin_update_settings.storage_limit_bytes < 0
     or admin_update_settings.storage_limit_bytes > 1099511627776 then
    raise exception 'storage_limit_bytes must be between 0 and 1099511627776';
  end if;
  if admin_update_settings.media_max_bytes < 1
     or admin_update_settings.media_max_bytes > 5368709120 then
    raise exception 'media_max_bytes must be between 1 and 5368709120';
  end if;
  if admin_update_settings.media_item_limit < 0
     or admin_update_settings.media_item_limit > 1000000 then
    raise exception 'media_item_limit must be between 0 and 1000000';
  end if;

  insert into public.platform_settings (id) values (true) on conflict (id) do nothing;
  update public.platform_settings s
     set invite_only           = coalesce(admin_update_settings.invite_only, s.invite_only),
         assistant_enabled     = coalesce(admin_update_settings.assistant_enabled, s.assistant_enabled),
         assistant_daily_limit = coalesce(admin_update_settings.assistant_daily_limit, s.assistant_daily_limit),
         storage_limit_bytes   = coalesce(admin_update_settings.storage_limit_bytes, s.storage_limit_bytes),
         media_max_bytes       = coalesce(admin_update_settings.media_max_bytes, s.media_max_bytes),
         media_item_limit      = coalesce(admin_update_settings.media_item_limit, s.media_item_limit),
         updated_at            = now(),
         updated_by            = auth.uid()
   where s.id
  returning to_jsonb(s) - 'id' into result;

  -- The Storage API enforces the bucket's own cap. Keep it in step when
  -- this database has Storage (skipped on plain Postgres).
  if to_regclass('storage.buckets') is not null then
    execute 'update storage.buckets set file_size_limit = $1, allowed_mime_types = $2 where id = ''family-media'''
      using (select s.media_max_bytes from public.platform_settings s), public.allowed_media_types();
  end if;

  perform public.log_admin_action('update_settings', 'settings', null, changes);
  return result;
end $$;

-- ───────────────────────── Privileges ─────────────────────────

revoke execute on function
  public.admin_list_families(text, int, int),
  public.admin_list_media(uuid, text, int, int),
  public.admin_delete_media(uuid),
  public.admin_revoke_device(uuid),
  public.admin_set_family_limits(uuid, int, bigint, int, boolean, boolean, boolean),
  public.admin_update_settings(boolean, boolean, int, bigint, bigint, int)
from public, anon;

grant execute on function
  public.admin_list_families(text, int, int),
  public.admin_list_media(uuid, text, int, int),
  public.admin_delete_media(uuid),
  public.admin_revoke_device(uuid),
  public.admin_set_family_limits(uuid, int, bigint, int, boolean, boolean, boolean),
  public.admin_update_settings(boolean, boolean, int, bigint, bigint, int)
to authenticated;
