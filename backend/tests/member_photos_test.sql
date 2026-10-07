-- Member photos (20261011000001, 20261011000002): members.avatar_path stays
-- in the family's folder of the `avatars` bucket, which the family's parents
-- write and everyone in the family reads. Runs on top of stub_storage.sql.
\set ON_ERROR_STOP 1
\set fam    '00000000-0000-0000-0000-00000000f001'
\set fam2   '00000000-0000-0000-0000-00000000f002'
\set m_mom  '00000000-0000-0000-0000-00000000a001'
\set m_dad  '00000000-0000-0000-0000-00000000a002'
\set m_emma '00000000-0000-0000-0000-00000000a003'
\set m_leo  '00000000-0000-0000-0000-00000000a004'
\set mom      'a0000000-0000-0000-0000-000000000001'
\set dad      'a0000000-0000-0000-0000-000000000002'
\set emma     'a0000000-0000-0000-0000-000000000003'
\set device   'd0000000-0000-0000-0000-000000000001'
\set stranger 'e0000000-0000-0000-0000-000000000001'

insert into auth.users (id, email, raw_app_meta_data) values
  (:'mom', 'mom@example.com', '{}'), (:'dad', 'dad@example.com', '{}'), (:'emma', 'emma@example.com', '{}'),
  (:'device', 'device@devices.homeos.invalid', '{"kind": "device"}'), (:'stranger', 'stranger@example.com', '{}');
update members set user_id = :'mom' where id = :'m_mom';
update members set user_id = :'dad' where id = :'m_dad';
update members set user_id = :'emma' where id = :'m_emma';
insert into devices (family_id, user_id) values (:'fam', :'device');
insert into families (id, name) values (:'fam2', 'Elsewhere');
insert into members (family_id, user_id, display_name, role) values (:'fam2', :'stranger', 'Stranger', 'parent');

select tests.eq((select count(*)::int from information_schema.columns
                  where table_schema = 'public' and table_name = 'members' and column_name = 'avatar_url'), 0,
                'avatar_url is now avatar_path');

-- ───────────────────────── The path on the row ─────────────────────────

select tests.login(:'mom');
select tests.eq(tests.affected(format($$update members set avatar_path = %L where id = %L$$, :'fam' || '/leo-1.jpg', :'m_leo')),
                1, 'parent sets a kid''s photo');
select tests.throws(format($$update members set avatar_path = %L where id = %L$$, :'fam2' || '/leo.jpg', :'m_leo'),
                    'that photo isn''t in this family''s folder', 'not in another family''s folder');
select tests.throws(format($$update members set avatar_path = %L where id = %L$$, :'mom' || '/avatar.jpg', :'m_leo'),
                    'that photo isn''t in this family''s folder', 'not someone''s profile photo');
select tests.throws(format($$update members set avatar_path = %L where id = %L$$, :'fam' || '/a/leo.jpg', :'m_leo'),
                    'that photo isn''t in this family''s folder', 'not nested');
select tests.throws(format($$update members set avatar_path = 'https://x/y.png' where id = %L$$, :'m_leo'),
                    'that photo isn''t in this family''s folder', 'not a URL');
select tests.throws(format($$insert into members (family_id, display_name, avatar_path) values (%L, 'Baby', %L)$$, :'fam', :'fam2' || '/b.jpg'),
                    'that photo isn''t in this family''s folder', 'checked on insert too');
select tests.eq(tests.affected(format($$insert into members (family_id, display_name, avatar_path) values (%L, 'Baby', %L)$$, :'fam', :'fam' || '/b.jpg')),
                1, 'new member with a photo');
select tests.eq(tests.affected(format($$update members set avatar_path = null where id = %L$$, :'m_leo')), 1, 'parent removes it');

select tests.login(:'emma');
select tests.throws(format($$update members set avatar_path = %L where id = %L$$, :'fam2' || '/emma.jpg', :'m_emma'),
                    'that photo isn''t in this family''s folder', 'kid can''t point elsewhere either');
select tests.eq(tests.affected(format($$update members set avatar_path = %L where id = %L$$, :'fam' || '/leo-1.jpg', :'m_leo')),
                0, 'kid can''t set a sibling''s photo');

-- ───────────────────────── The files ─────────────────────────

select tests.login(:'mom');
select tests.eq(tests.affected(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'fam' || '/leo-1.jpg')),
                1, 'parent uploads into the family folder');
select tests.eq(tests.affected(format($$update storage.objects set metadata = '{"size": 1}' where name = %L$$, :'fam' || '/leo-1.jpg')),
                1, 'parent replaces it');
select tests.eq(tests.affected(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'mom' || '/avatar.jpg')),
                1, 'her own profile photo still works');
select tests.throws(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'fam' || '/a/b.jpg'),
                    '%row-level security%', 'no nested folders');
select tests.throws(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'fam' || '/'),
                    '%row-level security%', 'needs a file name');
select tests.throws(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'fam2' || '/x.jpg'),
                    '%row-level security%', 'not into another family''s folder');
select tests.throws(format($$update storage.objects set name = %L where name = %L$$, :'dad' || '/avatar.jpg', :'fam' || '/leo-1.jpg'),
                    '%row-level security%', 'can''t move it into someone''s profile folder');

select tests.login(:'dad');
select tests.eq(tests.affected(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'fam' || '/baby.jpg')),
                1, 'the other parent uploads too');
select tests.eq(tests.affected(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'dad' || '/avatar.jpg')),
                1, 'dad''s profile photo');

select tests.login(:'emma');
select tests.throws(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'fam' || '/emma.jpg'),
                    '%row-level security%', 'kid can''t upload member photos');
select tests.eq(tests.affected(format($$delete from storage.objects where name = %L$$, :'fam' || '/leo-1.jpg')), 0,
                'kid can''t delete one');
select tests.eq((select array_agg(name order by name) from storage.objects where name like :'fam' || '/%'),
                array[:'fam' || '/baby.jpg', :'fam' || '/leo-1.jpg']::text[], 'kid sees the family''s member photos');

select tests.login(:'device');
select tests.throws(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'fam' || '/d.jpg'),
                    '%row-level security%', 'display can''t upload');
select tests.eq((select count(*)::int from storage.objects where name like :'fam' || '/%'), 2, 'display sees them');

select tests.login(:'stranger');
select tests.throws(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'fam' || '/s.jpg'),
                    '%row-level security%', 'stranger can''t upload');
select tests.eq((select count(*)::int from storage.objects where name like :'fam' || '/%'), 0, 'stranger sees none');
select tests.eq(tests.affected(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'fam2' || '/s.jpg')),
                1, 'a parent of the other family uses their own folder');

select tests.login(:'mom');
select tests.eq(tests.affected(format($$delete from storage.objects where name = %L$$, :'dad' || '/avatar.jpg')), 0,
                'parent can''t delete the other parent''s profile photo');
select tests.eq(tests.affected(format($$delete from storage.objects where name = %L$$, :'fam' || '/baby.jpg')), 1,
                'parent deletes a member photo');
select tests.eq((select count(*)::int from storage.objects where name like :'fam2' || '/%'), 0, 'not the other family''s');

-- Suspended: nothing in or out.
select tests.logout();
update families set status = 'suspended' where id = :'fam';
select tests.login(:'mom');
select tests.throws(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'fam' || '/later.jpg'),
                    '%row-level security%', 'suspended: no uploads');
select tests.login(:'emma');
select tests.eq((select count(*)::int from storage.objects where name like :'fam' || '/%'), 0, 'suspended: no member photos');
select tests.logout();
update families set status = 'active' where id = :'fam';

-- ───────────────────────── Moving a member ─────────────────────────

-- A parent of both families moves an account-less member; their photo path
-- stays behind, and they can still be edited.
select tests.logout();
insert into members (family_id, user_id, display_name, role) values (:'fam2', :'mom', 'Mom', 'parent');
update members set avatar_path = :'fam' || '/leo-1.jpg' where id = :'m_leo';
select tests.login(:'mom');
select tests.eq(tests.affected(format($$update members set family_id = %L where id = %L$$, :'fam2', :'m_leo')), 1, 'moved');
select tests.eq(tests.affected(format($$update members set display_name = 'Leonardo' where id = %L$$, :'m_leo')), 1,
                'still editable');
select tests.throws(format($$update members set avatar_path = %L where id = %L$$, :'fam' || '/leo-2.jpg', :'m_leo'),
                    'that photo isn''t in this family''s folder', 'a new photo goes in the new family''s folder');
select tests.logout();
