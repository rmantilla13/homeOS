-- Supabase-only migrations (storage buckets and policies), applied on top of
-- stub_storage.sql: the `avatars` bucket and the `family-media` bucket.
\set ON_ERROR_STOP 1
\set fam    '00000000-0000-0000-0000-00000000f001'
\set m_mom  '00000000-0000-0000-0000-00000000a001'
\set m_dad  '00000000-0000-0000-0000-00000000a002'
\set mom      'a0000000-0000-0000-0000-000000000001'
\set dad      'a0000000-0000-0000-0000-000000000002'
\set device   'd0000000-0000-0000-0000-000000000001'
\set stranger 'e0000000-0000-0000-0000-000000000001'

insert into auth.users (id, email, raw_app_meta_data) values
  (:'mom', 'mom@example.com', '{}'), (:'dad', 'dad@example.com', '{}'),
  (:'device', 'device@devices.homeos.invalid', '{"kind": "device"}'), (:'stranger', 'stranger@example.com', '{}');
update members set user_id = :'mom' where id = :'m_mom';
update members set user_id = :'dad' where id = :'m_dad';
insert into devices (family_id, user_id) values (:'fam', :'device');

select tests.eq((select public from storage.buckets where id = 'avatars'), false, 'avatars bucket is private');
select tests.eq((select public from storage.buckets where id = 'family-media'), false, 'family-media bucket is private');

-- Avatars: write only into your own folder.
select tests.login(:'mom');
select tests.eq(tests.affected(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'mom' || '/avatar.jpg')), 1, 'mom uploads her avatar');
select tests.throws(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'dad' || '/avatar.jpg'), '%row-level security%', 'not into dad''s folder');
select tests.throws($$insert into storage.objects (bucket_id, name) values ('avatars', 'avatar.jpg')$$, '%row-level security%', 'not at the root');
select tests.eq(tests.affected(format($$update storage.objects set metadata = '{"size": 1}' where name = %L$$, :'mom' || '/avatar.jpg')), 1, 'mom replaces her avatar');
select tests.throws(format($$update storage.objects set name = %L where name = %L$$, :'dad' || '/avatar.jpg', :'mom' || '/avatar.jpg'), '%row-level security%', 'cannot move it into dad''s folder');
select tests.login(:'dad');
select tests.eq(tests.affected(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'dad' || '/avatar.jpg')), 1, 'dad uploads his avatar');
select tests.login(:'stranger');
select tests.eq(tests.affected(format($$insert into storage.objects (bucket_id, name) values ('avatars', %L)$$, :'stranger' || '/me.png')), 1, 'stranger uploads too');
-- Odd paths elsewhere must not break the avatar check.
select tests.logout();
insert into storage.buckets (id, name) values ('other', 'other');
insert into storage.objects (bucket_id, name) values ('avatars', 'junk/file.png'), ('other', 'not-a-uuid/y'), ('other', 'plain');

-- Reads: yourself and people who share a family with you.
select tests.login(:'dad');
select tests.eq((select array_agg(name order by name) from storage.objects where bucket_id = 'avatars'),
                array[:'mom' || '/avatar.jpg', :'dad' || '/avatar.jpg']::text[], 'dad sees his and mom''s avatars');
select tests.eq(tests.affected(format($$update storage.objects set metadata = '{}' where name = %L$$, :'mom' || '/avatar.jpg')), 0, 'dad cannot change mom''s avatar');
select tests.eq(tests.affected(format($$delete from storage.objects where name = %L$$, :'mom' || '/avatar.jpg')), 0, 'dad cannot delete mom''s avatar');
select tests.login(:'stranger');
select tests.eq((select array_agg(name) from storage.objects where bucket_id = 'avatars'), array[:'stranger' || '/me.png']::text[], 'stranger sees only their own');
select tests.login(null);
select tests.eq((select count(*)::int from storage.objects), 0, 'anon sees nothing');
select tests.login(:'mom');
select tests.eq(tests.affected(format($$delete from storage.objects where name = %L$$, :'mom' || '/avatar.jpg')), 1, 'mom deletes her avatar');

-- Suspended family: no more shared avatars.
select tests.logout();
update families set status = 'suspended' where id = :'fam';
select tests.login(:'mom');
select tests.eq((select count(*)::int from storage.objects where bucket_id = 'avatars'), 0, 'suspended: dad''s avatar hidden');
select tests.logout();
update families set status = 'active' where id = :'fam';

-- family-media (20261006000002) still follows family membership.
select tests.login(:'device');
select tests.eq(tests.affected(format($$insert into storage.objects (bucket_id, name) values ('family-media', %L)$$, :'fam' || '/1.jpg')), 1, 'display uploads a photo');
select tests.login(:'stranger');
select tests.eq((select count(*)::int from storage.objects where bucket_id = 'family-media'), 0, 'stranger sees no photos');
select tests.throws(format($$insert into storage.objects (bucket_id, name) values ('family-media', %L)$$, :'fam' || '/2.jpg'), '%row-level security%', 'stranger cannot upload');
select tests.login(:'mom');
select tests.eq((select count(*)::int from storage.objects where bucket_id = 'family-media'), 1, 'mom sees the photo');
select tests.logout();
