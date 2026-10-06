-- Invite-only platform: platform invites (start a new family), family invites
-- (join an existing one), the invite-aware create_family, membership RPCs,
-- member guards and the optional Before User Created auth hook.
-- See docs/PLATFORM_SPEC.md §1.4 and docs/PLATFORM.md.

-- ───────────────────────────── Codes ─────────────────────────────

-- 'abcd-efgh ' → 'ABCDEFGH'. Comparison form; both invite tables store it.
create function public.normalize_invite_code(code text)
returns text
language sql immutable set search_path = public as $$
  select upper(regexp_replace(code, '[[:space:]-]+', '', 'g'))
$$;

-- 'ABCDEFGH' → 'ABCD-EFGH'. What people see and type.
create function public.format_invite_code(code text)
returns text
language sql immutable set search_path = public as $$
  select case when length(public.normalize_invite_code(code)) = 8
              then substr(public.normalize_invite_code(code), 1, 4) || '-' || substr(public.normalize_invite_code(code), 5, 4)
              else code end
$$;

-- A fresh 'XXXX-XXXX' code from an alphabet without look-alikes (no 0/O, 1/I).
-- 32 symbols, so one random byte mod 32 is uniform.
create function public.generate_invite_code()
returns text
language plpgsql volatile
set search_path = public, extensions  -- pgcrypto lives in `extensions` on Supabase
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  bytes bytea := gen_random_bytes(8);
  chars text := '';
begin
  for i in 0..7 loop
    chars := chars || substr(alphabet, get_byte(bytes, i) % 32 + 1, 1);
  end loop;
  return substr(chars, 1, 4) || '-' || substr(chars, 5, 4);
end $$;

-- A generated code (normalized) that neither invite table has used yet.
create function public.new_invite_code()
returns text
language plpgsql volatile security definer set search_path = public as $$
declare
  c text;
begin
  loop
    c := public.normalize_invite_code(public.generate_invite_code());
    exit when not exists (select 1 from public.platform_invites where code = c)
          and not exists (select 1 from public.family_invites where code = c);
  end loop;
  return c;
end $$;

-- ───────────────────────────── Tables ─────────────────────────────

-- Lets someone create a NEW family.
create table public.platform_invites (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{8}$'),
  email       text,                  -- if set, only this email may redeem (case-insensitive)
  note        text,
  max_uses    int not null default 1 check (max_uses > 0),
  use_count   int not null default 0,
  expires_at  timestamptz not null default now() + interval '30 days',
  created_by  uuid references auth.users on delete set null,
  created_at  timestamptz not null default now(),
  revoked_at  timestamptz
);
create index on public.platform_invites (created_at desc);

create table public.platform_invite_redemptions (
  invite_id    uuid references public.platform_invites on delete cascade,
  user_id      uuid references auth.users on delete cascade,
  family_id    uuid references public.families on delete set null,
  redeemed_at  timestamptz default now(),
  primary key (invite_id, user_id)
);

-- Lets someone JOIN an existing family.
create table public.family_invites (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references public.families on delete cascade,
  code        text not null unique check (code ~ '^[A-HJ-NP-Z2-9]{8}$'),
  role        public.member_role not null default 'parent',
  member_id   uuid references public.members on delete cascade,  -- claim an existing member row (e.g. a kid getting an account)
  email       text,
  invited_by  uuid references auth.users on delete set null default auth.uid(),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '14 days',
  accepted_by uuid references auth.users on delete set null,
  accepted_at timestamptz,
  revoked_at  timestamptz
);
create index on public.family_invites (family_id, created_at desc);

alter table public.platform_invites            enable row level security;
alter table public.platform_invite_redemptions enable row level security;
alter table public.family_invites              enable row level security;

-- Read-only to clients; every write goes through the RPCs below.
create policy platform_invites_read    on public.platform_invites            for select using (public.is_platform_admin());
create policy platform_redemptions_read on public.platform_invite_redemptions for select using (public.is_platform_admin());
create policy family_invites_read      on public.family_invites              for select using (public.is_family_parent(family_id));

-- ───────────────────────── Invite checks ─────────────────────────

-- Why a platform invite can't be used right now, or null when it can.
-- `who` is the would-be redeemer (null: anyone).
create function public.platform_invite_problem(inv public.platform_invites, who uuid)
returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if inv.id is null or inv.revoked_at is not null then
    return 'invite code not valid';
  elsif inv.expires_at <= now() then
    return 'invite code expired';
  elsif inv.use_count >= inv.max_uses
        or exists (select 1 from public.platform_invite_redemptions r where r.invite_id = inv.id and r.user_id = who) then
    return 'invite code already used';
  elsif who is not null and inv.email is not null
        and lower(btrim(inv.email)) is distinct from (select lower(btrim(u.email)) from auth.users u where u.id = who) then
    return 'invite is for a different email';
  end if;
  return null;
end $$;

create function public.family_invite_problem(inv public.family_invites, who uuid)
returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if inv.id is null or inv.revoked_at is not null
     or not exists (select 1 from public.families f where f.id = inv.family_id and f.status = 'active') then
    return 'invite code not valid';
  elsif inv.accepted_at is not null then
    return 'invite code already used';
  elsif inv.expires_at <= now() then
    return 'invite code expired';
  elsif who is not null and inv.email is not null
        and lower(btrim(inv.email)) is distinct from (select lower(btrim(u.email)) from auth.users u where u.id = who) then
    return 'invite is for a different email';
  end if;
  return null;
end $$;

-- ───────────────────────── create_family ─────────────────────────

drop function public.create_family(text, text, text);

-- Create a family and make the caller its first parent. While the platform
-- is invite-only, non-admins need an unused platform invite.
create function public.create_family(family_name text, my_name text, tz text default 'UTC', invite_code text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  norm text := public.normalize_invite_code(invite_code);
  inv public.platform_invites;
  problem text;
  name text;
  fid uuid;
begin
  if uid is null then
    raise exception 'not signed in';
  end if;
  if coalesce(btrim(family_name), '') = '' then
    raise exception 'family name required';
  end if;

  if coalesce((select s.invite_only from public.platform_settings s), true) and not public.is_platform_admin() then
    if coalesce(norm, '') = '' then
      raise exception 'invite code required';
    end if;
    -- Lock the invite so two sign-ups can't both take its last use.
    select * into inv from public.platform_invites pi where pi.code = norm for update;
    problem := public.platform_invite_problem(inv, uid);
    if problem is not null then
      raise exception '%', problem;
    end if;
  end if;

  name := coalesce(nullif(btrim(my_name), ''),
                   (select nullif(p.display_name, '') from public.profiles p where p.id = uid),
                   'Parent');
  insert into public.families (name, timezone) values (btrim(family_name), coalesce(nullif(tz, ''), 'UTC'))
  returning id into fid;
  insert into public.members (family_id, user_id, display_name, role)
  values (fid, uid, name, 'parent');

  if inv.id is not null then
    update public.platform_invites set use_count = use_count + 1 where id = inv.id;
    insert into public.platform_invite_redemptions (invite_id, user_id, family_id) values (inv.id, uid, fid);
  end if;

  update public.profiles set display_name = name where id = uid and display_name = '';
  return fid;
end $$;

-- ───────────────────────── preview_invite ─────────────────────────

-- What a code is for, without signing in. Bad codes reveal nothing but the
-- reason; good ones reveal only the family name, role and inviter's name.
create function public.preview_invite(code text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  norm text := public.normalize_invite_code(code);
  fi public.family_invites;
  pi public.platform_invites;
  problem text;
  result jsonb := jsonb_build_object('valid', false, 'kind', null, 'family_name', null,
                                     'role', null, 'invited_by', null, 'expires_at', null, 'reason', null);
begin
  if coalesce(norm, '') = '' then
    return result || jsonb_build_object('reason', 'invite code required');
  end if;
  if norm !~ '^[A-HJ-NP-Z2-9]{8}$' then
    return result || jsonb_build_object('reason', 'invite code not valid');
  end if;

  select * into fi from public.family_invites i where i.code = norm;
  if found then
    problem := public.family_invite_problem(fi, auth.uid());
    if problem is not null then
      return result || jsonb_build_object('reason', problem);
    end if;
    return result || jsonb_build_object(
      'valid', true,
      'kind', 'family',
      'family_name', (select f.name from public.families f where f.id = fi.family_id),
      'role', fi.role::text,
      'invited_by', (select coalesce(nullif(p.display_name, ''), m.display_name)
                     from (select fi.invited_by as uid) x
                     left join public.profiles p on p.id = x.uid
                     left join public.members m on m.user_id = x.uid and m.family_id = fi.family_id
                     where x.uid is not null),
      'expires_at', fi.expires_at);
  end if;

  select * into pi from public.platform_invites i where i.code = norm;
  problem := public.platform_invite_problem(pi, auth.uid());
  if problem is not null then
    return result || jsonb_build_object('reason', problem);
  end if;
  return result || jsonb_build_object('valid', true, 'kind', 'platform', 'expires_at', pi.expires_at);
end $$;

-- ─────────────────────── Family invites ───────────────────────

create function public.accept_family_invite(code text, display_name text default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  norm text := public.normalize_invite_code(code);
  inv public.family_invites;
  claimed public.members;
  problem text;
  name text;
begin
  if uid is null then
    raise exception 'not signed in';
  end if;
  if coalesce(norm, '') = '' then
    raise exception 'invite code required';
  end if;

  select * into inv from public.family_invites i where i.code = norm for update;
  problem := public.family_invite_problem(inv, uid);
  if problem is not null then
    raise exception '%', problem;
  end if;
  if exists (select 1 from public.members m where m.family_id = inv.family_id and m.user_id = uid) then
    raise exception 'already a member of this family';
  end if;

  name := coalesce(nullif(btrim(accept_family_invite.display_name), ''),
                   (select nullif(p.display_name, '') from public.profiles p where p.id = uid));

  if inv.member_id is not null then
    select * into claimed from public.members m where m.id = inv.member_id and m.family_id = inv.family_id for update;
    if not found then
      raise exception 'invite code not valid';
    elsif claimed.user_id is not null then
      raise exception 'that member already has an account';
    end if;
    update public.members set user_id = uid where id = claimed.id;
  else
    insert into public.members (family_id, user_id, display_name, role, color, sort_order)
    values (inv.family_id, uid, coalesce(name, 'New member'), inv.role, '#8E9CE6',
            (select coalesce(max(m.sort_order) + 1, 0) from public.members m where m.family_id = inv.family_id));
  end if;

  update public.family_invites set accepted_by = uid, accepted_at = now() where id = inv.id;
  if name is not null then
    update public.profiles p set display_name = name where p.id = uid and p.display_name = '';
  end if;
  return inv.family_id;
end $$;

-- Parents invite someone into their family. `member` hands an existing row
-- (usually a kid without a login) to whoever accepts; the invite then takes
-- that member's role.
create function public.create_family_invite(family uuid, role public.member_role default 'parent',
                                            member uuid default null, email text default null,
                                            expires_in_days int default 14)
returns table (id uuid, code text, expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  m public.members;
  invite_role public.member_role := create_family_invite.role;
  c text;
  new_id uuid;
  new_expiry timestamptz;
begin
  if family is null or not public.is_family_parent(family) then
    raise exception 'not allowed';
  end if;
  if expires_in_days is null or expires_in_days not between 1 and 60 then
    raise exception 'expires_in_days must be between 1 and 60';
  end if;
  if member is not null then
    select * into m from public.members x where x.id = member and x.family_id = family;
    if not found then
      raise exception 'member not found in this family';
    elsif m.user_id is not null then
      raise exception 'that member already has an account';
    end if;
    invite_role := m.role;
  end if;

  c := public.new_invite_code();
  insert into public.family_invites as fi (family_id, code, role, member_id, email, invited_by, expires_at)
  values (family, c, coalesce(invite_role, 'parent'), member,
          nullif(btrim(create_family_invite.email), ''), auth.uid(),
          now() + make_interval(days => expires_in_days))
  returning fi.id, fi.expires_at into new_id, new_expiry;

  id := new_id;
  code := public.format_invite_code(c);
  expires_at := new_expiry;
  return next;
end $$;

create function public.revoke_family_invite(invite uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  fid uuid;
begin
  select i.family_id into fid from public.family_invites i where i.id = invite;
  if fid is null or not public.is_family_parent(fid) then
    raise exception 'not allowed';
  end if;
  -- Accepted invites stay as a record of who joined.
  update public.family_invites set revoked_at = now()
  where id = invite and revoked_at is null and accepted_at is null;
end $$;

-- Linked parents of a family other than `except_member`. Locks the family
-- row so two parents can't leave or demote each other at the same time.
-- Callers only ever ask about their own family.
create function public.other_linked_parents(fid uuid, except_member uuid)
returns int
language plpgsql volatile security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_platform_admin()
     and not exists (select 1 from public.members where family_id = fid and user_id = auth.uid()) then
    raise exception 'not allowed';
  end if;
  perform 1 from public.families where id = fid for update;
  return (select count(*) from public.members
          where family_id = fid and role = 'parent' and user_id is not null and id <> except_member);
end $$;

-- Unlink the caller's member row. The row stays (points, history, the kid
-- still shows on the screen); only the login goes.
create function public.leave_family(family uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  me public.members;
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  select * into me from public.members m where m.family_id = family and m.user_id = auth.uid() for update;
  if not found then
    raise exception 'not a member of this family';
  end if;
  if me.role = 'parent' and public.other_linked_parents(family, me.id) = 0 then
    raise exception 'the last parent can''t leave';
  end if;
  update public.members set user_id = null where id = me.id;
end $$;

-- ───────────────────────── Member guards ─────────────────────────

-- Direct client writes to members (PostgREST as `authenticated`) are checked
-- here. Security definer RPCs (accept_family_invite, leave_family, admin_*)
-- run as the table owner and enforce their own rules, as do the service
-- role, migrations and platform admins.
create function public.members_guard()
returns trigger
language plpgsql set search_path = public as $$
declare
  parent boolean;
begin
  if auth.uid() is null or current_user not in ('authenticated', 'anon') or public.is_platform_admin() then
    return case when tg_op = 'DELETE' then old else new end;
  end if;

  -- Accounts join a family only by accepting an invite.
  if tg_op = 'INSERT' then
    if new.user_id is not null then
      raise exception 'accounts join a family through an invite';
    end if;
    return new;
  end if;

  parent := public.is_family_parent(old.family_id);

  if tg_op = 'UPDATE' then
    if not parent then
      if old.user_id is distinct from auth.uid() then
        raise exception 'not allowed';
      end if;
      if (new.id, new.family_id, new.user_id, new.role, new.birthday, new.sort_order, new.created_at)
         is distinct from (old.id, old.family_id, old.user_id, old.role, old.birthday, old.sort_order, old.created_at) then
        raise exception 'only a parent can change that';
      end if;
    elsif new.user_id is not null and new.user_id is distinct from old.user_id then
      raise exception 'accounts join a family through an invite';
    elsif old.user_id is not null and new.family_id <> old.family_id then
      -- A parent of two families can't carry someone's account into the other one.
      raise exception 'accounts join a family through an invite';
    end if;
  end if;

  -- Deleting, demoting, unlinking or moving the last linked parent.
  if old.role = 'parent' and old.user_id is not null
     and (tg_op = 'DELETE' or new.role <> 'parent' or new.user_id is null or new.family_id <> old.family_id)
     and public.other_linked_parents(old.family_id, old.id) = 0 then
    raise exception 'a family needs at least one parent with an account';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;

create trigger members_guard before insert or update or delete on public.members
  for each row execute function public.members_guard();

-- Everyone can edit their own row (name, color, avatar); the guard limits
-- non-parents to those columns.
create policy members_update_self on public.members for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ───────────────────────── Auth hook ─────────────────────────

-- Optional Before User Created hook (Dashboard → Authentication → Hooks).
-- Rejects sign-ups without an open invite while the platform is
-- invite-only. The RPCs above remain the real enforcement.
create function public.hook_before_user_created(event jsonb)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  u jsonb := event->'user';
  norm text := public.normalize_invite_code(u->'user_metadata'->>'invite_code');
  mail text := lower(btrim(u->>'email'));
begin
  if not coalesce((select s.invite_only from public.platform_settings s), true) then
    return '{}'::jsonb;
  end if;
  if u->'app_metadata'->>'kind' = 'device' then
    return '{}'::jsonb;  -- a display's own account, created by pair-device
  end if;

  if coalesce(norm, '') <> '' and (
       exists (select 1 from public.platform_invites i
               where i.code = norm and i.revoked_at is null and i.expires_at > now() and i.use_count < i.max_uses
                 and (i.email is null or lower(btrim(i.email)) = mail))
    or exists (select 1 from public.family_invites i join public.families f on f.id = i.family_id
               where i.code = norm and i.revoked_at is null and i.accepted_at is null and i.expires_at > now()
                 and f.status = 'active' and (i.email is null or lower(btrim(i.email)) = mail))) then
    return '{}'::jsonb;
  end if;

  if coalesce(mail, '') <> '' and (
       exists (select 1 from public.platform_invites i
               where lower(btrim(i.email)) = mail and i.revoked_at is null and i.expires_at > now() and i.use_count < i.max_uses)
    or exists (select 1 from public.family_invites i join public.families f on f.id = i.family_id
               where lower(btrim(i.email)) = mail and i.revoked_at is null and i.accepted_at is null
                 and i.expires_at > now() and f.status = 'active')) then
    return '{}'::jsonb;
  end if;

  return jsonb_build_object('error', jsonb_build_object(
    'http_code', 403,
    'message', 'homeOS is invite-only. Ask your family for an invite code.'));
end $$;

-- ───────────────────────── Privileges ─────────────────────────

-- Internal helpers and the hook aren't client API. members_guard is a
-- trigger (no EXECUTE check when it fires); other_linked_parents stays
-- callable because the guard runs as the client role.
revoke execute on function public.new_invite_code() from public, anon, authenticated;
revoke execute on function public.generate_invite_code() from public, anon, authenticated;
revoke execute on function public.platform_invite_problem(public.platform_invites, uuid) from public, anon, authenticated;
revoke execute on function public.family_invite_problem(public.family_invites, uuid) from public, anon, authenticated;
revoke execute on function public.members_guard() from public, anon, authenticated;
revoke execute on function public.hook_before_user_created(jsonb) from public, anon, authenticated;
revoke execute on function public.other_linked_parents(uuid, uuid) from public, anon;
grant execute on function public.other_linked_parents(uuid, uuid) to authenticated;

revoke execute on function public.create_family(text, text, text, text) from public, anon;
revoke execute on function public.accept_family_invite(text, text) from public, anon;
revoke execute on function public.create_family_invite(uuid, public.member_role, uuid, text, int) from public, anon;
revoke execute on function public.revoke_family_invite(uuid) from public, anon;
revoke execute on function public.leave_family(uuid) from public, anon;
grant execute on function public.create_family(text, text, text, text) to authenticated;
grant execute on function public.accept_family_invite(text, text) to authenticated;
grant execute on function public.create_family_invite(uuid, public.member_role, uuid, text, int) to authenticated;
grant execute on function public.revoke_family_invite(uuid) to authenticated;
grant execute on function public.leave_family(uuid) to authenticated;
grant execute on function public.preview_invite(text) to anon, authenticated;

-- Supabase's auth server runs the hook as supabase_auth_admin.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'supabase_auth_admin') then
    grant usage on schema public to supabase_auth_admin;
    grant execute on function public.hook_before_user_created(jsonb) to supabase_auth_admin;
  end if;
end $$;
