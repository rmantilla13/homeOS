-- Platform administration: audit log and the admin_* RPCs behind the admin
-- console. Every function checks is_platform_admin() itself (it is also true
-- for the service role) and every mutation writes an audit row.
-- See docs/PLATFORM_SPEC.md §1.6.

create table public.admin_audit_log (
  id           bigint generated always as identity primary key,
  admin_id     uuid,
  action       text not null,
  target_type  text,
  target_id    text,
  details      jsonb default '{}',
  created_at   timestamptz default now()
);
create index on public.admin_audit_log (created_at desc);

alter table public.admin_audit_log enable row level security;
create policy audit_read on public.admin_audit_log for select using (public.is_platform_admin());

-- The acting admin is auth.uid(); rows written under the service role have
-- no admin_id.
create function public.log_admin_action(action text, target_type text, target_id text, details jsonb default '{}')
returns void
language sql security definer set search_path = public as $$
  insert into public.admin_audit_log (admin_id, action, target_type, target_id, details)
  values (auth.uid(), action, target_type, target_id, coalesce(details, '{}'))
$$;

-- Latest sign of life in a family: devices checking in, edits to shared
-- content, chores, photos, assistant use. Admin-only (called by admin_*).
create function public.family_last_activity(fid uuid)
returns timestamptz
language sql stable security definer set search_path = public as $$
  select greatest(
    (select f.created_at from public.families f where f.id = fid),
    (select max(last_seen_at) from public.devices where family_id = fid),
    (select max(updated_at) from public.events where family_id = fid),
    (select max(updated_at) from public.tasks where family_id = fid),
    (select max(completed_at) from public.task_completions where family_id = fid),
    (select max(i.updated_at) from public.list_items i join public.lists l on l.id = i.list_id where l.family_id = fid),
    (select max(created_at) from public.media_items where family_id = fid),
    (select max(created_at) from public.points_ledger where family_id = fid),
    (select max(created_at) from public.family_memories where family_id = fid),
    (select max(created_at) from public.assistant_usage where family_id = fid))
$$;

-- Platform invite state for the console: revoked, used, expired or active.
create function public.platform_invite_status(inv public.platform_invites)
returns text
language sql stable set search_path = public as $$
  select case when inv.revoked_at is not null then 'revoked'
              when inv.use_count >= inv.max_uses then 'used'
              when inv.expires_at <= now() then 'expired'
              else 'active' end
$$;

-- ───────────────────────────── Reads ─────────────────────────────

create function public.admin_overview()
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
    'members',               (select count(*) from public.members),
    'open_platform_invites', (select count(*) from public.platform_invites i
                              where public.platform_invite_status(i) = 'active'),
    'assistant_requests_7d', (select count(*) from public.assistant_usage
                              where created_at >= now() - interval '7 days'),
    'assistant_tokens_7d',   (select coalesce(sum(input_tokens::bigint + output_tokens), 0) from public.assistant_usage
                              where created_at >= now() - interval '7 days'));
end $$;

create function public.admin_list_families(search text default null, lim int default 50, off int default 0)
returns table (id uuid, name text, status text, created_at timestamptz, member_count int, parent_count int,
               device_count int, assistant_requests_30d int, last_activity timestamptz)
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
           public.family_last_activity(f.id)
    from public.families f
    where q is null or strpos(lower(f.name), q) > 0 or f.id::text = q
    order by f.created_at desc, f.id
    limit greatest(least(coalesce(lim, 50), 500), 1) offset greatest(coalesce(off, 0), 0);
end $$;

create function public.admin_family_detail(family uuid)
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
       'last_activity', public.family_last_activity(f.id)),
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

create function public.admin_list_users(search text default null, lim int default 50, off int default 0)
returns table (id uuid, email text, display_name text, created_at timestamptz, last_sign_in_at timestamptz,
               banned boolean, is_admin boolean, is_device boolean, families jsonb)
language plpgsql stable security definer set search_path = public as $$
declare
  q text := lower(nullif(btrim(search), ''));
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  return query
    select u.id, u.email::text,
           coalesce(p.display_name, (select d.name from public.devices d where d.user_id = u.id)),
           u.created_at, u.last_sign_in_at,
           coalesce(u.banned_until > now(), false),
           exists (select 1 from public.platform_admins a where a.user_id = u.id),
           coalesce(u.raw_app_meta_data->>'kind', '') = 'device',
           coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'name', f.name, 'role', x.role) order by f.name)
                     from (select m.family_id, m.role::text as role from public.members m where m.user_id = u.id
                           union all
                           select d.family_id, 'device' from public.devices d where d.user_id = u.id) x
                     join public.families f on f.id = x.family_id), '[]'::jsonb)
    from auth.users u
    left join public.profiles p on p.id = u.id
    where q is null or strpos(lower(coalesce(u.email::text, '')), q) > 0
                    or strpos(lower(coalesce(p.display_name, '')), q) > 0
                    or u.id::text = q
    order by u.created_at desc, u.id
    limit greatest(least(coalesce(lim, 50), 500), 1) offset greatest(coalesce(off, 0), 0);
end $$;

create function public.admin_list_platform_invites(include_inactive boolean default false)
returns table (id uuid, code text, email text, note text, max_uses int, use_count int, expires_at timestamptz,
               created_at timestamptz, revoked_at timestamptz, created_by_email text, status text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  return query
    select i.id, public.format_invite_code(i.code), i.email, i.note, i.max_uses, i.use_count, i.expires_at,
           i.created_at, i.revoked_at, u.email::text, public.platform_invite_status(i)
    from public.platform_invites i
    left join auth.users u on u.id = i.created_by
    where coalesce(include_inactive, false) or public.platform_invite_status(i) = 'active'
    order by i.created_at desc, i.id;
end $$;

create function public.admin_get_settings()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  return (select to_jsonb(s) - 'id' from public.platform_settings s);
end $$;

create function public.admin_usage_by_day(days int default 30)
returns table (day date, requests int, input_tokens bigint, output_tokens bigint, families int)
language plpgsql stable security definer set search_path = public as $$
declare
  n int := greatest(least(coalesce(days, 30), 366), 1);
  today date := (now() at time zone 'UTC')::date;
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  return query
    select d.day::date,
           coalesce(x.requests, 0)::int,
           coalesce(x.input_tokens, 0)::bigint,
           coalesce(x.output_tokens, 0)::bigint,
           coalesce(x.families, 0)::int
    from generate_series((today - (n - 1))::timestamp, today::timestamp, interval '1 day') as d(day)
    left join (select (u.created_at at time zone 'UTC')::date as day, count(*) as requests,
                      sum(u.input_tokens) as input_tokens, sum(u.output_tokens) as output_tokens,
                      count(distinct u.family_id) as families
               from public.assistant_usage u
               where u.created_at >= (today - (n - 1))::timestamp at time zone 'UTC'
               group by 1) x on x.day = d.day::date
    order by 1;
end $$;

create function public.admin_list_audit(lim int default 100, off int default 0)
returns table (id bigint, created_at timestamptz, admin_email text, action text, target_type text,
               target_id text, details jsonb)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  return query
    select a.id, a.created_at, u.email::text, a.action, a.target_type, a.target_id, a.details
    from public.admin_audit_log a
    left join auth.users u on u.id = a.admin_id
    order by a.id desc
    limit greatest(least(coalesce(lim, 100), 500), 1) offset greatest(coalesce(off, 0), 0);
end $$;

-- ─────────────────────────── Mutations ───────────────────────────

create function public.admin_set_family_status(family uuid, status text, reason text default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  new_status text := admin_set_family_status.status;
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  if new_status is null or new_status not in ('active', 'suspended') then
    raise exception 'status must be active or suspended';
  end if;
  update public.families f
     set status           = new_status,
         suspended_at     = case when new_status = 'suspended' then coalesce(f.suspended_at, now()) end,
         suspended_reason = case when new_status = 'suspended' then nullif(btrim(reason), '') end
   where f.id = family;
  if not found then raise exception 'family not found'; end if;
  perform public.log_admin_action('set_family_status', 'family', family::text,
                                  jsonb_build_object('status', new_status, 'reason', nullif(btrim(reason), '')));
end $$;

-- Deletes the family and everything in it. Its displays' auth accounts go
-- too, when this database role is allowed to remove auth users.
create function public.admin_delete_family(family uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  f public.families;
  device_users uuid[];
  removed_devices int := 0;
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  select * into f from public.families x where x.id = family for update;
  if not found then raise exception 'family not found'; end if;

  select coalesce(array_agg(d.user_id), '{}') into device_users from public.devices d where d.family_id = family;
  delete from public.families x where x.id = family;
  begin
    delete from auth.users u where u.id = any(device_users);
    get diagnostics removed_devices = row_count;
  exception when insufficient_privilege then
    null;  -- left for the admin console's user list
  end;

  perform public.log_admin_action('delete_family', 'family', family::text,
                                  jsonb_build_object('name', f.name, 'device_accounts_removed', removed_devices));
end $$;

create function public.admin_create_platform_invite(email text default null, note text default null,
                                                    max_uses int default 1, expires_in_days int default 30)
returns table (id uuid, code text, expires_at timestamptz)
language plpgsql security definer set search_path = public as $$
#variable_conflict use_column
declare
  c text;
  new_id uuid;
  new_expiry timestamptz;
  invite_email text := nullif(btrim(admin_create_platform_invite.email), '');
  invite_note text := nullif(btrim(admin_create_platform_invite.note), '');
  uses int := admin_create_platform_invite.max_uses;
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  if uses is null or uses not between 1 and 10000 then
    raise exception 'max_uses must be between 1 and 10000';
  end if;
  if expires_in_days is null or expires_in_days not between 1 and 365 then
    raise exception 'expires_in_days must be between 1 and 365';
  end if;

  c := public.new_invite_code();
  insert into public.platform_invites as i (code, email, note, max_uses, expires_at, created_by)
  values (c, invite_email, invite_note, uses, now() + make_interval(days => expires_in_days), auth.uid())
  returning i.id, i.expires_at into new_id, new_expiry;

  perform public.log_admin_action('create_platform_invite', 'platform_invite', new_id::text,
                                  jsonb_build_object('code', public.format_invite_code(c), 'email', invite_email,
                                                     'note', invite_note, 'max_uses', uses, 'expires_at', new_expiry));
  id := new_id;
  code := public.format_invite_code(c);
  expires_at := new_expiry;
  return next;
end $$;

create function public.admin_revoke_platform_invite(invite uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  c text;
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  update public.platform_invites i set revoked_at = coalesce(i.revoked_at, now())
   where i.id = invite returning i.code into c;
  if not found then raise exception 'invite not found'; end if;
  perform public.log_admin_action('revoke_platform_invite', 'platform_invite', invite::text,
                                  jsonb_build_object('code', public.format_invite_code(c)));
end $$;

-- Null arguments leave that setting as it is.
create function public.admin_update_settings(invite_only boolean default null, assistant_enabled boolean default null,
                                             assistant_daily_limit int default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  changes jsonb := jsonb_strip_nulls(jsonb_build_object(
    'invite_only', admin_update_settings.invite_only,
    'assistant_enabled', admin_update_settings.assistant_enabled,
    'assistant_daily_limit', admin_update_settings.assistant_daily_limit));
  result jsonb;
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  if admin_update_settings.assistant_daily_limit < 0 then
    raise exception 'assistant_daily_limit must be 0 or more';
  end if;

  insert into public.platform_settings (id) values (true) on conflict (id) do nothing;
  update public.platform_settings s
     set invite_only           = coalesce(admin_update_settings.invite_only, s.invite_only),
         assistant_enabled     = coalesce(admin_update_settings.assistant_enabled, s.assistant_enabled),
         assistant_daily_limit = coalesce(admin_update_settings.assistant_daily_limit, s.assistant_daily_limit),
         updated_at            = now(),
         updated_by            = auth.uid()
   where s.id
  returning to_jsonb(s) - 'id' into result;

  perform public.log_admin_action('update_settings', 'settings', null, changes);
  return result;
end $$;

create function public.admin_set_admin(target uuid, make_admin boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare
  u auth.users;
begin
  if not public.is_platform_admin() then raise exception 'admin only'; end if;
  if make_admin is null then raise exception 'make_admin is required'; end if;
  select * into u from auth.users x where x.id = target;
  if not found then raise exception 'user not found'; end if;

  -- Serialize admin changes so two admins can't remove each other at once.
  lock table public.platform_admins in share row exclusive mode;
  if make_admin then
    if u.raw_app_meta_data->>'kind' = 'device' then
      raise exception 'a display account can''t be an admin';
    end if;
    insert into public.platform_admins (user_id, created_by) values (target, auth.uid())
    on conflict (user_id) do nothing;
  else
    if exists (select 1 from public.platform_admins a where a.user_id = target)
       and (select count(*) from public.platform_admins) = 1 then
      raise exception 'can''t remove the last admin';
    end if;
    delete from public.platform_admins a where a.user_id = target;
  end if;

  perform public.log_admin_action('set_admin', 'user', target::text,
                                  jsonb_build_object('make_admin', make_admin, 'email', u.email));
end $$;

-- ───────────────────────── Privileges ─────────────────────────

-- Internal helpers: only the security definer functions above call them.
revoke execute on function public.log_admin_action(text, text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.family_last_activity(uuid) from public, anon, authenticated;

-- Admin RPCs: signed-in callers only; the admin check happens inside.
revoke execute on function
  public.admin_overview(),
  public.admin_list_families(text, int, int),
  public.admin_family_detail(uuid),
  public.admin_list_users(text, int, int),
  public.admin_set_family_status(uuid, text, text),
  public.admin_delete_family(uuid),
  public.admin_create_platform_invite(text, text, int, int),
  public.admin_revoke_platform_invite(uuid),
  public.admin_list_platform_invites(boolean),
  public.admin_update_settings(boolean, boolean, int),
  public.admin_get_settings(),
  public.admin_set_admin(uuid, boolean),
  public.admin_usage_by_day(int),
  public.admin_list_audit(int, int)
from public, anon;

grant execute on function
  public.admin_overview(),
  public.admin_list_families(text, int, int),
  public.admin_family_detail(uuid),
  public.admin_list_users(text, int, int),
  public.admin_set_family_status(uuid, text, text),
  public.admin_delete_family(uuid),
  public.admin_create_platform_invite(text, text, int, int),
  public.admin_revoke_platform_invite(uuid),
  public.admin_list_platform_invites(boolean),
  public.admin_update_settings(boolean, boolean, int),
  public.admin_get_settings(),
  public.admin_set_admin(uuid, boolean),
  public.admin_usage_by_day(int),
  public.admin_list_audit(int, int)
to authenticated;
