-- Repeats: rrule_occurs_on / rrule_days (the RFC 5545 subset in
-- docs/PLATFORM_SPEC.md §1.11), event_occurrences and chores_due.
-- Expected days are worked out by hand; most series are the examples in
-- RFC 5545 §3.8.5.3, with dates (not times) and our UNTIL rule noted.
\set ON_ERROR_STOP 1
\set fam     '00000000-0000-0000-0000-00000000f001'
\set fam2    '00000000-0000-0000-0000-00000000f002'
\set m_mom   '00000000-0000-0000-0000-00000000a001'
\set m_emma  '00000000-0000-0000-0000-00000000a003'
\set m_leo   '00000000-0000-0000-0000-00000000a004'
\set m_other '00000000-0000-0000-0000-00000000b001'
\set mom     'a0000000-0000-0000-0000-000000000001'
\set other   'a0000000-0000-0000-0000-000000000099'
\set device  'd0000000-0000-0000-0000-000000000001'

-- Nothing below may depend on the session's zone.
set timezone = 'Asia/Tokyo';

-- Safe to run again (it may have been pasted into the SQL editor before a
-- push). The privilege checks at the end run after this second pass.
\ir ../supabase/migrations/20261010000001_recurrence.sql

-- ───────────────────────── rrule_occurs_on: single days ─────────────────────────

create temp table one_day (what text, rule text, dtstart date, day date, inst boolean, expected boolean);
insert into one_day values
  -- No rule, or none we can use: the first day only
  ('no rule: dtstart',                   null, '2026-10-07', '2026-10-07', true,  true),
  ('no rule: chore anchor',              null, '2026-10-07', '2026-10-07', false, true),
  ('no rule: not the next day',          null, '2026-10-07', '2026-10-08', true,  false),
  ('blank rule: dtstart',                '  ', '2026-10-07', '2026-10-07', true,  true),
  ('blank rule: not a week on',          '',   '2026-10-07', '2026-10-14', true,  false),
  ('unknown FREQ: dtstart',              'FREQ=FORTNIGHTLY', '2026-10-07', '2026-10-07', false, true),
  ('unknown FREQ: no repeats',           'FREQ=FORTNIGHTLY', '2026-10-07', '2026-10-21', true,  false),
  ('missing FREQ: dtstart',              'INTERVAL=1', '2026-10-07', '2026-10-07', true, true),
  ('missing FREQ: no repeats',           'BYDAY=MO,TU,WE,TH,FR,SA,SU', '2026-10-07', '2026-10-08', true, false),
  ('FREQ without a value',               'FREQ', '2026-10-07', '2026-10-08', true, false),
  ('null day',                           'FREQ=DAILY', '2026-10-07', null, true, false),
  ('null dtstart',                       'FREQ=DAILY', null, '2026-10-07', true, false),
  ('day before dtstart',                 'FREQ=DAILY', '2026-10-07', '2026-10-06', true,  false),
  ('day before dtstart, chore',          'FREQ=DAILY', '2026-10-07', '2026-10-06', false, false),
  -- Syntax
  ('RRULE: prefix',                      'RRULE:FREQ=WEEKLY;BYDAY=TH', '2026-10-07', '2026-10-08', false, true),
  ('lower case and spaces',              ' freq=weekly; byday=th ', '2026-10-07', '2026-10-15', false, true),
  ('lower case: other weekday',          'freq=weekly;byday=th', '2026-10-07', '2026-10-14', false, false),
  ('empty parts',                        'FREQ=DAILY;;', '2026-10-07', '2026-10-08', false, true),
  ('the last FREQ wins',                 'FREQ=DAILY;FREQ=WEEKLY', '2026-10-07', '2026-10-08', false, false),
  ('the last FREQ wins: a week on',      'FREQ=DAILY;FREQ=WEEKLY', '2026-10-07', '2026-10-14', false, true),
  -- A Wednesday "weekends" series: chores start on the pattern, events on dtstart (2026-10-07 is a Wednesday)
  ('weekend chore: not its Wednesday',   'FREQ=WEEKLY;BYDAY=SA,SU', '2026-10-07', '2026-10-07', false, false),
  ('weekend event: its Wednesday',       'FREQ=WEEKLY;BYDAY=SA,SU', '2026-10-07', '2026-10-07', true,  true),
  ('weekend chore: Saturday',            'FREQ=WEEKLY;BYDAY=SA,SU', '2026-10-07', '2026-10-10', false, true),
  ('weekend chore: Sunday',              'FREQ=WEEKLY;BYDAY=SA,SU', '2026-10-07', '2026-10-11', false, true),
  ('weekend chore: Thursday',            'FREQ=WEEKLY;BYDAY=SA,SU', '2026-10-07', '2026-10-08', false, false),
  ('weekend event: next Wednesday',      'FREQ=WEEKLY;BYDAY=SA,SU', '2026-10-07', '2026-10-14', true,  false),
  -- More often than daily is every day; INTERVAL doesn't apply, BYDAY still filters
  ('HOURLY',                             'FREQ=HOURLY', '2026-10-07', '2026-10-09', false, true),
  ('MINUTELY ignores INTERVAL',          'FREQ=MINUTELY;INTERVAL=4000', '2026-10-07', '2026-10-08', false, true),
  ('SECONDLY',                           'FREQ=SECONDLY', '2026-10-07', '2026-12-25', true, true),
  ('HOURLY on Saturdays: a Friday',      'FREQ=HOURLY;BYDAY=SA', '2026-10-07', '2026-10-09', false, false),
  -- DAILY
  ('every 3 days, over a month end',     'FREQ=DAILY;INTERVAL=3', '2026-01-30', '2026-02-02', false, true),
  ('every 3 days: off day',              'FREQ=DAILY;INTERVAL=3', '2026-01-30', '2026-02-03', false, false),
  ('DAILY BYDAY: Friday',                'FREQ=DAILY;BYDAY=MO,WE,FR', '2026-10-07', '2026-10-09', false, true),
  ('DAILY BYDAY: Thursday',              'FREQ=DAILY;BYDAY=MO,WE,FR', '2026-10-07', '2026-10-08', false, false),
  ('DAILY BYDAY ignores ordinals',       'FREQ=DAILY;BYDAY=1FR', '2026-10-07', '2026-10-16', false, true),
  ('DAILY BYMONTH: November',            'FREQ=DAILY;BYMONTH=12', '2026-10-07', '2026-11-30', false, false),
  ('DAILY BYMONTH: December',            'FREQ=DAILY;BYMONTH=12', '2026-10-07', '2026-12-01', false, true),
  ('DAILY BYMONTHDAY: the 15th',         'FREQ=DAILY;BYMONTHDAY=1,15', '2026-10-07', '2026-10-15', false, true),
  ('DAILY BYMONTHDAY: the 16th',         'FREQ=DAILY;BYMONTHDAY=1,15', '2026-10-07', '2026-10-16', false, false),
  ('every 2 days on Saturday: odd',      'FREQ=DAILY;INTERVAL=2;BYDAY=SA', '2026-10-07', '2026-10-10', false, false),
  ('every 2 days on Saturday: even',     'FREQ=DAILY;INTERVAL=2;BYDAY=SA', '2026-10-07', '2026-10-17', false, true),
  -- WEEKLY
  ('WEEKLY: dtstart''s weekday',         'FREQ=WEEKLY', '2026-10-07', '2026-10-14', false, true),
  ('WEEKLY: other weekday',              'FREQ=WEEKLY', '2026-10-07', '2026-10-15', false, false),
  ('every 2 weeks: next week',           'FREQ=WEEKLY;INTERVAL=2', '2026-10-07', '2026-10-14', true, false),
  ('every 2 weeks: two weeks on',        'FREQ=WEEKLY;INTERVAL=2', '2026-10-07', '2026-10-21', true, true),
  ('2 weeks MO,TH: Thursday of week 0',  'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH', '2026-10-07', '2026-10-08', false, true),
  ('2 weeks MO,TH: Monday of week 1',    'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH', '2026-10-07', '2026-10-12', false, false),
  ('2 weeks MO,TH: Thursday of week 1',  'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH', '2026-10-07', '2026-10-15', false, false),
  ('2 weeks MO,TH: Monday of week 2',    'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH', '2026-10-07', '2026-10-19', false, true),
  ('2 weeks MO,TH: Thursday of week 4',  'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH', '2026-10-07', '2026-11-05', false, true),
  ('WKST=MO: Sunday closes week 0',      'FREQ=WEEKLY;INTERVAL=2;BYDAY=SU;WKST=MO', '2026-10-07', '2026-10-11', false, true),
  ('WKST=MO: next Sunday is week 1',     'FREQ=WEEKLY;INTERVAL=2;BYDAY=SU;WKST=MO', '2026-10-07', '2026-10-18', false, false),
  ('WKST defaults to MO',                'FREQ=WEEKLY;INTERVAL=2;BYDAY=SU', '2026-10-07', '2026-10-11', false, true),
  ('WKST=SU: Sunday opens week 1',       'FREQ=WEEKLY;INTERVAL=2;BYDAY=SU;WKST=SU', '2026-10-07', '2026-10-11', false, false),
  ('WKST=SU: the Sunday of week 2',      'FREQ=WEEKLY;INTERVAL=2;BYDAY=SU;WKST=SU', '2026-10-07', '2026-10-18', false, true),
  ('WEEKLY BYDAY ignores ordinals',      'FREQ=WEEKLY;BYDAY=2TU', '2026-10-07', '2026-10-27', false, true),
  ('WEEKLY BYMONTH: October',            'FREQ=WEEKLY;BYDAY=MO;BYMONTH=11', '2026-10-07', '2026-10-12', false, false),
  ('WEEKLY BYMONTH: November',           'FREQ=WEEKLY;BYDAY=MO;BYMONTH=11', '2026-10-07', '2026-11-02', false, true),
  -- MONTHLY
  ('MONTHLY: dtstart''s day',            'FREQ=MONTHLY', '2026-10-07', '2026-11-07', false, true),
  ('MONTHLY: the day after',             'FREQ=MONTHLY', '2026-10-07', '2026-11-08', false, false),
  ('31st: no Feb 28',                    'FREQ=MONTHLY', '2026-01-31', '2026-02-28', false, false),
  ('31st: March 31',                     'FREQ=MONTHLY', '2026-01-31', '2026-03-31', false, true),
  ('31st: no April 30',                  'FREQ=MONTHLY', '2026-01-31', '2026-04-30', false, false),
  ('29th: no Feb 28 in 2027',            'FREQ=MONTHLY', '2027-01-29', '2027-02-28', false, false),
  ('29th: March 29 2027',                'FREQ=MONTHLY', '2027-01-29', '2027-03-29', false, true),
  ('29th: Feb 29 2028',                  'FREQ=MONTHLY', '2028-01-29', '2028-02-29', false, true),
  ('every 3 months: 3 on',               'FREQ=MONTHLY;INTERVAL=3', '2026-01-15', '2026-04-15', false, true),
  ('every 3 months: 2 on',               'FREQ=MONTHLY;INTERVAL=3', '2026-01-15', '2026-03-15', false, false),
  ('every 3 months: a year on',          'FREQ=MONTHLY;INTERVAL=3', '2026-01-15', '2027-01-15', false, true),
  ('2nd Tuesday: Jan 13',                'FREQ=MONTHLY;BYDAY=2TU', '2026-01-01', '2026-01-13', false, true),
  ('2nd Tuesday: Feb 10',                'FREQ=MONTHLY;BYDAY=2TU', '2026-01-01', '2026-02-10', false, true),
  ('2nd Tuesday: Apr 14',                'FREQ=MONTHLY;BYDAY=2TU', '2026-01-01', '2026-04-14', false, true),
  ('2nd Tuesday: not the 1st',           'FREQ=MONTHLY;BYDAY=2TU', '2026-01-01', '2026-04-07', false, false),
  ('2nd Tuesday: not the 3rd',           'FREQ=MONTHLY;BYDAY=2TU', '2026-01-01', '2026-04-21', false, false),
  ('last Friday: Jan 30',                'FREQ=MONTHLY;BYDAY=-1FR', '2026-01-01', '2026-01-30', false, true),
  ('last Friday: Feb 27',                'FREQ=MONTHLY;BYDAY=-1FR', '2026-01-01', '2026-02-27', false, true),
  ('last Friday: Apr 24',                'FREQ=MONTHLY;BYDAY=-1FR', '2026-01-01', '2026-04-24', false, true),
  ('last Friday: not Jan 23',            'FREQ=MONTHLY;BYDAY=-1FR', '2026-01-01', '2026-01-23', false, false),
  ('+1MO: Feb 2',                        'FREQ=MONTHLY;BYDAY=+1MO', '2026-01-01', '2026-02-02', false, true),
  ('+1MO: not Feb 9',                    'FREQ=MONTHLY;BYDAY=+1MO', '2026-01-01', '2026-02-09', false, false),
  ('5th Monday: Mar 30',                 'FREQ=MONTHLY;BYDAY=5MO', '2026-01-01', '2026-03-30', false, true),
  ('5th Monday: Aug 31',                 'FREQ=MONTHLY;BYDAY=5MO', '2026-01-01', '2026-08-31', false, true),
  ('5th Monday: October has four',       'FREQ=MONTHLY;BYDAY=5MO', '2026-01-01', '2026-10-26', false, false),
  ('MONTHLY every Monday',               'FREQ=MONTHLY;BYDAY=MO', '2026-01-01', '2026-10-26', false, true),
  ('MONTHLY every Monday: a Tuesday',    'FREQ=MONTHLY;BYDAY=MO', '2026-01-01', '2026-10-27', false, false),
  ('last day: Feb 28 2026',              'FREQ=MONTHLY;BYMONTHDAY=-1', '2026-01-01', '2026-02-28', false, true),
  ('last day: Feb 29 2028',              'FREQ=MONTHLY;BYMONTHDAY=-1', '2026-01-01', '2028-02-29', false, true),
  ('last day: not Feb 28 2028',          'FREQ=MONTHLY;BYMONTHDAY=-1', '2026-01-01', '2028-02-28', false, false),
  ('last day: Apr 30',                   'FREQ=MONTHLY;BYMONTHDAY=-1', '2026-01-01', '2026-04-30', false, true),
  ('BYMONTHDAY=31: April has none',      'FREQ=MONTHLY;BYMONTHDAY=31', '2026-01-01', '2026-04-30', false, false),
  ('BYMONTHDAY=31: May 31',              'FREQ=MONTHLY;BYMONTHDAY=31', '2026-01-01', '2026-05-31', false, true),
  ('BYMONTHDAY=-31: Jan 1',              'FREQ=MONTHLY;BYMONTHDAY=-31', '2026-01-01', '2026-01-01', false, true),
  ('BYMONTHDAY=-31: none in February',   'FREQ=MONTHLY;BYMONTHDAY=-31', '2026-01-01', '2026-02-01', false, false),
  ('BYMONTHDAY=-31: Mar 1',              'FREQ=MONTHLY;BYMONTHDAY=-31', '2026-01-01', '2026-03-01', false, true),
  ('Friday 13th: Feb 13',                'FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13', '2026-01-01', '2026-02-13', false, true),
  ('Friday 13th: a Friday 20th',         'FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13', '2026-01-01', '2026-02-20', false, false),
  ('Friday 13th: a Monday 13th',         'FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13', '2026-01-01', '2026-04-13', false, false),
  ('MONTHLY BYMONTH: July',              'FREQ=MONTHLY;BYMONTH=1,7', '2026-01-05', '2026-07-05', false, true),
  ('MONTHLY BYMONTH: June',              'FREQ=MONTHLY;BYMONTH=1,7', '2026-01-05', '2026-06-05', false, false),
  -- YEARLY
  ('YEARLY: a year on',                  'FREQ=YEARLY', '2026-10-07', '2027-10-07', false, true),
  ('YEARLY: a day off',                  'FREQ=YEARLY', '2026-10-07', '2027-10-08', false, false),
  ('YEARLY: a month off',                'FREQ=YEARLY', '2026-10-07', '2027-11-07', false, false),
  ('every 2 years: 1 on',                'FREQ=YEARLY;INTERVAL=2', '2026-10-07', '2027-10-07', false, false),
  ('every 2 years: 2 on',                'FREQ=YEARLY;INTERVAL=2', '2026-10-07', '2028-10-07', false, true),
  ('Feb 29: not Feb 28 2025',            'FREQ=YEARLY', '2024-02-29', '2025-02-28', false, false),
  ('Feb 29: not Mar 1 2025',             'FREQ=YEARLY', '2024-02-29', '2025-03-01', false, false),
  ('Feb 29: not Feb 28 2027',            'FREQ=YEARLY', '2024-02-29', '2027-02-28', false, false),
  ('Feb 29: 2028',                       'FREQ=YEARLY', '2024-02-29', '2028-02-29', false, true),
  ('Thanksgiving 2026',                  'FREQ=YEARLY;BYMONTH=11;BYDAY=4TH', '2025-11-27', '2026-11-26', true, true),
  ('Thanksgiving 2027',                  'FREQ=YEARLY;BYMONTH=11;BYDAY=4TH', '2025-11-27', '2027-11-25', true, true),
  ('Thanksgiving: not the 3rd Thursday', 'FREQ=YEARLY;BYMONTH=11;BYDAY=4TH', '2025-11-27', '2026-11-19', true, false),
  ('Memorial Day 2027',                  'FREQ=YEARLY;BYMONTH=5;BYDAY=-1MO', '2026-05-25', '2027-05-31', true, true),
  ('Memorial Day: not May 24 2027',      'FREQ=YEARLY;BYMONTH=5;BYDAY=-1MO', '2026-05-25', '2027-05-24', true, false),
  ('2nd Sunday, dtstart''s month',       'FREQ=YEARLY;BYDAY=2SU', '2026-05-10', '2027-05-09', true, true),
  ('2nd Sunday: not in June',            'FREQ=YEARLY;BYDAY=2SU', '2026-05-10', '2027-06-13', true, false),
  ('YEARLY BYMONTHDAY: not next month',  'FREQ=YEARLY;BYMONTHDAY=1', '2026-10-07', '2026-11-01', false, false),
  ('YEARLY BYMONTHDAY: a year on',       'FREQ=YEARLY;BYMONTHDAY=1', '2026-10-07', '2027-10-01', false, true),
  ('YEARLY BYMONTH: Feb',                'FREQ=YEARLY;BYMONTH=2,8', '2026-01-15', '2026-02-15', false, true),
  ('YEARLY BYMONTH: Aug',                'FREQ=YEARLY;BYMONTH=2,8', '2026-01-15', '2026-08-15', false, true),
  ('YEARLY BYMONTH: chore not on Jan',   'FREQ=YEARLY;BYMONTH=2,8', '2026-01-15', '2026-01-15', false, false),
  ('YEARLY BYMONTH: event on dtstart',   'FREQ=YEARLY;BYMONTH=2,8', '2026-01-15', '2026-01-15', true, true),
  -- UNTIL: the date as written
  ('UNTIL date: on it',                  'FREQ=DAILY;UNTIL=20261020', '2026-10-07', '2026-10-20', false, true),
  ('UNTIL date: after it',               'FREQ=DAILY;UNTIL=20261020', '2026-10-07', '2026-10-21', false, false),
  ('UNTIL floating time: on it',         'FREQ=DAILY;UNTIL=20261020T235959', '2026-10-07', '2026-10-20', false, true),
  ('UNTIL floating time: after it',      'FREQ=DAILY;UNTIL=20261020T235959', '2026-10-07', '2026-10-21', false, false),
  ('UNTIL UTC midnight: its date counts','FREQ=DAILY;UNTIL=20261020T000000Z', '2026-10-07', '2026-10-20', false, true),
  ('UNTIL UTC midnight: after it',       'FREQ=DAILY;UNTIL=20261020T000000Z', '2026-10-07', '2026-10-21', false, false),
  ('UNTIL before dtstart: event',        'FREQ=DAILY;UNTIL=20261001', '2026-10-07', '2026-10-07', true, true),
  ('UNTIL before dtstart: chore',        'FREQ=DAILY;UNTIL=20261001', '2026-10-07', '2026-10-07', false, false),
  ('UNTIL before dtstart: no repeats',   'FREQ=DAILY;UNTIL=20261001', '2026-10-07', '2026-10-08', true, false),
  -- COUNT
  ('COUNT=2: second',                    'FREQ=WEEKLY;COUNT=2', '2026-10-07', '2026-10-14', false, true),
  ('COUNT=2: third',                     'FREQ=WEEKLY;COUNT=2', '2026-10-07', '2026-10-21', false, false),
  ('COUNT with INTERVAL: third',         'FREQ=DAILY;INTERVAL=2;COUNT=3', '2026-10-07', '2026-10-11', false, true),
  ('COUNT with INTERVAL: fourth',        'FREQ=DAILY;INTERVAL=2;COUNT=3', '2026-10-07', '2026-10-13', false, false),
  ('COUNT, event: dtstart counts',       'FREQ=WEEKLY;BYDAY=SA,SU;COUNT=3', '2026-10-07', '2026-10-11', true, true),
  ('COUNT, event: 4th',                  'FREQ=WEEKLY;BYDAY=SA,SU;COUNT=3', '2026-10-07', '2026-10-17', true, false),
  ('COUNT, chore: 3rd',                  'FREQ=WEEKLY;BYDAY=SA,SU;COUNT=3', '2026-10-07', '2026-10-17', false, true),
  ('COUNT, chore: 4th',                  'FREQ=WEEKLY;BYDAY=SA,SU;COUNT=3', '2026-10-07', '2026-10-18', false, false),
  ('COUNT over 126 years: last one',     'FREQ=DAILY;COUNT=46301', '1900-01-01', '2026-10-07', true, true),
  ('COUNT over 126 years: one short',    'FREQ=DAILY;COUNT=46300', '1900-01-01', '2026-10-07', true, false),
  ('COUNT and UNTIL: both apply',        'FREQ=DAILY;COUNT=5;UNTIL=20261009', '2026-10-07', '2026-10-09', false, true),
  ('COUNT and UNTIL: UNTIL first',       'FREQ=DAILY;COUNT=5;UNTIL=20261009', '2026-10-07', '2026-10-10', false, false),
  -- Garbage values count as if the part weren't there
  ('INTERVAL=abc',                       'FREQ=DAILY;INTERVAL=abc', '2026-10-07', '2026-10-08', false, true),
  ('INTERVAL=0',                         'FREQ=DAILY;INTERVAL=0', '2026-10-07', '2026-10-08', false, true),
  ('INTERVAL=-2',                        'FREQ=DAILY;INTERVAL=-2', '2026-10-07', '2026-10-08', false, true),
  ('INTERVAL too big for an int',        'FREQ=DAILY;INTERVAL=99999999999', '2026-10-07', '2026-10-08', false, true),
  ('COUNT=abc',                          'FREQ=DAILY;COUNT=abc', '2026-10-07', '2027-10-08', false, true),
  ('COUNT=0',                            'FREQ=DAILY;COUNT=0', '2026-10-07', '2027-10-08', false, true),
  ('UNTIL with dashes',                  'FREQ=DAILY;UNTIL=2026-10-20', '2026-10-07', '2026-12-01', false, true),
  ('UNTIL month 13',                     'FREQ=DAILY;UNTIL=20261340', '2026-10-07', '2027-01-01', false, true),
  ('UNTIL Feb 29 2027',                  'FREQ=DAILY;UNTIL=20270229', '2026-10-07', '2027-03-01', false, true),
  ('UNTIL year 0',                       'FREQ=DAILY;UNTIL=00000101', '2026-10-07', '2027-03-01', false, true),
  ('BYDAY=MO,XX: dtstart''s weekday',    'FREQ=WEEKLY;BYDAY=MO,XX', '2026-10-07', '2026-10-14', false, true),
  ('BYDAY=MO,XX: not Monday',            'FREQ=WEEKLY;BYDAY=MO,XX', '2026-10-07', '2026-10-12', false, false),
  ('BYDAY=0MO',                          'FREQ=WEEKLY;BYDAY=0MO', '2026-10-07', '2026-10-14', false, true),
  ('BYDAY=+MO',                          'FREQ=WEEKLY;BYDAY=+MO', '2026-10-07', '2026-10-14', false, true),
  ('BYDAY empty',                        'FREQ=DAILY;BYDAY=', '2026-10-07', '2026-10-08', false, true),
  ('BYMONTHDAY=0: dtstart''s day',       'FREQ=MONTHLY;BYMONTHDAY=0', '2026-10-07', '2026-11-07', false, true),
  ('BYMONTHDAY=0: not the 1st',          'FREQ=MONTHLY;BYMONTHDAY=0', '2026-10-07', '2026-11-01', false, false),
  ('BYMONTHDAY=32',                      'FREQ=MONTHLY;BYMONTHDAY=32', '2026-10-07', '2026-11-07', false, true),
  ('BYMONTHDAY=x',                       'FREQ=MONTHLY;BYMONTHDAY=1,x', '2026-10-07', '2026-11-07', false, true),
  ('BYMONTH=13',                         'FREQ=DAILY;BYMONTH=13', '2026-10-07', '2026-10-08', false, true),
  ('WKST=XX is MO',                      'FREQ=WEEKLY;INTERVAL=2;BYDAY=SU;WKST=XX', '2026-10-07', '2026-10-11', false, true),
  -- Unsupported parts are ignored
  ('BYSETPOS ignored',                   'FREQ=MONTHLY;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1', '2026-10-07', '2026-10-08', false, true),
  ('BYYEARDAY ignored',                  'FREQ=YEARLY;BYYEARDAY=100', '2026-10-07', '2027-10-07', false, true),
  ('BYHOUR ignored',                     'FREQ=DAILY;BYHOUR=9,17', '2026-10-07', '2026-10-08', false, true),
  ('X- part ignored',                    'FREQ=DAILY;X-NAME=foo', '2026-10-07', '2026-10-08', false, true);

select tests.eq(
  (select string_agg(format('%s [%s from %s on %s]', what, rule, dtstart, day), '; ')
   from one_day where rrule_occurs_on(rule, dtstart, day, inst) is distinct from expected),
  null::text, 'rrule_occurs_on vectors');
select tests.eq(rrule_occurs_on('FREQ=WEEKLY;BYDAY=SA,SU', '2026-10-07', '2026-10-07'), true,
                'dtstart_is_instance defaults to true');

-- ───────────────────────── Series ─────────────────────────

create temp table series (what text, rule text, dtstart date, inst boolean, from_day date, to_day date, expected date[]);
insert into series values
  ('RFC daily, 10 times', 'FREQ=DAILY;COUNT=10', '1997-09-02', true, '1997-09-01', '1997-09-30',
   '{1997-09-02,1997-09-03,1997-09-04,1997-09-05,1997-09-06,1997-09-07,1997-09-08,1997-09-09,1997-09-10,1997-09-11}'),
  ('RFC every other day', 'FREQ=DAILY;INTERVAL=2', '1997-09-02', true, '1997-09-01', '1997-09-12',
   '{1997-09-02,1997-09-04,1997-09-06,1997-09-08,1997-09-10,1997-09-12}'),
  ('RFC every 10 days, 5 times', 'FREQ=DAILY;INTERVAL=10;COUNT=5', '1997-09-02', true, '1997-09-01', '1997-12-31',
   '{1997-09-02,1997-09-12,1997-09-22,1997-10-02,1997-10-12}'),
  ('RFC every day in January (YEARLY)', 'FREQ=YEARLY;UNTIL=20000131T140000Z;BYMONTH=1;BYDAY=SU,MO,TU,WE,TH,FR,SA',
   '1998-01-01', true, '1999-12-20', '2000-02-10', array(select date '2000-01-01' + i from generate_series(0, 30) i)),
  ('RFC every day in January (DAILY)', 'FREQ=DAILY;UNTIL=20000131T140000Z;BYMONTH=1',
   '1998-01-01', true, '1999-12-20', '2000-02-10', array(select date '2000-01-01' + i from generate_series(0, 30) i)),
  ('RFC weekly, 10 times', 'FREQ=WEEKLY;COUNT=10', '1997-09-02', true, '1997-09-01', '1997-12-31',
   '{1997-09-02,1997-09-09,1997-09-16,1997-09-23,1997-09-30,1997-10-07,1997-10-14,1997-10-21,1997-10-28,1997-11-04}'),
  ('RFC Tue and Thu, 10 times', 'FREQ=WEEKLY;COUNT=10;WKST=SU;BYDAY=TU,TH', '1997-09-02', true, '1997-09-01', '1997-12-31',
   '{1997-09-02,1997-09-04,1997-09-09,1997-09-11,1997-09-16,1997-09-18,1997-09-23,1997-09-25,1997-09-30,1997-10-02}'),
  -- RFC stops at Oct 2: its 09:00 instance on Oct 7 is after 00:00Z. A date-only UNTIL keeps the date.
  ('RFC Tue and Thu until Oct 7', 'FREQ=WEEKLY;UNTIL=19971007T000000Z;WKST=SU;BYDAY=TU,TH', '1997-09-02', true, '1997-09-01', '1997-12-31',
   '{1997-09-02,1997-09-04,1997-09-09,1997-09-11,1997-09-16,1997-09-18,1997-09-23,1997-09-25,1997-09-30,1997-10-02,1997-10-07}'),
  -- Same: RFC ends Dec 22; Wednesday Dec 24 is the UNTIL date.
  ('RFC every other week MO,WE,FR', 'FREQ=WEEKLY;INTERVAL=2;UNTIL=19971224T000000Z;WKST=SU;BYDAY=MO,WE,FR', '1997-09-01', true,
   '1997-09-01', '1997-12-31',
   '{1997-09-01,1997-09-03,1997-09-05,1997-09-15,1997-09-17,1997-09-19,1997-09-29,1997-10-01,1997-10-03,1997-10-13,1997-10-15,1997-10-17,1997-10-27,1997-10-29,1997-10-31,1997-11-10,1997-11-12,1997-11-14,1997-11-24,1997-11-26,1997-11-28,1997-12-08,1997-12-10,1997-12-12,1997-12-22,1997-12-24}'),
  ('RFC every other week TU,TH, 8 times', 'FREQ=WEEKLY;INTERVAL=2;COUNT=8;WKST=SU;BYDAY=TU,TH', '1997-09-02', true, '1997-09-01', '1997-12-31',
   '{1997-09-02,1997-09-04,1997-09-16,1997-09-18,1997-09-30,1997-10-02,1997-10-14,1997-10-16}'),
  ('RFC first Friday, 10 times', 'FREQ=MONTHLY;COUNT=10;BYDAY=1FR', '1997-09-05', true, '1997-09-01', '1998-12-31',
   '{1997-09-05,1997-10-03,1997-11-07,1997-12-05,1998-01-02,1998-02-06,1998-03-06,1998-04-03,1998-05-01,1998-06-05}'),
  ('RFC first Friday until Dec 24', 'FREQ=MONTHLY;UNTIL=19971224T000000Z;BYDAY=1FR', '1997-09-05', true, '1997-09-01', '1998-12-31',
   '{1997-09-05,1997-10-03,1997-11-07,1997-12-05}'),
  ('RFC every other month, first and last Sunday', 'FREQ=MONTHLY;INTERVAL=2;COUNT=10;BYDAY=1SU,-1SU', '1997-09-07', true,
   '1997-09-01', '1998-12-31',
   '{1997-09-07,1997-09-28,1997-11-02,1997-11-30,1998-01-04,1998-01-25,1998-03-01,1998-03-29,1998-05-03,1998-05-31}'),
  ('RFC second-to-last Monday', 'FREQ=MONTHLY;COUNT=6;BYDAY=-2MO', '1997-09-22', true, '1997-09-01', '1998-06-30',
   '{1997-09-22,1997-10-20,1997-11-17,1997-12-22,1998-01-19,1998-02-16}'),
  ('RFC third-to-last day', 'FREQ=MONTHLY;BYMONTHDAY=-3', '1997-09-28', true, '1997-09-01', '1998-02-28',
   '{1997-09-28,1997-10-29,1997-11-28,1997-12-29,1998-01-29,1998-02-26}'),
  ('RFC 2nd and 15th', 'FREQ=MONTHLY;COUNT=10;BYMONTHDAY=2,15', '1997-09-02', true, '1997-09-01', '1998-03-31',
   '{1997-09-02,1997-09-15,1997-10-02,1997-10-15,1997-11-02,1997-11-15,1997-12-02,1997-12-15,1998-01-02,1998-01-15}'),
  ('RFC first and last day', 'FREQ=MONTHLY;COUNT=10;BYMONTHDAY=1,-1', '1997-09-30', true, '1997-09-01', '1998-03-31',
   '{1997-09-30,1997-10-01,1997-10-31,1997-11-01,1997-11-30,1997-12-01,1997-12-31,1998-01-01,1998-01-31,1998-02-01}'),
  ('RFC every 18 months, 10th to 15th', 'FREQ=MONTHLY;INTERVAL=18;COUNT=10;BYMONTHDAY=10,11,12,13,14,15', '1997-09-10', true,
   '1997-09-01', '1999-12-31',
   '{1997-09-10,1997-09-11,1997-09-12,1997-09-13,1997-09-14,1997-09-15,1999-03-10,1999-03-11,1999-03-12,1999-03-13}'),
  ('RFC every Tuesday, every other month', 'FREQ=MONTHLY;INTERVAL=2;BYDAY=TU', '1997-09-02', true, '1997-09-01', '1998-03-31',
   '{1997-09-02,1997-09-09,1997-09-16,1997-09-23,1997-09-30,1997-11-04,1997-11-11,1997-11-18,1997-11-25,1998-01-06,1998-01-13,1998-01-20,1998-01-27,1998-03-03,1998-03-10,1998-03-17,1998-03-24,1998-03-31}'),
  ('RFC June and July, 10 times', 'FREQ=YEARLY;COUNT=10;BYMONTH=6,7', '1997-06-10', true, '1997-06-01', '2001-12-31',
   '{1997-06-10,1997-07-10,1998-06-10,1998-07-10,1999-06-10,1999-07-10,2000-06-10,2000-07-10,2001-06-10,2001-07-10}'),
  ('RFC every other year, Jan to Mar', 'FREQ=YEARLY;INTERVAL=2;COUNT=10;BYMONTH=1,2,3', '1997-03-10', true, '1997-01-01', '2003-12-31',
   '{1997-03-10,1999-01-10,1999-02-10,1999-03-10,2001-01-10,2001-02-10,2001-03-10,2003-01-10,2003-02-10,2003-03-10}'),
  ('RFC every Thursday in March', 'FREQ=YEARLY;BYMONTH=3;BYDAY=TH', '1997-03-13', true, '1997-01-01', '1999-12-31',
   '{1997-03-13,1997-03-20,1997-03-27,1998-03-05,1998-03-12,1998-03-19,1998-03-26,1999-03-04,1999-03-11,1999-03-18,1999-03-25}'),
  ('RFC Thursdays in June to August', 'FREQ=YEARLY;BYDAY=TH;BYMONTH=6,7,8', '1997-06-05', true, '1997-01-01', '1997-12-31',
   '{1997-06-05,1997-06-12,1997-06-19,1997-06-26,1997-07-03,1997-07-10,1997-07-17,1997-07-24,1997-07-31,1997-08-07,1997-08-14,1997-08-21,1997-08-28}'),
  -- RFC drops dtstart with EXDATE; a chore anchor is the same thing.
  ('RFC Friday 13th, chore', 'FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13', '1997-09-02', false, '1997-09-01', '2000-12-31',
   '{1998-02-13,1998-03-13,1998-11-13,1999-08-13,2000-10-13}'),
  ('RFC Friday 13th, event', 'FREQ=MONTHLY;BYDAY=FR;BYMONTHDAY=13', '1997-09-02', true, '1997-09-01', '2000-12-31',
   '{1997-09-02,1998-02-13,1998-03-13,1998-11-13,1999-08-13,2000-10-13}'),
  ('RFC Saturday after the first Sunday', 'FREQ=MONTHLY;BYDAY=SA;BYMONTHDAY=7,8,9,10,11,12,13', '1997-09-13', true,
   '1997-09-01', '1998-06-30',
   '{1997-09-13,1997-10-11,1997-11-08,1997-12-13,1998-01-10,1998-02-07,1998-03-07,1998-04-11,1998-05-09,1998-06-13}'),
  ('RFC US election day', 'FREQ=YEARLY;INTERVAL=4;BYMONTH=11;BYDAY=TU;BYMONTHDAY=2,3,4,5,6,7,8', '1996-11-05', true,
   '1996-01-01', '2004-12-31', '{1996-11-05,2000-11-07,2004-11-02}'),
  ('RFC WKST=MO', 'FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=MO', '1997-08-05', true, '1997-08-01', '1997-09-30',
   '{1997-08-05,1997-08-10,1997-08-19,1997-08-24}'),
  ('RFC WKST=SU', 'FREQ=WEEKLY;INTERVAL=2;COUNT=4;BYDAY=TU,SU;WKST=SU', '1997-08-05', true, '1997-08-01', '1997-09-30',
   '{1997-08-05,1997-08-17,1997-08-19,1997-08-31}'),
  ('RFC skips Feb 30', 'FREQ=MONTHLY;BYMONTHDAY=15,30;COUNT=5', '2007-01-15', true, '2007-01-01', '2007-12-31',
   '{2007-01-15,2007-01-30,2007-02-15,2007-03-15,2007-03-30}'),
  ('31st, months that have one', 'FREQ=MONTHLY', '2026-01-31', false, '2026-01-01', '2026-12-31',
   '{2026-01-31,2026-03-31,2026-05-31,2026-07-31,2026-08-31,2026-10-31,2026-12-31}'),
  ('Feb 29, leap years', 'FREQ=YEARLY', '2024-02-29', false, '2024-01-01', '2032-12-31',
   '{2024-02-29,2028-02-29,2032-02-29}'),
  ('weekends from a Wednesday, 3 times, event', 'FREQ=WEEKLY;BYDAY=SA,SU;COUNT=3', '2026-10-07', true, '2026-10-01', '2026-10-31',
   '{2026-10-07,2026-10-10,2026-10-11}'),
  ('weekends from a Wednesday, 3 times, chore', 'FREQ=WEEKLY;BYDAY=SA,SU;COUNT=3', '2026-10-07', false, '2026-10-01', '2026-10-31',
   '{2026-10-10,2026-10-11,2026-10-17}'),
  ('every 2 weeks MO,TH from a Wednesday', 'FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,TH', '2026-10-07', false, '2026-10-01', '2026-11-08',
   '{2026-10-08,2026-10-19,2026-10-22,2026-11-02,2026-11-05}'),
  ('a window in the middle of a COUNT', 'FREQ=WEEKLY;COUNT=10', '1997-09-02', true, '1997-10-01', '1997-10-31',
   '{1997-10-07,1997-10-14,1997-10-21,1997-10-28}');

select tests.eq(
  (select string_agg(format('%s: got %s', what, got), E'\n')
   from series, lateral (select array(select rrule_days(rule, dtstart, from_day, to_day, inst)) as got) g
   where got is distinct from expected),
  null::text, 'rrule_days series');
-- Each single-day COUNT check counts from dtstart, so on the multi-year COUNT
-- series only the days around the expected ones are checked one by one.
select tests.eq(
  (select string_agg(format('%s: got %s', what, got), E'\n')
   from series, lateral (select array(select from_day + i from generate_series(0, to_day - from_day) i
                                      where (to_day - from_day <= 500 or rule not like '%COUNT%'
                                             or exists (select 1 from unnest(expected) e where abs(e - (from_day + i)) <= 3))
                                        and rrule_occurs_on(rule, dtstart, from_day + i, inst)) as got) g
   where got is distinct from expected),
  null::text, 'rrule_occurs_on, day by day, matches the series');
select tests.eq(array(select rrule_days('FREQ=DAILY', '2026-10-07', '2026-10-10', '2026-10-09')), '{}'::date[],
                'an empty window has no days');

-- ───────────────────────── Bounds ─────────────────────────

select tests.eq(rrule_occurs_on(null, 'infinity', '2026-10-07'), false, 'an infinite dtstart has no days');
select tests.eq(rrule_occurs_on('FREQ=DAILY', '-infinity', '2026-10-07'), false, 'nor a minus-infinite one');
select tests.eq(rrule_occurs_on('FREQ=WEEKLY', '4713-01-01 BC', '2026-10-07'), false, 'nor one before the year 1');
select tests.eq((select count(*)::int from rrule_days('FREQ=DAILY', '2026-01-01', '2026-01-01', date '2026-01-01' + 3660)),
                3661, '3660 days at a time is fine');
select tests.throws(format('select count(*) from rrule_days(%L, %L, %L, %L)', 'FREQ=DAILY', '2026-01-01', '2026-01-01',
                           date '2026-01-01' + 3661),
                    'range can''t be longer than 3660 days', 'but no more');
select tests.eq(rrule_occurs_on('FREQ=YEARLY;COUNT=300', '1800-01-01', '2026-01-01'), false,
                'COUNT stops counting 200 years after dtstart');
select tests.eq(rrule_occurs_on('FREQ=YEARLY;COUNT=5;BYMONTH=2;BYMONTHDAY=30', '0001-01-01', '9999-01-01', false), false,
                'a COUNT that never matches gives up instead of walking millennia');

-- ───────────────────────── Calendar ─────────────────────────

-- The seed family moves to Los Angeles, which leaves DST on 2026-11-01.
-- The other house has a zone Postgres doesn't know.
insert into auth.users (id, email, raw_app_meta_data) values
  (:'mom', 'mom@example.com', '{}'),
  (:'other', 'neighbor@example.com', '{}'),
  (:'device', 'device@devices.homeos.invalid', '{"kind": "device"}');
update members set user_id = :'mom' where id = :'m_mom';
update families set timezone = 'America/Los_Angeles' where id = :'fam';
insert into families (id, name, timezone) values (:'fam2', 'Other House', 'Not/AZone');
insert into members (id, family_id, display_name, role, user_id) values (:'m_other', :'fam2', 'Neighbor', 'parent', :'other');
insert into devices (family_id, user_id, name) values (:'fam', :'device', 'Kitchen');

insert into events (id, family_id, title, starts_at, ends_at, all_day, rrule) values
  ('e0000000-0000-0000-0000-000000000001', :'fam', 'Dentist',    '2026-10-20 15:00-07', '2026-10-20 16:00-07', false, null),
  ('e0000000-0000-0000-0000-000000000002', :'fam', 'Soccer',     '2026-10-21 16:30-07', '2026-10-21 17:30-07', false, 'FREQ=WEEKLY;BYDAY=WE'),
  ('e0000000-0000-0000-0000-000000000003', :'fam', 'Sleepover',  '2026-10-23 18:00-07', '2026-10-25 12:00-07', false, 'FREQ=WEEKLY'),
  ('e0000000-0000-0000-0000-000000000004', :'fam', 'Pickup',     '2026-10-26 08:00-07', '2026-10-26 08:00-07', false, ''),
  ('e0000000-0000-0000-0000-000000000005', :'fam', 'Trip',       '2026-10-18 09:00-07', '2026-10-28 18:00-07', false, null),
  ('e0000000-0000-0000-0000-000000000006', :'fam', 'Old',        '2026-10-18 09:00-07', '2026-10-19 00:00-07', false, null),
  ('e0000000-0000-0000-0000-000000000007', :'fam', 'Swim',       '2026-10-19 07:00-07', '2026-10-19 07:30-07', false, 'FREQ=DAILY;COUNT=3'),
  ('e0000000-0000-0000-0000-000000000008', :'fam', 'Holiday',    '2026-10-25 00:00-07', '2026-10-25 23:59:59-07', true, 'FREQ=WEEKLY'),
  ('e0000000-0000-0000-0000-000000000009', :'fam', 'Early bird', '2026-11-01 00:00-07', '2026-11-01 00:30-07', false, null),
  -- Stored on a Wednesday, repeats on weekends: the Wednesday is its first day.
  ('e0000000-0000-0000-0000-000000000010', :'fam', 'Club',       '2026-10-21 10:00-07', '2026-10-21 11:00-07', false, 'FREQ=WEEKLY;BYDAY=SA,SU'),
  ('e0000000-0000-0000-0000-000000000099', :'fam2', 'Neighbor BBQ', '2026-10-20 12:00Z', '2026-10-20 13:00Z', false, 'FREQ=DAILY');
insert into event_members (event_id, member_id) values
  ('e0000000-0000-0000-0000-000000000002', :'m_emma'),
  ('e0000000-0000-0000-0000-000000000002', :'m_mom'),
  ('e0000000-0000-0000-0000-000000000010', :'m_leo'),
  ('e0000000-0000-0000-0000-000000000099', :'m_other');

select tests.login(:'mom');

-- A week, in order: by start, all-day first, then id
select tests.eq(array(select title from event_occurrences(:'fam', '2026-10-19 00:00-07', '2026-10-26 00:00-07')),
                '{Trip,Swim,Swim,Dentist,Swim,Club,Soccer,Sleepover,Club,Holiday,Club}'::text[],
                'a week of occurrences, in order');
select tests.eq((select count(*)::int from event_occurrences(:'fam', '2026-10-19 00:00-07', '2026-11-16 00:00-08') where title = 'Swim'),
                3, 'COUNT=3 stops after three');

-- Non-repeating: the stored row once
select tests.eq((select row(o.id, o.starts_at, o.ends_at, o.series_starts_at, o.series_ends_at, o.member_ids, o.rrule)::text
                 from event_occurrences(:'fam', '2026-10-19 00:00-07', '2026-10-26 00:00-07') o where o.title = 'Dentist'),
                row('e0000000-0000-0000-0000-000000000001'::uuid, '2026-10-20 15:00-07'::timestamptz, '2026-10-20 16:00-07'::timestamptz,
                    '2026-10-20 15:00-07'::timestamptz, '2026-10-20 16:00-07'::timestamptz, '{}'::uuid[], null::text)::text,
                'a one-off is its stored row, with no members as an empty array');
select tests.eq((select count(*)::int from event_occurrences(:'fam', '2026-10-20 00:00-07', '2026-10-21 00:00-07') where title = 'Trip'),
                1, 'an event under way at range_start overlaps');
select tests.eq((select count(*)::int from event_occurrences(:'fam', '2026-10-19 00:00-07', '2026-10-26 00:00-07') where title = 'Old'),
                0, 'an event ending at range_start doesn''t');
select tests.eq((select count(*)::int from event_occurrences(:'fam', '2026-10-26 08:00-07', '2026-10-26 09:00-07') where title = 'Pickup'),
                1, 'a zero-length event at range_start counts (blank rrule = one-off)');
select tests.eq((select count(*)::int from event_occurrences(:'fam', '2026-10-26 07:00-07', '2026-10-26 08:00-07') where title = 'Pickup'),
                0, 'a zero-length event at range_end doesn''t');

-- Weekly at 4:30pm stays at 4:30pm local through the DST change; the UTC instant moves.
select tests.eq(array(select starts_at from event_occurrences(:'fam', '2026-10-19 00:00-07', '2026-11-16 00:00-08') where title = 'Soccer'),
                '{2026-10-21 23:30Z,2026-10-28 23:30Z,2026-11-05 00:30Z,2026-11-12 00:30Z}'::timestamptz[],
                'weekly expansion across DST');
select tests.eq((select bool_and(ends_at - starts_at = interval '1 hour'
                                 and (starts_at at time zone 'America/Los_Angeles')::time = '16:30'
                                 and id = 'e0000000-0000-0000-0000-000000000002'
                                 and series_starts_at = '2026-10-21 16:30-07' and series_ends_at = '2026-10-21 17:30-07'
                                 and rrule = 'FREQ=WEEKLY;BYDAY=WE'
                                 and member_ids = array[:'m_mom', :'m_emma']::uuid[])
                 from event_occurrences(:'fam', '2026-10-19 00:00-07', '2026-11-16 00:00-08') where title = 'Soccer'),
                true, 'every occurrence: same local time and length, the series id and values, members by sort order');
select tests.logout();
update members set sort_order = 9 where id = :'m_mom';
select tests.login(:'mom');
select tests.eq((select distinct member_ids from event_occurrences(:'fam', '2026-10-19 00:00-07', '2026-11-16 00:00-08')
                 where title = 'Soccer'),
                array[:'m_emma', :'m_mom']::uuid[], 'members follow sort_order, not their ids');
select tests.logout();
update members set sort_order = 0 where id = :'m_mom';
select tests.login(:'mom');

-- Fri 6pm to Sun noon: the one that began Friday Oct 30 overlaps a Saturday window
-- and ends at noon local on Nov 1, after the clocks go back.
select tests.eq((select array_agg(row(starts_at, ends_at)::text)
                 from event_occurrences(:'fam', '2026-10-31 00:00-07', '2026-11-02 00:00-08') where title = 'Sleepover'),
                array[row('2026-10-30 18:00-07'::timestamptz, '2026-11-01 12:00-08'::timestamptz)::text],
                'a long occurrence that began before range_start');
select tests.eq((select array_agg(row(starts_at, ends_at)::text)
                 from event_occurrences(:'fam', '2026-11-01 00:00-07', '2026-11-02 00:00-08') where title = 'Sleepover'),
                array[row('2026-10-30 18:00-07'::timestamptz, '2026-11-01 12:00-08'::timestamptz)::text],
                'and one that began two days before range_start');
select tests.eq(array(select title from event_occurrences(:'fam', '2026-10-31 00:00-07', '2026-11-02 00:00-08')),
                '{Sleepover,Club,Holiday,Early bird,Club}'::text[], 'the DST weekend, all-day first at the same start');
select tests.eq((select row(starts_at, ends_at)::text
                 from event_occurrences(:'fam', '2026-10-31 00:00-07', '2026-11-02 00:00-08') where title = 'Holiday'),
                row('2026-11-01 00:00-07'::timestamptz, '2026-11-01 23:59:59-08'::timestamptz)::text,
                'an all-day repeat covers the whole local day it lands on');
select tests.eq(array(select starts_at from event_occurrences(:'fam', '2026-10-31 00:00-07', '2026-11-02 00:00-08') where title = 'Club'),
                '{2026-10-31 10:00-07,2026-11-01 10:00-08}'::timestamptz[], 'Saturday and Sunday at 10am local');
select tests.eq(array(select (starts_at at time zone 'America/Los_Angeles')::date
                      from event_occurrences(:'fam', '2026-10-19 00:00-07', '2026-10-26 00:00-07') where title = 'Club'),
                '{2026-10-21,2026-10-24,2026-10-25}'::date[], 'a stored Wednesday is the first of a weekend series');
select tests.eq((select count(*)::int
                 from (select starts_at, lag(starts_at) over () as prev
                       from event_occurrences(:'fam', '2026-10-01 00:00-07', '2027-03-01 00:00-08')) o
                 where o.prev > o.starts_at),
                0, 'in start order over five months');

-- RLS: only your own family's events, whatever fid you pass
select tests.eq((select count(*)::int from event_occurrences(:'fam2', '2026-10-19 00:00-07', '2026-10-26 00:00-07')),
                0, 'another family''s events never appear');
select tests.eq((select count(*)::int from event_occurrences(:'fam', '2026-10-19 00:00-07', '2026-10-26 00:00-07')
                 where family_id <> :'fam' or title = 'Neighbor BBQ'), 0, 'and none leak into your own');
select tests.login(:'device');
select tests.eq((select count(*)::int from event_occurrences(:'fam', '2026-10-19 00:00-07', '2026-10-26 00:00-07')),
                11, 'the family''s display sees them');
select tests.login(:'other');
select tests.eq((select count(*)::int from event_occurrences(:'fam', '2026-10-19 00:00-07', '2026-10-26 00:00-07')),
                0, 'a neighbor sees none of them');
select tests.eq(array(select starts_at from event_occurrences(:'fam2', '2026-10-19 00:00-07', '2026-10-23 00:00-07')),
                '{2026-10-20 12:00Z,2026-10-21 12:00Z,2026-10-22 12:00Z}'::timestamptz[],
                'a zone Postgres doesn''t know falls back to UTC');

-- Ranges
select tests.login(:'mom');
select tests.throws(format('select * from event_occurrences(%L, %L, %L)', :'fam', '2026-10-20 00:00Z', '2026-10-20 00:00Z'),
                    'range_end must be after range_start', 'an empty range');
select tests.throws(format('select * from event_occurrences(%L, %L, %L)', :'fam', '2026-10-21 00:00Z', '2026-10-20 00:00Z'),
                    'range_end must be after range_start', 'a backwards range');
select tests.throws(format('select * from event_occurrences(%L, null, %L)', :'fam', '2026-10-20 00:00Z'),
                    'range_end must be after range_start', 'a missing bound');
select tests.throws(format('select * from event_occurrences(%L, %L, %L)', :'fam', '2026-01-01 00:00Z', '2027-02-05 00:00:01Z'),
                    'range can''t be longer than 400 days', 'more than 400 days');
select tests.eq((select count(*)::int from event_occurrences(:'fam', '2026-01-01 00:00Z', '2027-02-05 00:00Z')) > 0,
                true, '400 days is fine');

-- DST: a repeat in the hour the clocks skip starts when they do and keeps
-- its length; one in the hour that happens twice is the first (RFC 5545).
-- Then rows nobody should save but anyone in the family can: they mustn't
-- break the calendar.
select tests.logout();
insert into events (id, family_id, title, starts_at, ends_at, all_day, rrule) values
  ('e0000000-0000-0000-0000-000000000011', :'fam', 'Night feed', '2027-03-10 02:00-08', '2027-03-10 03:00-08', false, 'FREQ=DAILY'),
  ('e0000000-0000-0000-0000-000000000012', :'fam', 'Late show',  '2026-10-25 01:15-07', '2026-10-25 01:45-07', false, 'FREQ=WEEKLY'),
  ('e0000000-0000-0000-0000-000000000013', :'fam', 'Forever',    '2026-10-20 09:00-07', 'infinity', false, 'FREQ=WEEKLY'),
  ('e0000000-0000-0000-0000-000000000014', :'fam', 'Always',     '-infinity', '2026-10-20 10:00-07', false, 'FREQ=DAILY'),
  ('e0000000-0000-0000-0000-000000000015', :'fam', 'Ages',       '2026-10-20 11:00-07', '9999-12-31 00:00Z', false, 'FREQ=WEEKLY');
select tests.login(:'mom');
select tests.eq((select array_agg(row(starts_at, ends_at)::text order by starts_at)
                 from event_occurrences(:'fam', '2027-03-13 00:00-08', '2027-03-16 00:00-07') where title = 'Night feed'),
                array[row('2027-03-13 02:00-08'::timestamptz, '2027-03-13 03:00-08'::timestamptz)::text,
                      row('2027-03-14 03:00-07'::timestamptz, '2027-03-14 04:00-07'::timestamptz)::text,
                      row('2027-03-15 02:00-07'::timestamptz, '2027-03-15 03:00-07'::timestamptz)::text],
                'a repeat in the skipped hour');
select tests.eq((select array_agg(row(starts_at, ends_at)::text)
                 from event_occurrences(:'fam', '2026-11-01 00:00-07', '2026-11-02 00:00-08') where title = 'Late show'),
                array[row('2026-11-01 01:15-07'::timestamptz, '2026-11-01 01:45-07'::timestamptz)::text],
                'a repeat in the hour that happens twice');
select tests.eq((select count(*)::int from event_occurrences(:'fam', '2026-10-19 00:00-07', '2026-10-26 00:00-07')
                 where title in ('Forever', 'Always')), 0, 'repeating rows with infinite dates are skipped');
select tests.eq((select count(*)::int from event_occurrences(:'fam', '2026-10-19 00:00-07', '2026-10-26 00:00-07')
                 where title = 'Ages'), 1, 'a repeat lasting thousands of years doesn''t raise');
select tests.eq((select count(*)::int from event_occurrences(:'fam', '2026-10-19 00:00-07', '2026-10-26 00:00-07')
                 where title not in ('Forever', 'Always', 'Ages', 'Late show')), 11, 'and the rest of the week is as before');

-- ───────────────────────── Chores ─────────────────────────

select tests.logout();
-- The seed chores are anchored at now(); these are anchored by hand.
delete from tasks where family_id = :'fam';
insert into tasks (family_id, title, assignee_id, rrule, due_date, archived, requires_approval, created_at) values
  (:'fam', 'Change filter', null, 'FREQ=MONTHLY', '2026-01-31', false, true, '2026-01-01 08:00-08'),
  (:'fam', 'Old chore', null, 'FREQ=DAILY', null, true, true, '2026-10-01 08:00-07'),
  (:'fam', 'Water plants', :'m_emma', null, null, false, true, '2026-10-01 09:00-07'),
  (:'fam', 'Clean garage', :'m_leo', null, null, false, true, '2026-10-01 10:00-07'),
  (:'fam', 'Fix bike', :'m_leo', null, '2026-10-10', false, true, '2026-10-01 11:00-07'),
  (:'fam', 'Mow lawn', :'m_leo', null, null, false, false, '2026-10-01 12:00-07'),
  (:'fam', 'Sort mail', null, '', null, false, true, '2026-10-01 13:00-07'),
  (:'fam', 'Pay allowance', :'m_mom', 'FREQ=MONTHLY;BYMONTHDAY=1', null, false, true, '2026-10-01 14:00-07'),
  (:'fam', 'Feed fish', :'m_emma', 'FREQ=DAILY;INTERVAL=2', '2026-10-06', false, true, '2026-10-02 08:00-07'),
  -- Created on a Wednesday evening in Los Angeles (already Thursday in UTC).
  (:'fam', 'Weekend tidy', :'m_emma', 'FREQ=WEEKLY;BYDAY=SA,SU', null, false, true, '2026-10-07 18:00-07'),
  (:'fam', 'Water lawn', :'m_leo', 'FREQ=WEEKLY', null, false, true, '2026-10-08 02:00Z'),
  (:'fam2', 'Neighbor chore', null, 'FREQ=DAILY', null, false, true, '2026-10-01 08:00Z');
-- Water plants done on the 5th (waiting for a parent), Clean garage tried and
-- turned down on the 5th, Mow lawn done and approved on the 3rd.
insert into task_completions (task_id, member_id, for_date)
select id, assignee_id, '2026-10-05' from tasks where title in ('Water plants', 'Clean garage');
update task_completions set status = 'rejected' where task_id = (select id from tasks where title = 'Clean garage');
insert into task_completions (task_id, member_id, for_date)
select id, assignee_id, '2026-10-03' from tasks where title = 'Mow lawn';
select tests.eq((select status::text from task_completions c join tasks t on t.id = c.task_id where t.title = 'Mow lawn'),
                'approved', 'setup: Mow lawn needs no approval');

select tests.login(:'mom');
-- In created_at order. The 31st also brings the monthly chore anchored on Jan 31.
select tests.eq(
  (select string_agg(format('%s: got %s', due.day, got), E'\n')
   from (values ('2026-10-05'::date, '{Water plants,Clean garage,Sort mail}'::text[]),
                ('2026-10-06', '{Clean garage,Sort mail,Feed fish}'),
                ('2026-10-07', '{Clean garage,Sort mail,Water lawn}'),
                ('2026-10-10', '{Clean garage,Fix bike,Sort mail,Feed fish,Weekend tidy}'),
                ('2026-10-12', '{Clean garage,Fix bike,Sort mail,Feed fish}'),
                ('2026-10-14', '{Clean garage,Fix bike,Sort mail,Feed fish,Water lawn}'),
                ('2026-10-15', '{Clean garage,Fix bike,Sort mail}'),
                ('2026-10-31', '{Change filter,Clean garage,Fix bike,Sort mail,Weekend tidy}'),
                ('2026-11-01', '{Clean garage,Fix bike,Sort mail,Pay allowance,Feed fish,Weekend tidy}')) due (day, expected),
        lateral (select array(select title from chores_due(:'fam', due.day)) as got) g
   where got is distinct from due.expected),
  null::text, 'chores due, day by day');
select tests.eq((select 'Change filter' = any (array(select title from chores_due(:'fam', '2026-01-31')))), true,
                'monthly from the 31st: January 31');
select tests.eq((select 'Change filter' = any (array(select title from chores_due(:'fam', '2026-02-28')))), false,
                'monthly from the 31st: not February 28');
select tests.eq((select 'Change filter' = any (array(select title from chores_due(:'fam', '2026-03-31')))), true,
                'monthly from the 31st: March 31');
select tests.eq((select 'Feed fish' = any (array(select title from chores_due(:'fam', '2026-10-04')))), false,
                'nothing before the due date it repeats from');
select tests.eq((select row(t.id, t.points, t.assignee_id, t.requires_approval)::text
                 from chores_due(:'fam', '2026-10-10') t where t.title = 'Fix bike'),
                (select row(t.id, t.points, t.assignee_id, t.requires_approval)::text from tasks t where t.title = 'Fix bike'),
                'whole task rows');
select tests.eq((select count(*)::int from chores_due(:'fam2', '2026-10-10')), 0, 'another family''s chores never appear');
select tests.throws(format('select * from chores_due(%L, null)', :'fam'), 'day is required', 'a day is required');
select tests.login(:'device');
select tests.eq(array(select title from chores_due(:'fam', '2026-10-10')),
                '{Clean garage,Fix bike,Sort mail,Feed fish,Weekend tidy}'::text[], 'the display gets the same list');
select tests.login(:'other');
select tests.eq((select count(*)::int from chores_due(:'fam', '2026-10-10')), 0, 'a neighbor gets none');
select tests.eq(array(select title from chores_due(:'fam2', '2026-10-10')), '{Neighbor chore}'::text[],
                'their own, created in a zone Postgres doesn''t know');
select tests.logout();
insert into tasks (family_id, title, rrule, due_date) values
  (:'fam', 'Never', 'FREQ=DAILY', 'infinity'),
  (:'fam', 'Ever', 'FREQ=WEEKLY', '-infinity');
select tests.login(:'mom');
select tests.eq(array(select title from chores_due(:'fam', '2026-10-10')),
                '{Clean garage,Fix bike,Sort mail,Feed fish,Weekend tidy}'::text[],
                'a repeating chore with an infinite due date is never due, and breaks nothing');
select tests.logout();

-- ───────────────────────── Privileges ─────────────────────────

select tests.ok(not has_function_privilege('anon', 'event_occurrences(uuid, timestamptz, timestamptz)', 'execute'), 'anon cannot list events');
select tests.ok(not has_function_privilege('anon', 'chores_due(uuid, date)', 'execute'), 'anon cannot list chores');
select tests.ok(has_function_privilege('authenticated', 'event_occurrences(uuid, timestamptz, timestamptz)', 'execute'), 'signed in: events');
select tests.ok(has_function_privilege('authenticated', 'chores_due(uuid, date)', 'execute'), 'signed in: chores');
select tests.ok(has_function_privilege('authenticated', 'rrule_occurs_on(text, date, date, boolean)', 'execute'), 'signed in: rrule_occurs_on');
select tests.ok(has_function_privilege('authenticated', 'rrule_days(text, date, date, date, boolean)', 'execute'), 'signed in: rrule_days');
