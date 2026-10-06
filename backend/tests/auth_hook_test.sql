-- hook_before_user_created: lets sign-ups through only with an open invite
-- (by code or by email) while the platform is invite-only.
\set ON_ERROR_STOP 1
\set fam  '00000000-0000-0000-0000-00000000f001'
\set fam2 '00000000-0000-0000-0000-00000000f002'

insert into families (id, name, status) values (:'fam2', 'Suspended family', 'suspended');

insert into platform_invites (code, email, max_uses, use_count, expires_at, revoked_at) values
  ('AAAABBBB', null,                  1, 0, now() + interval '30 days', null),   -- open
  ('GGGGHHHH', 'Newbie@Example.com',  1, 0, now() + interval '30 days', null),   -- open, email-bound
  ('HHHHJJJJ', 'invited@example.com', 1, 0, now() + interval '30 days', null),   -- open, sent by email
  ('CCCCDDDD', null,                  1, 1, now() + interval '30 days', null),   -- used
  ('DDDDEEEE', null,                  1, 0, now() - interval '1 minute', null),  -- expired
  ('EEEEFFFF', null,                  1, 0, now() + interval '30 days', now()),  -- revoked
  ('KKKKLLLL', 'late@example.com',    1, 0, now() - interval '1 minute', null);  -- expired, email-bound

insert into family_invites (family_id, code, email, expires_at, accepted_at, revoked_at) values
  (:'fam',  'FFFFGGGG', 'aunt@example.com', now() + interval '14 days', null, null),   -- open, email-bound
  (:'fam',  'MMMMNNNN', null, now() + interval '14 days', now(), null),                -- accepted
  (:'fam',  'NNNNPPPP', null, now() + interval '14 days', null, now()),                -- revoked
  (:'fam',  'PPPPQQQQ', null, now() - interval '1 minute', null, null),                -- expired
  (:'fam2', 'QQQQRRRR', 'cousin@example.com', now() + interval '14 days', null, null); -- suspended family

-- The payload Supabase Auth sends (see docs/PLATFORM.md).
create function tests.signup(email text, code text default null, app jsonb default '{}') returns jsonb language sql as $$
  select jsonb_build_object(
    'metadata', jsonb_build_object('uuid', gen_random_uuid(), 'time', now(), 'name', 'before-user-created', 'ip_address', '127.0.0.1'),
    'user', jsonb_build_object(
      'id', gen_random_uuid(), 'aud', 'authenticated', 'role', '', 'email', email, 'phone', '',
      'app_metadata', jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')) || app,
      'user_metadata', case when code is null then '{}'::jsonb else jsonb_build_object('invite_code', code, 'display_name', 'Someone') end,
      'identities', '[]'::jsonb, 'created_at', now(), 'updated_at', now(), 'is_anonymous', false))
$$;
create function tests.allowed(result jsonb) returns boolean language sql as $$ select result = '{}'::jsonb $$;
create function tests.rejected(result jsonb) returns boolean language sql as $$
  select result = '{"error": {"http_code": 403, "message": "homeOS is invite-only. Ask your family for an invite code."}}'::jsonb
$$;

-- Supabase Auth calls the hook as supabase_auth_admin.
set role supabase_auth_admin;

-- Displays created by pair-device.
select tests.ok(tests.allowed(hook_before_user_created(tests.signup('device-1@devices.homeos.invalid', null, '{"kind": "device"}'))), 'device account');

-- By code.
select tests.ok(tests.allowed(hook_before_user_created(tests.signup('anyone@example.com', 'AAAA-BBBB'))), 'open platform code');
select tests.ok(tests.allowed(hook_before_user_created(tests.signup('anyone@example.com', ' aaaabbbb'))), 'code normalized');
select tests.ok(tests.allowed(hook_before_user_created(tests.signup('anyone@example.com', 'meet-them'))), 'open family code (seed)');
select tests.ok(tests.allowed(hook_before_user_created(tests.signup('NEWBIE@example.com', 'GGGG-HHHH'))), 'email-bound code, right email');
select tests.ok(tests.allowed(hook_before_user_created(tests.signup('Aunt@Example.com', 'FFFF-GGGG'))), 'email-bound family code, right email');
select tests.ok(tests.rejected(hook_before_user_created(tests.signup('anyone@example.com', 'GGGG-HHHH'))), 'email-bound code, wrong email');
select tests.ok(tests.rejected(hook_before_user_created(tests.signup('anyone@example.com', 'FFFF-GGGG'))), 'email-bound family code, wrong email');
select tests.ok(tests.rejected(hook_before_user_created(tests.signup('anyone@example.com', 'CCCC-DDDD'))), 'used code');
select tests.ok(tests.rejected(hook_before_user_created(tests.signup('anyone@example.com', 'DDDD-EEEE'))), 'expired code');
select tests.ok(tests.rejected(hook_before_user_created(tests.signup('anyone@example.com', 'EEEE-FFFF'))), 'revoked code');
select tests.ok(tests.rejected(hook_before_user_created(tests.signup('anyone@example.com', 'MMMM-NNNN'))), 'accepted family code');
select tests.ok(tests.rejected(hook_before_user_created(tests.signup('anyone@example.com', 'NNNN-PPPP'))), 'revoked family code');
select tests.ok(tests.rejected(hook_before_user_created(tests.signup('anyone@example.com', 'PPPP-QQQQ'))), 'expired family code');
select tests.ok(tests.rejected(hook_before_user_created(tests.signup('cousin@example.com', 'QQQQ-RRRR'))), 'suspended family code');
select tests.ok(tests.rejected(hook_before_user_created(tests.signup('anyone@example.com', 'ZZZZ-ZZZZ'))), 'unknown code');
select tests.ok(tests.rejected(hook_before_user_created(tests.signup('anyone@example.com', ''))), 'empty code');

-- By email alone (invites sent from the admin console, OAuth sign-ups).
select tests.ok(tests.allowed(hook_before_user_created(tests.signup('Invited@Example.com'))), 'open platform invite for this email');
select tests.ok(tests.allowed(hook_before_user_created(tests.signup('aunt@example.com'))), 'open family invite for this email');
select tests.ok(tests.rejected(hook_before_user_created(tests.signup('late@example.com'))), 'expired invite for this email');
select tests.ok(tests.rejected(hook_before_user_created(tests.signup('cousin@example.com'))), 'suspended family invite for this email');
select tests.ok(tests.rejected(hook_before_user_created(tests.signup('nobody@example.com'))), 'no invite');
select tests.ok(tests.rejected(hook_before_user_created(tests.signup(null))), 'phone sign-up, no code');
select tests.ok(tests.rejected(hook_before_user_created('{}')), 'empty payload');

-- Open platform: everyone gets in.
reset role;
update platform_settings set invite_only = false;
set role supabase_auth_admin;
select tests.ok(tests.allowed(hook_before_user_created(tests.signup('nobody@example.com'))), 'invite-only off');
reset role;
update platform_settings set invite_only = true;

-- Only the auth server may call it.
select tests.ok(has_function_privilege('supabase_auth_admin', 'hook_before_user_created(jsonb)', 'execute'), 'auth admin may execute');
select tests.ok(not has_function_privilege('authenticated', 'hook_before_user_created(jsonb)', 'execute'), 'authenticated may not');
select tests.ok(not has_function_privilege('anon', 'hook_before_user_created(jsonb)', 'execute'), 'anon may not');
select tests.login(null);
select tests.throws($$select hook_before_user_created('{}')$$, 'permission denied%', 'anon call refused');
select tests.login('a0000000-0000-0000-0000-000000000001');
select tests.throws($$select hook_before_user_created('{}')$$, 'permission denied%', 'authenticated call refused');
select tests.logout();
