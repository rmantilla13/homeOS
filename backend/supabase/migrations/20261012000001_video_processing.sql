-- Server-made wall copies of videos. A video the phone couldn't optimize
-- (or one from an older app) gets a 1080p HEVC copy made in a Vercel
-- Sandbox, and the row is moved onto it. See docs/PLATFORM_SPEC.md §1.13.
--
-- media_items.processing says where a video stands:
--   null        not known: rows from before this, or from an app that doesn't send it
--   pending     uploaded as it was; the server should make a wall copy
--   processing  a job is running (media_jobs has the attempt)
--   done        plays well on the wall: the phone optimized it, or the server did
--   failed      the server gave up; the original stays
-- A signed-in client may set null, 'pending' or 'done', and only on insert.
--
-- media_jobs is the server's bookkeeping, for the service role only. The
-- admin app reaches it through the media-jobs edge function, which calls the
-- media_job_* functions below. Safe to run again.

alter table public.media_items add column if not exists processing text;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.media_items'::regclass
                    and conname = 'media_items_processing_check') then
    alter table public.media_items
      add constraint media_items_processing_check
      check (processing is null
             or (kind = 'video' and processing in ('pending', 'processing', 'done', 'failed')));
  end if;
end $$;

comment on column public.media_items.processing is
  'Videos: null (unknown), pending, processing, done (plays well on the wall) or failed. See media_jobs.';

-- What the sweep looks for: Blob videos that aren't done yet.
create index if not exists media_items_unprocessed_idx
  on public.media_items (created_at)
  where kind = 'video' and file_store = 'blob' and processing is distinct from 'done';

create table if not exists public.media_jobs (
  media_id      uuid primary key references public.media_items on delete cascade,
  attempts      int not null default 0 check (attempts >= 0),
  started_at    timestamptz,
  finished_at   timestamptz,
  -- The file the row pointed at before the swap, deleted by the sweep once
  -- no display can still be playing it.
  replaced_path text check (replaced_path is null or char_length(replaced_path) <= 300),
  error         text check (error is null or char_length(error) <= 500),
  updated_at    timestamptz not null default now()
);

create index if not exists media_jobs_replaced_idx
  on public.media_jobs (finished_at) where replaced_path is not null;

alter table public.media_jobs enable row level security;
revoke all on table public.media_jobs from public, anon, authenticated;
grant select, insert, update, delete on table public.media_jobs to service_role;

-- media_items_guard freezes the other columns. It is left alone here (the
-- Blob migrations redefine it when they run again), so processing has its
-- own small guard.
create or replace function public.media_items_processing_guard()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_signed_in_client() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.processing is not null and new.processing not in ('pending', 'done') then
      raise exception 'a new video starts as pending or done';
    end if;
  elsif new.processing is distinct from old.processing then
    raise exception 'only a caption or the frame can be changed';
  end if;
  return new;
end $$;

drop trigger if exists media_items_processing_guard on public.media_items;
create trigger media_items_processing_guard
  before insert or update on public.media_items
  for each row execute function public.media_items_processing_guard();

-- ───────────────────────────── Jobs ─────────────────────────────

-- Marks up to p_limit videos as processing and returns them, never more than
-- p_max_running at once. p_media_id picks one video (the phone asked for
-- it); without it, pending rows come first, then rows nobody has looked at,
-- newest first. A job that started more than p_stale_after ago is taken
-- again; one out of attempts becomes failed.
create or replace function public.media_job_claim(
  p_media_id uuid default null,
  p_limit int default 1,
  p_max_running int default 2,
  p_max_attempts int default 3,
  p_stale_after interval default interval '1 hour')
returns table (media_id uuid, family_id uuid, storage_path text, thumbnail_path text,
               byte_size bigint, content_type text, attempt int)
language plpgsql security definer set search_path = public as $$
declare
  running int;
  room int;
  r record;
  n int;
begin
  -- One claim at a time, so two sweeps can't both see a free slot.
  perform pg_advisory_xact_lock(481516235);

  with gave_up as (
    update public.media_items m set processing = 'failed'
      from public.media_jobs j
     where j.media_id = m.id and m.processing = 'processing'
       and j.started_at <= now() - p_stale_after and j.attempts >= p_max_attempts
    returning m.id)
  update public.media_jobs j
     set finished_at = now(), updated_at = now(),
         error = coalesce(j.error, 'timed out')
    from gave_up g where j.media_id = g.id;

  select count(*)::int into running
    from public.media_items m join public.media_jobs j on j.media_id = m.id
   where m.processing = 'processing' and j.started_at > now() - p_stale_after;
  room := least(greatest(coalesce(p_limit, 1), 0), greatest(coalesce(p_max_running, 2) - running, 0));
  if room = 0 then
    return;
  end if;

  for r in
    select m.id, m.family_id, m.storage_path, m.thumbnail_path, m.byte_size, m.content_type
      from public.media_items m
      left join public.media_jobs j on j.media_id = m.id
     where m.kind = 'video' and m.file_store = 'blob'
       and (p_media_id is null or m.id = p_media_id)
       and coalesce(j.attempts, 0) < p_max_attempts
       and (m.processing is null or m.processing = 'pending'
            or (m.processing = 'processing' and (j.started_at is null or j.started_at <= now() - p_stale_after)))
     order by (m.processing is null), m.created_at desc
     limit room
     for update of m skip locked
  loop
    update public.media_items m set processing = 'processing' where m.id = r.id;
    insert into public.media_jobs as j (media_id, attempts, started_at, finished_at, error, updated_at)
    values (r.id, 1, now(), null, null, now())
    on conflict on constraint media_jobs_pkey do update
      set attempts = j.attempts + 1, started_at = now(), finished_at = null, error = null, updated_at = now()
    returning j.attempts into n;
    media_id := r.id;
    family_id := r.family_id;
    storage_path := r.storage_path;
    thumbnail_path := r.thumbnail_path;
    byte_size := r.byte_size;
    content_type := r.content_type;
    attempt := n;
    return next;
  end loop;
end $$;

-- A job finished. p_path null: the file already plays well on the wall, so
-- the row stays on it. Otherwise the row moves to the copy at
-- `<family_id>/<id>-wall.mp4`, whose size (from Blob, not the worker) can't
-- be more than the original's. A poster is added only when the row has none.
-- An attempt that is no longer the running one is refused.
create or replace function public.media_job_finish(
  p_media_id uuid,
  p_attempt int,
  p_path text default null,
  p_bytes bigint default null,
  p_width int default null,
  p_height int default null,
  p_thumbnail_path text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  m public.media_items;
  j public.media_jobs;
  base text;
  max_bytes bigint;
begin
  select * into m from public.media_items x where x.id = p_media_id for update;
  if not found then
    raise exception 'media not found';
  end if;
  select * into j from public.media_jobs x where x.media_id = p_media_id for update;
  if m.processing is distinct from 'processing' or j.attempts is distinct from p_attempt then
    raise exception 'that job is not running';
  end if;

  base := lower(m.family_id::text) || '/' || lower(m.id::text);
  if p_thumbnail_path is not null and p_thumbnail_path <> base || '-thumb.jpg' then
    raise exception 'the poster must be %', base || '-thumb.jpg';
  end if;
  if p_width is not null and (p_width < 1 or p_width > 16384) then p_width := null; end if;
  if p_height is not null and (p_height < 1 or p_height > 16384) then p_height := null; end if;

  if p_path is null then
    update public.media_items x
       set processing = 'done',
           thumbnail_path = coalesce(x.thumbnail_path, p_thumbnail_path)
     where x.id = m.id;
    update public.media_jobs x set finished_at = now(), error = null, updated_at = now()
     where x.media_id = m.id;
    return jsonb_build_object('storage_path', m.storage_path, 'replaced_path', null);
  end if;

  if p_path <> base || '-wall.mp4' then
    raise exception 'the copy must be %', base || '-wall.mp4';
  end if;
  if p_path = m.storage_path then
    raise exception 'the row is already on that copy';
  end if;
  select s.media_max_bytes into max_bytes from public.platform_settings s;
  if p_bytes is null or p_bytes < 1 or p_bytes > coalesce(m.byte_size, max_bytes) then
    raise exception 'the copy must be smaller than the original';
  end if;

  update public.media_items x
     set storage_path = p_path,
         byte_size = p_bytes,
         content_type = 'video/mp4',
         width = coalesce(p_width, x.width),
         height = coalesce(p_height, x.height),
         thumbnail_path = coalesce(x.thumbnail_path, p_thumbnail_path),
         processing = 'done'
   where x.id = m.id;
  update public.media_jobs x
     set finished_at = now(), error = null, updated_at = now(),
         replaced_path = coalesce(x.replaced_path, m.storage_path)
   where x.media_id = m.id;
  return jsonb_build_object('storage_path', p_path, 'replaced_path', m.storage_path);
end $$;

-- A job failed. It goes back to pending for another try, or to failed when
-- p_retry is false or the attempts are used up. Returns the new state, or
-- null when that attempt is no longer the running one.
create or replace function public.media_job_fail(
  p_media_id uuid,
  p_attempt int,
  p_error text,
  p_retry boolean default true,
  p_max_attempts int default 3)
returns text
language plpgsql security definer set search_path = public as $$
declare
  m public.media_items;
  j public.media_jobs;
  state text;
begin
  select * into m from public.media_items x where x.id = p_media_id for update;
  select * into j from public.media_jobs x where x.media_id = p_media_id for update;
  if m.id is null or m.processing is distinct from 'processing' or j.attempts is distinct from p_attempt then
    return null;
  end if;
  state := case when p_retry and j.attempts < p_max_attempts then 'pending' else 'failed' end;
  update public.media_items x set processing = state where x.id = m.id;
  update public.media_jobs x
     set finished_at = now(), updated_at = now(), error = left(coalesce(p_error, 'failed'), 500)
   where x.media_id = m.id;
  return state;
end $$;

-- Originals swapped out at least p_older_than ago, for the sweep to delete.
create or replace function public.media_job_replaced_due(
  p_older_than interval default interval '6 hours',
  p_limit int default 100)
returns table (media_id uuid, replaced_path text)
language sql stable security definer set search_path = public as $$
  select j.media_id, j.replaced_path
    from public.media_jobs j
   where j.replaced_path is not null and j.finished_at <= now() - p_older_than
   order by j.finished_at
   limit greatest(least(coalesce(p_limit, 100), 1000), 1)
$$;

-- The sweep deleted that original.
create or replace function public.media_job_replaced_cleared(p_media_id uuid, p_path text)
returns boolean
language plpgsql security definer set search_path = public as $$
declare
  n int;
begin
  update public.media_jobs j set replaced_path = null, updated_at = now()
   where j.media_id = p_media_id and j.replaced_path = p_path;
  get diagnostics n = row_count;
  return n > 0;
end $$;

revoke execute on function public.media_items_processing_guard() from public, anon, authenticated;
revoke execute on function public.media_job_claim(uuid, int, int, int, interval) from public, anon, authenticated;
revoke execute on function public.media_job_finish(uuid, int, text, bigint, int, int, text) from public, anon, authenticated;
revoke execute on function public.media_job_fail(uuid, int, text, boolean, int) from public, anon, authenticated;
revoke execute on function public.media_job_replaced_due(interval, int) from public, anon, authenticated;
revoke execute on function public.media_job_replaced_cleared(uuid, text) from public, anon, authenticated;
grant execute on function public.media_job_claim(uuid, int, int, int, interval) to service_role;
grant execute on function public.media_job_finish(uuid, int, text, bigint, int, int, text) to service_role;
grant execute on function public.media_job_fail(uuid, int, text, boolean, int) to service_role;
grant execute on function public.media_job_replaced_due(interval, int) to service_role;
grant execute on function public.media_job_replaced_cleared(uuid, text) to service_role;
