-- Suspending a family hides all of its data from its members and displays,
-- takes away parent rights, and only admins can change it.
\set ON_ERROR_STOP 1
\set fam    '00000000-0000-0000-0000-00000000f001'
\set m_mom  '00000000-0000-0000-0000-00000000a001'
\set m_emma '00000000-0000-0000-0000-00000000a003'
\set m_leo  '00000000-0000-0000-0000-00000000a004'
\set mom    'a0000000-0000-0000-0000-000000000001'
\set emma   'a0000000-0000-0000-0000-000000000003'
\set device 'd0000000-0000-0000-0000-000000000001'
\set admin  'ad000000-0000-0000-0000-000000000001'

insert into auth.users (id, email, raw_app_meta_data) values
  (:'mom', 'mom@example.com', '{}'), (:'emma', 'emma@example.com', '{}'),
  (:'device', 'device@devices.homeos.invalid', '{"kind": "device"}'), (:'admin', 'admin@example.com', '{}');
update members set user_id = :'mom' where id = :'m_mom';
update members set user_id = :'emma' where id = :'m_emma';
insert into devices (family_id, user_id) values (:'fam', :'device');
insert into platform_admins (user_id) values (:'admin');
insert into events (family_id, title, starts_at, ends_at) values (:'fam', 'Soccer', now() + interval '1 day', now() + interval '1 day 1 hour');
insert into family_memories (family_id, content) values (:'fam', 'Leo is allergic to peanuts');
insert into media_items (family_id, storage_path, kind) values (:'fam', :'fam' || '/1.jpg', 'photo');
insert into list_items (list_id, text) select id, 'Milk' from lists;
insert into points_ledger (family_id, member_id, delta, reason) values (:'fam', :'m_leo', 10, 'bonus');
insert into assistant_threads (family_id, owner_id) values (:'fam', :'mom');
select id as task from tasks where title = 'Feed the dog' \gset

-- How much of the family a caller can see, across every family table.
create function tests.visible() returns int language sql as $$
  select ((select count(*) from families) + (select count(*) from members) + (select count(*) from devices)
        + (select count(*) from events) + (select count(*) from tasks) + (select count(*) from rewards)
        + (select count(*) from lists) + (select count(*) from list_items) + (select count(*) from meal_plans)
        + (select count(*) from media_items) + (select count(*) from points_ledger) + (select count(*) from member_points)
        + (select count(*) from family_memories) + (select count(*) from family_invites)
        + (select count(*) from assistant_threads))::int
$$;

select tests.login(:'mom');
select tests.ok(tests.visible() > 20, 'mom sees her family');
select tests.eq((select count(*)::int from my_family_ids()), 1, 'one family');
select tests.login(:'device');
select tests.eq((select count(*)::int from tasks), 4, 'display sees chores');

-- Suspend (as an admin).
select tests.login(:'admin');
select admin_set_family_status(:'fam', 'suspended', 'Payment dispute');
select tests.logout();
select tests.eq((select status || ' / ' || suspended_reason from families where id = :'fam'), 'suspended / Payment dispute', 'suspended with reason');
select tests.ok((select suspended_at is not null from families where id = :'fam'), 'suspended_at set');

select tests.login(:'mom');
select tests.eq(tests.visible(), 0, 'mom sees nothing');
select tests.eq((select count(*)::int from my_family_ids()), 0, 'my_family_ids leaves it out');
select tests.ok(not is_family_member(:'fam') and not is_family_parent(:'fam'), 'no membership, no parent rights');
select tests.throws(format($$insert into tasks (family_id, title) values (%L, 'Sneak')$$, :'fam'), '%row-level security%', 'mom cannot add chores');
select tests.throws(format('select adjust_points(%L, 100, %L)', :'m_leo', 'sneak'), 'not allowed', 'mom cannot give points');
select tests.throws(format('select create_family_invite(%L)', :'fam'), 'not allowed', 'mom cannot invite');
select tests.eq(tests.affected(format($$update families set status = 'active' where id = %L$$, :'fam')), 0, 'mom cannot unsuspend (filtered)');
select tests.eq(tests.affected($$update families set status = 'active'$$), 0, 'mom cannot unsuspend (unfiltered)');

select tests.login(:'emma');
select tests.eq(tests.visible(), 0, 'kid sees nothing');

select tests.login(:'device');
select tests.eq(tests.visible(), 0, 'display sees nothing');
select tests.throws(format($$insert into task_completions (task_id, member_id) values (%L, %L)$$, :'task', :'m_leo'),
                    '%row-level security%', 'display cannot complete chores');
select tests.throws(format($$insert into family_memories (family_id, content) values (%L, 'x')$$, :'fam'), '%row-level security%', 'display cannot add memories');

-- Admin functions still see it.
select tests.login(:'admin');
select tests.eq(admin_family_detail(:'fam')->'family'->>'status', 'suspended', 'admin sees the suspended family');

-- Unsuspend: everything is back and the reason is cleared.
select admin_set_family_status(:'fam', 'active');
select tests.logout();
select tests.ok((select suspended_at is null and suspended_reason is null from families where id = :'fam'), 'suspension cleared');
select tests.login(:'mom');
select tests.ok(tests.visible() > 20, 'mom sees her family again');

-- Parents rename their family but can't touch status or limits.
select tests.eq(tests.affected(format($$update families set name = 'The Demos' where id = %L$$, :'fam')), 1, 'parent renames family');
select tests.throws(format($$update families set status = 'suspended' where id = %L$$, :'fam'), 'only a platform admin can change that', 'parent cannot suspend');
select tests.throws(format($$update families set assistant_daily_limit = 100000 where id = %L$$, :'fam'), 'only a platform admin can change that', 'parent cannot raise the assistant limit');
select tests.throws(format($$update families set suspended_reason = 'x' where id = %L$$, :'fam'), 'only a platform admin can change that', 'parent cannot set a reason');
select tests.throws($$select families_guard()$$, 'permission denied%', 'trigger function not callable');
select tests.logout();
