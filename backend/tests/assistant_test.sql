-- Assistant threads and messages belong to one person (or display) in one
-- family; usage is written by the service role and read by admins.
\set ON_ERROR_STOP 1
\set fam    '00000000-0000-0000-0000-00000000f001'
\set fam2   '00000000-0000-0000-0000-00000000f002'
\set m_mom  '00000000-0000-0000-0000-00000000a001'
\set m_dad  '00000000-0000-0000-0000-00000000a002'
\set mom      'a0000000-0000-0000-0000-000000000001'
\set dad      'a0000000-0000-0000-0000-000000000002'
\set device   'd0000000-0000-0000-0000-000000000001'
\set stranger 'e0000000-0000-0000-0000-000000000001'
\set admin    'ad000000-0000-0000-0000-000000000001'

insert into auth.users (id, email, raw_app_meta_data) values
  (:'mom', 'mom@example.com', '{}'), (:'dad', 'dad@example.com', '{}'),
  (:'device', 'device@devices.homeos.invalid', '{"kind": "device"}'),
  (:'stranger', 'stranger@example.com', '{}'), (:'admin', 'admin@example.com', '{}');
update members set user_id = :'mom' where id = :'m_mom';
update members set user_id = :'dad' where id = :'m_dad';
insert into devices (family_id, user_id) values (:'fam', :'device');
insert into platform_admins (user_id) values (:'admin');
insert into families (id, name) values (:'fam2', 'Strangers');
insert into members (family_id, user_id, display_name, role) values (:'fam2', :'stranger', 'Sam', 'parent');

-- Mom starts a thread; owner defaults to her, title to 'New chat'.
select tests.login(:'mom');
insert into assistant_threads (family_id) values (:'fam') returning id as mom_thread \gset
select tests.eq((select owner_id from assistant_threads where id = :'mom_thread'), :'mom'::uuid, 'owner defaults to the caller');
select tests.eq((select title from assistant_threads where id = :'mom_thread'), 'New chat', 'default title');

-- Messages: family_id comes from the thread; created_by from the caller.
insert into assistant_messages (thread_id, role, content) values (:'mom_thread', 'user', 'What''s for dinner?') returning id as msg1 \gset
select tests.eq((select family_id from assistant_messages where id = :'msg1'), :'fam'::uuid, 'family_id filled from the thread');
select tests.eq((select created_by from assistant_messages where id = :'msg1'), :'mom'::uuid, 'created_by defaults to the caller');
select tests.eq((select row(mode, actions)::text from assistant_messages where id = :'msg1'), row('chat', '[]'::jsonb)::text, 'defaults');
insert into assistant_messages (thread_id, family_id, role, content, mode, actions)
values (:'mom_thread', :'fam2', 'assistant', 'Tacos.', 'quick', '[{"type": "set_meal", "summary": "Tacos on Friday"}]') returning id as msg2 \gset
select tests.eq((select family_id from assistant_messages where id = :'msg2'), :'fam'::uuid, 'a wrong family_id is corrected');
select tests.throws(format($$insert into assistant_messages (thread_id, role, content) values (%L, 'system', 'x')$$, :'mom_thread'), '%check constraint%', 'role is user or assistant');
select tests.throws(format($$insert into assistant_messages (thread_id, role, content, mode) values (%L, 'user', 'x', 'loud')$$, :'mom_thread'), '%check constraint%', 'mode is chat or quick');
select tests.throws(format($$insert into assistant_messages (thread_id, role, content, created_by) values (%L, 'user', 'x', %L)$$, :'mom_thread', :'dad'),
                    '%row-level security%', 'cannot post as someone else');
select tests.throws(format($$insert into assistant_threads (family_id, owner_id) values (%L, %L)$$, :'fam', :'dad'), '%row-level security%', 'cannot create a thread for someone else');
select tests.throws(format($$insert into assistant_threads (family_id) values (%L)$$, :'fam2'), '%row-level security%', 'cannot create a thread in another family');
select tests.throws(format($$insert into assistant_messages (thread_id, role, content) values (%L, 'assistant', repeat('x', 100001))$$, :'mom_thread'),
                    '%check constraint%', 'message size is bounded');
select tests.eq((select count(*)::int from assistant_messages), 2, 'mom sees her messages');

-- Append-only.
select tests.eq(tests.affected($$update assistant_messages set content = 'edited'$$), 0, 'messages cannot be edited');
select tests.eq(tests.affected($$delete from assistant_messages$$), 0, 'messages cannot be deleted');

-- Threads: rename, archive, updated_at moves.
select updated_at as before_rename from assistant_threads where id = :'mom_thread' \gset
select tests.eq(tests.affected(format($$update assistant_threads set title = 'Dinner', archived = true where id = %L$$, :'mom_thread')), 1, 'owner renames and archives');
select tests.ok((select updated_at > :'before_rename'::timestamptz from assistant_threads where id = :'mom_thread'), 'updated_at touched');
select tests.throws(format($$update assistant_threads set owner_id = %L where id = %L$$, :'dad', :'mom_thread'), '%row-level security%', 'cannot hand a thread to someone else');
select tests.throws(format($$update assistant_threads set family_id = %L where id = %L$$, :'fam2', :'mom_thread'), '%row-level security%', 'cannot move a thread to another family');

-- Dad (same family) sees none of Mom's chats.
select tests.login(:'dad');
select tests.eq((select count(*)::int from assistant_threads), 0, 'other parent sees no threads');
select tests.eq((select count(*)::int from assistant_messages), 0, 'other parent sees no messages');
select tests.throws(format($$insert into assistant_messages (thread_id, role, content) values (%L, 'user', 'peek')$$, :'mom_thread'), '%row-level security%', 'cannot post into another''s thread');
select tests.eq(tests.affected($$delete from assistant_threads$$), 0, 'cannot delete another''s thread');
select tests.eq(tests.affected($$update assistant_threads set title = 'x'$$), 0, 'cannot rename another''s thread');

-- The display keeps its own threads.
select tests.login(:'device');
insert into assistant_threads (family_id, title) values (:'fam', 'Kitchen') returning id as device_thread \gset
insert into assistant_messages (thread_id, role, content, mode) values (:'device_thread', 'user', 'Timer for 10 minutes', 'quick');
select tests.eq((select count(*)::int from assistant_threads), 1, 'display sees only its thread');
select tests.login(:'mom');
select tests.eq((select count(*)::int from assistant_threads), 1, 'mom does not see the display thread');

-- Strangers see nothing and can't post anywhere.
select tests.login(:'stranger');
select tests.eq((select count(*)::int from assistant_threads) + (select count(*)::int from assistant_messages), 0, 'stranger sees nothing');
select tests.throws(format($$insert into assistant_threads (family_id) values (%L)$$, :'fam'), '%row-level security%', 'stranger cannot start a thread there');

-- Usage: service role writes, admins read, nobody else.
select tests.login(:'mom');
select tests.throws(format($$insert into assistant_usage (family_id, user_id, model) values (%L, %L, 'claude-opus-5-5')$$, :'fam', :'mom'),
                    '%row-level security%', 'clients cannot write usage');
select tests.login_service();
insert into assistant_usage (family_id, user_id, thread_id, mode, model, input_tokens, output_tokens, cache_read_tokens, tool_calls)
values (:'fam', :'mom', :'mom_thread', 'chat', 'claude-opus-5-5', 1200, 300, 800, 1),
       (:'fam', :'device', :'device_thread', 'quick', 'claude-opus-5-5', 900, 40, 0, 0);
insert into assistant_messages (thread_id, role, content, created_by) values (:'mom_thread', 'assistant', 'Done.', null);
select tests.login(:'mom');
select tests.eq((select count(*)::int from assistant_usage), 0, 'members cannot read usage');
select tests.eq((select count(*)::int from assistant_messages), 3, 'service-role reply shows in the thread');
select tests.login(:'admin');
select tests.eq((select count(*)::int from assistant_usage), 2, 'admins read usage');
select tests.eq((select count(*)::int from assistant_threads), 0, 'admins do not read chats');

-- Leaving the family (or a suspension) hides your old threads.
select tests.login(:'mom');
select leave_family(:'fam');
select tests.eq((select count(*)::int from assistant_threads), 0, 'left the family: threads hidden');
select tests.logout();
update members set user_id = :'mom' where id = :'m_mom';
update families set status = 'suspended' where id = :'fam';
select tests.login(:'mom');
select tests.eq((select count(*)::int from assistant_threads), 0, 'suspended: threads hidden');
select tests.logout();
update families set status = 'active' where id = :'fam';

-- Deleting a thread takes its messages; usage keeps the row without the link.
select tests.login(:'mom');
select tests.eq(tests.affected(format('delete from assistant_threads where id = %L', :'mom_thread')), 1, 'owner deletes the thread');
select tests.logout();
select tests.eq((select count(*)::int from assistant_messages where thread_id = :'mom_thread'), 0, 'messages went with it');
select tests.eq((select count(*)::int from assistant_usage where thread_id is null), 1, 'usage row kept, unlinked');
