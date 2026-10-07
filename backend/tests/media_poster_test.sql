-- Blob posters as the phone records them: `<family_id>/<id>-thumb.jpg` next
-- to `<family_id>/<id>.<ext>`, set when the row is inserted. No migration
-- backs this; it pins what the schema already does for the media API.
\set ON_ERROR_STOP 1
\set fam      '00000000-0000-0000-0000-00000000f001'
\set fam2     '00000000-0000-0000-0000-00000000f002'
\set m_mom    '00000000-0000-0000-0000-00000000a001'
\set mom      'a0000000-0000-0000-0000-000000000001'
\set stranger 'e0000000-0000-0000-0000-000000000001'
\set vid      '0c1d0000-0000-4000-8000-000000000001'
\set pic      '0c1d0000-0000-4000-8000-000000000002'
\set big      '0c1d0000-0000-4000-8000-000000000003'
\set bare     '0c1d0000-0000-4000-8000-000000000004'
\set tight    '0c1d0000-0000-4000-8000-000000000005'

insert into auth.users (id, email, raw_app_meta_data) values
  (:'mom', 'mom@example.com', '{}'),
  (:'stranger', 'stranger@example.com', '{}');
update members set user_id = :'mom' where id = :'m_mom';
insert into families (id, name) values (:'fam2', 'Other House');
select media_max_bytes as max_bytes from platform_settings \gset

-- ───────────────────────────── Insert ─────────────────────────────

select tests.login(:'mom');
select tests.eq(tests.affected(format(
  $$insert into media_items (id, family_id, storage_path, thumbnail_path, kind, byte_size, content_type, file_store, uploaded_by)
    values (%L, %L, %L, %L, 'video', 123456789, 'video/mp4', 'blob', %L)$$,
  :'vid', :'fam', :'fam' || '/' || :'vid' || '.mp4', :'fam' || '/' || :'vid' || '-thumb.jpg', :'m_mom')),
  1, 'a Blob video lands with its poster');
select tests.eq(tests.affected(format(
  $$insert into media_items (id, family_id, storage_path, thumbnail_path, kind, byte_size, content_type, file_store, uploaded_by)
    values (%L, %L, %L, %L, 'photo', 1500000, 'image/jpeg', 'blob', %L)$$,
  :'pic', :'fam', :'fam' || '/' || :'pic' || '.jpg', :'fam' || '/' || :'pic' || '-thumb.jpg', :'m_mom')),
  1, 'a Blob photo lands with its poster');
select tests.eq((select thumbnail_path from media_items where id = :'vid'),
  :'fam' || '/' || :'vid' || '-thumb.jpg', 'the member reads the poster back');

-- Older apps and failed poster PUTs insert without one.
select tests.eq(tests.affected(format(
  $$insert into media_items (id, family_id, storage_path, kind, byte_size, content_type, file_store)
    values (%L, %L, %L, 'video', 2000, 'video/quicktime', 'blob')$$,
  :'bare', :'fam', :'fam' || '/' || :'bare' || '.mov')),
  1, 'a Blob row without a poster still lands');

select tests.throws(format(
  $$insert into media_items (family_id, storage_path, thumbnail_path, kind, byte_size, content_type, file_store)
    values (%L, %L, %L, 'photo', 10, 'image/jpeg', 'blob')$$,
  :'fam', :'fam' || '/x.jpg', :'fam2' || '/x-thumb.jpg'),
  '%media_items_thumb_in_family%', 'a poster in another family''s folder is refused');
select tests.throws(format(
  $$insert into media_items (family_id, storage_path, thumbnail_path, kind, byte_size, content_type, file_store)
    values (%L, %L, %L, 'photo', 10, 'image/jpeg', 'blob')$$,
  :'fam', :'fam' || '/y.jpg', :'fam' || '/y.jpg'),
  '%media_items_thumb_in_family%', 'a poster is a different object from the file');

-- ───────────────────────────── Frozen ─────────────────────────────

-- The guard freezes thumbnail_path for signed-in clients, so the phone has
-- to set it in the insert.
select tests.throws(format($$update media_items set thumbnail_path = null where id = %L$$, :'vid'),
  'only a caption or the frame can be changed', 'a member cannot clear the poster');
select tests.throws(format($$update media_items set thumbnail_path = %L where id = %L$$,
  :'fam' || '/' || :'pic' || '-thumb.jpg', :'vid'),
  'only a caption or the frame can be changed', 'a member cannot swap the poster');
select tests.throws(format($$update media_items set thumbnail_path = %L where id = %L$$,
  :'fam' || '/' || :'bare' || '-thumb.jpg', :'bare'),
  'only a caption or the frame can be changed', 'a member cannot add a poster later');
select tests.eq(tests.affected(format($$update media_items set caption = 'Beach', show_on_frame = false where id = %L$$, :'vid')),
  1, 'caption and frame flag still change');

select tests.login(:'stranger');
select tests.eq(tests.affected(format($$update media_items set thumbnail_path = null where id = %L$$, :'vid')),
  0, 'a stranger cannot see the row');

-- ───────────────────────────── Bytes ─────────────────────────────

-- byte_size is whatever the phone sent for the file. The poster is not
-- added, so it never trips the per-file cap or the family quota.
select tests.login(:'mom');
select tests.eq(tests.affected(format(
  $$insert into media_items (id, family_id, storage_path, thumbnail_path, kind, byte_size, content_type, file_store)
    values (%L, %L, %L, %L, 'video', %s, 'video/mp4', 'blob')$$,
  :'big', :'fam', :'fam' || '/' || :'big' || '.mp4', :'fam' || '/' || :'big' || '-thumb.jpg', :'max_bytes')),
  1, 'a file at the per-file cap still lands with its poster');
select tests.eq((select byte_size from media_items where id = :'vid'), 123456789::bigint, 'the row keeps the file''s size');

select tests.logout();
select tests.eq(public.family_storage_bytes(:'fam'::uuid), (123456789 + 1500000 + 2000 + :max_bytes)::bigint,
  'posters are not billed');

-- Room for exactly one more 1000-byte file.
update families set storage_limit_bytes = public.family_storage_bytes(:'fam'::uuid) + 1000 where id = :'fam';
select tests.login(:'mom');
select tests.eq(tests.affected(format(
  $$insert into media_items (id, family_id, storage_path, thumbnail_path, kind, byte_size, content_type, file_store)
    values (%L, %L, %L, %L, 'photo', 1000, 'image/jpeg', 'blob')$$,
  :'tight', :'fam', :'fam' || '/' || :'tight' || '.jpg', :'fam' || '/' || :'tight' || '-thumb.jpg')),
  1, 'a poster doesn''t count against the family quota');
select tests.throws(format(
  $$insert into media_items (family_id, storage_path, kind, byte_size, content_type, file_store)
    values (%L, %L, 'photo', 1, 'image/jpeg', 'blob')$$, :'fam', :'fam' || '/over.jpg'),
  'storage limit reached', 'the quota itself still applies');
select tests.logout();
