-- media_items.file_store: videos may live in Vercel Blob; photos may not.
\set ON_ERROR_STOP 1
\set fam     '00000000-0000-0000-0000-00000000f001'
\set m_mom   '00000000-0000-0000-0000-00000000a001'
\set mom     'a0000000-0000-0000-0000-000000000001'
\set stranger 'e0000000-0000-0000-0000-000000000001'

insert into auth.users (id, email, raw_app_meta_data) values
  (:'mom', 'mom@example.com', '{}'),
  (:'stranger', 'stranger@example.com', '{}');
update members set user_id = :'mom' where id = :'m_mom';

insert into media_items (family_id, storage_path, kind)
values (:'fam', :'fam' || '/old.jpg', 'photo');
select tests.eq(
  (select file_store from media_items where storage_path = :'fam' || '/old.jpg'),
  'supabase',
  'existing files stay in supabase');

select tests.throws(
  format($$insert into media_items (family_id, storage_path, kind, file_store) values (%L, %L, 'photo', 'blob')$$,
         :'fam', :'fam' || '/nope.jpg'),
  '%media_items_blob_is_video%',
  'a photo cannot live in blob');

select tests.throws(
  format($$insert into media_items (family_id, storage_path, kind, file_store) values (%L, %L, 'video', 's3')$$,
         :'fam', :'fam' || '/nope.mp4'),
  '%media_items_file_store_check%',
  'unknown store rejected');

select tests.login(:'mom');
select tests.eq(
  tests.affected(format(
    $$insert into media_items (family_id, storage_path, kind, file_store) values (%L, %L, 'video', 'blob')$$,
    :'fam', :'fam' || '/clip.mp4')),
  1,
  'a member records a blob video');

select tests.login(:'stranger');
select tests.throws(
  format($$insert into media_items (family_id, storage_path, kind, file_store) values (%L, %L, 'video', 'blob')$$,
         :'fam', :'fam' || '/stolen.mp4'),
  '%row-level security%',
  'a stranger cannot insert a blob video');
