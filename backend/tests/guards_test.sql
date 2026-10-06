-- tasks_guard, the color format checks and the display's last_seen_at
-- (20261007000007_family_guards.sql): what kids and the kitchen display may
-- write directly through PostgREST.
\set ON_ERROR_STOP 1
\set fam    '00000000-0000-0000-0000-00000000f001'
\set m_mom  '00000000-0000-0000-0000-00000000a001'
\set m_emma '00000000-0000-0000-0000-00000000a003'
\set mom      'a0000000-0000-0000-0000-000000000001'
\set emma     'a0000000-0000-0000-0000-000000000003'
\set device   'd0000000-0000-0000-0000-000000000001'
\set device2  'd0000000-0000-0000-0000-000000000002'

insert into auth.users (id, email, raw_app_meta_data) values
  (:'mom', 'mom@example.com', '{}'), (:'emma', 'emma@example.com', '{}'),
  (:'device', 'd1@devices.homeos.invalid', '{"kind": "device"}'),
  (:'device2', 'd2@devices.homeos.invalid', '{"kind": "device"}');
update members set user_id = :'mom' where id = :'m_mom';
update members set user_id = :'emma' where id = :'m_emma';
insert into devices (id, family_id, user_id) values
  ('dd000000-0000-0000-0000-000000000001', :'fam', :'device'),
  ('dd000000-0000-0000-0000-000000000002', :'fam', :'device2');

-- Emma's bed (5 points, no approval needed) and Leo's dog (10 points, needs approval).
select id as bed from tasks where title = 'Make your bed' \gset
select id as dog from tasks where title = 'Feed the dog' \gset

-- ───────────────────────── Chores: kids ─────────────────────────

select tests.login(:'emma');
select tests.throws(format($$insert into tasks (family_id, title, assignee_id, points, requires_approval)
                             values (%L, 'Free points', %L, 9999, false)$$, :'fam', :'m_emma'),
                    'only a parent can%', 'kid cannot add points that skip approval');
select tests.throws(format($$update tasks set points = 9999 where id = %L$$, :'bed'),
                    'only a parent can%', 'kid cannot raise a chore''s points');
select tests.throws(format($$update tasks set requires_approval = false where id = %L$$, :'dog'),
                    'only a parent can%', 'kid cannot drop approval');
select tests.throws(format($$update tasks set points = 0, requires_approval = true where id = %L$$, :'bed'),
                    'only a parent can%', 'kid cannot change points at all');
-- What stays open to everyone: chores a parent approves (the assistant's
-- add_chore), chores without points, wording, and archiving.
select tests.eq(tests.affected(format($$insert into tasks (family_id, title, points) values (%L, 'Water the plants', 20)$$, :'fam')),
                1, 'kid adds a chore with points that a parent approves');
select tests.eq(tests.affected(format($$insert into tasks (family_id, title, requires_approval) values (%L, 'Tidy up', false)$$, :'fam')),
                1, 'kid adds a chore without points that needs no approval');
select tests.eq(tests.affected(format($$update tasks set title = 'Feed Rex', notes = 'two scoops' where id = %L$$, :'dog')),
                1, 'kid edits the wording');
select tests.eq(tests.affected($$update tasks set archived = true where title = 'Tidy up'$$), 1, 'kid archives a chore');
-- The old exploit end to end: no new chore, so ticking one off pays nothing extra.
select tests.throws(format($$insert into tasks (family_id, title, assignee_id, points, requires_approval)
                             values (%L, 'Jackpot', %L, 1000, false)$$, :'fam', :'m_emma'),
                    'only a parent can%', 'jackpot chore refused');
select tests.eq((select balance from member_points where member_id = :'m_emma'), 0, 'emma has no points');
select tests.logout();

-- ───────────────────────── Chores: the kitchen display ─────────────────────────

select tests.login(:'device');
select tests.throws(format($$insert into tasks (family_id, title, points, requires_approval) values (%L, 'Screen chore', 50, false)$$, :'fam'),
                    'only a parent can%', 'display cannot add points that skip approval');
select tests.eq(tests.affected(format($$insert into tasks (family_id, title, points) values (%L, 'Empty the dishwasher', 10)$$, :'fam')),
                1, 'display adds a chore a parent approves (assistant add_chore)');
-- Ticking off chores is unchanged: auto-approved only where a parent said so.
insert into task_completions (task_id, member_id) values (:'bed', :'m_emma');
select tests.eq((select status::text from task_completions where task_id = :'bed'), 'approved', 'no-approval chore still auto-approves');
select tests.eq((select balance from member_points where member_id = :'m_emma'), 5, 'and pays its points');
insert into task_completions (task_id, member_id) select id, :'m_emma' from tasks where title = 'Empty the dishwasher';
select tests.eq((select c.status::text from task_completions c join tasks t on t.id = c.task_id where t.title = 'Empty the dishwasher'),
                'pending', 'a chore added from the screen waits for a parent');
-- Wall create: displays may insert rewards; kids may not; parents archive.
select tests.eq(tests.affected(format($$insert into rewards (family_id, title, icon, cost)
                                       values (%L, 'Extra story time', '📖', 40)$$, :'fam')),
                1, 'display can add a reward');
select tests.eq(tests.affected($$update rewards set active = false where title = 'Extra story time'$$),
                0, 'display cannot archive a reward');
select tests.logout();

select tests.login(:'emma');
select tests.throws(format($$insert into rewards (family_id, title, cost) values (%L, 'Kid reward', 10)$$, :'fam'),
                    '%row-level security%', 'kid cannot add a reward');
select tests.logout();

-- ───────────────────────── Chores: parents ─────────────────────────

select tests.login(:'mom');
select tests.eq(tests.affected(format($$update tasks set points = 25, requires_approval = false where id = %L$$, :'dog')),
                1, 'parent changes points and approval');
select tests.eq(tests.affected(format($$insert into tasks (family_id, title, points, requires_approval) values (%L, 'Big job', 100, false)$$, :'fam')),
                1, 'parent adds an auto-approved chore with points');
select tests.eq(tests.affected($$update rewards set active = false where title = 'Extra story time'$$),
                1, 'parent archives a reward the display added');
select tests.logout();

-- ───────────────────────── Colors ─────────────────────────

select tests.login(:'emma');
select tests.throws(format($$update members set color = 'red;position:fixed;inset:0' where id = %L$$, :'m_emma'),
                    '%members_color_hex%', 'member color must be #RRGGBB');
select tests.throws(format($$update members set color = 'url(https://tracker.example/x.png)' where id = %L$$, :'m_emma'),
                    '%members_color_hex%', 'no urls in member colors');
select tests.throws(format($$update members set color = '#11223344' where id = %L$$, :'m_emma'),
                    '%members_color_hex%', 'no alpha (Qt reads #AARRGGBB, iOS #RRGGBB)');
select tests.eq(tests.affected(format($$update members set color = '#7cc08b' where id = %L$$, :'m_emma')), 1, 'hex color accepted');
select tests.throws(format($$insert into events (family_id, title, starts_at, ends_at, color) values (%L, 'Party', now(), now(), 'red')$$, :'fam'),
                    '%events_color_hex%', 'event color must be #RRGGBB');
select tests.eq(tests.affected(format($$insert into events (family_id, title, starts_at, ends_at) values (%L, 'Party', now(), now())$$, :'fam')),
                1, 'events without a color are fine');
select tests.logout();

-- ───────────────────────── Displays check in ─────────────────────────

select tests.login(:'device');
select tests.eq(tests.affected($$update devices set last_seen_at = now() where id = 'dd000000-0000-0000-0000-000000000001'$$),
                1, 'display records when it was last seen');
select tests.eq(tests.affected($$update devices set last_seen_at = now() where id = 'dd000000-0000-0000-0000-000000000002'$$),
                0, 'but not for another display');
select tests.logout();
