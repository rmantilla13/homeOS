-- Cross-family leaks: a display retargeting itself, a suspended family
-- gaining a display, and rows that name a person from another household.
\set ON_ERROR_STOP 1
\set fam     '00000000-0000-0000-0000-00000000f001'
\set fam2    '00000000-0000-0000-0000-00000000f002'
\set m_mom   '00000000-0000-0000-0000-00000000a001'
\set m_other '00000000-0000-0000-0000-00000000b001'
\set mom     'a0000000-0000-0000-0000-000000000001'
\set device  'd0000000-0000-0000-0000-000000000001'
\set device2 'd0000000-0000-0000-0000-000000000002'
\set other   'a0000000-0000-0000-0000-000000000099'
\set admin   'ad000000-0000-0000-0000-000000000001'

insert into auth.users (id, email, raw_app_meta_data) values
  (:'mom', 'mom@example.com', '{}'),
  (:'device', 'device@devices.homeos.invalid', '{"kind": "device"}'),
  (:'device2', 'device2@devices.homeos.invalid', '{"kind": "device"}'),
  (:'other', 'neighbor@example.com', '{}'),
  (:'admin', 'admin@example.com', '{}');
update members set user_id = :'mom' where id = :'m_mom';
insert into families (id, name) values (:'fam2', 'Other House');
insert into members (id, family_id, display_name, role, user_id)
values (:'m_other', :'fam2', 'Neighbor', 'parent', :'other');
insert into devices (family_id, user_id, name) values (:'fam', :'device', 'Kitchen');
insert into tasks (family_id, title) values (:'fam2', 'Neighbor chore');
insert into platform_admins (user_id) values (:'admin');

-- ───────────────────────────── Displays ─────────────────────────────

select tests.login(:'device');
select tests.throws(format($$update devices set family_id = %L where user_id = %L$$, :'fam2', :'device'),
                    'a display can''t move to another family', 'display cannot join another family');
select tests.eq((select count(*)::int from tasks where title = 'Neighbor chore'), 0, 'and still cannot see it');
select tests.eq((select family_id::text from devices where user_id = :'device'), :'fam', 'stays on its own family');
select tests.throws(format($$update devices set user_id = %L where user_id = %L$$, :'mom', :'device'),
                    'a display can''t move to another family', 'display cannot change its account');
select tests.eq(tests.affected(format(
  $$update devices set name = 'Kitchen wall', last_seen_at = now() where user_id = %L$$, :'device')),
  1, 'display can rename itself and check in');
select tests.login(:'mom');
select tests.throws(format('select admin_revoke_device((select id from devices where user_id = %L))', :'device'),
                    'admin only', 'a parent cannot revoke a display');

select tests.logout();
update families set status = 'suspended' where id = :'fam2';
select tests.throws(format($$insert into devices (family_id, user_id) values (%L, %L)$$, :'fam2', :'device2'),
                    'this family is suspended', 'a suspended family cannot gain a display');
update families set status = 'active' where id = :'fam2';

-- ───────────────────────────── Foreign people ─────────────────────────────

select tests.login(:'mom');
insert into events (id, family_id, title, starts_at, ends_at)
values ('22222222-2222-2222-2222-222222222222', :'fam', 'Dinner', now(), now() + interval '1 hour');
select tests.throws(format(
  $$insert into event_members (event_id, member_id) values ('22222222-2222-2222-2222-222222222222', %L)$$, :'m_other'),
  'that person isn''t in this family', 'an event cannot guest another family');
select tests.eq(tests.affected(format(
  $$insert into event_members (event_id, member_id) values ('22222222-2222-2222-2222-222222222222', %L)$$, :'m_mom')),
  1, 'a guest from this family is fine');
select tests.throws(format(
  $$insert into events (family_id, title, starts_at, ends_at, created_by) values (%L, 'Nope', now(), now(), %L)$$,
  :'fam', :'m_other'), 'that person isn''t in this family', 'created_by stays in the family');
select tests.throws(format($$update tasks set assignee_id = %L where title = 'Feed the dog'$$, :'m_other'),
                    'that person isn''t in this family', 'a chore cannot be assigned outside the family');
select tests.throws(format(
  $$insert into list_items (list_id, text, added_by) select id, 'Eggs', %L from lists where family_id = %L$$,
  :'m_other', :'fam'), 'that person isn''t in this family', 'added_by stays in the family');
select tests.eq(tests.affected($$insert into list_items (list_id, text) select id, 'Milk' from lists where family_id = '00000000-0000-0000-0000-00000000f001'$$),
                1, 'a list item with no author is fine');

select tests.logout();
insert into media_items (family_id, storage_path, kind, byte_size, content_type)
values (:'fam2', :'fam2' || '/yard.jpg', 'photo', 50, 'image/jpeg');
select tests.login(:'mom');
select tests.eq((select count(*)::int from media_items), 0, 'mom sees none of the other family''s media');
select tests.logout();
update families set status = 'suspended' where id = :'fam2';
select tests.login(:'other');
select tests.throws(format(
  $$insert into media_items (family_id, storage_path, kind, byte_size, content_type) values (%L, %L, 'photo', 10, 'image/jpeg')$$,
  :'fam2', :'fam2' || '/more.jpg'), '%row-level security%', 'suspended family cannot add media');
select tests.eq((select count(*)::int from media_items), 0, 'suspended member sees no media');

-- ───────────────────────────── Revoke ─────────────────────────────

select tests.logout();
select id as dev from devices where user_id = :'device' \gset
select tests.login(:'admin');
select tests.eq(admin_revoke_device(:'dev')->>'auth_user_removed', 'true', 'revoke removes the display account');
select tests.eq((select details->>'name' from admin_audit_log where action = 'revoke_device'), 'Kitchen wall', 'revoke is audited');
select tests.throws(format('select admin_revoke_device(%L)', :'dev'), 'device not found', 'already revoked');
select tests.logout();
select tests.ok(not exists (select 1 from devices where user_id = :'device'), 'display row is gone');
select tests.ok(not exists (select 1 from auth.users where id = :'device'), 'auth user is gone');
select tests.ok(exists (select 1 from auth.users where id = :'mom'), 'people keep their accounts');
