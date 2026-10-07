-- delete_my_account: who may delete their own account, what goes with it,
-- and what stays with the family.
\set ON_ERROR_STOP 1
\set fam    '00000000-0000-0000-0000-00000000f001'
\set solo   '00000000-0000-0000-0000-00000000f002'
\set m_mom  '00000000-0000-0000-0000-00000000a001'
\set m_dad  '00000000-0000-0000-0000-00000000a002'
\set m_emma '00000000-0000-0000-0000-00000000a003'
\set m_solo '00000000-0000-0000-0000-00000000a009'
\set mom      'a0000000-0000-0000-0000-000000000001'
\set dad      'a0000000-0000-0000-0000-000000000002'
\set emma     'a0000000-0000-0000-0000-000000000003'
\set device   'd0000000-0000-0000-0000-000000000001'
\set device2  'd0000000-0000-0000-0000-000000000002'
\set solo_u   'e0000000-0000-0000-0000-000000000001'
\set admin    'ad000000-0000-0000-0000-000000000001'

insert into auth.users (id, email, raw_app_meta_data) values
  (:'mom', 'mom@example.com', '{}'), (:'dad', 'dad@example.com', '{}'), (:'emma', 'emma@example.com', '{}'),
  (:'device', 'device-1@devices.homeos.invalid', '{"kind": "device"}'),
  (:'device2', 'device-2@devices.homeos.invalid', '{"kind": "device"}'),
  (:'solo_u', 'solo@example.com', '{}'), (:'admin', 'admin@example.com', '{}');
update members set user_id = :'mom' where id = :'m_mom';
update members set user_id = :'emma' where id = :'m_emma';
insert into devices (family_id, user_id, name) values (:'fam', :'device', 'Kitchen');
insert into platform_admins (user_id) values (:'admin');
insert into assistant_threads (family_id, owner_id, title) values (:'fam', :'mom', 'Dinner ideas');

-- A family with one account (and a kid without one), a display and some content.
insert into families (id, name) values (:'solo', 'Just Me');
insert into members (id, family_id, user_id, display_name, role) values
  (:'m_solo', :'solo', :'solo_u', 'Sam', 'parent');
insert into members (family_id, display_name, role) values (:'solo', 'Kiddo', 'child');
insert into devices (family_id, user_id, name) values (:'solo', :'device2', 'Hall');
insert into events (family_id, title, starts_at, ends_at) values (:'solo', 'Dentist', now(), now() + interval '1 hour');
insert into media_items (family_id, storage_path, kind, file_store) values (:'solo', :'solo' || '/a.jpg', 'photo', 'blob');
insert into assistant_threads (family_id, owner_id, title) values (:'solo', :'solo_u', 'Hi');

-- ───────────────────────── Who can't ─────────────────────────

select tests.login(null);
select tests.throws('select delete_my_account()', 'permission denied%', 'anon cannot call it');

select tests.login(:'device');
select tests.throws('select delete_my_account()', 'a display can''t delete its account%', 'a display is refused');

select tests.login(:'admin');
select tests.throws('select delete_my_account()', 'platform admins can''t delete their account here%', 'a platform admin is refused');

-- Mom is the only parent with a login, and Emma has one too.
select tests.login(:'mom');
select tests.throws('select delete_my_account()',
                    'you''re the only parent with a login in The Demo Family. Make someone else there a parent first',
                    'the last parent of a family with other accounts is refused');
select tests.logout();
select tests.ok(exists (select 1 from auth.users where id = :'mom'), 'refused: the account stays');
select tests.eq((select user_id from members where id = :'m_mom'), :'mom'::uuid, 'refused: still linked');

-- ───────────────────────── A parent, with another parent left ─────────────────────────

update members set user_id = :'dad' where id = :'m_dad';
select tests.login(:'mom');
select tests.eq(delete_my_account(),
                '{"families_deleted": [], "device_users": [], "auth_user_removed": true}'::jsonb,
                'mom deletes her account');
select tests.logout();
select tests.ok(not exists (select 1 from auth.users where id = :'mom'), 'the account is gone');
select tests.ok(not exists (select 1 from profiles where id = :'mom'), 'the profile went with it');
select tests.ok(not exists (select 1 from assistant_threads where owner_id = :'mom'), 'her chats went with it');
select tests.ok(exists (select 1 from families where id = :'fam'), 'the family stays');
select tests.eq((select user_id from members where id = :'m_mom'), null::uuid, 'her member row stays, unlinked');
select tests.eq((select details from admin_audit_log where action = 'delete_own_account' and target_id = :'mom'),
                '{"families_deleted": 0, "device_accounts": 0}'::jsonb, 'audited without her email');

-- ───────────────────────── A child ─────────────────────────

select tests.login(:'emma');
select tests.eq(delete_my_account()->>'auth_user_removed', 'true', 'a kid can delete their account');
select tests.logout();
select tests.eq((select user_id from members where id = :'m_emma'), null::uuid, 'her row stays with the family');
select tests.ok(exists (select 1 from members where id = :'m_emma'), 'with her points and history');

-- ───────────────────────── The only account in a family ─────────────────────────

-- Supabase may not let SQL delete auth users. The edge function then needs
-- the ids, and everything else must already be done.
create function tests.no_auth_delete() returns trigger language plpgsql as $$
begin
  raise exception 'permission denied for table users' using errcode = 'insufficient_privilege';
end $$;
create trigger no_auth_delete before delete on auth.users for each row execute function tests.no_auth_delete();

select tests.login(:'solo_u');
select tests.eq(delete_my_account(),
                jsonb_build_object('families_deleted', jsonb_build_array(:'solo'),
                                   'device_users', jsonb_build_array(:'device2'),
                                   'auth_user_removed', false),
                'the only account takes the family with it, and names what Auth must remove');
select tests.logout();
select tests.ok(not exists (select 1 from families where id = :'solo'), 'that family is gone');
select tests.ok(not exists (select 1 from members where family_id = :'solo'), 'with its members');
select tests.ok(not exists (select 1 from devices where family_id = :'solo'), 'its displays');
select tests.ok(not exists (select 1 from media_items where family_id = :'solo'), 'and its photos');
select tests.ok(exists (select 1 from auth.users where id = :'solo_u'), 'the account waits for the edge function');
select tests.ok(exists (select 1 from families where id = :'fam'), 'other families are untouched');

drop trigger no_auth_delete on auth.users;

-- Asked again (the edge function retrying after Auth failed): nothing left to do in SQL.
select tests.login(:'solo_u');
select tests.eq(delete_my_account(),
                '{"families_deleted": [], "device_users": [], "auth_user_removed": true}'::jsonb,
                'a retry is harmless');
select tests.logout();
select tests.ok(not exists (select 1 from auth.users where id = :'solo_u'), 'and the account goes');
select tests.ok(exists (select 1 from auth.users where id = :'device'), 'the other family''s display stays');
