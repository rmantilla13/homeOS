-- Server-made wall copies (20261013000001_video_processing): what a member
-- may set, and the job functions the media-jobs edge function calls with
-- the service role.
\set ON_ERROR_STOP 1
\set fam      '00000000-0000-0000-0000-00000000f001'
\set m_mom    '00000000-0000-0000-0000-00000000a001'
\set mom      'a0000000-0000-0000-0000-000000000001'
\set v1       '0d1d0000-0000-4000-8000-000000000001'
\set v2       '0d1d0000-0000-4000-8000-000000000002'
\set v3       '0d1d0000-0000-4000-8000-000000000003'
\set v4       '0d1d0000-0000-4000-8000-000000000004'
\set done     '0d1d0000-0000-4000-8000-000000000005'
\set pic      '0d1d0000-0000-4000-8000-000000000006'
\set old      '0d1d0000-0000-4000-8000-000000000007'

insert into auth.users (id, email, raw_app_meta_data) values (:'mom', 'mom@example.com', '{}');
update members set user_id = :'mom' where id = :'m_mom';

-- ───────────────────────────── Members ─────────────────────────────

select tests.login(:'mom');
select tests.eq(tests.affected(format(
  $$insert into media_items (id, family_id, storage_path, kind, byte_size, content_type, file_store, processing, created_at)
    values (%L, %L, %L, 'video', 500000000, 'video/quicktime', 'blob', 'pending', now() - interval '3 minutes')$$,
  :'v1', :'fam', :'fam' || '/' || :'v1' || '.mov')), 1, 'the phone records an original as pending');
select tests.eq(tests.affected(format(
  $$insert into media_items (id, family_id, storage_path, kind, byte_size, content_type, file_store, processing)
    values (%L, %L, %L, 'video', 40000000, 'video/mp4', 'blob', 'done')$$,
  :'done', :'fam', :'fam' || '/' || :'done' || '.mp4')), 1, 'and an optimized video as done');
select tests.eq(tests.affected(format(
  $$insert into media_items (id, family_id, storage_path, kind, byte_size, content_type, file_store, created_at)
    values (%L, %L, %L, 'video', 30000000, 'video/quicktime', 'blob', now() - interval '1 day')$$,
  :'old', :'fam', :'fam' || '/' || :'old' || '.mov')), 1, 'an older app sends no processing at all');
select tests.eq(tests.affected(format(
  $$insert into media_items (id, family_id, storage_path, kind, byte_size, content_type, file_store)
    values (%L, %L, %L, 'photo', 1000, 'image/jpeg', 'blob')$$,
  :'pic', :'fam', :'fam' || '/' || :'pic' || '.jpg')), 1, 'photos leave it null');

select tests.throws(format(
  $$insert into media_items (family_id, storage_path, kind, byte_size, content_type, file_store, processing)
    values (%L, %L, 'video', 10, 'video/mp4', 'blob', 'processing')$$, :'fam', :'fam' || '/x.mp4'),
  'a new video starts as pending or done', 'a member cannot start a row as processing');
select tests.throws(format(
  $$insert into media_items (family_id, storage_path, kind, byte_size, content_type, file_store, processing)
    values (%L, %L, 'video', 10, 'video/mp4', 'blob', 'failed')$$, :'fam', :'fam' || '/y.mp4'),
  'a new video starts as pending or done', 'or as failed');
select tests.throws(format(
  $$insert into media_items (family_id, storage_path, kind, byte_size, content_type, file_store, processing)
    values (%L, %L, 'photo', 10, 'image/jpeg', 'blob', 'pending')$$, :'fam', :'fam' || '/z.jpg'),
  '%media_items_processing_check%', 'a photo has no processing state');
select tests.throws(format(
  $$insert into media_items (family_id, storage_path, kind, byte_size, content_type, file_store, processing)
    values (%L, %L, 'video', 10, 'video/mp4', 'blob', 'sideways')$$, :'fam', :'fam' || '/w.mp4'),
  '%', 'an unknown state is refused');

select tests.throws(format($$update media_items set processing = 'done' where id = %L$$, :'v1'),
  'only a caption or the frame can be changed', 'a member cannot mark a row done later');
select tests.throws(format($$update media_items set processing = null where id = %L$$, :'done'),
  'only a caption or the frame can be changed', 'or clear it');
select tests.eq(tests.affected(format($$update media_items set caption = 'Beach' where id = %L$$, :'v1')),
  1, 'the caption still changes');
select tests.eq((select processing from media_items where id = :'v1'), 'pending', 'a member reads the state');

select tests.throws($$select * from media_jobs$$, '%permission denied%', 'a member cannot read media_jobs');
select tests.throws(format($$select * from media_job_claim(%L)$$, :'v1'),
  '%permission denied%', 'a member cannot claim a job');
select tests.throws(format($$select media_job_finish(%L, 1)$$, :'v1'),
  '%permission denied%', 'or finish one');
select tests.logout();

-- ───────────────────────────── Claim ─────────────────────────────

select tests.login_service();
-- The phone asks for its own video.
create temp table c1 as select * from media_job_claim(:'v1');
select tests.eq((select count(*)::int from c1), 1, 'the asked-for video is claimed');
select tests.eq((select attempt from c1), 1, 'first attempt');
select tests.eq((select storage_path from c1), :'fam' || '/' || :'v1' || '.mov', 'with its path');
select tests.eq((select byte_size from c1), 500000000::bigint, 'and its size');
select tests.eq((select processing from media_items where id = :'v1'), 'processing', 'the row is processing');
select tests.eq((select count(*)::int from media_job_claim(:'v1')), 0, 'a running job is not claimed twice');
select tests.eq((select count(*)::int from media_job_claim(:'done')), 0, 'a done video is never claimed');
select tests.eq((select count(*)::int from media_job_claim(:'pic')), 0, 'nor a photo');

-- The sweep: one more slot (two run at once), the null row from the older app.
create temp table c2 as select * from media_job_claim(null, 5);
select tests.eq((select count(*)::int from c2), 1, 'at most two jobs run at once');
select tests.eq((select media_id from c2), :'old'::uuid, 'the sweep takes the unknown row');
select tests.eq((select count(*)::int from media_job_claim(null, 5)), 0, 'no slot left');
select tests.eq((select count(*)::int from media_job_claim(null, 5, 3)), 0, 'nothing else to claim');

-- Pending rows come before unknown ones.
select tests.logout();
insert into media_items (id, family_id, storage_path, kind, byte_size, content_type, file_store, processing, created_at)
values (:'v2', :'fam', :'fam' || '/' || :'v2' || '.mov', 'video', 9000, 'video/quicktime', 'blob', null, now()),
       (:'v3', :'fam', :'fam' || '/' || :'v3' || '.mov', 'video', 9000, 'video/quicktime', 'blob', 'pending', now() - interval '2 days');
select tests.login_service();
select tests.eq((select media_id from media_job_claim(null, 1, 3)), :'v3'::uuid, 'pending goes first');

-- ───────────────────────────── Finish ─────────────────────────────

select tests.throws(format($$select media_job_finish(%L, 2, %L, 1000)$$, :'v1', :'fam' || '/' || :'v1' || '-wall.mp4'),
  'that job is not running', 'a stale attempt is refused');
select tests.throws(format($$select media_job_finish(%L, 1, %L, 1000)$$, :'v1', :'fam' || '/' || :'v2' || '-wall.mp4'),
  'the copy must be %', 'the copy must be this video''s -wall.mp4');
select tests.throws(format($$select media_job_finish(%L, 1, %L, 1000)$$, :'v1', :'fam' || '/' || :'v1' || '.mp4'),
  'the copy must be %', 'not some other name');
select tests.throws(format($$select media_job_finish(%L, 1, %L, 501048577)$$, :'v1', :'fam' || '/' || :'v1' || '-wall.mp4'),
  'the copy can''t be bigger than the original', 'a copy more than 1 MiB bigger than the original is refused');
select tests.throws(format($$select media_job_finish(%L, 1, %L, 0)$$, :'v1', :'fam' || '/' || :'v1' || '-wall.mp4'),
  'the copy can''t be bigger than the original', 'an empty copy is refused');
select tests.throws(format($$select media_job_finish(%L, 1, %L, 1000, null, null, %L)$$,
  :'v1', :'fam' || '/' || :'v1' || '-wall.mp4', :'fam' || '/' || :'v2' || '-thumb.jpg'),
  'the poster must be %', 'the poster must be this video''s');

select tests.eq((select media_job_finish(:'v1', 1, :'fam' || '/' || :'v1' || '-wall.mp4', 42000000, 1920, 1080,
                                         :'fam' || '/' || :'v1' || '-thumb.jpg')->>'replaced_path'),
  :'fam' || '/' || :'v1' || '.mov', 'finish answers the original''s path');
select tests.eq((select storage_path from media_items where id = :'v1'), :'fam' || '/' || :'v1' || '-wall.mp4',
  'the row moved to the copy');
select tests.eq((select byte_size from media_items where id = :'v1'), 42000000::bigint, 'with the copy''s size');
select tests.eq((select content_type from media_items where id = :'v1'), 'video/mp4', 'as an MP4');
select tests.eq((select width || 'x' || height from media_items where id = :'v1'), '1920x1080', 'and its dimensions');
select tests.eq((select thumbnail_path from media_items where id = :'v1'), :'fam' || '/' || :'v1' || '-thumb.jpg',
  'a row without a poster gets one');
select tests.eq((select processing from media_items where id = :'v1'), 'done', 'the row is done');
select tests.eq((select caption from media_items where id = :'v1'), 'Beach', 'the caption survives the swap');
select tests.eq((select replaced_path from media_jobs where media_id = :'v1'), :'fam' || '/' || :'v1' || '.mov',
  'the original waits for the sweep');
select tests.throws(format($$select media_job_finish(%L, 1, %L, 1000)$$, :'v1', :'fam' || '/' || :'v1' || '-wall.mp4'),
  'that job is not running', 'a second callback is refused');

-- Already fine as it was: the row stays on its file.
select tests.eq((select media_job_finish(:'old', 1)->>'storage_path'), :'fam' || '/' || :'old' || '.mov',
  'a video that already fits stays on its file');
select tests.eq((select processing from media_items where id = :'old'), 'done', 'and is done');
select tests.eq((select replaced_path from media_jobs where media_id = :'old'), null::text, 'nothing to delete');

-- The family is billed for what is stored now.
select tests.logout();
select tests.eq(public.family_storage_bytes(:'fam'::uuid), (42000000 + 40000000 + 30000000 + 1000 + 9000 + 9000)::bigint,
  'the quota counts the copy, not the original');

-- ───────────────────────────── Fail ─────────────────────────────

select tests.login_service();
select tests.eq(media_job_fail(:'v3', 2, 'nope'), null::text, 'a stale attempt can''t fail the job');
select tests.eq(media_job_fail(:'v3', 1, 'ffmpeg exited 1'), 'pending', 'a failure goes back to pending');
select tests.eq((select error from media_jobs where media_id = :'v3'), 'ffmpeg exited 1', 'with the reason');
select tests.eq((select attempt from media_job_claim(:'v3', 1, 3)), 2, 'the next try is attempt 2');
select tests.eq(media_job_fail(:'v3', 2, 'again'), 'pending', 'still another try left');
select tests.eq((select attempt from media_job_claim(:'v3', 1, 3)), 3, 'attempt 3');
select tests.eq(media_job_fail(:'v3', 3, 'third time'), 'failed', 'three failures and it stops');
select tests.eq((select processing from media_items where id = :'v3'), 'failed', 'the row is failed');
select tests.eq((select count(*)::int from media_job_claim(:'v3', 1, 3)), 0, 'a failed row is not claimed again');

select tests.eq((select attempt from media_job_claim(:'v2', 1, 3)), 1, 'v2 starts');
select tests.eq(media_job_fail(:'v2', 1, 'not a video', false), 'failed', 'a failure without retry is final');

-- A job that never reported back is taken again after p_stale_after.
select tests.logout();
insert into media_items (id, family_id, storage_path, kind, byte_size, content_type, file_store, processing)
values (:'v4', :'fam', :'fam' || '/' || :'v4' || '.mov', 'video', 9000, 'video/quicktime', 'blob', 'pending');
select tests.login_service();
select tests.eq((select attempt from media_job_claim(:'v4', 1, 3)), 1, 'v4 starts');
select tests.eq((select count(*)::int from media_job_claim(:'v4', 1, 3)), 0, 'not stale yet');
select tests.logout();
update media_jobs set started_at = now() - interval '2 hours' where media_id = :'v4';
select tests.login_service();
select tests.eq((select attempt from media_job_claim(:'v4', 1, 3)), 2, 'a stale job is taken again');
select tests.logout();
update media_jobs set started_at = now() - interval '2 hours', attempts = 3 where media_id = :'v4';
select tests.login_service();
select tests.eq((select count(*)::int from media_job_claim(null, 5, 3)), 0, 'out of attempts, nothing is claimed');
select tests.eq((select processing from media_items where id = :'v4'), 'failed', 'and the stale row is failed');
select tests.eq((select error from media_jobs where media_id = :'v4'), 'timed out', 'as timed out');

-- ───────────────────────────── Originals ─────────────────────────────

select tests.eq((select count(*)::int from media_job_replaced_due()), 0, 'an original is kept for six hours');
select tests.logout();
update media_jobs set finished_at = now() - interval '7 hours' where media_id = :'v1';
select tests.login_service();
select tests.eq((select replaced_path from media_job_replaced_due()), :'fam' || '/' || :'v1' || '.mov',
  'then it is due');
select tests.eq(media_job_replaced_cleared(:'v1', 'something/else.mov'), false, 'only the recorded path clears');
select tests.eq(media_job_replaced_cleared(:'v1', :'fam' || '/' || :'v1' || '.mov'), true, 'clearing it');
select tests.eq((select count(*)::int from media_job_replaced_due()), 0, 'nothing left to delete');

-- Deleting the row takes its job with it.
select tests.logout();
delete from media_items where id = :'v1';
select tests.eq((select count(*)::int from media_jobs where media_id = :'v1'), 0, 'the job goes with the row');

-- ───────────────────────────── Again ─────────────────────────────

-- Safe to run again: the states, the jobs and the guard stay as they were.
\ir ../supabase/migrations/20261013000001_video_processing.sql
select tests.eq((select processing from media_items where id = :'v3'), 'failed', 'a re-run keeps the states');
select tests.eq((select attempts from media_jobs where media_id = :'v3'), 3, 'and the jobs');
select tests.eq((select count(*)::int from pg_trigger where tgname = 'media_items_processing_guard'), 1, 'one guard trigger');
select tests.login(:'mom');
select tests.throws(format($$update media_items set processing = 'pending' where id = %L$$, :'v3'),
  'only a caption or the frame can be changed', 'the guard still holds after a re-run');
select tests.logout();
