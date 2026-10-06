-- review_completion and resolve_redemption need an explicit yes or no; a
-- null flag used to cancel a redemption without refunding its points.
\set ON_ERROR_STOP 1
\set fam    '00000000-0000-0000-0000-00000000f001'
\set m_mom  '00000000-0000-0000-0000-00000000a001'
\set m_leo  '00000000-0000-0000-0000-00000000a004'
\set mom    'a0000000-0000-0000-0000-000000000001'

insert into auth.users (id, email) values (:'mom', 'mom@example.com');
update members set user_id = :'mom' where id = :'m_mom';
insert into points_ledger (family_id, member_id, delta, reason) values (:'fam', :'m_leo', 100, 'bonus');

select tests.login(:'mom');
select redeem_reward((select id from rewards where cost = 30), :'m_leo') as rid \gset
select tests.throws(format('select resolve_redemption(%L, null)', :'rid'), 'fulfilled is required', 'null fulfilled');
select tests.eq((select status::text from reward_redemptions where id = :'rid'), 'requested', 'still open');
select tests.eq((select balance from member_points where member_id = :'m_leo'), 70, 'points still held');
select resolve_redemption(:'rid', false);
select tests.eq((select balance from member_points where member_id = :'m_leo'), 100, 'cancel refunds');

insert into task_completions (task_id, member_id)
select id, assignee_id from tasks where title = 'Feed the dog' returning id as cid \gset
select tests.throws(format('select review_completion(%L, null)', :'cid'), 'approve is required', 'null approve');
select tests.eq((select status::text from task_completions where id = :'cid'), 'pending', 'still pending');
select review_completion(:'cid', true);
select tests.eq((select status::text from task_completions where id = :'cid'), 'approved', 'approve works');
select tests.logout();
