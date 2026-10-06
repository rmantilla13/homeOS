-- members_guard and members_update_self: what kids and parents may change
-- directly, and the "at least one parent with an account" rule.
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
-- Setup runs without a JWT, so the guard stays out of the way.
update members set user_id = :'mom' where id = :'m_mom';
update members set user_id = :'emma' where id = :'m_emma';
insert into devices (family_id, user_id) values (:'fam', :'device');
insert into families (id, name) values (:'fam2', 'Elsewhere');

-- ───────────────────────── Kids ─────────────────────────

select tests.login(:'emma');
select tests.eq(tests.affected(format($$update members set display_name = 'Em', color = '#123456', avatar_url = 'https://x/y.png' where id = %L$$, :'m_emma')),
                1, 'kid edits own name, color, avatar');
select tests.throws(format($$update members set role = 'parent' where id = %L$$, :'m_emma'), 'only a parent can change that', 'kid cannot promote self');
select tests.throws(format($$update members set family_id = %L where id = %L$$, :'fam2', :'m_emma'), 'only a parent can change that', 'kid cannot move family');
select tests.throws(format($$update members set user_id = null where id = %L$$, :'m_emma'), 'only a parent can change that', 'kid cannot unlink directly');
select tests.throws(format($$update members set user_id = %L where id = %L$$, :'stranger', :'m_emma'), 'only a parent can change that', 'kid cannot hand over the row');
select tests.throws(format($$update members set birthday = '2015-01-01' where id = %L$$, :'m_emma'), 'only a parent can change that', 'kid cannot change birthday');
select tests.throws(format($$update members set sort_order = 99 where id = %L$$, :'m_emma'), 'only a parent can change that', 'kid cannot reorder');
select tests.eq(tests.affected(format($$update members set display_name = 'Leopold' where id = %L$$, :'m_leo')), 0, 'kid cannot edit a sibling');
select tests.eq(tests.affected($$delete from members$$), 0, 'kid cannot delete members');
select tests.throws(format($$insert into members (family_id, display_name) values (%L, 'Imaginary friend')$$, :'fam'), '%row-level security%', 'kid cannot add members');
select tests.logout();
select tests.eq((select display_name || ' ' || color || ' ' || role::text from members where id = :'m_emma'), 'Em #123456 child', 'only the allowed edit stuck');

-- Displays read members but can't change them.
select tests.login(:'device');
select tests.eq((select count(*)::int from members), 4, 'display reads members');
select tests.eq(tests.affected($$update members set display_name = 'x'$$), 0, 'display cannot edit members');

-- Strangers see and touch nothing, not even the parent count.
select tests.login(:'stranger');
select tests.eq(tests.affected($$update members set display_name = 'x'$$), 0, 'stranger cannot edit members');
select tests.throws(format('select other_linked_parents(%L, %L)', :'fam', :'m_dad'), 'not allowed', 'guard helper refuses outsiders');
select tests.login(null);
select tests.throws(format('select other_linked_parents(%L, %L)', :'fam', :'m_dad'), 'permission denied%', 'guard helper not for anon');

-- ───────────────────────── Parents ─────────────────────────

select tests.login(:'mom');
select tests.eq(tests.affected(format($$update members set role = 'other', birthday = '2016-05-01', sort_order = 7 where id = %L$$, :'m_leo')),
                1, 'parent edits any column of a kid');
select tests.ok((select role = 'other' from members where id = :'m_leo'), 'role changed');
select tests.eq(tests.affected(format($$update members set role = 'child' where id = %L$$, :'m_leo')), 1, 'and back');
select tests.eq(tests.affected(format($$insert into members (family_id, display_name) values (%L, 'Baby')$$, :'fam')), 1, 'parent adds a kid without an account');
select tests.throws(format($$insert into members (family_id, user_id, display_name, role) values (%L, %L, 'Sneaky', 'parent')$$, :'fam', :'stranger'),
                    'accounts join a family through an invite', 'parent cannot add an account directly');
select tests.throws(format($$update members set user_id = %L where id = %L$$, :'stranger', :'m_leo'),
                    'accounts join a family through an invite', 'parent cannot link an account directly');
select tests.throws(format($$update members set user_id = %L where id = %L$$, :'stranger', :'m_emma'),
                    'accounts join a family through an invite', 'parent cannot swap an account');
select tests.eq(tests.affected(format($$update members set user_id = null where id = %L$$, :'m_emma')), 1, 'parent may unlink a kid');
select tests.eq(tests.affected($$delete from members where display_name = 'Baby'$$), 1, 'parent deletes a kid');

-- Mom is the only parent with an account; Dad's row has none.
select tests.throws(format($$update members set role = 'child' where id = %L$$, :'m_mom'), 'a family needs at least one parent with an account', 'last parent cannot demote self');
select tests.throws(format($$delete from members where id = %L$$, :'m_mom'), 'a family needs at least one parent with an account', 'last parent cannot delete self');
select tests.throws(format($$update members set user_id = null where id = %L$$, :'m_mom'), 'a family needs at least one parent with an account', 'last parent cannot unlink self');
select tests.throws($$delete from members$$, 'a family needs at least one parent with an account', 'bulk delete stops at the last parent');
select tests.eq(tests.affected(format($$update members set role = 'other' where id = %L$$, :'m_dad')), 1, 'unlinked parents can be demoted');
select tests.eq(tests.affected(format($$update members set role = 'parent' where id = %L$$, :'m_dad')), 1, 'and promoted');

-- With Dad linked there are two; one may step down, then the other can't.
select tests.logout();
update members set user_id = :'dad' where id = :'m_dad';
select tests.login(:'mom');
select tests.eq(tests.affected(format($$update members set role = 'other' where id = %L$$, :'m_mom')), 1, 'mom steps down while dad is linked');
select tests.login(:'dad');
select tests.throws(format($$update members set role = 'child' where id = %L$$, :'m_dad'), 'a family needs at least one parent with an account', 'dad is now the last');
select tests.eq(tests.affected(format($$delete from members where id = %L$$, :'m_mom')), 1, 'dad removes mom''s row');
select tests.throws(format($$delete from members where id = %L$$, :'m_dad'), 'a family needs at least one parent with an account', 'dad cannot delete himself');

-- Platform admins and the service role skip the guard.
select tests.logout();
insert into platform_admins (user_id) values (:'dad');
select tests.login(:'dad');
select tests.eq(tests.affected(format($$update members set role = 'other' where id = %L$$, :'m_dad')), 1, 'admin skips the guard');
select tests.logout();
delete from platform_admins;
update members set role = 'parent' where id = :'m_dad';
select tests.login_service();
select tests.eq(tests.affected(format($$update members set role = 'child' where id = %L$$, :'m_dad')), 1, 'service role skips the guard');
select tests.eq(tests.affected(format($$update members set role = 'parent', user_id = %L where id = %L$$, :'stranger', :'m_leo')), 1, 'service role may link accounts');

-- Suspended families: nothing to edit.
select tests.logout();
update members set role = 'parent' where id = :'m_dad';
update families set status = 'suspended' where id = :'fam';
select tests.login(:'dad');
select tests.eq(tests.affected(format($$update members set display_name = 'x' where id = %L$$, :'m_dad')), 0, 'suspended: own row hidden');
select tests.eq(tests.affected(format($$update members set display_name = 'x' where id = %L$$, :'m_leo')), 0, 'suspended: parent rights gone');

select tests.throws($$select members_guard()$$, 'permission denied%', 'trigger function not callable');
select tests.logout();
