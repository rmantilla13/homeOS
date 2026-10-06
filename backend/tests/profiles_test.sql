-- Profiles: created on sign-up (not for displays), visible to yourself and
-- to people who share a family with you, editable only by you.
\set ON_ERROR_STOP 1

-- Sign-ups, the way Supabase Auth inserts them.
insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data) values
  ('a0000000-0000-0000-0000-000000000001', 'mom@example.com',    '{"display_name": "Mom"}', '{"provider": "email"}'),
  ('a0000000-0000-0000-0000-000000000002', 'dad.smith@example.com', '{}',                   '{"provider": "email"}'),
  ('a0000000-0000-0000-0000-000000000003', null,                 '{"display_name": "  "}', '{}'),
  ('d0000000-0000-0000-0000-000000000001', 'device-1@devices.homeos.invalid', '{}',
   '{"provider": "email", "kind": "device", "family_id": "00000000-0000-0000-0000-00000000f001"}'),
  ('e0000000-0000-0000-0000-000000000001', 'stranger@example.com', '{"display_name": "Stranger"}', '{}');

-- Trigger: display name from metadata, else the email's local part, else ''.
select tests.eq((select display_name from profiles where id = 'a0000000-0000-0000-0000-000000000001'), 'Mom', 'name from metadata');
select tests.eq((select display_name from profiles where id = 'a0000000-0000-0000-0000-000000000002'), 'dad.smith', 'name from email');
select tests.eq((select display_name from profiles where id = 'a0000000-0000-0000-0000-000000000003'), '', 'blank name');
select tests.ok(not exists (select 1 from profiles where id = 'd0000000-0000-0000-0000-000000000001'), 'devices get no profile');
select tests.eq((select count(*)::int from profiles), 4, 'four people, four profiles');

-- Deleting the auth user removes the profile.
insert into auth.users (id, email) values ('a0000000-0000-0000-0000-0000000000ff', 'gone@example.com');
delete from auth.users where id = 'a0000000-0000-0000-0000-0000000000ff';
select tests.ok(not exists (select 1 from profiles where id = 'a0000000-0000-0000-0000-0000000000ff'), 'profile cascades');

-- Mom and Dad are parents of the demo family; the device is its display.
update members set user_id = 'a0000000-0000-0000-0000-000000000001' where id = '00000000-0000-0000-0000-00000000a001';
update members set user_id = 'a0000000-0000-0000-0000-000000000002' where id = '00000000-0000-0000-0000-00000000a002';
insert into devices (family_id, user_id) values ('00000000-0000-0000-0000-00000000f001', 'd0000000-0000-0000-0000-000000000001');

-- Mom sees herself and Dad, not the stranger or the blank user.
select tests.login('a0000000-0000-0000-0000-000000000001');
select tests.eq((select count(*)::int from profiles), 2, 'mom sees own + family profiles');
select tests.ok(exists (select 1 from profiles where display_name = 'dad.smith'), 'mom sees dad');
select tests.ok(not exists (select 1 from profiles where display_name = 'Stranger'), 'mom does not see stranger');
select tests.ok(shares_family_with('a0000000-0000-0000-0000-000000000002'), 'shares_family_with dad');
select tests.ok(not shares_family_with('e0000000-0000-0000-0000-000000000001'), 'not with stranger');

-- Stranger sees only their own row.
select tests.login('e0000000-0000-0000-0000-000000000001');
select tests.eq((select count(*)::int from profiles), 1, 'stranger sees only self');
select tests.eq((select id from profiles), 'e0000000-0000-0000-0000-000000000001'::uuid, 'and it is theirs');

-- Devices aren't linked through members, so they see no profiles.
select tests.login('d0000000-0000-0000-0000-000000000001');
select tests.eq((select count(*)::int from profiles), 0, 'device sees no profiles');

-- Anonymous callers see nothing.
select tests.login(null);
select tests.eq((select count(*)::int from profiles), 0, 'anon sees no profiles');

-- Updates: your own row only; updated_at moves.
select tests.login('a0000000-0000-0000-0000-000000000001');
select tests.eq(tests.affected($$update profiles set display_name = 'Mama', avatar_path = 'a0000000-0000-0000-0000-000000000001/avatar.jpg'
                                 where id = 'a0000000-0000-0000-0000-000000000001'$$), 1, 'mom updates own profile');
select tests.eq(tests.affected($$update profiles set display_name = 'hacked' where id = 'a0000000-0000-0000-0000-000000000002'$$),
                0, 'mom cannot update dad');
select tests.throws($$update profiles set id = 'e0000000-0000-0000-0000-000000000001' where id = 'a0000000-0000-0000-0000-000000000001'$$,
                    '%row-level security%', 'cannot move a profile to another id');
select tests.throws($$insert into profiles (id, display_name) values ('a0000000-0000-0000-0000-000000000003', 'x')$$,
                    '%row-level security%', 'no client inserts');
select tests.eq(tests.affected($$delete from profiles$$), 0, 'no client deletes');
select tests.logout();
select tests.eq((select display_name from profiles where id = 'a0000000-0000-0000-0000-000000000001'), 'Mama', 'update stuck');
select tests.ok((select updated_at > created_at or updated_at = now() from profiles where id = 'a0000000-0000-0000-0000-000000000001'),
                'updated_at touched');
select tests.eq((select display_name from profiles where id = 'a0000000-0000-0000-0000-000000000002'), 'dad.smith', 'dad untouched');

-- Avatar read check used by the storage policies.
select tests.login('a0000000-0000-0000-0000-000000000002');
select tests.ok(can_read_avatar('a0000000-0000-0000-0000-000000000002/avatar.jpg'), 'own avatar');
select tests.ok(can_read_avatar('a0000000-0000-0000-0000-000000000001/avatar.jpg'), 'family avatar');
select tests.ok(not can_read_avatar('e0000000-0000-0000-0000-000000000001/avatar.jpg'), 'stranger avatar');
select tests.ok(not can_read_avatar('not-a-uuid/avatar.jpg'), 'junk path');
select tests.ok(not can_read_avatar('avatar.jpg'), 'no folder');
select tests.login(null);
select tests.ok(not can_read_avatar('a0000000-0000-0000-0000-000000000001/avatar.jpg'), 'anon reads nothing');

-- A suspended family no longer shares profiles.
select tests.logout();
update families set status = 'suspended' where id = '00000000-0000-0000-0000-00000000f001';
select tests.login('a0000000-0000-0000-0000-000000000001');
select tests.eq((select count(*)::int from profiles), 1, 'suspended: only own profile');
select tests.ok(not can_read_avatar('a0000000-0000-0000-0000-000000000002/avatar.jpg'), 'suspended: no family avatars');

-- handle_new_user is a trigger, not API.
select tests.throws($$select handle_new_user()$$, 'permission denied%', 'trigger function not callable');
select tests.logout();
