-- Connected calendars. See docs/PLATFORM_SPEC.md §1.13.
--
-- 1. Events come in from other calendars: a Google account (OAuth) or any
--    calendar link (ICS or webcal: iCloud public calendars, Outlook, schools,
--    sports teams, Google's secret address). Each calendar is a
--    `calendar_sources` row. The `calendar-sync` function fetches it and
--    hands the occurrences to `calendar_apply_sync`, which writes them as
--    plain `events` rows with `source_id` set, so the display, the iOS app
--    and the assistant show them with no extra work. They are read-only
--    here: the other calendar owns them.
-- 2. The family's own events go out through a secret link
--    (`calendar_feeds`) that Google Calendar, Apple Calendar and Outlook can
--    subscribe to.
--
-- Secrets (Google refresh tokens, calendar links) live in tables only the
-- service role can read. Parents see the account's email and the link's host.

-- ───────────────────────────── Tables ─────────────────────────────

-- A Google account a parent connected for the family. It goes with that
-- parent's login, and when they leave the family (members_calendar_cleanup).
create table public.calendar_accounts (
  id               uuid primary key default gen_random_uuid(),
  family_id        uuid not null references public.families on delete cascade,
  provider         text not null default 'google' check (provider in ('google')),
  email            text not null default '',
  -- Google refused the refresh token (revoked, password changed): a parent
  -- has to connect the account again.
  needs_reconnect  boolean not null default false,
  created_by       uuid not null references auth.users on delete cascade,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (family_id, provider, email)
);

-- Service role only.
create table public.calendar_account_tokens (
  account_id               uuid primary key references public.calendar_accounts on delete cascade,
  refresh_token            text not null,
  access_token             text,
  access_token_expires_at  timestamptz,
  updated_at               timestamptz not null default now()
);

create table public.calendar_sources (
  id                  uuid primary key default gen_random_uuid(),
  family_id           uuid not null references public.families on delete cascade,
  provider            text not null check (provider in ('ics', 'google')),
  account_id          uuid references public.calendar_accounts on delete cascade,
  google_calendar_id  text,
  url_host            text,               -- a link's host, to tell links apart; the link itself is secret
  name                text not null,
  color               text,               -- the events' color; null uses the member's
  member_id           uuid references public.members on delete set null,   -- who the events are for
  busy_only           boolean not null default false,                       -- titles become "Busy"
  enabled             boolean not null default true,
  last_attempt_at     timestamptz,
  last_synced_at      timestamptz,
  last_error          text,
  event_count         int not null default 0,
  created_by          uuid references auth.users on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint calendar_sources_name check (length(btrim(name)) between 1 and 100),
  constraint calendar_sources_color_hex check (color ~ '^#[0-9A-Fa-f]{6}$'),
  constraint calendar_sources_provider_fields check (
    case provider when 'google' then account_id is not null and google_calendar_id is not null
                  else account_id is null and google_calendar_id is null end),
  unique (account_id, google_calendar_id)
);
create index on public.calendar_sources (family_id);

-- The calendar link of an 'ics' source. Service role only: a link like
-- Google's secret address reads someone's whole calendar.
create table public.calendar_source_links (
  source_id  uuid primary key references public.calendar_sources on delete cascade,
  url        text not null check (length(url) <= 2048)
);

-- The family's own calendar as a subscribable link. Parents only.
create table public.calendar_feeds (
  family_id   uuid primary key references public.families on delete cascade,
  token       text not null unique,
  created_by  uuid references auth.users on delete set null default auth.uid(),
  created_at  timestamptz not null default now()
);

-- Imported events: one row per occurrence, keyed by the other calendar's id
-- for it. The old (family, external_source, external_id) key was never
-- written, and two parents may connect the same shared calendar.
alter table public.events add column source_id uuid references public.calendar_sources on delete cascade;
alter table public.events drop constraint if exists events_family_id_external_source_external_id_key;
alter table public.events add constraint events_source_external unique (source_id, external_id);
alter table public.events add constraint events_source_has_id check (source_id is null or external_id is not null);

create trigger calendar_accounts_touch before update on public.calendar_accounts
  for each row execute function public.touch_updated_at();
create trigger calendar_sources_touch before update on public.calendar_sources
  for each row execute function public.touch_updated_at();

-- ───────────────────────────── Guards ─────────────────────────────

-- Signed-in clients (PostgREST runs them as `authenticated` or `anon`) can't
-- add, change or delete imported events; the next sync would undo it. Calendar
-- sync (the service role), the functions below and cascades run as other
-- roles.
create function public.events_source_guard()
returns trigger
language plpgsql set search_path = public as $$
begin
  if current_user not in ('authenticated', 'anon') then
    return coalesce(new, old);
  end if;
  if tg_op <> 'INSERT' and old.source_id is not null then
    raise exception 'this event comes from a connected calendar; change it there';
  end if;
  if tg_op <> 'DELETE' and new.source_id is not null then
    raise exception 'only calendar sync can add events from a connected calendar';
  end if;
  return coalesce(new, old);
end $$;

create trigger events_source_guard
  before insert or update or delete on public.events
  for each row execute function public.events_source_guard();

-- Who an imported event is for comes from its calendar (member_id). Not
-- security definer: the client's own RLS decides which events it can see.
create function public.event_members_source_guard()
returns trigger
language plpgsql set search_path = public as $$
begin
  if current_user in ('authenticated', 'anon')
     and exists (select 1 from public.events e
                  where e.source_id is not null
                    and e.id in (case when tg_op <> 'INSERT' then old.event_id end,
                                 case when tg_op <> 'DELETE' then new.event_id end)) then
    raise exception 'this event comes from a connected calendar; change it there';
  end if;
  return coalesce(new, old);
end $$;

create trigger event_members_source_guard
  before insert or update or delete on public.event_members
  for each row execute function public.event_members_source_guard();

-- Parents may rename a calendar, recolor it, say who it's for, show it as
-- busy only, and turn it off. Everything else is the sync's. A Google
-- calendar shown as Busy shows its details again only when the parent who
-- connected that account says so: they're that person's calendars.
create function public.calendar_sources_guard()
returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' and current_user in ('authenticated', 'anon')
     and (new.id, new.family_id, new.provider, new.account_id, new.google_calendar_id, new.url_host,
          new.last_attempt_at, new.last_synced_at, new.last_error, new.event_count, new.created_by, new.created_at)
         is distinct from
         (old.id, old.family_id, old.provider, old.account_id, old.google_calendar_id, old.url_host,
          old.last_attempt_at, old.last_synced_at, old.last_error, old.event_count, old.created_by, old.created_at) then
    raise exception 'only a calendar''s name, color, person, privacy and on/off can be changed';
  end if;
  if tg_op = 'UPDATE' and current_user in ('authenticated', 'anon')
     and old.busy_only and not new.busy_only and old.account_id is not null
     and not exists (select 1 from public.calendar_accounts a
                      where a.id = old.account_id and a.created_by = auth.uid()) then
    raise exception 'only the person who connected this Google account can show its details';
  end if;
  if new.member_id is not null and (tg_op = 'INSERT' or new.member_id is distinct from old.member_id)
     and not exists (select 1 from public.members m where m.id = new.member_id and m.family_id = new.family_id) then
    raise exception 'that person isn''t in this family';
  end if;
  if new.account_id is not null and (tg_op = 'INSERT' or new.account_id is distinct from old.account_id)
     and not exists (select 1 from public.calendar_accounts a
                      where a.id = new.account_id and a.family_id = new.family_id) then
    raise exception 'that account isn''t in this family';
  end if;
  new.name := btrim(new.name);
  if tg_op = 'UPDATE' and old.enabled and not new.enabled then
    new.event_count := 0;
  end if;
  return new;
end $$;

create trigger calendar_sources_guard
  before insert or update on public.calendar_sources
  for each row execute function public.calendar_sources_guard();

-- A parent's change shows at once: turning a calendar off removes its
-- events, and a new color, person or "busy only" applies to the events
-- already here. Turning "busy only" off, or a calendar back on, waits for the
-- next sync (the app asks for one).
create function public.calendar_sources_apply()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.enabled and not new.enabled then
    delete from public.events where source_id = new.id;
    return null;
  end if;
  if new.color is distinct from old.color then
    update public.events set color = new.color where source_id = new.id;
  end if;
  if new.busy_only and not old.busy_only then
    update public.events set title = 'Busy', description = null, location = null
     where source_id = new.id;
  end if;
  if new.member_id is distinct from old.member_id then
    perform public.calendar_link_member(new.id, new.member_id);
  end if;
  return null;
end $$;

create trigger calendar_sources_apply
  after update on public.calendar_sources
  for each row execute function public.calendar_sources_apply();

-- A parent's Google account leaves with them: when their member row loses
-- its login (leave_family, account deletion) or goes.
create function public.members_calendar_cleanup()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.user_id is not null and (tg_op = 'DELETE' or new.user_id is distinct from old.user_id) then
    delete from public.calendar_accounts where family_id = old.family_id and created_by = old.user_id;
  end if;
  return null;
end $$;

create trigger members_calendar_cleanup
  after update of user_id or delete on public.members
  for each row execute function public.members_calendar_cleanup();

-- ───────────────────────────── Sync ─────────────────────────────

-- Links every event of a calendar to `member` (none when null), and only them.
create function public.calendar_link_member(source uuid, member uuid)
returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.event_members em
   using public.events e
   where em.event_id = e.id and e.source_id = source and em.member_id is distinct from member;
  if member is not null then
    insert into public.event_members (event_id, member_id)
    select e.id, member from public.events e where e.source_id = source
    on conflict do nothing;
  end if;
end $$;

-- Claims calendars to sync now by stamping last_attempt_at, so overlapping
-- runs don't fetch the same one twice. Enabled calendars of active families
-- not tried in the last `min_age_seconds`, least recently tried first.
-- `only_family` / `only_source` narrow it (the app's "Sync now").
create function public.calendar_claim_due(lim int default 20, min_age_seconds int default 900,
                                          only_family uuid default null, only_source uuid default null)
returns setof public.calendar_sources
language plpgsql security definer set search_path = public as $$
begin
  return query
  update public.calendar_sources c
     set last_attempt_at = now()
   where c.id in (
     select s.id
       from public.calendar_sources s
       join public.families f on f.id = s.family_id
      where s.enabled and f.status = 'active'
        and (only_family is null or s.family_id = only_family)
        and (only_source is null or s.id = only_source)
        and (s.last_attempt_at is null
             or s.last_attempt_at <= now() - make_interval(secs => greatest(min_age_seconds, 0)))
      order by s.last_attempt_at nulls first, s.id
      limit greatest(least(lim, 200), 0)
      for update of s skip locked)
  returning c.*;
end $$;

-- Replaces a calendar's events with `rows`, a JSON array of
-- { uid, title, description, location, starts_at, ends_at, all_day }, one per
-- occurrence (at most 5000). Rows that changed are updated in place, so ids
-- stay put and Realtime only hears about real changes; events no longer in
-- the calendar are deleted. Rows without a uid, a start or an end, or that
-- end before they start, are left out. Returns
-- { added, updated, removed, event_count }.
create function public.calendar_apply_sync(source uuid, rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s public.calendar_sources;
  fam_status text;
  added int;
  changed int;
  removed int;
  total int;
begin
  select * into s from public.calendar_sources where id = source for update;
  if not found then
    raise exception 'calendar not found';
  end if;
  select f.status into fam_status from public.families f where f.id = s.family_id;
  if fam_status is distinct from 'active' then
    raise exception 'this family is suspended';
  end if;
  if rows is null or jsonb_typeof(rows) <> 'array' then
    raise exception 'rows must be a JSON array';
  end if;
  if jsonb_array_length(rows) > 5000 then
    raise exception 'too many events (at most 5000)';
  end if;
  if not s.enabled then
    rows := '[]';  -- turned off while it was syncing: nothing stays
  end if;

  create temp table if not exists calendar_incoming (
    uid text primary key, title text, description text, location text,
    starts_at timestamptz, ends_at timestamptz, all_day boolean
  ) on commit drop;
  truncate pg_temp.calendar_incoming;
  insert into pg_temp.calendar_incoming
  select r.uid,
         case when s.busy_only then 'Busy'
              else coalesce(nullif(btrim(left(r.title, 500)), ''), 'Untitled event') end,
         case when s.busy_only then null else nullif(btrim(left(r.description, 4000)), '') end,
         case when s.busy_only then null else nullif(btrim(left(r.location, 500)), '') end,
         r.starts_at, r.ends_at, coalesce(r.all_day, false)
    from jsonb_to_recordset(rows) as r(uid text, title text, description text, location text,
                                       starts_at timestamptz, ends_at timestamptz, all_day boolean)
   where nullif(r.uid, '') is not null and length(r.uid) <= 1024
     and isfinite(r.starts_at) and isfinite(r.ends_at) and r.ends_at >= r.starts_at
  on conflict (uid) do nothing;

  with written as (
    insert into public.events as e (family_id, source_id, external_source, external_id, title, description,
                                    location, starts_at, ends_at, all_day, color)
    select s.family_id, s.id, s.provider, i.uid, i.title, i.description, i.location,
           i.starts_at, i.ends_at, i.all_day, s.color
      from pg_temp.calendar_incoming i
    on conflict (source_id, external_id) do update
       set title = excluded.title, description = excluded.description, location = excluded.location,
           starts_at = excluded.starts_at, ends_at = excluded.ends_at, all_day = excluded.all_day,
           color = excluded.color
     where (e.title, e.description, e.location, e.starts_at, e.ends_at, e.all_day, e.color)
           is distinct from (excluded.title, excluded.description, excluded.location, excluded.starts_at,
                             excluded.ends_at, excluded.all_day, excluded.color)
    returning (xmax = 0) as inserted
  )
  select count(*) filter (where inserted), count(*) filter (where not inserted)
    into added, changed
    from written;

  delete from public.events e
   where e.source_id = s.id
     and not exists (select 1 from pg_temp.calendar_incoming i where i.uid = e.external_id);
  get diagnostics removed = row_count;

  perform public.calendar_link_member(s.id, s.member_id);

  select count(*) into total from public.events where source_id = s.id;
  update public.calendar_sources
     set last_attempt_at = now(), last_synced_at = now(), last_error = null, event_count = total
   where id = s.id;
  truncate pg_temp.calendar_incoming;
  return jsonb_build_object('added', added, 'updated', changed, 'removed', removed, 'event_count', total);
end $$;

-- ───────────────────────────── Sharing out ─────────────────────────────

-- The token of the family's subscribable calendar link, made on first use.
-- `rotate` replaces it, so the old link stops working. Parents only.
create function public.calendar_feed_token(family uuid, rotate boolean default false)
returns text
language plpgsql volatile security definer
set search_path = public, extensions  -- pgcrypto lives in `extensions` on Supabase
as $$
declare
  t text;
begin
  if family is null or not public.is_family_member(family) or not public.is_family_parent(family) then
    raise exception 'only a parent can share the family calendar';
  end if;
  if not coalesce(rotate, false) then
    select f.token into t from public.calendar_feeds f where f.family_id = family;
    if found then
      return t;
    end if;
  end if;
  -- 24 random bytes, URL-safe base64: 32 characters.
  t := translate(encode(gen_random_bytes(24), 'base64'), '+/', '-_');
  insert into public.calendar_feeds (family_id, token, created_by)
  values (family, t, auth.uid())
  on conflict (family_id) do update
     set token = excluded.token, created_by = excluded.created_by, created_at = now();
  return t;
end $$;

-- ───────────────────────────── Reads ─────────────────────────────

-- Imported events change when their calendar does, not when the family does.
create or replace function public.family_last_activity(fid uuid)
returns timestamptz
language sql stable security definer set search_path = public as $$
  with h as (select now() + interval '10 minutes' as horizon)
  select greatest(
    (select f.created_at from public.families f where f.id = fid and f.created_at <= h.horizon),
    (select max(last_seen_at) from public.devices where family_id = fid and last_seen_at <= h.horizon),
    (select max(updated_at) from public.events
      where family_id = fid and source_id is null and updated_at <= h.horizon),
    (select max(updated_at) from public.tasks where family_id = fid and updated_at <= h.horizon),
    (select max(completed_at) from public.task_completions where family_id = fid and completed_at <= h.horizon),
    (select max(i.updated_at) from public.list_items i join public.lists l on l.id = i.list_id
      where l.family_id = fid and i.updated_at <= h.horizon),
    (select max(created_at) from public.media_items where family_id = fid and created_at <= h.horizon),
    (select max(created_at) from public.points_ledger where family_id = fid and created_at <= h.horizon),
    (select max(created_at) from public.family_memories where family_id = fid and created_at <= h.horizon),
    (select max(created_at) from public.assistant_usage where family_id = fid and created_at <= h.horizon))
  from h
$$;

-- event_occurrences gains `source_id` (null for the family's own events), so
-- clients can tell imported events apart. A new result column means a new
-- function; the body is otherwise the one from 20261010000002.
drop function public.event_occurrences(uuid, timestamptz, timestamptz);

-- One row per event occurrence that overlaps [range_start, range_end).
-- `id` is the stored event (what edits and deletes name); `starts_at` and
-- `ends_at` are this occurrence, `series_*` the stored row. A repeat keeps
-- the series' local start time and local length in the family's time zone,
-- so a 4:30pm practice stays at 4:30pm across a DST change. A repeating row
-- with an infinite start or end is skipped rather than failing the call.
-- `source_id` is the connected calendar an imported event came from.
create function public.event_occurrences(fid uuid, range_start timestamptz, range_end timestamptz)
returns table (id uuid, family_id uuid, title text, description text, location text,
               starts_at timestamptz, ends_at timestamptz, all_day boolean, rrule text, color text,
               created_by uuid, series_starts_at timestamptz, series_ends_at timestamptz,
               member_ids uuid[], source_id uuid)
language plpgsql stable security invoker set search_path = public as $$
declare
  tz text;
begin
  if range_start is null or range_end is null or range_end <= range_start then
    raise exception 'range_end must be after range_start';
  end if;
  if range_end - range_start > interval '400 days' then
    raise exception 'range can''t be longer than 400 days';
  end if;

  -- A zone Postgres doesn't know would fail every row; fall back to UTC.
  select f.timezone into tz from public.families f where f.id = fid;
  begin
    perform now() at time zone tz;
  exception when invalid_parameter_value then
    tz := null;
  end;
  tz := coalesce(nullif(tz, ''), 'UTC');

  return query
  with ev as (
    select e.*, e.starts_at at time zone tz as local_start, e.ends_at at time zone tz as local_end
    from public.events e
    where e.family_id = fid and e.starts_at < range_end
      -- A past one-off event can't overlap the window. Plain comparisons, so
      -- Postgres can apply them before the per-row RLS check and the cost
      -- follows the window, not the family's whole history.
      and (e.rrule is not null or e.ends_at > range_start or e.starts_at >= range_start)
  ),
  rep as (
    select ev.* from ev
    where nullif(btrim(ev.rrule), '') is not null and isfinite(ev.starts_at) and isfinite(ev.ends_at)
  ),
  occ as (
    select ev.id as event_id, ev.starts_at as o_start, ev.ends_at as o_end
    from ev
    where nullif(btrim(ev.rrule), '') is null
    union all
    -- Repeats: start early enough to catch a long one already under way.
    select rep.id, s.o_start, greatest(s.o_start, s.o_end)
    from rep
    cross join lateral public.rrule_days(
      rep.rrule, rep.local_start::date,
      greatest(rep.local_start::date,
               (range_start at time zone tz)::date - least(rep.local_end::date - rep.local_start::date, 800) - 1),
      (range_end at time zone tz)::date, true) as d(day)
    cross join lateral (
      select d.day + rep.local_start::time as ls,
             d.day + rep.local_start::time + (rep.local_end - rep.local_start) as le
    ) w
    cross join lateral (
      select w.ls at time zone tz as s1, w.le at time zone tz as e1
    ) u
    cross join lateral (
      -- A local time that happens twice (the hour the clocks go back) is the
      -- first one, as in RFC 5545; Postgres alone would pick the second.
      select case when (u.s1 - interval '1 hour') at time zone tz = w.ls then u.s1 - interval '1 hour' else u.s1 end as s0,
             case when (u.e1 - interval '1 hour') at time zone tz = w.le then u.e1 - interval '1 hour' else u.e1 end as e0
    ) v
    cross join lateral (
      select case when d.day = rep.local_start::date then rep.starts_at else v.s0 end as o_start,
             case when d.day = rep.local_start::date then rep.ends_at
                  -- A start in the hour the clocks skip moves forward with
                  -- them (RFC 5545): keep the length rather than the end time.
                  when v.s0 at time zone tz <> w.ls then v.s0 + (rep.local_end - rep.local_start)
                  else v.e0 end as o_end
    ) s
  ),
  who as (
    select em.event_id, array_agg(em.member_id order by m.sort_order, em.member_id) as ids
    from public.event_members em
    join ev on ev.id = em.event_id
    left join public.members m on m.id = em.member_id
    group by em.event_id
  )
  select ev.id, ev.family_id, ev.title, ev.description, ev.location, o.o_start, o.o_end,
         ev.all_day, ev.rrule, ev.color, ev.created_by, ev.starts_at, ev.ends_at,
         coalesce(who.ids, '{}'::uuid[]), ev.source_id
  from occ o
  join ev on ev.id = o.event_id
  left join who on who.event_id = o.event_id
  where o.o_start < range_end and (o.o_end > range_start or o.o_start >= range_start)
  order by o.o_start, ev.all_day desc, ev.id;
end $$;

-- ───────────────────────────── Access ─────────────────────────────

alter table public.calendar_accounts       enable row level security;
alter table public.calendar_account_tokens enable row level security;
alter table public.calendar_sources        enable row level security;
alter table public.calendar_source_links   enable row level security;
alter table public.calendar_feeds          enable row level security;

-- Secrets: the service role only. RLS with no policies already says so.
revoke all on public.calendar_account_tokens, public.calendar_source_links from anon, authenticated;

-- Everyone in the family sees which calendars come in (an event shows where
-- it's from). Parents see the Google accounts, change and remove calendars,
-- and see or stop the shared link. New calendars and accounts come only
-- through calendar-sync, which checks the link or the Google sign-in first.
create policy calendar_sources_read on public.calendar_sources for select
  using (public.is_family_member(family_id));
create policy calendar_sources_update on public.calendar_sources for update
  using (public.is_family_member(family_id) and public.is_family_parent(family_id))
  with check (public.is_family_member(family_id) and public.is_family_parent(family_id));
create policy calendar_sources_delete on public.calendar_sources for delete
  using (public.is_family_member(family_id) and public.is_family_parent(family_id));

create policy calendar_accounts_read on public.calendar_accounts for select
  using (public.is_family_member(family_id) and public.is_family_parent(family_id));

create policy calendar_feeds_read on public.calendar_feeds for select
  using (public.is_family_member(family_id) and public.is_family_parent(family_id));
create policy calendar_feeds_delete on public.calendar_feeds for delete
  using (public.is_family_member(family_id) and public.is_family_parent(family_id));

revoke insert on public.calendar_sources, public.calendar_accounts, public.calendar_feeds from anon, authenticated;
revoke update on public.calendar_accounts, public.calendar_feeds from anon, authenticated;
revoke delete on public.calendar_accounts from anon, authenticated;

-- Triggers and the sync's own calls are not API.
revoke execute on function
  public.events_source_guard(),
  public.event_members_source_guard(),
  public.calendar_sources_guard(),
  public.calendar_sources_apply(),
  public.members_calendar_cleanup(),
  public.calendar_link_member(uuid, uuid),
  public.calendar_claim_due(int, int, uuid, uuid),
  public.calendar_apply_sync(uuid, jsonb)
from public, anon, authenticated;
grant execute on function
  public.calendar_claim_due(int, int, uuid, uuid),
  public.calendar_apply_sync(uuid, jsonb)
to service_role;

revoke execute on function public.calendar_feed_token(uuid, boolean) from public, anon;
grant execute on function public.calendar_feed_token(uuid, boolean) to authenticated;

revoke execute on function public.event_occurrences(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.event_occurrences(uuid, timestamptz, timestamptz) to authenticated, service_role;
