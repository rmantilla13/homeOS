-- Invite-only platform: codes, create_family with platform invites,
-- preview_invite, family invites (create, accept, claim, revoke) and
-- leave_family.
\set ON_ERROR_STOP 1
\set fam    '00000000-0000-0000-0000-00000000f001'
\set m_mom  '00000000-0000-0000-0000-00000000a001'
\set m_dad  '00000000-0000-0000-0000-00000000a002'
\set m_emma '00000000-0000-0000-0000-00000000a003'
\set m_leo  '00000000-0000-0000-0000-00000000a004'
\set mom      'a0000000-0000-0000-0000-000000000001'
\set dad      'a0000000-0000-0000-0000-000000000002'
\set emma     'a0000000-0000-0000-0000-000000000003'
\set leo      'a0000000-0000-0000-0000-000000000004'
\set grandma  'a0000000-0000-0000-0000-000000000005'
\set other    'b0000000-0000-0000-0000-000000000001'
\set noname   'b0000000-0000-0000-0000-000000000002'
\set newbie   'b0000000-0000-0000-0000-000000000003'
\set multi1   'b0000000-0000-0000-0000-000000000004'
\set multi2   'b0000000-0000-0000-0000-000000000005'
\set blank    'b0000000-0000-0000-0000-000000000006'
\set device   'd0000000-0000-0000-0000-000000000001'
\set stranger 'e0000000-0000-0000-0000-000000000001'
\set admin    'ad000000-0000-0000-0000-000000000001'

insert into auth.users (id, email, raw_user_meta_data, raw_app_meta_data) values
  (:'mom',      'mom@example.com',      '{"display_name": "Mom"}', '{}'),
  (:'dad',      'dad@example.com',      '{}', '{}'),
  (:'emma',     'emma@example.com',     '{"display_name": "Emma"}', '{}'),
  (:'leo',      'leo@example.com',      '{}', '{}'),
  (:'grandma',  'Grandma@Example.com',  '{}', '{}'),
  (:'other',    'other@example.com',    '{}', '{}'),
  (:'noname',   null,                   '{}', '{}'),
  (:'newbie',   'newbie@example.com',   '{}', '{}'),
  (:'multi1',   'multi1@example.com',   '{}', '{}'),
  (:'multi2',   'multi2@example.com',   '{}', '{}'),
  (:'blank',    null,                   '{}', '{}'),
  (:'device',   'device-1@devices.homeos.invalid', '{}', '{"kind": "device"}'),
  (:'stranger', 'stranger@example.com', '{}', '{}'),
  (:'admin',    'admin@example.com',    '{}', '{}');
update members set user_id = :'mom' where id = :'m_mom';
insert into devices (family_id, user_id) values (:'fam', :'device');
insert into platform_admins (user_id) values (:'admin');

create function tests.no_leak(p jsonb, reason text) returns boolean language sql as $$
  select p = jsonb_build_object('valid', false, 'kind', null, 'family_name', null, 'role', null,
                                'invited_by', null, 'expires_at', null, 'reason', reason)
$$;

-- ───────────────────────────── Codes ─────────────────────────────

select tests.ok(generate_invite_code() ~ '^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$', 'code is XXXX-XXXX from the alphabet');
select tests.eq((select count(distinct generate_invite_code())::int from generate_series(1, 2000)), 2000, 'codes are random');
select tests.eq((select count(distinct ch)::int
                 from (select regexp_split_to_table(replace(generate_invite_code(), '-', ''), '') as ch
                       from generate_series(1, 500)) x), 32, 'every symbol shows up');
select tests.eq(normalize_invite_code(' abcd-efgh '), 'ABCDEFGH', 'normalize: case, dash, spaces');
select tests.eq(normalize_invite_code(E'ab cd\tef--gh'), 'ABCDEFGH', 'normalize: inner whitespace');
select tests.eq(format_invite_code('abcdefgh'), 'ABCD-EFGH', 'display form');
select tests.ok(normalize_invite_code(null) is null, 'normalize null');
select tests.login(:'mom');
select tests.throws($$select generate_invite_code()$$, 'permission denied%', 'generator is internal');
select tests.throws($$select new_invite_code()$$, 'permission denied%', 'new_invite_code is internal');
select tests.logout();

-- ──────────────────── create_family (invite-only) ────────────────────

insert into platform_invites (id, code, email, max_uses, expires_at, revoked_at) values
  ('11000000-0000-0000-0000-000000000001', 'AAAABBBB', null, 1, now() + interval '30 days', null),   -- open, single use
  ('11000000-0000-0000-0000-000000000002', 'CCCCDDDD', null, 1, now() - interval '1 minute', null),  -- expired
  ('11000000-0000-0000-0000-000000000003', 'EEEEFFFF', null, 1, now() + interval '30 days', now()),  -- revoked
  ('11000000-0000-0000-0000-000000000004', 'GGGGHHHH', 'Newbie@Example.com ', 1, now() + interval '30 days', null),
  ('11000000-0000-0000-0000-000000000005', 'JJJJKKKK', null, 3, now() + interval '30 days', null);   -- multi-use

select tests.ok((select invite_only from platform_settings), 'platform starts invite-only');

select tests.login(:'other');
select tests.throws($$select create_family('Others', 'Me')$$, 'invite code required', 'no code');
select tests.throws($$select create_family('Others', 'Me', 'UTC', ' - ')$$, 'invite code required', 'blank code');
select tests.throws($$select create_family('Others', 'Me', 'UTC', 'ZZZZ-ZZZZ')$$, 'invite code not valid', 'unknown code');
select tests.throws($$select create_family('Others', 'Me', 'UTC', 'cccc-dddd')$$, 'invite code expired', 'expired code');
select tests.throws($$select create_family('Others', 'Me', 'UTC', 'EEEE-FFFF')$$, 'invite code not valid', 'revoked code');
select tests.throws($$select create_family('Others', 'Me', 'UTC', 'GGGG-HHHH')$$, 'invite is for a different email', 'email-bound code');
select tests.throws($$select create_family('Others', 'Me', 'UTC', 'MEET-THEM')$$, 'invite code not valid', 'family code is not a platform code');
select tests.throws($$select create_family('  ', 'Me', 'UTC', 'AAAA-BBBB')$$, 'family name required', 'family name required');
select tests.eq((select count(*)::int from families), 0, 'failed attempts created nothing (and other sees no families)');

-- Lowercase, spaced codes work; the redemption is recorded.
select create_family('The Others', 'Olive', 'Europe/Paris', ' aaaa bbbb ') as other_fam \gset
select tests.eq((select name from families where id = :'other_fam'), 'The Others', 'family created');
select tests.eq((select timezone from families where id = :'other_fam'), 'Europe/Paris', 'timezone kept');
select tests.eq((select role::text from members where family_id = :'other_fam' and user_id = :'other'), 'parent', 'caller is a linked parent');
select tests.eq((select display_name from members where family_id = :'other_fam' and user_id = :'other'), 'Olive', 'member name');
select tests.eq((select display_name from profiles where id = :'other'), 'other', 'non-empty profile name kept');
select tests.logout();
select tests.eq((select use_count from platform_invites where code = 'AAAABBBB'), 1, 'use_count incremented');
select tests.eq((select family_id from platform_invite_redemptions where invite_id = '11000000-0000-0000-0000-000000000001' and user_id = :'other'),
                :'other_fam'::uuid, 'redemption recorded');

-- Used up.
select tests.login(:'stranger');
select tests.throws($$select create_family('Mine', 'Me', 'UTC', 'AAAABBBB')$$, 'invite code already used', 'single-use code used');

-- Email-bound: matches case-insensitively.
select tests.login(:'newbie');
select tests.ok(create_family('Newbies', 'Nia', 'UTC', 'gggg-hhhh') is not null, 'email-bound code for the right email');

-- No profile name yet: create_family fills it.
select tests.login(:'noname');
select tests.eq((select display_name from profiles where id = :'noname'), '', 'blank profile before');
select tests.ok(create_family('Nameless', 'Pat', 'UTC', 'JJJJ-KKKK') is not null, 'multi-use code, first use');
select tests.eq((select display_name from profiles where id = :'noname'), 'Pat', 'profile name filled in');
select tests.throws($$select create_family('Again', 'Pat', 'UTC', 'JJJJ-KKKK')$$, 'invite code already used', 'same person cannot reuse a multi-use code');
select tests.login(:'multi1');
select tests.ok(create_family('Multi', 'M', 'UTC', 'JJJJKKKK') is not null, 'multi-use code, second use');
select tests.logout();
select tests.eq((select use_count from platform_invites where code = 'JJJJKKKK'), 2, 'multi-use count');

-- Anonymous callers can't call it at all.
select tests.login(null);
select tests.throws($$select create_family('Anon', 'A')$$, 'permission denied%', 'anon cannot create families');

-- Platform admins don't need a code.
select tests.login(:'admin');
select tests.ok(create_family('Admin Family', 'Ada') is not null, 'admin bypasses invite-only');

-- With invite-only off, anyone signed in can create a family.
select tests.logout();
update platform_settings set invite_only = false;
select tests.login(:'stranger');
select tests.ok(create_family('Open Family', 'Sam') is not null, 'invite-only off: no code needed');
select tests.logout();
update platform_settings set invite_only = true;

-- ───────────────────────── Family invites ─────────────────────────

-- Only parents of the family create invites.
select id as m_other from members where family_id = :'other_fam' limit 1 \gset
select tests.login(:'mom');
select id as inv_generic, code as code_generic, expires_at as exp_generic from create_family_invite(:'fam') \gset
select tests.ok(:'code_generic' ~ '^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$', 'returns the display form');
select tests.ok(:'exp_generic'::timestamptz between now() + interval '13 days 23 hours' and now() + interval '14 days 1 hour', 'default expiry 14 days');
select tests.eq((select code from family_invites where id = :'inv_generic'), replace(:'code_generic', '-', ''), 'stored normalized');
select tests.eq((select role::text from family_invites where id = :'inv_generic'), 'parent', 'default role parent');
select tests.eq((select invited_by from family_invites where id = :'inv_generic'), :'mom'::uuid, 'invited_by is the caller');
select tests.throws(format('select create_family_invite(%L, expires_in_days => 0)', :'fam'), 'expires_in_days must be between 1 and 60', '0 days');
select tests.throws(format('select create_family_invite(%L, expires_in_days => 61)', :'fam'), 'expires_in_days must be between 1 and 60', '61 days');
select tests.ok((select expires_at from create_family_invite(:'fam', expires_in_days => 60)) > now() + interval '59 days', '60 days ok');
select tests.throws(format('select create_family_invite(%L, member => %L)', :'fam', :'m_other'),
                    'member not found in this family', 'member of another family');
select tests.throws(format('select create_family_invite(%L, member => %L)', :'fam', :'m_mom'),
                    'that member already has an account', 'member already linked');
select tests.throws(format('select create_family_invite(%L)', :'other_fam'), 'not allowed', 'mom is not a parent there');

-- An invite for an existing member takes that member's role.
select id as inv_emma, code as code_emma from create_family_invite(:'fam', member => :'m_emma') \gset
select tests.eq((select role::text from family_invites where id = :'inv_emma'), 'child', 'member invite takes the member role');
select id as inv_dad, code as code_dad from create_family_invite(:'fam', member => :'m_dad') \gset
select id as inv_leo1, code as code_leo1 from create_family_invite(:'fam', member => :'m_leo') \gset
select id as inv_leo2, code as code_leo2 from create_family_invite(:'fam', member => :'m_leo') \gset
select id as inv_grandma, code as code_grandma from create_family_invite(:'fam', 'other', email => 'grandma@example.com') \gset
select id as inv_old, code as code_old from create_family_invite(:'fam') \gset
select id as inv_revoked, code as code_revoked from create_family_invite(:'fam') \gset
select id as inv_susp, code as code_susp from create_family_invite(:'fam') \gset
select id as inv_noname, code as code_noname from create_family_invite(:'fam', 'child') \gset

select tests.login(:'stranger');
select tests.throws(format('select create_family_invite(%L)', :'fam'), 'not allowed', 'stranger cannot invite');
select tests.login(:'device');
select tests.throws(format('select create_family_invite(%L)', :'fam'), 'not allowed', 'display cannot invite');
select tests.login(null);
select tests.throws(format('select create_family_invite(%L)', :'fam'), 'permission denied%', 'anon cannot invite');

-- ───────────────────────── preview_invite ─────────────────────────

select tests.ok(has_function_privilege('anon', 'preview_invite(text)', 'execute'), 'anon may preview');
select tests.ok(has_function_privilege('authenticated', 'preview_invite(text)', 'execute'), 'authenticated may preview');

select tests.login(null);
select tests.eq((select array_agg(k order by k) from jsonb_object_keys(preview_invite(:'code_generic')) k),
                array['expires_at', 'family_name', 'invited_by', 'kind', 'reason', 'role', 'valid'], 'preview shape');
select tests.eq(preview_invite(:'code_generic'),
                jsonb_build_object('valid', true, 'kind', 'family', 'family_name', 'The Demo Family', 'role', 'parent',
                                   'invited_by', 'Mom', 'expires_at', :'exp_generic'::timestamptz, 'reason', null),
                'family invite preview');
select tests.eq(preview_invite(lower(replace(:'code_emma', '-', ' ')))->>'role', 'child', 'lowercase + spaces work; role of claimed member');
select tests.eq(preview_invite('lets-play') - 'expires_at',
                '{"valid": true, "kind": "platform", "family_name": null, "role": null, "invited_by": null, "reason": null}'::jsonb,
                'platform invite preview');
select tests.ok(preview_invite('LETSPLAY')->>'expires_at' is not null, 'platform invite expiry');
select tests.ok(tests.no_leak(preview_invite('ZZZZ-ZZZZ'), 'invite code not valid'), 'unknown code');
select tests.ok(tests.no_leak(preview_invite('abc'), 'invite code not valid'), 'malformed code');
select tests.ok(tests.no_leak(preview_invite(''), 'invite code required'), 'empty code');
select tests.ok(tests.no_leak(preview_invite(null), 'invite code required'), 'null code');
select tests.ok(tests.no_leak(preview_invite('AAAA-BBBB'), 'invite code already used'), 'used platform code');
select tests.ok(tests.no_leak(preview_invite('CCCC-DDDD'), 'invite code expired'), 'expired platform code');
select tests.ok(tests.no_leak(preview_invite('EEEE-FFFF'), 'invite code not valid'), 'revoked platform code');
-- Email-bound: anonymous callers can't be checked; signed-in ones are.
select tests.eq(preview_invite(:'code_grandma')->>'valid', 'true', 'anon: email-bound invite looks valid');
select tests.login(:'stranger');
select tests.ok(tests.no_leak(preview_invite(:'code_grandma'), 'invite is for a different email'), 'wrong email');
select tests.ok(tests.no_leak(preview_invite('JJJJ-KKKK'), null) = false, 'multi-use code still open for stranger');
select tests.login(:'noname');
select tests.ok(tests.no_leak(preview_invite('JJJJ-KKKK'), 'invite code already used'), 'already redeemed by caller');

-- ───────────────────────── accept_family_invite ─────────────────────────

select tests.login(null);
select tests.throws(format('select accept_family_invite(%L)', :'code_generic'), 'permission denied%', 'anon cannot accept');

-- Claim an existing member row: Emma gets an account.
select tests.login(:'emma');
select tests.throws($$select accept_family_invite('')$$, 'invite code required', 'empty code');
select tests.throws($$select accept_family_invite('ZZZZ-ZZZZ')$$, 'invite code not valid', 'unknown code');
select tests.throws($$select accept_family_invite('LETS-PLAY')$$, 'invite code not valid', 'platform code is not a family code');
select tests.eq(accept_family_invite(lower(:'code_emma')), :'fam'::uuid, 'claim returns the family');
select tests.eq((select user_id from members where id = :'m_emma'), :'emma'::uuid, 'member row linked');
select tests.eq((select count(*)::int from members where family_id = :'fam'), 4, 'no new member row');
select tests.eq((select count(*)::int from tasks), 4, 'emma now sees family data');
select tests.throws(format('select create_family_invite(%L)', :'fam'), 'not allowed', 'kids cannot invite');
select tests.throws(format('select revoke_family_invite(%L)', :'inv_generic'), 'not allowed', 'kids cannot revoke');
select tests.eq((select count(*)::int from family_invites), 0, 'kids cannot list invites');
select tests.logout();
select tests.eq((select accepted_by from family_invites where id = :'inv_emma'), :'emma'::uuid, 'accepted_by');
select tests.ok((select accepted_at is not null from family_invites where id = :'inv_emma'), 'accepted_at');

-- Used invites stay used.
select tests.login(:'stranger');
select tests.throws(format('select accept_family_invite(%L)', :'code_emma'), 'invite code already used', 'accepted invite');
select tests.ok(tests.no_leak(preview_invite(:'code_emma'), 'invite code already used'), 'accepted invite preview');

-- A second invite for an already-claimed member.
select tests.login(:'leo');
select tests.ok(accept_family_invite(:'code_leo1') = :'fam'::uuid, 'leo claims his row');
select tests.login(:'stranger');
select tests.throws(format('select accept_family_invite(%L)', :'code_leo2'), 'that member already has an account', 'row already claimed');
select tests.logout();
select tests.ok((select accepted_at is null from family_invites where id = :'inv_leo2'), 'failed accept left the invite open');

-- Email-bound invite: wrong email, then the right one in another case.
select tests.login(:'stranger');
select tests.throws(format('select accept_family_invite(%L)', :'code_grandma'), 'invite is for a different email', 'wrong email');
select tests.login(:'grandma');
select tests.ok(accept_family_invite(:'code_grandma', 'Grandma') = :'fam'::uuid, 'right email');
select tests.logout();
select tests.eq((select row(role::text, color, display_name, sort_order)::text from members where user_id = :'grandma'),
                row('other', '#8E9CE6', 'Grandma', 4)::text, 'new member: invite role, default color, given name, last');
select tests.eq((select display_name from profiles where id = :'grandma'), 'Grandma', 'empty profile name filled in');

-- Already a member.
select tests.login(:'mom');
select tests.throws(format('select accept_family_invite(%L)', :'code_generic'), 'already a member of this family', 'mom already in');
select tests.logout();
select tests.ok((select accepted_at is null from family_invites where id = :'inv_generic'), 'still open after the failed accept');

-- Expired.
update family_invites set expires_at = now() - interval '1 second' where id = :'inv_old';
select tests.login(:'stranger');
select tests.throws(format('select accept_family_invite(%L)', :'code_old'), 'invite code expired', 'expired invite');
select tests.ok(tests.no_leak(preview_invite(:'code_old'), 'invite code expired'), 'expired preview');

-- Revoked: parents only.
select tests.throws(format('select revoke_family_invite(%L)', :'inv_revoked'), 'not allowed', 'stranger cannot revoke');
select tests.login(:'device');
select tests.throws(format('select revoke_family_invite(%L)', :'inv_revoked'), 'not allowed', 'display cannot revoke');
select tests.login(:'mom');
select revoke_family_invite(:'inv_revoked');
select revoke_family_invite(:'inv_emma');   -- accepted: stays a record of who joined
select tests.throws($$select revoke_family_invite('99999999-9999-9999-9999-999999999999')$$, 'not allowed', 'unknown invite');
select tests.logout();
select tests.ok((select revoked_at is not null from family_invites where id = :'inv_revoked'), 'revoked');
select tests.ok((select revoked_at is null from family_invites where id = :'inv_emma'), 'accepted invite not revoked');
select tests.login(:'stranger');
select tests.throws(format('select accept_family_invite(%L)', :'code_revoked'), 'invite code not valid', 'revoked invite');
select tests.ok(tests.no_leak(preview_invite(:'code_revoked'), 'invite code not valid'), 'revoked preview');

-- Suspended families take no new members.
select tests.logout();
update families set status = 'suspended' where id = :'fam';
select tests.login(:'stranger');
select tests.throws(format('select accept_family_invite(%L)', :'code_susp'), 'invite code not valid', 'suspended family');
select tests.ok(tests.no_leak(preview_invite(:'code_susp'), 'invite code not valid'), 'suspended preview');
select tests.logout();
update families set status = 'active' where id = :'fam';

-- No name given: the profile name, else 'New member'.
select tests.login(:'blank');
select tests.ok(accept_family_invite(:'code_noname', '   ') = :'fam'::uuid, 'accept with a blank name');
select tests.logout();
select tests.eq((select display_name from members where user_id = :'blank' and family_id = :'fam'), 'New member', 'fallback name');
select tests.eq((select role::text from members where user_id = :'blank' and family_id = :'fam'), 'child', 'invite role');
select tests.eq((select display_name from profiles where id = :'blank'), '', 'blank profile stays blank');
select tests.eq((select display_name from members where user_id = :'leo' and family_id = :'fam'), 'Leo', 'claimed rows keep their name');

-- ───────────────────────── Invite visibility ─────────────────────────

select tests.login(:'mom');
select tests.eq((select count(*)::int from family_invites), (select count(*)::int from family_invites where family_id = :'fam'),
                'mom sees only her family''s invites');
select tests.ok((select count(*) from family_invites) >= 10, 'mom sees her family''s invites');
select tests.throws(format($$insert into family_invites (family_id, code) values (%L, 'QQQQRRRR')$$, :'fam'), '%row-level security%', 'no direct inserts');
select tests.eq(tests.affected($$update family_invites set expires_at = now() + interval '1 year'$$), 0, 'no direct updates');
select tests.eq(tests.affected($$delete from family_invites$$), 0, 'no direct deletes');
select tests.eq((select count(*)::int from platform_invites), 0, 'platform invites hidden from parents');
select tests.eq((select count(*)::int from platform_invite_redemptions), 0, 'redemptions hidden from parents');
select tests.login(:'device');
select tests.eq((select count(*)::int from family_invites), 0, 'displays see no invites');
select tests.login(:'other');
select tests.eq((select count(*)::int from family_invites), 0, 'other family sees none of these invites');
select tests.login(:'admin');
select tests.ok((select count(*) from platform_invites) >= 6, 'admins see platform invites');
select tests.ok((select count(*) from platform_invite_redemptions) >= 4, 'admins see redemptions');

-- ───────────────────────── leave_family ─────────────────────────

-- Mom is the only parent with an account.
select tests.login(:'mom');
select tests.throws(format('select leave_family(%L)', :'fam'), 'the last parent can''t leave', 'last parent');
select tests.throws(format('select leave_family(%L)', :'other_fam'), 'not a member of this family', 'not a member');
select tests.login(null);
select tests.throws(format('select leave_family(%L)', :'fam'), 'permission denied%', 'anon cannot leave');

-- Kids can leave (the row stays, unlinked).
select tests.login(:'emma');
select leave_family(:'fam');
select tests.eq((select count(*)::int from tasks), 0, 'emma no longer sees the family');
select tests.logout();
select tests.ok((select user_id is null from members where id = :'m_emma'), 'emma row unlinked, not deleted');

-- With Dad linked, Mom may leave; then Dad is the last parent.
select tests.login(:'dad');
select tests.ok(accept_family_invite(:'code_dad') = :'fam'::uuid, 'dad claims his row');
select tests.login(:'mom');
select leave_family(:'fam');
select tests.eq((select count(*)::int from families), 0, 'mom left');
select tests.login(:'dad');
select tests.throws(format('select leave_family(%L)', :'fam'), 'the last parent can''t leave', 'dad is now the last parent');
select tests.logout();
select tests.ok((select user_id is null from members where id = :'m_mom'), 'mom row unlinked');
