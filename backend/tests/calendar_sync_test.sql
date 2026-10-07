-- Connected calendars (docs/PLATFORM_SPEC.md §1.13): calendar_sources and
-- their secrets, calendar_apply_sync, calendar_claim_due, the read-only
-- guards on imported events, parents' settings, the shared link, and what
-- goes when a parent leaves.
\set ON_ERROR_STOP 1
\set fam     '00000000-0000-0000-0000-00000000f001'
\set fam2    '00000000-0000-0000-0000-00000000f002'
\set fam3    '00000000-0000-0000-0000-00000000f003'
\set m_mom   '00000000-0000-0000-0000-00000000a001'
\set m_dad   '00000000-0000-0000-0000-00000000a002'
\set m_emma  '00000000-0000-0000-0000-00000000a003'
\set m_leo   '00000000-0000-0000-0000-00000000a004'
\set m_other '00000000-0000-0000-0000-00000000b001'
\set mom     'a0000000-0000-0000-0000-000000000001'
\set dad     'a0000000-0000-0000-0000-000000000002'
\set emma    'a0000000-0000-0000-0000-000000000003'
\set other   'a0000000-0000-0000-0000-000000000099'
\set device  'd0000000-0000-0000-0000-000000000001'
\set school  'c0000000-0000-0000-0000-000000000001'
\set work    'c0000000-0000-0000-0000-000000000002'
\set dadcal  'c0000000-0000-0000-0000-000000000003'
\set acct    'ac000000-0000-0000-0000-000000000001'
\set dadacct 'ac000000-0000-0000-0000-000000000002'

set timezone = 'UTC';

insert into auth.users (id, email, raw_app_meta_data) values
  (:'mom', 'mom@example.com', '{}'),
  (:'dad', 'dad@example.com', '{}'),
  (:'emma', 'emma@example.com', '{}'),
  (:'other', 'neighbor@example.com', '{}'),
  (:'device', 'device@devices.homeos.invalid', '{"kind": "device"}');
update members set user_id = :'mom' where id = :'m_mom';
update members set user_id = :'dad' where id = :'m_dad';
update members set user_id = :'emma' where id = :'m_emma';
insert into families (id, name) values (:'fam2', 'Other House');
insert into members (id, family_id, display_name, role, user_id) values (:'m_other', :'fam2', 'Neighbor', 'parent', :'other');
insert into devices (family_id, user_id, name) values (:'fam', :'device', 'Kitchen');

-- ───────────────────────── Schema ─────────────────────────

select tests.ok(not exists (select 1 from pg_constraint
                             where conrelid = 'public.events'::regclass and contype = 'u'
                               and pg_get_constraintdef(oid) like '%external_source%'),
                'the old (family, external_source, external_id) key is gone');
select tests.ok(exists (select 1 from pg_constraint where conname = 'events_source_external'),
                'imported events are keyed by (source_id, external_id)');

-- ───────────────────────── What calendar-sync writes ─────────────────────────

select tests.login_service();
insert into calendar_sources (id, family_id, provider, url_host, name, color, created_by)
values (:'school', :'fam', 'ics', 'school.example.org', '  School  ', '#3366CC', :'mom');
insert into calendar_source_links (source_id, url) values (:'school', 'https://school.example.org/cal.ics?key=secret');
insert into calendar_accounts (id, family_id, email, created_by) values (:'acct', :'fam', 'mom@gmail.com', :'mom');
insert into calendar_account_tokens (account_id, refresh_token) values (:'acct', 'refresh-secret');
insert into calendar_sources (id, family_id, provider, account_id, google_calendar_id, name, member_id, created_by)
values (:'work', :'fam', 'google', :'acct', 'mom@gmail.com', 'Mom at work', :'m_mom', :'mom');

select tests.eq((select name from calendar_sources where id = :'school'), 'School', 'names are trimmed');
select tests.throws($$insert into calendar_sources (family_id, provider, name) values ('00000000-0000-0000-0000-00000000f001', 'google', 'No account')$$,
                    '%calendar_sources_provider_fields%', 'a Google calendar needs its account');
select tests.throws($$insert into calendar_sources (family_id, provider, name, account_id, google_calendar_id)
                      values ('00000000-0000-0000-0000-00000000f001', 'ics', 'Link', 'ac000000-0000-0000-0000-000000000001', 'x')$$,
                    '%calendar_sources_provider_fields%', 'a link has no account');
select tests.throws($$insert into calendar_sources (family_id, provider, name) values ('00000000-0000-0000-0000-00000000f001', 'ics', '   ')$$,
                    '%calendar_sources_name%', 'a calendar needs a name');
select tests.throws($$insert into calendar_sources (family_id, provider, name, color) values ('00000000-0000-0000-0000-00000000f001', 'ics', 'Red', 'red')$$,
                    '%calendar_sources_color_hex%', 'colors are #RRGGBB');
select tests.throws($$insert into calendar_sources (family_id, provider, name, member_id)
                      values ('00000000-0000-0000-0000-00000000f001', 'ics', 'Theirs', '00000000-0000-0000-0000-00000000b001')$$,
                    'that person isn''t in this family', 'the person must be in the family');
select tests.throws($$insert into calendar_sources (family_id, provider, name, account_id, google_calendar_id)
                      values ('00000000-0000-0000-0000-00000000f002', 'google', 'Stolen', 'ac000000-0000-0000-0000-000000000001', 'x')$$,
                    'that account isn''t in this family', 'the account must be the family''s');

-- ───────────────────────── calendar_apply_sync ─────────────────────────

select tests.eq(calendar_apply_sync(:'school', $$[
  {"uid": "fair", "title": "Science fair", "description": "Gym", "location": "School", "starts_at": "2026-10-20T15:00:00Z", "ends_at": "2026-10-20T17:00:00Z"},
  {"uid": "break@2026-10-23", "title": "Fall break", "starts_at": "2026-10-23T04:00:00Z", "ends_at": "2026-10-24T03:59:59Z", "all_day": true},
  {"uid": "break@2026-10-24", "title": "  ", "starts_at": "2026-10-24T04:00:00Z", "ends_at": "2026-10-25T03:59:59Z", "all_day": true},
  {"uid": "fair", "title": "Duplicate uid: the first one wins", "starts_at": "2026-10-21T15:00:00Z", "ends_at": "2026-10-21T16:00:00Z"},
  {"uid": "", "title": "No uid", "starts_at": "2026-10-21T15:00:00Z", "ends_at": "2026-10-21T16:00:00Z"},
  {"uid": "backwards", "title": "Ends first", "starts_at": "2026-10-21T15:00:00Z", "ends_at": "2026-10-21T14:00:00Z"},
  {"uid": "nostart", "title": "No start", "ends_at": "2026-10-21T14:00:00Z"},
  {"uid": "forever", "title": "Infinite", "starts_at": "2026-10-21T15:00:00Z", "ends_at": "infinity"}
]$$::jsonb), '{"added": 3, "updated": 0, "removed": 0, "event_count": 3}'::jsonb, 'three good rows go in');

select tests.eq((select array_agg(title order by external_id) from events where source_id = :'school'),
                array['Fall break', 'Untitled event', 'Science fair'], 'titles, with a blank one named');
select tests.eq((select array_agg(distinct color) from events where source_id = :'school'), array['#3366CC'],
                'events take the calendar''s color');
select tests.eq((select external_source from events where source_id = :'school' limit 1), 'ics', 'external_source is the provider');
select tests.ok((select last_synced_at is not null and last_attempt_at is not null and last_error is null and event_count = 3
                   from calendar_sources where id = :'school'), 'the calendar records the sync');

-- The same rows again change nothing, so Realtime stays quiet.
create temp table before_resync as select id, updated_at from events where source_id = :'school';
select tests.eq(calendar_apply_sync(:'school', $$[
  {"uid": "fair", "title": "Science fair", "description": "Gym", "location": "School", "starts_at": "2026-10-20T15:00:00Z", "ends_at": "2026-10-20T17:00:00Z"},
  {"uid": "break@2026-10-23", "title": "Fall break", "starts_at": "2026-10-23T04:00:00Z", "ends_at": "2026-10-24T03:59:59Z", "all_day": true},
  {"uid": "break@2026-10-24", "title": "", "starts_at": "2026-10-24T04:00:00Z", "ends_at": "2026-10-25T03:59:59Z", "all_day": true}
]$$::jsonb), '{"added": 0, "updated": 0, "removed": 0, "event_count": 3}'::jsonb, 'nothing new');
select tests.ok(not exists (select 1 from events e join before_resync b using (id) where e.updated_at <> b.updated_at),
                'unchanged rows are not rewritten');

-- A moved event keeps its id; a cancelled one goes.
select tests.eq(calendar_apply_sync(:'school', $$[
  {"uid": "fair", "title": "Science fair (moved)", "location": "School", "starts_at": "2026-10-22T15:00:00Z", "ends_at": "2026-10-22T17:00:00Z"},
  {"uid": "break@2026-10-23", "title": "Fall break", "starts_at": "2026-10-23T04:00:00Z", "ends_at": "2026-10-24T03:59:59Z", "all_day": true},
  {"uid": "picture-day", "title": "Picture day", "starts_at": "2026-10-27T13:00:00Z", "ends_at": "2026-10-27T14:00:00Z"}
]$$::jsonb), '{"added": 1, "updated": 1, "removed": 1, "event_count": 3}'::jsonb, 'one moved, one gone, one new');
select tests.ok((select id from events where source_id = :'school' and external_id = 'fair')
                  = (select id from before_resync b join events e using (id) where e.external_id = 'fair'),
                'a changed event keeps its id');
select tests.eq((select description from events where source_id = :'school' and external_id = 'fair'), null::text,
                'a dropped description goes');

-- Long text is clipped.
select tests.eq(calendar_apply_sync(:'work', jsonb_build_array(jsonb_build_object(
  'uid', 'standup', 'title', repeat('t', 900), 'description', repeat('d', 5000), 'location', repeat('l', 900),
  'starts_at', '2026-10-21T13:00:00Z', 'ends_at', '2026-10-21T13:15:00Z'))),
  '{"added": 1, "updated": 0, "removed": 0, "event_count": 1}'::jsonb, 'the work calendar syncs');
select tests.eq((select array[length(title), length(description), length(location)] from events where source_id = :'work'),
                array[500, 4000, 500], 'title, description and location are clipped');
select tests.eq((select array_agg(member_id) from event_members em join events e on e.id = em.event_id where e.source_id = :'work'),
                array[:'m_mom'::uuid], 'events are for the calendar''s person');
select tests.eq((select color from events where source_id = :'work'), null::text, 'no calendar color: the person''s shows');

select tests.throws(format('select calendar_apply_sync(%L, %L)', :'school', '{"uid": "x"}'), 'rows must be a JSON array', 'rows must be an array');
select tests.throws(format('select calendar_apply_sync(%L, null)', :'school'), 'rows must be a JSON array', 'rows are required');
select tests.throws(format('select calendar_apply_sync(%L, %L)', 'c0000000-0000-0000-0000-0000000000ff', '[]'), 'calendar not found', 'unknown calendar');
select tests.throws(format('select calendar_apply_sync(%L, %L)', :'school',
                           (select jsonb_agg(jsonb_build_object('uid', g::text, 'starts_at', '2026-10-21T13:00:00Z', 'ends_at', '2026-10-21T13:15:00Z'))
                              from generate_series(1, 5001) g)),
                    'too many events (at most 5000)', 'at most 5000 rows');

-- ───────────────────────── Who sees what ─────────────────────────

select tests.login(:'mom');
select tests.eq((select count(*)::int from calendar_sources), 2, 'a parent sees the family''s calendars');
select tests.eq((select count(*)::int from calendar_accounts), 1, 'a parent sees the Google accounts');
select tests.throws('select * from calendar_account_tokens', 'permission denied%', 'tokens are secret');
select tests.throws('select * from calendar_source_links', 'permission denied%', 'links are secret');
select tests.throws(format('insert into calendar_sources (family_id, provider, name) values (%L, %L, %L)', :'fam', 'ics', 'Mine'),
                    'permission denied%', 'calendars are added through calendar-sync');
select tests.throws(format('insert into calendar_accounts (family_id, email, created_by) values (%L, %L, %L)', :'fam', 'x@gmail.com', :'mom'),
                    'permission denied%', 'accounts are added through calendar-sync');
select tests.throws(format('delete from calendar_accounts where id = %L', :'acct'), 'permission denied%',
                    'accounts are disconnected through calendar-sync');
select tests.throws('select calendar_apply_sync(''c0000000-0000-0000-0000-000000000001'', ''[]'')', 'permission denied%',
                    'clients can''t write imported events through the sync');
select tests.throws('select * from calendar_claim_due()', 'permission denied%', 'clients can''t claim calendars');

-- event_occurrences says where an event came from.
select tests.eq((select array_agg(distinct source_id) from event_occurrences(:'fam', '2026-10-19', '2026-10-30') where title = 'Fall break'),
                array[:'school'::uuid], 'event_occurrences returns source_id');
insert into events (family_id, title, starts_at, ends_at) values (:'fam', 'Bake sale', '2026-10-22 10:00Z', '2026-10-22 11:00Z');
select tests.eq((select source_id from event_occurrences(:'fam', '2026-10-19', '2026-10-30') where title = 'Bake sale'), null::uuid,
                'the family''s own events have no source');
select tests.eq((select member_ids from event_occurrences(:'fam', '2026-10-19', '2026-10-30') where source_id = :'work'),
                array[:'m_mom'::uuid], 'imported events list their person');

select tests.login(:'emma');
select tests.eq((select count(*)::int from calendar_sources), 2, 'a child sees the calendars');
select tests.eq((select count(*)::int from calendar_accounts), 0, 'a child doesn''t see the Google accounts');
select tests.eq(tests.affected(format('update calendar_sources set name = %L where id = %L', 'Mine', :'school')), 0, 'a child can''t rename a calendar');
select tests.eq(tests.affected(format('delete from calendar_sources where id = %L', :'school')), 0, 'a child can''t remove a calendar');

select tests.login(:'device');
select tests.eq((select count(*)::int from calendar_sources), 2, 'the display sees the calendars');
select tests.eq((select count(*)::int from calendar_accounts), 0, 'the display doesn''t see the accounts');

select tests.login(:'other');
select tests.eq((select count(*)::int from calendar_sources), 0, 'another family sees no calendars');
select tests.eq((select count(*)::int from events where source_id is not null), 0, 'another family sees no imported events');
select tests.eq(tests.affected(format('delete from calendar_sources where id = %L', :'school')), 0, 'another family can''t remove one');

-- ───────────────────────── Imported events are read-only ─────────────────────────

select tests.login(:'mom');
select tests.throws(format('update events set title = %L where source_id = %L', 'Mine now', :'school'),
                    'this event comes from a connected calendar; change it there', 'imported events can''t be edited');
select tests.throws(format('delete from events where source_id = %L', :'school'),
                    'this event comes from a connected calendar; change it there', 'imported events can''t be deleted');
select tests.throws(format('insert into events (family_id, title, starts_at, ends_at, source_id, external_id) values (%L, %L, now(), now(), %L, %L)',
                           :'fam', 'Fake', :'school', 'fake'),
                    'only calendar sync can add events from a connected calendar', 'clients can''t add imported events');
select tests.throws(format('update events set source_id = %L, external_id = %L where title = %L', :'school', 'x', 'Bake sale'),
                    'only calendar sync can add events from a connected calendar', 'clients can''t adopt an event into a calendar');
select tests.throws(format('insert into event_members (event_id, member_id) select id, %L from events where external_id = %L', :'m_leo', 'fair'),
                    'this event comes from a connected calendar; change it there', 'who an imported event is for comes from its calendar');
select tests.throws(format('delete from event_members where member_id = %L', :'m_mom'),
                    'this event comes from a connected calendar; change it there', 'imported links can''t be removed');
select tests.eq(tests.affected(format('update events set title = %L where title = %L', 'Bake sale!', 'Bake sale')), 1,
                'the family''s own events stay editable');
select tests.eq(tests.affected(format('insert into event_members (event_id, member_id) select id, %L from events where title = %L', :'m_leo', 'Bake sale!')), 1,
                'and so do their people');

-- ───────────────────────── Parents' settings ─────────────────────────

select tests.throws(format('update calendar_sources set last_error = null, event_count = 99 where id = %L', :'school'),
                    'only a calendar''s name, color, person, privacy and on/off can be changed', 'sync fields are the sync''s');
select tests.throws(format('update calendar_sources set provider = %L where id = %L', 'google', :'school'),
                    'only a calendar''s name, color, person, privacy and on/off can be changed', 'the provider is fixed');
select tests.throws(format('update calendar_sources set member_id = %L where id = %L', :'m_other', :'school'),
                    'that person isn''t in this family', 'only the family''s people');

-- A new color and person apply to the events already here.
select tests.eq(tests.affected(format('update calendar_sources set name = %L, color = %L, member_id = %L where id = %L',
                                      'Leo''s school', '#22AA55', :'m_leo', :'school')), 1, 'a parent changes a calendar');
select tests.eq((select array_agg(distinct color) from events where source_id = :'school'), array['#22AA55'], 'the new color shows at once');
select tests.eq((select count(*)::int from event_members em join events e on e.id = em.event_id
                  where e.source_id = :'school' and em.member_id = :'m_leo'), 3, 'every event is now Leo''s');
select tests.eq(tests.affected(format('update calendar_sources set member_id = null where id = %L', :'school')), 1, 'nobody in particular');
select tests.eq((select count(*)::int from event_members em join events e on e.id = em.event_id where e.source_id = :'school'), 0,
                'and the links go');

-- Busy only hides the details at once.
select tests.eq(tests.affected(format('update calendar_sources set busy_only = true where id = %L', :'work')), 1, 'show work as busy');
-- Mom's Google calendar shows its details again only when Mom says so.
select tests.login(:'dad');
select tests.throws(format('update calendar_sources set busy_only = false where id = %L', :'work'),
                    'only the person who connected this Google account can show its details', 'not another parent');
select tests.eq(tests.affected(format('update calendar_sources set name = %L where id = %L', 'Mom (work)', :'work')), 1,
                'another parent may still rename it');
select tests.login(:'mom');
select tests.ok((select bool_and(title = 'Busy' and description is null and location is null) from events where source_id = :'work'),
                'titles become Busy');
select tests.login_service();
select calendar_apply_sync(:'work', '[{"uid": "standup", "title": "Standup", "description": "Room 4", "location": "HQ", "starts_at": "2026-10-21T13:00:00Z", "ends_at": "2026-10-21T13:15:00Z"}]');
select tests.eq((select array[title, description, location] from events where source_id = :'work'), array['Busy', null, null],
                'and stay Busy on the next sync');

-- Off removes the events; the next sync brings nothing in.
select tests.login(:'mom');
select tests.eq(tests.affected(format('update calendar_sources set busy_only = false where id = %L', :'work')), 1,
                'the parent who connected it can show the details again');
select tests.eq(tests.affected(format('update calendar_sources set enabled = false where id = %L', :'work')), 1, 'turn work off');
select tests.eq((select count(*)::int from events where source_id = :'work'), 0, 'its events go');
select tests.eq((select event_count from calendar_sources where id = :'work'), 0, 'and the count');
select tests.login_service();
select tests.eq(calendar_apply_sync(:'work', '[{"uid": "standup", "title": "Standup", "starts_at": "2026-10-21T13:00:00Z", "ends_at": "2026-10-21T13:15:00Z"}]')->>'event_count',
                '0', 'a sync that was already running brings nothing in');

-- Removing a person still works when imported events are theirs.
select tests.login_service();
insert into calendar_sources (id, family_id, provider, name, member_id)
values ('c0000000-0000-0000-0000-000000000005', :'fam', 'ics', 'Soccer club', :'m_leo');
select calendar_apply_sync('c0000000-0000-0000-0000-000000000005', '[{"uid": "game", "title": "Game", "starts_at": "2026-10-24T15:00:00Z", "ends_at": "2026-10-24T16:00:00Z"}]');
select tests.login(:'mom');
select tests.eq(tests.affected(format('delete from members where id = %L', :'m_leo')), 1, 'a parent removes a member with imported events');
select tests.eq((select member_id from calendar_sources where id = 'c0000000-0000-0000-0000-000000000005'), null::uuid,
                'their calendar is nobody''s now');
select tests.eq((select count(*)::int from events where source_id = 'c0000000-0000-0000-0000-000000000005'), 1, 'its events stay');
select tests.eq(tests.affected('delete from calendar_sources where id = ''c0000000-0000-0000-0000-000000000005'''), 1, 'and go with it');

-- ───────────────────────── calendar_claim_due ─────────────────────────

select tests.login_service();
update calendar_sources set last_attempt_at = null;
select tests.eq(array(select id from calendar_claim_due()), array[:'school'::uuid], 'enabled calendars are due');
select tests.eq(array(select id from calendar_claim_due()), array[]::uuid[], 'a claimed calendar waits');
select tests.eq(array(select id from calendar_claim_due(20, 0)), array[:'school'::uuid], 'unless asked for at once');
select tests.eq(array(select id from calendar_claim_due(20, 0, :'fam2')), array[]::uuid[], 'only_family narrows');
select tests.eq(array(select id from calendar_claim_due(20, 0, null, :'work')), array[]::uuid[], 'a calendar that''s off isn''t due');
update calendar_sources set enabled = true where id = :'work';
select tests.eq(array(select id from calendar_claim_due(20, 0, :'fam', :'work')), array[:'work'::uuid], 'only_source narrows');
select tests.eq(array(select id from calendar_claim_due(1, 0)), array[:'school'::uuid], 'least recently tried first, up to lim');
update families set status = 'suspended' where id = :'fam';
select tests.eq(array(select id from calendar_claim_due(20, 0)), array[]::uuid[], 'a suspended family''s calendars wait');
select tests.throws(format('select calendar_apply_sync(%L, %L)', :'school', '[]'), 'this family is suspended', 'and don''t sync');
update families set status = 'active' where id = :'fam';

-- ───────────────────────── The shared link ─────────────────────────

select tests.login(:'mom');
create temp table feed as select calendar_feed_token(:'fam') as token;
select tests.ok((select token ~ '^[A-Za-z0-9_-]{32}$' from feed), 'a 32-character URL-safe token');
select tests.eq(calendar_feed_token(:'fam'), (select token from feed), 'the same link until it''s replaced');
select tests.ok(calendar_feed_token(:'fam', true) <> (select token from feed), 'rotate makes a new link');
select tests.eq((select count(*)::int from calendar_feeds), 1, 'a parent sees the link');
select tests.throws(format('select calendar_feed_token(%L)', :'fam2'), 'only a parent can share the family calendar', 'not another family''s');
select tests.login(:'emma');
select tests.throws(format('select calendar_feed_token(%L)', :'fam'), 'only a parent can share the family calendar', 'not a child');
select tests.eq((select count(*)::int from calendar_feeds), 0, 'a child doesn''t see the link');
select tests.login(:'device');
select tests.throws(format('select calendar_feed_token(%L)', :'fam'), 'only a parent can share the family calendar', 'not the display');
select tests.login(null);
select tests.throws(format('select calendar_feed_token(%L)', :'fam'), 'permission denied%', 'not signed out');
select tests.login(:'mom');
select tests.eq(tests.affected(format('delete from calendar_feeds where family_id = %L', :'fam')), 1, 'a parent stops sharing');

-- ───────────────────────── Removing things ─────────────────────────

-- Removing a calendar takes its events (past the read-only guard).
select tests.eq(tests.affected(format('delete from calendar_sources where id = %L', :'school')), 1, 'a parent removes a calendar');
select tests.eq((select count(*)::int from events where external_source = 'ics'), 0, 'its events go with it');

-- Dad connects his own Google account; Mom leaves the family, and hers goes.
select tests.login_service();
insert into calendar_accounts (id, family_id, email, created_by) values (:'dadacct', :'fam', 'dad@gmail.com', :'dad');
insert into calendar_sources (id, family_id, provider, account_id, google_calendar_id, name)
values (:'dadcal', :'fam', 'google', :'dadacct', 'dad@gmail.com', 'Dad');
select calendar_apply_sync(:'work', '[{"uid": "standup", "title": "Standup", "starts_at": "2026-10-21T13:00:00Z", "ends_at": "2026-10-21T13:15:00Z"}]');
select calendar_apply_sync(:'dadcal', '[{"uid": "run", "title": "Run", "starts_at": "2026-10-21T11:00:00Z", "ends_at": "2026-10-21T12:00:00Z"}]');
select tests.login(:'mom');
select leave_family(:'fam');
select tests.logout();
select tests.eq((select array_agg(email) from calendar_accounts), array['dad@gmail.com'], 'a parent''s Google account leaves with them');
select tests.eq((select count(*)::int from events where source_id = :'work'), 0, 'with its calendars'' events');
select tests.eq((select count(*)::int from events where source_id = :'dadcal'), 1, 'the other parent''s stay');

-- Deleting a login takes that person's Google accounts.
delete from auth.users where id = :'dad';
select tests.eq((select count(*)::int from calendar_accounts), 0, 'a deleted login''s accounts go');
select tests.eq((select count(*)::int from events where source_id is not null), 0, 'and their events');

-- Imported events don't make a family look active.
insert into families (id, name, created_at) values (:'fam3', 'Quiet House', now() - interval '30 days');
insert into calendar_sources (id, family_id, provider, name) values ('c0000000-0000-0000-0000-000000000004', :'fam3', 'ics', 'Holidays');
select calendar_apply_sync('c0000000-0000-0000-0000-000000000004', '[{"uid": "h", "title": "Holiday", "starts_at": "2026-12-25T00:00:00Z", "ends_at": "2026-12-25T23:59:59Z", "all_day": true}]');
select tests.eq(family_last_activity(:'fam3'), (select created_at from families where id = :'fam3'),
                'family_last_activity ignores imported events');

-- Deleting a family takes everything.
delete from families where id = :'fam3';
select tests.eq((select count(*)::int from calendar_sources where family_id = :'fam3'), 0, 'a deleted family''s calendars go');
