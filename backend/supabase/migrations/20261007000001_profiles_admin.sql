-- Accounts layer: a profile per person, platform admins and settings, and
-- family suspension. See docs/PLATFORM_SPEC.md §1.1–1.3.

-- ───────────────────────────── Profiles ─────────────────────────────

-- One row per person. Device accounts (the wall displays) don't get one.
create table public.profiles (
  id            uuid primary key references auth.users on delete cascade,
  display_name  text not null default '',
  avatar_path   text,                 -- object path in bucket `avatars`, e.g. '<user_id>/avatar.jpg'
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

create function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.raw_app_meta_data->>'kind' = 'device' then
    return new;
  end if;
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(nullif(btrim(new.raw_user_meta_data->>'display_name'), ''),
                           split_part(new.email, '@', 1), ''))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- People who signed up before this migration.
insert into public.profiles (id, display_name)
select u.id, coalesce(nullif(btrim(u.raw_user_meta_data->>'display_name'), ''), split_part(u.email, '@', 1), '')
from auth.users u
where coalesce(u.raw_app_meta_data->>'kind', '') <> 'device'
on conflict (id) do nothing;

-- ───────────────────── Platform admins and settings ─────────────────────

create table public.platform_admins (
  user_id     uuid primary key references auth.users on delete cascade,
  created_at  timestamptz default now(),
  created_by  uuid
);

-- Exactly one row (id is always true).
create table public.platform_settings (
  id                     boolean primary key default true check (id),
  invite_only            boolean not null default true,
  assistant_enabled      boolean not null default true,
  assistant_daily_limit  int not null default 200 check (assistant_daily_limit >= 0),  -- per family per day
  updated_at             timestamptz not null default now(),
  updated_by             uuid
);
insert into public.platform_settings default values;

-- The service role key counts as an admin too, so server-side code (edge
-- functions, jobs) can call the admin RPCs.
create function public.is_service_role()
returns boolean
language sql stable set search_path = public as $$
  select coalesce(coalesce(nullif(current_setting('request.jwt.claim.role', true), ''),
                           nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'role') = 'service_role',
                  false)
$$;

create function public.is_platform_admin()
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.is_service_role(), false)
      or exists (select 1 from public.platform_admins where user_id = auth.uid())
$$;

alter table public.platform_admins   enable row level security;
alter table public.platform_settings enable row level security;

-- Read-only to admins; writes go through the admin_* RPCs.
create policy platform_admins_read   on public.platform_admins   for select using (public.is_platform_admin());
create policy platform_settings_read on public.platform_settings for select using (public.is_platform_admin());

-- ───────────────────────── Family suspension ─────────────────────────

alter table public.families
  add column status                text not null default 'active' check (status in ('active', 'suspended')),
  add column suspended_at          timestamptz,
  add column suspended_reason      text,
  add column assistant_daily_limit int check (assistant_daily_limit >= 0);  -- null: platform default

-- A suspended family drops out of every RLS check, so its members and
-- devices see none of its data. Admin functions query tables directly.
create or replace function public.my_family_ids()
returns setof uuid
language sql stable security definer set search_path = public
as $$
  select m.family_id from public.members m join public.families f on f.id = m.family_id
  where m.user_id = auth.uid() and f.status = 'active'
  union
  select d.family_id from public.devices d join public.families f on f.id = d.family_id
  where d.user_id = auth.uid() and f.status = 'active'
$$;

-- Parents of a suspended family lose their write rights too.
create or replace function public.is_family_parent(fid uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from public.members m join public.families f on f.id = m.family_id
    where m.family_id = fid and m.user_id = auth.uid() and m.role = 'parent' and f.status = 'active'
  )
$$;

-- Parents may rename their family, but status and limits belong to admins.
create function public.families_guard()
returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is null or current_user not in ('authenticated', 'anon') or public.is_platform_admin() then
    return new;
  end if;
  if (new.status, new.suspended_at, new.suspended_reason, new.assistant_daily_limit)
     is distinct from (old.status, old.suspended_at, old.suspended_reason, old.assistant_daily_limit) then
    raise exception 'only a platform admin can change that';
  end if;
  return new;
end $$;

create trigger families_guard before update on public.families
  for each row execute function public.families_guard();

-- ─────────────────────── Profile visibility ───────────────────────

-- True when the caller and `other` are both linked members of an active family.
create function public.shares_family_with(other uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from public.members me
    join public.members them on them.family_id = me.family_id
    join public.families f on f.id = me.family_id
    where me.user_id = auth.uid() and them.user_id = other and f.status = 'active'
  )
$$;

-- Storage check for the `avatars` bucket (policies in 20261007000005):
-- objects live at '<user_id>/<file>'.
create function public.can_read_avatar(object_name text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  folder text := split_part(object_name, '/', 1);
begin
  if auth.uid() is null or folder !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  return folder::uuid = auth.uid() or public.shares_family_with(folder::uuid);
end $$;

alter table public.profiles enable row level security;

create policy profiles_read on public.profiles for select
  using (id = auth.uid() or public.shares_family_with(id));
create policy profiles_update on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

-- Trigger functions aren't API.
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.families_guard() from public, anon, authenticated;
