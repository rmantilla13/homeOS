-- homeOS core schema: families, members, devices, calendar, tasks, rewards,
-- points ledger, lists, meal plans and media metadata.
-- Every row is scoped to a family and protected by row-level security.

-- ───────────────────────────── Types ─────────────────────────────

create type public.member_role as enum ('parent', 'child', 'other');
create type public.completion_status as enum ('pending', 'approved', 'rejected');
create type public.redemption_status as enum ('requested', 'fulfilled', 'cancelled');
create type public.media_kind as enum ('photo', 'video');
create type public.meal_slot as enum ('breakfast', 'lunch', 'dinner', 'snack');

-- ───────────────────────────── Tables ─────────────────────────────

create table public.families (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  timezone    text not null default 'UTC',
  created_at  timestamptz not null default now()
);

-- Everyone who appears on the screen. Kids usually have no login (user_id null).
create table public.members (
  id            uuid primary key default gen_random_uuid(),
  family_id     uuid not null references public.families on delete cascade,
  user_id       uuid references auth.users on delete set null,
  display_name  text not null,
  role          public.member_role not null default 'child',
  color         text not null default '#4F8EF7',
  avatar_url    text,
  birthday      date,
  sort_order    int not null default 0,
  created_at    timestamptz not null default now(),
  unique (family_id, user_id)
);
create index on public.members (user_id);

-- Paired wall screens. Each device signs in as its own auth user.
create table public.devices (
  id            uuid primary key default gen_random_uuid(),
  family_id     uuid not null references public.families on delete cascade,
  user_id       uuid not null unique references auth.users on delete cascade,
  name          text not null default 'Wall display',
  last_seen_at  timestamptz,
  created_at    timestamptz not null default now()
);

-- Short-lived codes shown on an unpaired display. Only the pair-device edge
-- function (service role) touches this table: RLS on, no policies.
create table public.pairing_codes (
  code          text primary key,
  secret_hash   text not null,
  family_id     uuid references public.families on delete cascade,
  device_id     uuid references public.devices on delete cascade,
  claimed_by    uuid references auth.users on delete set null,
  expires_at    timestamptz not null default now() + interval '10 minutes',
  created_at    timestamptz not null default now()
);

create table public.events (
  id              uuid primary key default gen_random_uuid(),
  family_id       uuid not null references public.families on delete cascade,
  title           text not null,
  description     text,
  location        text,
  starts_at       timestamptz not null,
  ends_at         timestamptz not null,
  all_day         boolean not null default false,
  rrule           text,                       -- RFC 5545 recurrence rule
  color           text,                       -- overrides member color
  external_source text,                       -- 'google' | 'icloud' | null
  external_id     text,
  created_by      uuid references public.members on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (ends_at >= starts_at),
  unique (family_id, external_source, external_id)
);
create index on public.events (family_id, starts_at);

create table public.event_members (
  event_id   uuid not null references public.events on delete cascade,
  member_id  uuid not null references public.members on delete cascade,
  primary key (event_id, member_id)
);

create table public.tasks (
  id                 uuid primary key default gen_random_uuid(),
  family_id          uuid not null references public.families on delete cascade,
  title              text not null,
  notes              text,
  icon               text,
  assignee_id        uuid references public.members on delete set null,
  points             int not null default 0 check (points >= 0),
  due_date           date,
  rrule              text,                    -- recurring chores
  requires_approval  boolean not null default true,
  archived           boolean not null default false,
  created_by         uuid references public.members on delete set null,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index on public.tasks (family_id, archived);

create table public.task_completions (
  id            uuid primary key default gen_random_uuid(),
  task_id       uuid not null references public.tasks on delete cascade,
  family_id     uuid not null references public.families on delete cascade,
  member_id     uuid not null references public.members on delete cascade,
  for_date      date not null default current_date,
  status        public.completion_status not null default 'pending',
  completed_at  timestamptz not null default now(),
  reviewed_by   uuid references public.members on delete set null,
  reviewed_at   timestamptz,
  unique (task_id, member_id, for_date)
);
create index on public.task_completions (family_id, status);

create table public.rewards (
  id           uuid primary key default gen_random_uuid(),
  family_id    uuid not null references public.families on delete cascade,
  title        text not null,
  description  text,
  icon         text,
  cost         int not null check (cost > 0),
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

create table public.reward_redemptions (
  id            uuid primary key default gen_random_uuid(),
  family_id     uuid not null references public.families on delete cascade,
  reward_id     uuid not null references public.rewards on delete restrict,
  member_id     uuid not null references public.members on delete cascade,
  cost          int not null,
  status        public.redemption_status not null default 'requested',
  created_at    timestamptz not null default now(),
  resolved_at   timestamptz
);

-- Append-only. Written only by the security-definer functions below.
create table public.points_ledger (
  id             bigint generated always as identity primary key,
  family_id      uuid not null references public.families on delete cascade,
  member_id      uuid not null references public.members on delete cascade,
  delta          int not null check (delta <> 0),
  reason         text not null,
  completion_id  uuid references public.task_completions on delete set null,
  redemption_id  uuid references public.reward_redemptions on delete set null,
  created_by     uuid references auth.users on delete set null default auth.uid(),
  created_at     timestamptz not null default now()
);
create index on public.points_ledger (member_id);

create table public.lists (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families on delete cascade,
  name        text not null,
  kind        text not null default 'shopping',
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);

create table public.list_items (
  id          uuid primary key default gen_random_uuid(),
  list_id     uuid not null references public.lists on delete cascade,
  text        text not null,
  quantity    text,
  done        boolean not null default false,
  added_by    uuid references public.members on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index on public.list_items (list_id);

create table public.meal_plans (
  id         uuid primary key default gen_random_uuid(),
  family_id  uuid not null references public.families on delete cascade,
  date       date not null,
  meal       public.meal_slot not null,
  title      text not null,
  notes      text,
  unique (family_id, date, meal)
);

-- Metadata for files in the `family-media` storage bucket.
create table public.media_items (
  id                uuid primary key default gen_random_uuid(),
  family_id         uuid not null references public.families on delete cascade,
  storage_path      text not null unique,     -- '<family_id>/<id>.<ext>'
  kind              public.media_kind not null,
  width             int,
  height            int,
  duration_seconds  numeric,
  taken_at          timestamptz,
  caption           text,
  show_on_frame     boolean not null default true,
  uploaded_by       uuid references public.members on delete set null,
  created_at        timestamptz not null default now()
);
create index on public.media_items (family_id, taken_at desc);

-- ───────────────────────────── Views ─────────────────────────────

create view public.member_points with (security_invoker = true) as
  select m.id as member_id,
         m.family_id,
         coalesce(sum(l.delta), 0)::int as balance
  from public.members m
  left join public.points_ledger l on l.member_id = m.id
  group by m.id, m.family_id;

-- ──────────────────────── Access helpers ────────────────────────

create function public.my_family_ids()
returns setof uuid
language sql stable security definer set search_path = public
as $$
  select family_id from public.members where user_id = auth.uid()
  union
  select family_id from public.devices where user_id = auth.uid()
$$;

create function public.is_family_member(fid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select fid in (select public.my_family_ids())
$$;

create function public.is_family_parent(fid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.members
    where family_id = fid and user_id = auth.uid() and role = 'parent'
  )
$$;

-- The member row of the signed-in person in a family (null for devices).
create function public.my_member_id(fid uuid)
returns uuid
language sql stable security definer set search_path = public
as $$
  select id from public.members where family_id = fid and user_id = auth.uid()
$$;

-- ───────────────────────── Triggers ─────────────────────────

create function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger events_touch     before update on public.events     for each row execute function public.touch_updated_at();
create trigger tasks_touch      before update on public.tasks      for each row execute function public.touch_updated_at();
create trigger list_items_touch before update on public.list_items for each row execute function public.touch_updated_at();

-- New completions: take family from the task, and auto-approve when the task
-- does not need a parent. Clients cannot self-approve.
create function public.prepare_completion()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t public.tasks;
begin
  select * into t from public.tasks where id = new.task_id;
  if not found then
    raise exception 'task % not found', new.task_id;
  end if;
  if not exists (select 1 from public.members where id = new.member_id and family_id = t.family_id) then
    raise exception 'member does not belong to the task''s family';
  end if;
  new.family_id   := t.family_id;
  new.status      := case when t.requires_approval then 'pending' else 'approved' end;
  new.reviewed_by := null;
  new.reviewed_at := case when t.requires_approval then null else now() end;
  return new;
end $$;

create trigger task_completions_prepare
  before insert on public.task_completions
  for each row execute function public.prepare_completion();

-- Post points when a completion becomes approved, and reverse them if an
-- approved completion is later rejected or deleted.
create function public.completion_points()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  pts int;
  t_title text;
begin
  if tg_op = 'DELETE' then
    if old.status = 'approved' then
      select points, tasks.title into pts, t_title from public.tasks where id = old.task_id;
      if pts > 0 then
        insert into public.points_ledger (family_id, member_id, delta, reason)
        values (old.family_id, old.member_id, -pts, 'Chore removed: ' || t_title);
      end if;
    end if;
    return old;
  end if;

  select points, tasks.title into pts, t_title from public.tasks where id = new.task_id;
  if coalesce(pts, 0) = 0 then
    return new;
  end if;

  if new.status = 'approved' and (tg_op = 'INSERT' or old.status <> 'approved') then
    insert into public.points_ledger (family_id, member_id, delta, reason, completion_id)
    values (new.family_id, new.member_id, pts, 'Chore: ' || t_title, new.id);
  elsif tg_op = 'UPDATE' and old.status = 'approved' and new.status <> 'approved' then
    insert into public.points_ledger (family_id, member_id, delta, reason, completion_id)
    values (new.family_id, new.member_id, -pts, 'Chore un-approved: ' || t_title, new.id);
  end if;
  return new;
end $$;

create trigger task_completions_points
  after insert or update of status or delete on public.task_completions
  for each row execute function public.completion_points();

-- ───────────────────────── RPC functions ─────────────────────────

-- Create a family and make the caller its first parent.
create function public.create_family(family_name text, my_name text, tz text default 'UTC')
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  fid uuid;
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  insert into public.families (name, timezone) values (family_name, tz) returning id into fid;
  insert into public.members (family_id, user_id, display_name, role)
  values (fid, auth.uid(), my_name, 'parent');
  return fid;
end $$;

create function public.review_completion(completion uuid, approve boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  c public.task_completions;
begin
  select * into c from public.task_completions where id = completion for update;
  if not found or not public.is_family_parent(c.family_id) then
    raise exception 'not allowed';
  end if;
  update public.task_completions
     set status      = case when approve then 'approved' else 'rejected' end::public.completion_status,
         reviewed_by = public.my_member_id(c.family_id),
         reviewed_at = now()
   where id = completion;
end $$;

-- Spend points on a reward. Locks the member row so two taps at once can't
-- overspend.
create function public.redeem_reward(reward uuid, member uuid)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  r public.rewards;
  bal int;
  rid uuid;
begin
  select * into r from public.rewards where id = reward and active;
  if not found or not public.is_family_member(r.family_id) then
    raise exception 'reward not available';
  end if;
  perform 1 from public.members where id = member and family_id = r.family_id for update;
  if not found then
    raise exception 'member not in family';
  end if;

  select coalesce(sum(delta), 0) into bal from public.points_ledger where member_id = member;
  if bal < r.cost then
    raise exception 'not enough points (have %, need %)', bal, r.cost;
  end if;

  insert into public.reward_redemptions (family_id, reward_id, member_id, cost)
  values (r.family_id, r.id, member, r.cost) returning id into rid;
  insert into public.points_ledger (family_id, member_id, delta, reason, redemption_id)
  values (r.family_id, member, -r.cost, 'Reward: ' || r.title, rid);
  return rid;
end $$;

-- Parents mark a redemption fulfilled, or cancel it and refund the points.
create function public.resolve_redemption(redemption uuid, fulfilled boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  d public.reward_redemptions;
begin
  select * into d from public.reward_redemptions where id = redemption for update;
  if not found or not public.is_family_parent(d.family_id) then
    raise exception 'not allowed';
  end if;
  if d.status <> 'requested' then
    raise exception 'redemption already resolved';
  end if;
  update public.reward_redemptions
     set status = case when fulfilled then 'fulfilled' else 'cancelled' end::public.redemption_status,
         resolved_at = now()
   where id = redemption;
  if not fulfilled then
    insert into public.points_ledger (family_id, member_id, delta, reason, redemption_id)
    values (d.family_id, d.member_id, d.cost, 'Refund: reward cancelled', d.id);
  end if;
end $$;

create function public.adjust_points(member uuid, delta int, reason text)
returns void
language plpgsql security definer set search_path = public as $$
declare
  fid uuid;
begin
  select family_id into fid from public.members where id = member;
  if fid is null or not public.is_family_parent(fid) then
    raise exception 'not allowed';
  end if;
  insert into public.points_ledger (family_id, member_id, delta, reason)
  values (fid, member, delta, reason);
end $$;

-- ───────────────────────── Row-level security ─────────────────────────

alter table public.families           enable row level security;
alter table public.members            enable row level security;
alter table public.devices            enable row level security;
alter table public.pairing_codes      enable row level security;
alter table public.events             enable row level security;
alter table public.event_members      enable row level security;
alter table public.tasks              enable row level security;
alter table public.task_completions   enable row level security;
alter table public.rewards            enable row level security;
alter table public.reward_redemptions enable row level security;
alter table public.points_ledger      enable row level security;
alter table public.lists              enable row level security;
alter table public.list_items         enable row level security;
alter table public.meal_plans         enable row level security;
alter table public.media_items        enable row level security;

-- families: members read, parents edit. Created via create_family().
create policy families_read   on public.families for select using (public.is_family_member(id));
create policy families_update on public.families for update using (public.is_family_parent(id));

-- members & rewards: everyone in the family reads, parents manage.
create policy members_read  on public.members for select using (public.is_family_member(family_id));
create policy members_write on public.members for all
  using (public.is_family_parent(family_id)) with check (public.is_family_parent(family_id));

create policy rewards_read  on public.rewards for select using (public.is_family_member(family_id));
create policy rewards_write on public.rewards for all
  using (public.is_family_parent(family_id)) with check (public.is_family_parent(family_id));

-- devices: family reads (and a device can update its own last_seen_at), parents remove.
create policy devices_read   on public.devices for select using (public.is_family_member(family_id));
create policy devices_touch  on public.devices for update using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy devices_delete on public.devices for delete using (public.is_family_parent(family_id));

-- Shared family content: any member or paired device can read and write.
create policy events_all     on public.events     for all using (public.is_family_member(family_id)) with check (public.is_family_member(family_id));
create policy tasks_all      on public.tasks      for all using (public.is_family_member(family_id)) with check (public.is_family_member(family_id));
create policy lists_all      on public.lists      for all using (public.is_family_member(family_id)) with check (public.is_family_member(family_id));
create policy meal_plans_all on public.meal_plans for all using (public.is_family_member(family_id)) with check (public.is_family_member(family_id));
create policy media_all      on public.media_items for all using (public.is_family_member(family_id)) with check (public.is_family_member(family_id));

create policy event_members_all on public.event_members for all
  using (exists (select 1 from public.events e where e.id = event_id and public.is_family_member(e.family_id)))
  with check (exists (select 1 from public.events e where e.id = event_id and public.is_family_member(e.family_id)));

create policy list_items_all on public.list_items for all
  using (exists (select 1 from public.lists l where l.id = list_id and public.is_family_member(l.family_id)))
  with check (exists (select 1 from public.lists l where l.id = list_id and public.is_family_member(l.family_id)));

-- Completions: anyone in the family can mark done (the display, kids). Status
-- changes go through review_completion(); parents may delete.
create policy completions_read   on public.task_completions for select using (public.is_family_member(family_id));
create policy completions_insert on public.task_completions for insert
  with check (exists (select 1 from public.tasks t where t.id = task_id and public.is_family_member(t.family_id)));
create policy completions_delete on public.task_completions for delete using (public.is_family_parent(family_id));

-- Redemptions and ledger: read-only to clients; written by RPC functions.
create policy redemptions_read on public.reward_redemptions for select using (public.is_family_member(family_id));
create policy ledger_read      on public.points_ledger      for select using (public.is_family_member(family_id));
