-- Local development seed: one demo family. Link a parent by inserting a
-- member with your auth user id, or call create_family() from the iOS app.

insert into public.families (id, name, timezone)
values ('00000000-0000-0000-0000-00000000f001', 'The Demo Family', 'America/New_York');

insert into public.members (id, family_id, display_name, role, color, sort_order) values
  ('00000000-0000-0000-0000-00000000a001', '00000000-0000-0000-0000-00000000f001', 'Mom',  'parent', '#E86A92', 0),
  ('00000000-0000-0000-0000-00000000a002', '00000000-0000-0000-0000-00000000f001', 'Dad',  'parent', '#4F8EF7', 1),
  ('00000000-0000-0000-0000-00000000a003', '00000000-0000-0000-0000-00000000f001', 'Emma', 'child',  '#F5A623', 2),
  ('00000000-0000-0000-0000-00000000a004', '00000000-0000-0000-0000-00000000f001', 'Leo',  'child',  '#50C878', 3);

insert into public.tasks (family_id, title, icon, assignee_id, points, rrule, requires_approval) values
  ('00000000-0000-0000-0000-00000000f001', 'Make your bed',     'bed',    '00000000-0000-0000-0000-00000000a003', 5,  'FREQ=DAILY', false),
  ('00000000-0000-0000-0000-00000000f001', 'Feed the dog',      'pets',   '00000000-0000-0000-0000-00000000a004', 10, 'FREQ=DAILY', true),
  ('00000000-0000-0000-0000-00000000f001', 'Homework',          'book',   '00000000-0000-0000-0000-00000000a003', 15, 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH', true),
  ('00000000-0000-0000-0000-00000000f001', 'Take out recycling','trash',  '00000000-0000-0000-0000-00000000a004', 10, 'FREQ=WEEKLY;BYDAY=TH', true);

insert into public.rewards (family_id, title, icon, cost) values
  ('00000000-0000-0000-0000-00000000f001', '30 min screen time', 'tv',        30),
  ('00000000-0000-0000-0000-00000000f001', 'Pick Friday movie',  'movie',     50),
  ('00000000-0000-0000-0000-00000000f001', 'Ice cream trip',     'icecream', 100);

insert into public.lists (family_id, name) values
  ('00000000-0000-0000-0000-00000000f001', 'Groceries');
