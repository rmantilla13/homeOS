-- Photos for members without a login (usually kids), which parents set from
-- the iOS app's Profile → Manage family. See PLATFORM_SPEC.md §1.7.
--
-- members.avatar_url was never written by an app. It becomes avatar_path, an
-- object path in the `avatars` bucket like profiles.avatar_path. A member's
-- photo lives in their family's folder, '<family_id>/<file>': the family's
-- parents write it, and everyone in the family, displays included, reads it.
-- The Storage policies are in 20261011000002 (Supabase-only). A member with
-- a login shows their profile photo instead, when they have one.

alter table public.members rename column avatar_url to avatar_path;

-- Whatever was there isn't a path an app can show.
update public.members set avatar_path = null
 where avatar_path !~ ('^' || family_id::text || '/[^/]+$');

-- One level down in the member's own family folder, so emptying that folder
-- when the family is deleted takes every member photo with it. Checked when
-- the path is set or changed, not on every later edit, so moving an
-- account-less member (members_guard allows that) doesn't make them
-- uneditable.
create function public.members_avatar_guard()
returns trigger
language plpgsql set search_path = public as $$
declare
  check_path boolean := tg_op = 'INSERT';
begin
  if tg_op = 'UPDATE' then
    check_path := new.avatar_path is distinct from old.avatar_path;
  end if;
  if check_path and new.avatar_path is not null
     and new.avatar_path !~ ('^' || new.family_id::text || '/[^/]+$') then
    raise exception 'that photo isn''t in this family''s folder';
  end if;
  return new;
end $$;

create trigger members_avatar_guard before insert or update on public.members
  for each row execute function public.members_avatar_guard();

-- Storage read check for `avatars` (policy in 20261007000005): your own
-- folder, the folder of anyone who shares a family with you, and now the
-- folder of a family you're in (its member photos).
create or replace function public.can_read_avatar(object_name text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  folder text := split_part(object_name, '/', 1);
begin
  if auth.uid() is null or folder !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  return folder::uuid = auth.uid() or public.shares_family_with(folder::uuid) or public.is_family_member(folder::uuid);
end $$;

-- Storage write check for member photos: '<family_id>/<file>', by a parent
-- of that family. Profile photos keep their own policies (owner only).
create function public.can_write_member_photo(object_name text)
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  parts text[] := string_to_array(object_name, '/');
begin
  if auth.uid() is null or coalesce(cardinality(parts), 0) <> 2 or parts[2] = ''
     or parts[1] !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  return public.is_family_parent(parts[1]::uuid);
end $$;

-- A trigger, not API. can_write_member_photo stays callable: Storage policies
-- run it as the client role.
revoke execute on function public.members_avatar_guard() from public, anon, authenticated;
