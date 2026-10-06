-- Two sign-ups racing for the last use of an invite: the second waits on the
-- invite's row lock, then sees it used. Uses dblink (Postgres contrib) for
-- the two sessions; skipped when it isn't installed.
\set ON_ERROR_STOP 1
select not exists (select 1 from pg_available_extensions where name = 'dblink') as no_dblink \gset
\if :no_dblink
\echo 'skipped: dblink is not installed'
\quit
\endif
create extension dblink;

\set fam '00000000-0000-0000-0000-00000000f001'
\set u1  'b0000000-0000-0000-0000-000000000001'
\set u2  'b0000000-0000-0000-0000-000000000002'
\set u3  'b0000000-0000-0000-0000-000000000003'
\set u4  'b0000000-0000-0000-0000-000000000004'

insert into auth.users (id, email) values
  (:'u1', 'u1@example.com'), (:'u2', 'u2@example.com'), (:'u3', 'u3@example.com'), (:'u4', 'u4@example.com');
insert into platform_invites (id, code, max_uses) values ('11000000-0000-0000-0000-000000000001', 'RACERACE', 1);
insert into family_invites (id, family_id, code) values ('22000000-0000-0000-0000-000000000001', :'fam', 'TAKETAKE');

select format('dbname=%s host=%s port=%s user=%s', current_database(),
              split_part(current_setting('unix_socket_directories'), ',', 1), current_setting('port'), current_user) as conn \gset
select dblink_connect('a', :'conn'), dblink_connect('b', :'conn');

-- True once session b is blocked on a lock.
create function tests.b_waits() returns boolean language plpgsql as $$
begin
  for i in 1..100 loop
    perform pg_stat_clear_snapshot();  -- stats are cached per transaction
    if exists (select 1 from pg_stat_activity where wait_event_type = 'Lock' and query like '%race-b%') then
      return true;
    end if;
    perform pg_sleep(0.05);
  end loop;
  return false;
end $$;

-- Runs `first` in session a (left open), starts `second` in session b, checks
-- b waits for a, commits a and returns b's error (null if b succeeded).
create function tests.race(first text, second text) returns text language plpgsql as $$
declare
  err text;
begin
  perform dblink_exec('a', 'begin');
  perform * from dblink('a', first) as t(x text);
  perform dblink_send_query('b', second || ' -- race-b');
  perform tests.ok(tests.b_waits(), 'second session waits on the first');
  perform dblink_exec('a', 'commit');
  perform * from dblink_get_result('b', false) as t(x text);
  err := nullif(dblink_error_message('b'), 'OK');
  perform * from dblink_get_result('b', false) as t(x text);  -- clears the connection
  return err;
end $$;

-- Platform invite with one use left.
select * from dblink('a', format('select tests.login(%L)::text', :'u1')) as t(x text);
select * from dblink('b', format('select tests.login(%L)::text', :'u2')) as t(x text);
select tests.ok(tests.race($$select create_family('One', 'A', 'UTC', 'RACE-RACE')::text$$,
                           $$select create_family('Two', 'B', 'UTC', 'RACE-RACE')::text$$)
                like '%invite code already used%', 'second sign-up loses the last use');
select tests.eq((select use_count from platform_invites where code = 'RACERACE'), 1, 'one use counted');
select tests.eq((select count(*)::int from platform_invite_redemptions), 1, 'one redemption');
select tests.eq((select count(*)::int from families where name in ('One', 'Two')), 1, 'one family created');

-- Family invite.
select * from dblink('a', format('select tests.login(%L)::text', :'u3')) as t(x text);
select * from dblink('b', format('select tests.login(%L)::text', :'u4')) as t(x text);
select tests.ok(tests.race($$select accept_family_invite('TAKE-TAKE')::text$$,
                           $$select accept_family_invite('TAKE-TAKE')::text$$)
                like '%invite code already used%', 'second accept loses');
select tests.eq((select accepted_by from family_invites where code = 'TAKETAKE'), :'u3'::uuid, 'first accept wins');
select tests.eq((select count(*)::int from members where user_id in (:'u3', :'u4')), 1, 'one member added');

select dblink_disconnect('a'), dblink_disconnect('b');
