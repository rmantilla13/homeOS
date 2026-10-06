-- Direct-write guards on deployed tables (20261006000001). See
-- docs/PLATFORM_SPEC.md §1.8.
--
-- 1. tasks_all lets any family member, the kitchen display included, write
--    chores, and prepare_completion auto-approves a chore that doesn't need
--    approval. A child could add a 9999-point chore without approval, tick it
--    off and redeem rewards. Now only parents decide what a chore is worth
--    and whether it needs a parent's OK; everyone can still add chores that a
--    parent approves (the assistant's add_chore), reword and archive them.
-- 2. members.color and events.color took any text, and the admin console,
--    the display and the iOS app all render it. They're now '#RRGGBB', the
--    one form all three read the same way (Qt reads 8 digits as #AARRGGBB,
--    iOS ignores alpha).

-- ───────────────────────────── Chores ─────────────────────────────

create function public.tasks_guard()
returns trigger
language plpgsql set search_path = public as $$
begin
  -- Security definer code, the service role, migrations and platform admins
  -- enforce their own rules (same as members_guard).
  if auth.uid() is null or current_user not in ('authenticated', 'anon') or public.is_platform_admin() then
    return new;
  end if;
  if public.is_family_parent(new.family_id)
     and (tg_op = 'INSERT' or public.is_family_parent(old.family_id)) then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.points > 0 and not new.requires_approval then
      raise exception 'only a parent can add points that skip approval';
    end if;
  elsif (new.points, new.requires_approval, new.family_id)
        is distinct from (old.points, old.requires_approval, old.family_id) then
    raise exception 'only a parent can change a chore''s points or approval';
  end if;
  return new;
end $$;

create trigger tasks_guard before insert or update on public.tasks
  for each row execute function public.tasks_guard();

revoke execute on function public.tasks_guard() from public, anon, authenticated;

-- ───────────────────────────── Colors ─────────────────────────────

-- Rows written before the check get the defaults. Without a JWT the member
-- guard stays out of the way.
update public.members set color = '#4F8EF7' where color !~ '^#[0-9A-Fa-f]{6}$';
update public.events set color = null where color !~ '^#[0-9A-Fa-f]{6}$';

alter table public.members add constraint members_color_hex check (color ~ '^#[0-9A-Fa-f]{6}$');
alter table public.events add constraint events_color_hex check (color ~ '^#[0-9A-Fa-f]{6}$');
