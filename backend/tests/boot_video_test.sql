-- The platform boot video: one private object every display may read, and
-- nobody but the service role may write or see the row (it names the admin).
-- Applied on stub_storage.sql.
\set ON_ERROR_STOP 1
\set device  'd0000000-0000-0000-0000-000000000001'
\set mom     'a0000000-0000-0000-0000-000000000001'

insert into auth.users (id, email, raw_app_meta_data) values
  (:'mom', 'mom@example.com', '{}'),
  (:'device', 'device@devices.homeos.invalid', '{"kind": "device"}');

select tests.eq((select public from storage.buckets where id = 'boot-video'), false, 'boot-video bucket is private');
select tests.eq((select file_size_limit from storage.buckets where id = 'boot-video'), 20971520::bigint, 'boot video capped at 20 MB');
select tests.ok((select allowed_mime_types = array['video/mp4']::text[] from storage.buckets where id = 'boot-video'), 'boot video is mp4 only');

select tests.login(null);
select tests.throws($$select count(*) from platform_boot_video$$, 'permission denied%', 'anon cannot read the boot video row');
select tests.throws(
  $$insert into platform_boot_video (byte_size, duration_ms) values (1000, 1000)$$,
  'permission denied%', 'anon cannot set the boot video');
select tests.login(:'device');
select tests.throws(
  $$insert into platform_boot_video (byte_size, duration_ms) values (1000, 1000)$$,
  'permission denied%', 'display cannot set the boot video');
select tests.login(:'mom');
select tests.throws(
  $$insert into platform_boot_video (byte_size, duration_ms) values (1000, 1000)$$,
  'permission denied%', 'a parent cannot set the boot video');

select tests.login_service();
insert into platform_boot_video (byte_size, duration_ms) values (12000, 6000);
select tests.throws(
  $$update platform_boot_video set byte_size = 20971521$$,
  '%byte_size%', 'the row rejects a file over 20 MB');
select tests.throws(
  $$update platform_boot_video set duration_ms = 13000$$,
  '%duration_ms%', 'the row rejects a video longer than 12 seconds');
select tests.logout();

select tests.login(null);
select tests.throws($$select updated_by from platform_boot_video$$, 'permission denied%', 'anon cannot see who set the boot video');
select tests.throws($$delete from platform_boot_video$$, 'permission denied%', 'anon cannot remove the boot video');
select tests.login(:'device');
select tests.throws($$select byte_size from platform_boot_video$$, 'permission denied%', 'display cannot read the boot video row');
select tests.login(:'mom');
select tests.throws($$select byte_size from platform_boot_video$$, 'permission denied%', 'a parent cannot read the boot video row');
select tests.login(:'device');
select tests.throws(
  $$update platform_boot_video set duration_ms = 1000$$,
  'permission denied%', 'display cannot change the boot video');

-- Only current.mp4 is readable. A pending upload is not.
select tests.logout();
insert into storage.objects (bucket_id, name) values
  ('boot-video', 'current.mp4'),
  ('boot-video', 'pending/11111111-1111-4111-8111-111111111111.mp4');

select tests.login(null);
select tests.eq(
  (select array_agg(name order by name) from storage.objects where bucket_id = 'boot-video'),
  array['current.mp4']::text[], 'anon reads only the current boot video');
select tests.throws(
  $$insert into storage.objects (bucket_id, name) values ('boot-video', 'current.mp4')$$,
  '%row-level security%', 'anon cannot upload a boot video');
select tests.login(:'device');
select tests.eq((select count(*)::int from storage.objects where bucket_id = 'boot-video'), 1, 'display reads the current boot video');
select tests.throws(
  $$insert into storage.objects (bucket_id, name) values ('boot-video', 'other.mp4')$$,
  '%row-level security%', 'display cannot upload a boot video');
select tests.eq(tests.affected($$delete from storage.objects where bucket_id = 'boot-video'$$), 0, 'display cannot delete the boot video');
select tests.login(:'mom');
select tests.eq(tests.affected($$delete from storage.objects where bucket_id = 'boot-video'$$), 0, 'a parent cannot delete the boot video');
select tests.throws(
  $$insert into storage.objects (bucket_id, name, metadata) values ('boot-video', 'clip.mp4', '{"mimetype": "video/mp4"}')$$,
  '%row-level security%', 'a parent cannot upload a boot video');
select tests.logout();
select tests.eq((select count(*)::int from storage.objects where bucket_id = 'boot-video'), 2, 'service role still sees the pending upload');

-- Safe to run again, for a copy pasted into the SQL editor before the push.
-- That older copy let anon read the row; a re-run takes that back and keeps
-- the video, the bucket and the object policy.
grant select on table public.platform_boot_video to anon, authenticated;
create policy platform_boot_video_read on public.platform_boot_video
  for select to anon, authenticated using (true);
\ir ../supabase/migrations/20261008000004_boot_video.sql
\ir ../supabase/migrations/20261008000004_boot_video.sql
select tests.eq((select duration_ms from platform_boot_video), 6000, 'a re-run keeps the boot video row');
select tests.eq(
  (select count(*)::int from pg_policies where tablename = 'platform_boot_video'), 0,
  'a re-run drops the old read policy');
select tests.eq(
  (select count(*)::int from pg_policies where schemaname = 'storage' and policyname = 'boot video read'), 1,
  'a re-run keeps one object read policy');
select tests.eq((select public from storage.buckets where id = 'boot-video'), false, 'the bucket stays private after a re-run');
select tests.login(null);
select tests.throws($$select byte_size from platform_boot_video$$, 'permission denied%', 'anon cannot read the row after a re-run');
select tests.eq(
  (select array_agg(name order by name) from storage.objects where bucket_id = 'boot-video'),
  array['current.mp4']::text[], 'anon still reads the current boot video after a re-run');
select tests.logout();
