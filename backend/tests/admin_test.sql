-- admin_* RPCs: refuse everyone but platform admins (and the service role),
-- work for admins, and leave an audit trail for every change.
\set ON_ERROR_STOP 1
\set fam    '00000000-0000-0000-0000-00000000f001'
\set m_mom  '00000000-0000-0000-0000-00000000a001'
\set mom      'a0000000-0000-0000-0000-000000000001'
\set device   'd0000000-0000-0000-0000-000000000001'
\set stranger 'e0000000-0000-0000-0000-000000000001'
\set admin    'ad000000-0000-0000-0000-000000000001'
\set admin2   'ad000000-0000-0000-0000-000000000002'

insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data, last_sign_in_at, banned_until) values
  (:'mom', 'mom@example.com', '{"display_name": "Mom"}', '{}', now(), null),
  (:'device', 'device-1@devices.homeos.invalid', '{}', '{"kind": "device"}', now(), null),
  (:'stranger', 'stranger@example.com', '{}', '{}', null, now() + interval '100 years'),
  (:'admin', 'admin@example.com', '{"display_name": "Ada"}', '{}', now(), null),
  (:'admin2', 'admin2@example.com', '{}', '{}', null, null);
update members set user_id = :'mom' where id = :'m_mom';
insert into devices (family_id, user_id, name, last_seen_at) values (:'fam', :'device', 'Kitchen', now());

-- Every admin function, called with valid arguments.
create table tests.admin_calls (sql text);
insert into tests.admin_calls values
  ('select admin_overview()'),
  ('select * from admin_list_families()'),
  (format('select admin_family_detail(%L)', :'fam')),
  ('select * from admin_list_users()'),
  (format('select admin_set_family_status(%L, ''suspended'')', :'fam')),
  (format('select admin_delete_family(%L)', :'fam')),
  ('select * from admin_create_platform_invite()'),
  ('select admin_revoke_platform_invite((select id from platform_invites limit 1))'),
  ('select * from admin_list_platform_invites(true)'),
  ('select admin_update_settings(invite_only => false)'),
  ('select admin_get_settings()'),
  (format('select admin_set_admin(%L, true)', :'stranger')),
  ('select * from admin_usage_by_day()'),
  ('select * from admin_list_audit()');
grant select on tests.admin_calls to anon, authenticated;

-- Before anyone is an admin.
select tests.ok(not has_function_privilege('anon', 'admin_overview()', 'execute'), 'anon cannot call admin RPCs');
select tests.ok(not has_function_privilege('anon', 'admin_set_admin(uuid, boolean)', 'execute'), 'anon cannot call admin_set_admin');
select tests.ok(has_function_privilege('authenticated', 'admin_overview()', 'execute'), 'authenticated may call (checked inside)');
select tests.ok(not has_function_privilege('authenticated', 'log_admin_action(text, text, text, jsonb)', 'execute'), 'audit writer is internal');
select tests.ok(not has_function_privilege('authenticated', 'family_last_activity(uuid)', 'execute'), 'activity helper is internal');

select tests.login(:'mom');
select tests.ok(not is_platform_admin(), 'mom is not an admin');
select tests.throws(sql, 'admin only', 'non-admin: ' || sql) from tests.admin_calls;
select tests.eq((select count(*)::int from platform_settings) + (select count(*)::int from platform_admins)
              + (select count(*)::int from admin_audit_log) + (select count(*)::int from platform_invites), 0, 'admin tables hidden');
select tests.throws($$insert into admin_audit_log (action) values ('forged')$$, '%row-level security%', 'no forged audit rows');
select tests.throws($$insert into platform_admins (user_id) values ('a0000000-0000-0000-0000-000000000001')$$, '%row-level security%', 'cannot make yourself admin');
select tests.eq(tests.affected($$update platform_settings set invite_only = false$$), 0, 'cannot change settings directly');
select tests.login(:'device');
select tests.throws(sql, 'admin only', 'display: ' || sql) from tests.admin_calls;
select tests.login(null);
select tests.throws(sql, 'permission denied%', 'anon: ' || sql) from tests.admin_calls;

-- Bootstrap the first admin by hand (docs/PLATFORM.md).
select tests.logout();
insert into platform_admins (user_id) values (:'admin');
select tests.eq((select count(*)::int from admin_audit_log), 0, 'refused calls left no audit rows');

select tests.login(:'admin');
select tests.ok(is_platform_admin(), 'admin is an admin');
select tests.eq((select count(*)::int from platform_admins), 1, 'admins read platform_admins');
select tests.eq((select count(*)::int from platform_settings), 1, 'admins read platform_settings');

-- ───────────────────────────── Settings ─────────────────────────────

select tests.eq(admin_get_settings() - 'updated_at',
                '{"invite_only": true, "assistant_enabled": true, "assistant_daily_limit": 200, "updated_by": null}'::jsonb, 'default settings');
select tests.eq(admin_update_settings(assistant_daily_limit => 50) - 'updated_at',
                jsonb_build_object('invite_only', true, 'assistant_enabled', true, 'assistant_daily_limit', 50, 'updated_by', :'admin'),
                'one setting changed, the rest kept');
select tests.eq(admin_update_settings(invite_only => false, assistant_enabled => false)->>'assistant_daily_limit', '50', 'nulls leave values alone');
select tests.eq(admin_update_settings() - 'updated_at' - 'updated_by',
                '{"invite_only": false, "assistant_enabled": false, "assistant_daily_limit": 50}'::jsonb, 'no arguments: no change');
select tests.throws($$select admin_update_settings(assistant_daily_limit => -1)$$, 'assistant_daily_limit must be 0 or more', 'negative limit');
select admin_update_settings(true, true, 200);
select tests.eq((select details from admin_audit_log where action = 'update_settings' order by id limit 1),
                '{"assistant_daily_limit": 50}'::jsonb, 'audit records the change');
select tests.eq((select count(*)::int from admin_audit_log where action = 'update_settings' and admin_id = :'admin'), 4, 'one audit row per update');

-- ───────────────────────── Platform invites ─────────────────────────

select id as inv1, code as code1, expires_at as exp1 from admin_create_platform_invite('New@Example.com', 'For the Parks', 2, 7) \gset
select tests.ok(:'code1' ~ '^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$', 'display code');
select tests.ok(:'exp1'::timestamptz between now() + interval '6 days 23 hours' and now() + interval '7 days 1 hour', 'expiry');
select tests.eq((select row(code, email, note, max_uses, use_count, created_by)::text from platform_invites where id = :'inv1'),
                row(replace(:'code1', '-', ''), 'New@Example.com', 'For the Parks', 2, 0, :'admin'::uuid)::text, 'stored');
select tests.ok((select expires_at > now() + interval '29 days' from admin_create_platform_invite()), 'defaults: 30 days');
select tests.throws($$select admin_create_platform_invite(max_uses => 0)$$, 'max_uses must be between 1 and 10000', 'max_uses 0');
select tests.throws($$select admin_create_platform_invite(expires_in_days => 0)$$, 'expires_in_days must be between 1 and 365', '0 days');
select tests.eq((select details->>'code' from admin_audit_log where action = 'create_platform_invite' and target_id = :'inv1'), :'code1', 'audited with code');

select id as inv_revoke from admin_create_platform_invite(note => 'to revoke') \gset
select id as inv_used from admin_create_platform_invite(note => 'to use') \gset
select id as inv_expired from admin_create_platform_invite(note => 'to expire') \gset
select admin_revoke_platform_invite(:'inv_revoke');
select tests.throws($$select admin_revoke_platform_invite('99999999-9999-9999-9999-999999999999')$$, 'invite not found', 'unknown invite');
select tests.ok(exists (select 1 from admin_audit_log where action = 'revoke_platform_invite' and target_id = :'inv_revoke'), 'revoke audited');
select tests.logout();
update platform_invites set use_count = 1 where id = :'inv_used';
update platform_invites set expires_at = now() - interval '1 second' where id = :'inv_expired';
select tests.login(:'admin');
select tests.eq((select status from admin_list_platform_invites(true) where id = :'inv1'), 'active', 'status active');
select tests.eq((select status from admin_list_platform_invites(true) where id = :'inv_revoke'), 'revoked', 'status revoked');
select tests.eq((select status from admin_list_platform_invites(true) where id = :'inv_used'), 'used', 'status used');
select tests.eq((select status from admin_list_platform_invites(true) where id = :'inv_expired'), 'expired', 'status expired');
select tests.ok(not exists (select 1 from admin_list_platform_invites() where status <> 'active'), 'default list: active only');
select tests.ok(exists (select 1 from admin_list_platform_invites() where id = :'inv1'), 'active invite listed');
select tests.eq((select created_by_email || ' ' || code from admin_list_platform_invites() where id = :'inv1'), 'admin@example.com ' || :'code1', 'creator email and display code');
select tests.eq((select code from admin_list_platform_invites(true) where note = 'Local development'), 'LETS-PLAY', 'seed invite in display form');

-- ───────────────────────── Families ─────────────────────────

-- Some assistant use: two requests today, one yesterday, one long ago.
select tests.logout();
insert into assistant_usage (family_id, user_id, model, input_tokens, output_tokens, created_at) values
  (:'fam', :'mom', 'claude-opus-5-5', 1000, 100, now()),
  (:'fam', :'device', 'claude-opus-5-5', 500, 50, now()),
  (:'fam', :'mom', 'claude-opus-5-5', 200, 20, now() - interval '1 day'),
  (:'fam', :'mom', 'claude-opus-5-5', 999, 99, now() - interval '60 days');
insert into families (name, created_at) values ('Old quiet family', now() - interval '90 days');
select tests.login(:'admin');

select tests.eq(admin_overview(), jsonb_build_object(
  'families', 2, 'families_active_7d', 1, 'suspended_families', 0, 'users', 4, 'devices', 1, 'members', 4,
  'open_platform_invites', 3, 'assistant_requests_7d', 3, 'assistant_tokens_7d', 1870), 'overview numbers');

select tests.eq((select row(name, status, member_count, parent_count, device_count, assistant_requests_30d)::text
                 from admin_list_families() where id = :'fam'),
                row('The Demo Family', 'active', 4, 2, 1, 3)::text, 'family row');
select tests.ok((select last_activity > now() - interval '1 minute' from admin_list_families() where id = :'fam'), 'last activity is recent');
select tests.eq((select count(*)::int from admin_list_families('demo')), 1, 'search by name');
select tests.eq((select count(*)::int from admin_list_families(:'fam')), 1, 'search by id');
select tests.eq((select count(*)::int from admin_list_families('nothing like this')), 0, 'search miss');
select tests.eq((select count(*)::int from admin_list_families(lim => 1)), 1, 'limit');
select tests.eq((select name from admin_list_families(lim => 1, off => 1)), 'Old quiet family', 'offset (newest first)');

-- Families write most of these timestamps themselves. Ones in the future
-- (past a few minutes of clock skew) don't make a quiet family look active.
select tests.logout();
select id as quiet from families where name = 'Old quiet family' \gset
insert into events (family_id, title, starts_at, ends_at, updated_at) values (:'quiet', 'Forever', now(), now(), 'infinity');
insert into family_memories (family_id, content, created_at) values (:'quiet', 'We are always busy', now() + interval '1 year');
insert into devices (family_id, user_id, last_seen_at) values (:'quiet', :'admin2', now() + interval '1 day');
select tests.login(:'admin');
select tests.eq((admin_overview()->>'families_active_7d')::int, 1, 'future timestamps don''t count as activity');
select tests.ok((select last_activity < now() - interval '80 days' from admin_list_families() where id = :'quiet'),
                'last activity ignores future timestamps');
select tests.ok((select last_activity > now() - interval '1 minute' from admin_list_families() where id = :'fam'),
                'real activity still counts');
select tests.logout();
delete from devices where family_id = :'quiet';
select tests.login(:'admin');

select admin_family_detail(:'fam') as detail \gset
select tests.eq((select array_agg(k order by k) from jsonb_object_keys(:'detail'::jsonb) k),
                array['devices', 'family', 'invites', 'members', 'usage_by_day'], 'detail shape');
select tests.eq((:'detail'::jsonb)->'family'->>'name', 'The Demo Family', 'detail family');
select tests.eq(jsonb_array_length((:'detail'::jsonb)->'members'), 4, 'detail members');
select tests.eq((select m->>'email' from jsonb_array_elements((:'detail'::jsonb)->'members') m where m->>'user_id' = :'mom'), 'mom@example.com', 'member email');
select tests.eq((:'detail'::jsonb)->'devices'->0->>'name', 'Kitchen', 'detail devices');
select tests.eq((:'detail'::jsonb)->'invites'->0->>'code', 'MEET-THEM', 'detail invites in display form');
select tests.eq((:'detail'::jsonb)->'invites'->0->>'status', 'active', 'invite status');
select tests.eq(jsonb_array_length((:'detail'::jsonb)->'usage_by_day'), 30, '30 days of usage');
select tests.eq(((:'detail'::jsonb)->'usage_by_day'->29->>'requests')::int, 2, 'today''s requests');
select tests.eq(((:'detail'::jsonb)->'usage_by_day'->29->>'input_tokens')::int, 1500, 'today''s input tokens');
select tests.throws($$select admin_family_detail('99999999-9999-9999-9999-999999999999')$$, 'family not found', 'unknown family');

select tests.throws(format('select admin_set_family_status(%L, %L)', :'fam', 'banned'), 'status must be active or suspended', 'bad status');
select tests.throws($$select admin_set_family_status('99999999-9999-9999-9999-999999999999', 'suspended')$$, 'family not found', 'unknown family');
select admin_set_family_status(:'fam', 'suspended', 'Spam');
select tests.eq((admin_overview()->>'suspended_families')::int, 1, 'overview counts the suspension');
select admin_set_family_status(:'fam', 'active');
select tests.eq((select array_agg(details->>'status' order by id) from admin_audit_log where action = 'set_family_status'),
                array['suspended', 'active'], 'status changes audited');

-- ───────────────────────── Users and admins ─────────────────────────

select tests.eq((select count(*)::int from admin_list_users()), 5, 'every auth user');
select tests.eq((select row(display_name, is_admin, is_device, banned, families)::text from admin_list_users() where id = :'mom'),
                row('Mom', false, false, false, jsonb_build_array(jsonb_build_object('id', :'fam'::uuid, 'name', 'The Demo Family', 'role', 'parent')))::text,
                'person row');
select tests.eq((select row(display_name, is_device, families->0->>'role')::text from admin_list_users() where id = :'device'),
                row('Kitchen', true, 'device')::text, 'display row');
select tests.ok((select banned from admin_list_users() where id = :'stranger'), 'banned user');
select tests.ok((select is_admin from admin_list_users() where id = :'admin'), 'admin flag');
select tests.eq((select array_agg(id) from admin_list_users('MOM@')), array[:'mom'::uuid], 'search by email');
select tests.eq((select array_agg(id) from admin_list_users('ada')), array[:'admin'::uuid], 'search by display name');
select tests.eq((select count(*)::int from admin_list_users(lim => 2)), 2, 'limit');

select tests.throws(format('select admin_set_admin(%L, false)', :'admin'), 'can''t remove the last admin', 'last admin stays');
select tests.throws(format('select admin_set_admin(%L, true)', :'device'), 'a display account can''t be an admin', 'displays are not admins');
select tests.throws($$select admin_set_admin('99999999-9999-9999-9999-999999999999', true)$$, 'user not found', 'unknown user');
select admin_set_admin(:'admin2', true);
select admin_set_admin(:'admin2', true);  -- idempotent
select tests.eq((select created_by from platform_admins where user_id = :'admin2'), :'admin'::uuid, 'created_by');
select tests.login(:'admin2');
select tests.ok(is_platform_admin(), 'new admin');
select admin_set_admin(:'admin', false);
select tests.throws(format('select admin_set_admin(%L, false)', :'admin2'), 'can''t remove the last admin', 'still one left');
select tests.login(:'admin');
select tests.throws('select admin_overview()', 'admin only', 'removed admin is refused');
select tests.login(:'admin2');
select admin_set_admin(:'admin', true);
select tests.eq((select count(*)::int from admin_audit_log where action = 'set_admin'), 4, 'admin changes audited');
select tests.eq((select admin_id from admin_audit_log where action = 'set_admin' order by id desc limit 1), :'admin2'::uuid, 'audit names the acting admin');

-- ───────────────────────── Usage and audit ─────────────────────────

select tests.eq((select count(*)::int from admin_usage_by_day(7)), 7, 'one row per day');
select tests.eq((select row(requests, input_tokens, output_tokens, families)::text from admin_usage_by_day(7) order by day desc limit 1),
                row(2, 1500::bigint, 150::bigint, 1)::text, 'today');
select tests.eq((select requests from admin_usage_by_day(7) order by day desc offset 1 limit 1), 1, 'yesterday');
select tests.eq((select sum(requests)::int from admin_usage_by_day()), 3, '30 days leave out the old request');
select tests.eq((select max(day) from admin_usage_by_day()), (now() at time zone 'UTC')::date, 'ends today (UTC)');
select tests.eq((select count(*)::int from admin_usage_by_day(0)), 1, 'at least one day');

select tests.eq((select admin_email from admin_list_audit() order by id desc limit 1), 'admin2@example.com', 'audit shows the admin email');
select tests.eq((select count(*)::int from admin_list_audit(lim => 3)), 3, 'audit limit');
select tests.ok((select bool_and(a.id > b.id) from admin_list_audit(lim => 1) a, admin_list_audit(lim => 1, off => 1) b), 'newest first');

-- ───────────────────────── Deleting a family ─────────────────────────

select tests.throws($$select admin_delete_family('99999999-9999-9999-9999-999999999999')$$, 'family not found', 'unknown family');
select admin_delete_family(:'fam');
select tests.logout();
select tests.ok(not exists (select 1 from families where id = :'fam'), 'family gone');
select tests.ok(not exists (select 1 from members where family_id = :'fam'), 'members gone (guard skipped)');
select tests.ok(not exists (select 1 from auth.users where id = :'device'), 'display account removed');
select tests.ok(exists (select 1 from auth.users where id = :'mom'), 'people keep their accounts');
select tests.eq((select details from admin_audit_log where action = 'delete_family'),
                '{"name": "The Demo Family", "device_accounts_removed": 1}'::jsonb, 'deletion audited');

-- ───────────────────────── Service role ─────────────────────────

-- Server-side callers with the service role count as admins. There's no
-- auth.uid(), so their audit rows carry no admin id.
select tests.login_service();
select tests.ok(is_platform_admin(), 'service role counts as admin');
select id as svc_inv from admin_create_platform_invite('emailed@example.com') \gset
select tests.logout();
select tests.ok((select admin_id is null from admin_audit_log where target_id = :'svc_inv'), 'service-role audit row has no admin id');
select tests.ok((select created_by is null from platform_invites where id = :'svc_inv'), 'no creator');
