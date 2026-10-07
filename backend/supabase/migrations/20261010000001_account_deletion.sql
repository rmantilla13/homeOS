-- Deleting your own account from the iOS app (App Store guideline 5.1.1(v)).
-- See docs/PLATFORM.md → "Deleting your account" and PLATFORM_SPEC.md §1.11.
--
-- delete_my_account() removes the caller's data in one transaction:
--   * A family where the caller is the only person with an account goes with
--     everything in it, its paired displays included.
--   * In any other family the caller's member row stays, unlinked, with its
--     points and history, as when they leave. A parent can remove it.
--   * The account itself, which takes the profile, assistant chats and invite
--     redemptions with it (on delete cascade). Rows they created for the
--     family (events, chores, photos, memory) stay with the family.
-- The last parent with an account in a family that has other accounts is
-- refused, like leave_family: someone has to be left to run it.
--
-- SQL can't remove Storage or Blob files, and Supabase may not let SQL delete
-- from auth.users. The delete-account edge function finishes both from what
-- this returns. Safe to run again.

create or replace function public.delete_my_account()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  m public.members;
  gone uuid[] := '{}';
  device_users uuid[] := '{}';
  removed boolean := false;
begin
  if me is null then
    raise exception 'not signed in';
  end if;
  if exists (select 1 from public.devices d where d.user_id = me) then
    raise exception 'a display can''t delete its account; unpair it instead';
  end if;
  if exists (select 1 from public.platform_admins a where a.user_id = me) then
    raise exception 'platform admins can''t delete their account here; ask another admin to remove your admin access first';
  end if;

  for m in select x.* from public.members x where x.user_id = me order by x.family_id for update of x loop
    -- Lock the family, so a parent leaving or demoted at the same moment waits.
    perform 1 from public.families f where f.id = m.family_id for update;
    if not exists (select 1 from public.members o
                   where o.family_id = m.family_id and o.user_id is not null and o.id <> m.id) then
      gone := gone || m.family_id;
    elsif m.role = 'parent' and public.other_linked_parents(m.family_id, m.id) = 0 then
      raise exception 'you''re the only parent with a login in %. Make someone else there a parent first',
        (select f.name from public.families f where f.id = m.family_id);
    end if;
  end loop;

  if cardinality(gone) > 0 then
    select coalesce(array_agg(d.user_id), '{}') into device_users from public.devices d where d.family_id = any(gone);
    delete from public.families f where f.id = any(gone);
  end if;
  update public.members x set user_id = null where x.user_id = me;

  -- No email or name: the person asked for those to go.
  perform public.log_admin_action('delete_own_account', 'user', me::text,
    jsonb_build_object('families_deleted', cardinality(gone), 'device_accounts', cardinality(device_users)));

  begin
    delete from auth.users u where u.id = me or u.id = any(device_users);
    removed := true;
  exception when insufficient_privilege then
    removed := false;  -- the edge function deletes them through Auth
  end;

  return jsonb_build_object(
    'families_deleted', to_jsonb(gone),
    'device_users', to_jsonb(device_users),
    'auth_user_removed', removed);
end $$;

revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
