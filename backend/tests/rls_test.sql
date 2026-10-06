-- Exercises RLS, chore approval, points ledger and reward redemption.
-- Run with tests/run.sh (needs a local Postgres 15+).
\set ON_ERROR_STOP 1
-- Table and function grants come from stub_auth.sql's default privileges, as on Supabase.
insert into auth.users values ('11111111-1111-1111-1111-111111111111'), ('22222222-2222-2222-2222-222222222222'), ('33333333-3333-3333-3333-333333333333');
-- Mom (parent) is user 1; device is user 2; user 3 is a stranger.
update members set user_id = '11111111-1111-1111-1111-111111111111' where display_name = 'Mom';
insert into devices (family_id, user_id) values ('00000000-0000-0000-0000-00000000f001', '22222222-2222-2222-2222-222222222222');

set role authenticated;

-- Stranger sees nothing
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select 'stranger tasks' as t, count(*) from tasks;

-- Device marks chores done for Emma (auto-approved, 5 pts) and Leo (pending)
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select 'device tasks' as t, count(*) from tasks;
insert into task_completions (task_id, member_id, status)
  select id, assignee_id, 'approved' from tasks where title in ('Make your bed', 'Feed the dog');
select m.display_name, c.status from task_completions c join members m on m.id = c.member_id order by 1;
-- Device cannot approve
do $$ begin
  perform review_completion((select id from task_completions where status = 'pending' limit 1), true);
  raise exception 'device approval should fail';
exception when raise_exception then
  if sqlerrm = 'device approval should fail' then raise; end if;
end $$;

-- Parent approves Leo's chore
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select review_completion(id, true) from task_completions where status = 'pending';
select m.display_name, p.balance from member_points p join members m using (family_id) where m.id = p.member_id order by 1;

-- Leo can't afford ice cream (10 pts) but Mom can't cheat via insert
do $$ begin
  perform redeem_reward((select id from rewards where cost = 100), '00000000-0000-0000-0000-00000000a004');
  raise exception 'should not afford';
exception when raise_exception then
  if sqlerrm = 'should not afford' then raise; end if; raise notice 'ok: %', sqlerrm;
end $$;
do $$ begin
  insert into points_ledger (family_id, member_id, delta, reason) values ('00000000-0000-0000-0000-00000000f001', '00000000-0000-0000-0000-00000000a004', 1000, 'cheat');
  raise exception 'ledger insert should be blocked';
exception when insufficient_privilege then raise notice 'ok: ledger write blocked';
end $$;

-- Give points, redeem, cancel (refund), un-approve
select adjust_points('00000000-0000-0000-0000-00000000a004', 25, 'bonus');
select resolve_redemption(redeem_reward((select id from rewards where cost = 30), '00000000-0000-0000-0000-00000000a004'), false);
select review_completion(c.id, false) from task_completions c join tasks t on t.id = c.task_id where t.title = 'Feed the dog';
select m.display_name, p.balance from member_points p join members m on m.id = p.member_id where p.balance <> 0 order by 1;
select reason, delta from points_ledger order by id;

-- Family memories: device can add, stranger can't see, device can't delete
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
insert into family_memories (family_id, content) values ('00000000-0000-0000-0000-00000000f001', 'Leo is allergic to peanuts');
delete from family_memories;  -- RLS: device is not a parent, so nothing is deleted
select 'device sees memories' as t, count(*) from family_memories;
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select 'stranger sees memories' as t, count(*) from family_memories;

-- create_family by stranger: invite-only by default (see invites_test.sql),
-- open once an admin turns invite_only off
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
select count(*) as fams_before from families;
do $$ begin
  perform create_family('Stranger Family', 'Sam');
  raise exception 'create_family without an invite should fail';
exception when raise_exception then
  if sqlerrm <> 'invite code required' then raise; end if;
end $$;
reset role;
update platform_settings set invite_only = false;
set role authenticated;
select create_family('Stranger Family', 'Sam') is not null as created;
select name from families;
