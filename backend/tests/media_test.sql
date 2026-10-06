-- Media quotas, path binding, and the admin RPCs that list and remove media.
\set ON_ERROR_STOP 1
\set fam     '00000000-0000-0000-0000-00000000f001'
\set fam2    '00000000-0000-0000-0000-00000000f002'
\set m_mom   '00000000-0000-0000-0000-00000000a001'
\set m_other '00000000-0000-0000-0000-00000000b001'
\set mom     'a0000000-0000-0000-0000-000000000001'
\set admin   'ad000000-0000-0000-0000-000000000001'

insert into auth.users (id, email) values (:'mom', 'mom@example.com'), (:'admin', 'admin@example.com');
update members set user_id = :'mom' where id = :'m_mom';
insert into platform_admins (user_id) values (:'admin');
insert into families (id, name) values (:'fam2', 'Other House');
insert into members (id, family_id, display_name, role) values (:'m_other', :'fam2', 'Neighbor', 'child');

-- ───────────────────────────── Uploads ─────────────────────────────

select tests.login(:'mom');
select tests.throws(format(
  $$insert into media_items (family_id, storage_path, kind, byte_size, content_type)
    values (%L, %L, 'photo', 100, 'image/jpeg')$$, :'fam', :'fam2' || '/secret.jpg'),
  '%media_items_path_in_family%', 'a row cannot point at another family''s file');
select tests.throws(format(
  $$insert into media_items (family_id, storage_path, kind, byte_size, content_type)
    values (%L, %L, 'photo', 100, 'image/jpeg')$$, :'fam', :'fam' || '/nested/a.jpg'),
  '%media_items_path_in_family%', 'one folder deep');
select tests.throws(format(
  $$insert into media_items (family_id, storage_path, kind, byte_size, content_type)
    values (%L, %L, 'photo', 100, 'text/html')$$, :'fam', :'fam' || '/page.html'),
  'file type not allowed', 'html is not media');
select tests.throws(format(
  $$insert into media_items (family_id, storage_path, kind, byte_size, content_type, uploaded_by)
    values (%L, %L, 'photo', 100, 'image/jpeg', %L)$$, :'fam', :'fam' || '/who.jpg', :'m_other'),
  'that person isn''t in this family', 'uploader is in this family');

insert into media_items (id, family_id, storage_path, kind, byte_size, content_type, thumbnail_path, caption, uploaded_by)
values ('11111111-1111-1111-1111-111111111111', :'fam', :'fam' || '/picnic.jpg', 'photo', 400, 'image/jpeg',
        :'fam' || '/picnic-thumb.jpg', 'Picnic', :'m_mom');
select tests.eq(tests.affected($$update media_items set caption = 'The picnic', show_on_frame = false
                                where id = '11111111-1111-1111-1111-111111111111'$$),
                1, 'caption and frame flag can change');
select tests.throws($$update media_items set byte_size = 1 where id = '11111111-1111-1111-1111-111111111111'$$,
                    'only a caption or the frame can be changed', 'size is fixed at upload');
select tests.throws(format($$update media_items set storage_path = %L where id = '11111111-1111-1111-1111-111111111111'$$,
                           :'fam' || '/other.jpg'),
                    'only a caption or the frame can be changed', 'path is fixed at upload');
select tests.throws(format(
  $$insert into media_items (family_id, storage_path, thumbnail_path, kind, byte_size, content_type)
    values (%L, %L, %L, 'photo', 10, 'image/jpeg')$$,
  :'fam', :'fam' || '/same.jpg', :'fam' || '/same.jpg'),
  '%media_items_thumb_in_family%', 'thumbnail is a different object');

-- An older app omits byte_size. The row is allowed; it just doesn't add
-- bytes on this side (Storage counts the object when it exists).
select tests.eq(tests.affected(format(
  $$insert into media_items (family_id, storage_path, kind) values (%L, %L, 'photo')$$,
  :'fam', :'fam' || '/old.jpg')), 1, 'legacy upload without a size still lands');

-- ───────────────────────────── Quotas ─────────────────────────────

select tests.logout();
update families set storage_limit_bytes = 1000, media_item_limit = 3 where id = :'fam';
select tests.login(:'mom');
select tests.throws(format(
  $$insert into media_items (family_id, storage_path, kind, byte_size, content_type)
    values (%L, %L, 'photo', 700, 'image/jpeg')$$, :'fam', :'fam' || '/big.jpg'),
  'storage limit reached', 'row bytes count toward the quota');
select tests.throws(format(
  $$insert into media_items (family_id, storage_path, kind, byte_size, content_type)
    values (%L, %L, 'video', 536870913, 'video/mp4')$$, :'fam', :'fam' || '/huge.mp4'),
  'file is too large', 'one row cannot claim more than the per-file cap');
select tests.eq(tests.affected(format(
  $$insert into media_items (family_id, storage_path, kind, byte_size, content_type)
    values (%L, %L, 'photo', 100, 'image/jpeg')$$, :'fam', :'fam' || '/third.jpg')),
  1, 'under both limits');
-- picnic 400 + old null + third 100 = 2 counted rows with bytes, 3 rows total. Cap is 3.
select tests.throws(format(
  $$insert into media_items (family_id, storage_path, kind, byte_size, content_type)
    values (%L, %L, 'photo', 1, 'image/jpeg')$$, :'fam', :'fam' || '/fourth.jpg'),
  'media item limit reached', 'item cap');

select tests.throws(format($$update families set storage_limit_bytes = 999999999999 where id = %L$$, :'fam'),
                    'only a platform admin can change that', 'parent cannot raise the storage quota');
select tests.throws(format($$update families set media_item_limit = 1000000 where id = %L$$, :'fam'),
                    'only a platform admin can change that', 'parent cannot raise the item cap');

-- ───────────────────────────── Admin ─────────────────────────────

select tests.throws(format('select * from admin_list_media(%L)', :'fam'), 'admin only', 'parent cannot list media');
select tests.throws($$select admin_delete_media('11111111-1111-1111-1111-111111111111')$$, 'admin only', 'parent cannot delete media');
select tests.login(:'admin');

select tests.eq((select storage_bytes::int from admin_list_families() where id = :'fam'), 500, 'family storage is the summed sizes');
select tests.eq((select media_count from admin_list_families() where id = :'fam'), 3, 'family item count');
select tests.eq((select storage_limit_bytes from admin_list_families() where id = :'fam'), 1000::bigint, 'list shows the effective quota');
select tests.eq((select media_item_limit from admin_list_families() where id = :'fam'), 3, 'list shows the effective item cap');
select tests.eq((admin_family_detail(:'fam')->'family'->>'storage_bytes')::int, 500, 'detail storage');
select tests.eq((admin_family_detail(:'fam')->'family'->>'media_count')::int, 3, 'detail count');
select tests.eq((admin_family_detail(:'fam')->'family'->>'storage_limit_bytes')::int, 1000, 'detail raw quota');
select tests.eq((admin_overview()->>'storage_bytes')::int, 500, 'platform storage');
select tests.eq((admin_overview()->>'media_items')::int, 3, 'platform item count');
select tests.eq((admin_overview()->>'families_over_quota')::int, 0, 'under the quota');

select tests.eq((select count(*)::int from admin_list_media(:'fam')), 3, 'lists this family');
select tests.eq((select count(*)::int from admin_list_media(:'fam2')), 0, 'not the other family');
select tests.eq((select caption from admin_list_media(:'fam', 'photo') where id = '11111111-1111-1111-1111-111111111111'),
                'The picnic', 'kind filter and caption');
select tests.eq((select uploaded_by_name from admin_list_media(:'fam') where id = '11111111-1111-1111-1111-111111111111'),
                'Mom', 'uploader name');
select tests.throws(format('select * from admin_list_media(%L, ''audio'')', :'fam'), 'kind must be photo or video', 'bad kind');
select tests.throws($$select * from admin_list_media('99999999-9999-9999-9999-999999999999')$$, 'family not found', 'unknown family');

select tests.eq(admin_delete_media('11111111-1111-1111-1111-111111111111')->>'storage_path',
                :'fam' || '/picnic.jpg', 'delete returns the object path');
select tests.eq((select count(*)::int from media_items where id = '11111111-1111-1111-1111-111111111111'), 0, 'row is gone');
select tests.eq((select details->>'thumbnail_path' from admin_audit_log where action = 'delete_media'),
                :'fam' || '/picnic-thumb.jpg', 'removal is audited');
select tests.throws($$select admin_delete_media('11111111-1111-1111-1111-111111111111')$$, 'media not found', 'already gone');

-- Limits: set, reject a bad value, clear back to the platform default.
select tests.eq((admin_set_family_limits(:'fam', storage_limit_bytes => 2048)->>'storage_limit_bytes')::int, 2048, 'override stored');
-- Admins aren't family members, so RLS hides the families row. Read it as superuser.
select tests.logout();
select tests.eq((select storage_limit_bytes::int from families where id = :'fam'), 2048, 'column updated');
select tests.login(:'admin');
select tests.throws(format('select admin_set_family_limits(%L, storage_limit_bytes => -1)', :'fam'),
                    'storage_limit_bytes must be between 0 and 1099511627776', 'negative quota');
select tests.eq((admin_set_family_limits(:'fam', use_platform_storage_limit => true)->>'storage_limit_bytes') is null, true,
                'cleared override');
select tests.eq((admin_set_family_limits(:'fam', use_platform_storage_limit => true)->>'storage_limit_effective')::bigint,
                5368709120::bigint, 'platform default applies again');
select tests.eq((select count(*)::int from admin_audit_log where action = 'set_family_limits'), 2,
                'a no-op limit change is not audited');
select tests.eq((select details->>'storage_limit_bytes' from admin_audit_log where action = 'set_family_limits' order by id desc limit 1),
                null, 'audit shows the reset');
select tests.logout();
