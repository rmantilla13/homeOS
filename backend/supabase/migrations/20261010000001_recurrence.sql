-- Repeats worked out once, in the database. See docs/PLATFORM_SPEC.md §1.11.
--
-- The display, the iOS app and the assistant each read `rrule` their own
-- way: weekly and monthly-by-date at best, no INTERVAL, and repeating events
-- showed only their first day everywhere. Now:
--
-- 1. rrule_occurs_on(rule, dtstart, day) answers "does this series fall on
--    this day" for the RFC 5545 subset in §1.11, and rrule_days lists those
--    days in a range (one parse per series, which the calendar needs).
-- 2. event_occurrences(fid, range_start, range_end) expands repeating events
--    in the family's time zone: one row per occurrence.
-- 3. chores_due(fid, day) is the family's chores for a day. A one-time chore
--    stays up until someone finishes it.
--
-- The two that read tables are security invoker, so RLS decides what a
-- caller sees, exactly as if they had selected the rows themselves.

-- ───────────────────────────── Rules ─────────────────────────────

-- Every day in [from_day, to_day] on which the series anchored at the local
-- date `dtstart` occurs, in order. With dtstart_is_instance (events) dtstart
-- is the first occurrence even when it doesn't fit the pattern; without it
-- (chores, anchored at a creation or due date) only matching days count.
-- Parts this doesn't understand are ignored, and a bad value in a known part
-- counts as if the part weren't there, so a rule never raises.
-- The day query's plan doesn't depend on the rule, but Postgres kept
-- re-planning it for every call, which cost more than running it.
create function public.rrule_days(rule text, dtstart date, from_day date, to_day date,
                                  dtstart_is_instance boolean default true)
returns setof date
language plpgsql immutable
set search_path = public
set plan_cache_mode = force_generic_plan
as $$
declare
  codes   constant text[] := array['MO', 'TU', 'WE', 'TH', 'FR', 'SA', 'SU'];
  r       text := upper(regexp_replace(coalesce(rule, ''), '\s', '', 'g'));
  part    text;
  k       text;
  v       text;
  tok     text;
  w       int;
  n       int;
  y       int;
  m       int;
  freq    int;      -- 1 daily, 2 weekly, 3 monthly, 4 yearly, 0 more often than daily
  ival    int := 1;
  cnt     int;
  until_d date;
  wkst    int := 0; -- weekdays are 0 = Monday … 6 = Sunday throughout
  wd_all  int[];    -- BYDAY weekdays, ordinals ignored
  wd_any  int[];    -- BYDAY weekdays without an ordinal
  wd_nth  int[];    -- weekday * 100 + n for "nth such weekday of the month"
  wd_last int[];    -- weekday * 100 + n for "nth such weekday from the end"
  mdays   int[];    -- BYMONTHDAY, negative counts from the end of the month
  months  int[];    -- BYMONTH
  dt_wd   int;
  dt_dom  int := extract(day from dtstart);
  dt_mon  int := extract(month from dtstart);
  dt_yr   int := extract(year from dtstart);
  dt_ws   date;     -- start of dtstart's week (WKST)
  last_d  date;
  c0      date;
  c1      date;
  seen    int := 0;
  hit     date;
begin
  if left(r, 6) = 'RRULE:' then
    r := substr(r, 7);
  end if;

  foreach part in array string_to_array(r, ';') loop
    k := split_part(part, '=', 1);
    v := substr(part, length(k) + 2);
    case k
      when 'FREQ' then
        freq := case v when 'DAILY' then 1 when 'WEEKLY' then 2 when 'MONTHLY' then 3 when 'YEARLY' then 4
                       when 'HOURLY' then 0 when 'MINUTELY' then 0 when 'SECONDLY' then 0 end;
      when 'INTERVAL' then
        ival := case when v ~ '^\+?[0-9]{1,9}$' then greatest(v::int, 1) else 1 end;
      when 'COUNT' then
        cnt := case when v ~ '^\+?[0-9]{1,9}$' then nullif(greatest(v::int, 0), 0) end;
      when 'UNTIL' then
        -- The date part as written; a time (UTC or not) doesn't move it.
        until_d := null;
        if v ~ '^[0-9]{8}(T[0-9]{6}Z?)?$' then
          y := substr(v, 1, 4)::int;
          m := substr(v, 5, 2)::int;
          n := substr(v, 7, 2)::int;
          if y >= 1 and m between 1 and 12 then
            if n between 1 and make_date(y + m / 12, m % 12 + 1, 1) - make_date(y, m, 1) then
              until_d := make_date(y, m, n);
            end if;
          end if;
        end if;
      when 'WKST' then
        wkst := coalesce(array_position(codes, v) - 1, 0);
      when 'BYDAY' then
        wd_all := '{}'; wd_any := '{}'; wd_nth := '{}'; wd_last := '{}';
        foreach tok in array string_to_array(v, ',') loop
          if tok !~ '^([+-]?[0-9]{1,2})?(MO|TU|WE|TH|FR|SA|SU)$' then
            wd_all := null;
            exit;
          end if;
          w := array_position(codes, right(tok, 2)) - 1;
          n := coalesce(nullif(left(tok, -2), '')::int, 0);
          if n = 0 and left(tok, -2) <> '' then  -- "0MO"
            wd_all := null;
            exit;
          end if;
          wd_all := wd_all || w;
          if n = 0 then
            wd_any := wd_any || w;
          elsif n > 0 then
            wd_nth := wd_nth || (w * 100 + n);
          else
            wd_last := wd_last || (w * 100 - n);
          end if;
        end loop;
        if cardinality(wd_all) = 0 then
          wd_all := null;
        end if;
      when 'BYMONTHDAY' then
        mdays := '{}';
        foreach tok in array string_to_array(v, ',') loop
          n := case when tok ~ '^[+-]?[0-9]{1,2}$' then tok::int end;
          if n is null or abs(n) not between 1 and 31 then
            mdays := null;
            exit;
          end if;
          mdays := mdays || n;
        end loop;
        if cardinality(mdays) = 0 then
          mdays := null;
        end if;
      when 'BYMONTH' then
        months := '{}';
        foreach tok in array string_to_array(v, ',') loop
          n := case when tok ~ '^\+?[0-9]{1,2}$' then tok::int end;
          if n is null or n not between 1 and 12 then
            months := null;
            exit;
          end if;
          months := months || n;
        end loop;
        if cardinality(months) = 0 then
          months := null;
        end if;
      else
        null;  -- BYSETPOS, BYYEARDAY, BYWEEKNO, BYHOUR, … aren't supported
    end case;
  end loop;

  -- No rule, or no FREQ we know: the series is its first day only.
  if freq is null then
    if dtstart between from_day and to_day then
      return next dtstart;
    end if;
    return;
  end if;
  -- A date has no hours: something every few hours or minutes is daily.
  if freq = 0 then
    freq := 1;
    ival := 1;
  end if;
  if wd_all is null then
    wd_any := null; wd_nth := null; wd_last := null;
  end if;
  -- The first instance stands even when UNTIL is before it.
  if dtstart_is_instance and until_d < dtstart then
    until_d := dtstart;
  end if;

  dt_wd := ((dtstart - date '2001-01-01') % 7 + 7) % 7;  -- 2001-01-01 was a Monday
  dt_ws := dtstart - (dt_wd - wkst + 7) % 7;
  last_d := least(to_day, until_d);
  -- COUNT numbers occurrences from dtstart, so count from there. Work through
  -- the days in chunks and stop at the COUNTth occurrence or at to_day.
  c0 := case when cnt is null then greatest(from_day, dtstart) else dtstart end;
  while c0 <= last_d loop
    c1 := case when last_d - c0 > 999 then c0 + 999 else last_d end;
    for hit in
      select x.d
      from generate_series(0, c1 - c0) i
      cross join lateral (select c0 + i as d) x
      cross join lateral (
        select ((x.d - date '2001-01-01') % 7 + 7) % 7 as wd,
               extract(day from x.d)::int as dom,
               extract(month from x.d)::int as mon,
               extract(year from x.d)::int as yr
      ) p
      cross join lateral (
        select make_date(p.yr + p.mon / 12, p.mon % 12 + 1, 1) - make_date(p.yr, p.mon, 1) as dim
      ) q
      where (dtstart_is_instance and x.d = dtstart)
         or (-- INTERVAL, in this rule's own periods counted from dtstart's
             case freq
               when 1 then (x.d - dtstart) % ival = 0
               when 2 then ((x.d - (p.wd - wkst + 7) % 7 - dt_ws) / 7) % ival = 0
               when 3 then (p.yr * 12 + p.mon - dt_yr * 12 - dt_mon) % ival = 0
               else (p.yr - dt_yr) % ival = 0
             end
             -- BYMONTH limits any frequency; YEARLY stays in dtstart's month without it
             and case when months is not null then p.mon = any (months)
                      when freq = 4 then p.mon = dt_mon
                      else true end
             and (mdays is null or p.dom = any (mdays) or p.dom - q.dim - 1 = any (mdays))
             and case freq
                   when 1 then wd_all is null or p.wd = any (wd_all)
                   when 2 then p.wd = any (coalesce(wd_all, array[dt_wd]))
                   -- MONTHLY and YEARLY: with neither BYDAY nor BYMONTHDAY,
                   -- dtstart's day of the month (months without it skipped)
                   else case when wd_all is null then mdays is not null or p.dom = dt_dom
                             else p.wd = any (wd_any)
                                  or p.wd * 100 + (p.dom + 6) / 7 = any (wd_nth)
                                  or p.wd * 100 + (q.dim - p.dom + 7) / 7 = any (wd_last) end
                 end)
      order by x.d
    loop
      seen := seen + 1;
      if seen > cnt then
        return;
      end if;
      if hit >= from_day then
        return next hit;
      end if;
    end loop;
    c0 := c1 + 1;
  end loop;
end $$;

-- Is `day` an occurrence of the series anchored at the local date `dtstart`?
create function public.rrule_occurs_on(rule text, dtstart date, day date,
                                       dtstart_is_instance boolean default true)
returns boolean
language sql immutable set search_path = public as $$
  select exists (select 1 from public.rrule_days(rule, dtstart, day, day, dtstart_is_instance))
$$;

-- ───────────────────────────── Calendar ─────────────────────────────

-- One row per event occurrence that overlaps [range_start, range_end).
-- `id` is the stored event (what edits and deletes name); `starts_at` and
-- `ends_at` are this occurrence, `series_*` the stored row. A repeat keeps
-- the series' local start time and local length in the family's time zone,
-- so a 4:30pm practice stays at 4:30pm across a DST change.
create function public.event_occurrences(fid uuid, range_start timestamptz, range_end timestamptz)
returns table (id uuid, family_id uuid, title text, description text, location text,
               starts_at timestamptz, ends_at timestamptz, all_day boolean, rrule text, color text,
               created_by uuid, series_starts_at timestamptz, series_ends_at timestamptz,
               member_ids uuid[])
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
  ),
  occ as (
    select ev.id as event_id, ev.starts_at as o_start, ev.ends_at as o_end
    from ev
    where nullif(btrim(ev.rrule), '') is null
    union all
    -- Repeats: start early enough to catch a long one already under way.
    select ev.id, s.o_start, greatest(s.o_start, s.o_end)
    from ev
    cross join lateral public.rrule_days(
      ev.rrule, ev.local_start::date,
      (range_start at time zone tz)::date - (ev.local_end::date - ev.local_start::date) - 1,
      (range_end at time zone tz)::date, true) as d(day)
    cross join lateral (
      select case when d.day = ev.local_start::date then ev.starts_at
                  else (d.day + ev.local_start::time) at time zone tz end as o_start,
             case when d.day = ev.local_start::date then ev.ends_at
                  else (d.day + ev.local_start::time + (ev.local_end - ev.local_start)) at time zone tz end as o_end
    ) s
    where nullif(btrim(ev.rrule), '') is not null
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
         coalesce(who.ids, '{}'::uuid[])
  from occ o
  join ev on ev.id = o.event_id
  left join who on who.event_id = o.event_id
  where o.o_start < range_end and (o.o_end > range_start or o.o_start >= range_start)
  order by o.o_start, ev.all_day desc, ev.id;
end $$;

-- ───────────────────────────── Chores ─────────────────────────────

-- The family's chores for `day`. A repeating chore follows its rule from
-- its due date, or the local day it was created. A one-time chore is up
-- from its due date (or right away) until someone finishes it: it still
-- shows on the day it was done, then it's gone. A rejected try doesn't
-- count as finished.
create function public.chores_due(fid uuid, day date)
returns setof public.tasks
language plpgsql stable security invoker set search_path = public as $$
declare
  tz text;
begin
  if day is null then
    raise exception 'day is required';
  end if;

  select f.timezone into tz from public.families f where f.id = fid;
  begin
    perform now() at time zone tz;
  exception when invalid_parameter_value then
    tz := null;
  end;
  tz := coalesce(nullif(tz, ''), 'UTC');

  return query
  select t.*
  from public.tasks t
  where t.family_id = fid
    and not t.archived
    and case when nullif(btrim(t.rrule), '') is null then
               (t.due_date is null or t.due_date <= day)
               and not exists (select 1 from public.task_completions c
                               where c.task_id = t.id and c.for_date < day and c.status <> 'rejected')
             else public.rrule_occurs_on(t.rrule, coalesce(t.due_date, (t.created_at at time zone tz)::date),
                                         day, false)
        end
  order by t.created_at, t.id;
end $$;

-- ───────────────────────── Privileges ─────────────────────────

revoke execute on function
  public.rrule_days(text, date, date, date, boolean),
  public.rrule_occurs_on(text, date, date, boolean),
  public.event_occurrences(uuid, timestamptz, timestamptz),
  public.chores_due(uuid, date)
from public, anon;

grant execute on function
  public.rrule_days(text, date, date, date, boolean),
  public.rrule_occurs_on(text, date, date, boolean),
  public.event_occurrences(uuid, timestamptz, timestamptz),
  public.chores_due(uuid, date)
to authenticated;
