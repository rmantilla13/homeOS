# Platform: accounts, invites, admins

homeOS is invite-only. This page covers how accounts and families fit
together, how invites work from end to end, how to make the first platform
admin and turn on the sign-up hook, and the assistant's limits. The exact
names live in [PLATFORM_SPEC.md](PLATFORM_SPEC.md); the SQL is in
`backend/supabase/migrations/20261007*.sql`.

## Accounts

There are two kinds of auth users:

| | People | Displays |
|---|---|---|
| Created by | Signing up in the iOS app (or an admin's email invite) | `pair-device`, when a parent pairs a screen |
| `app_metadata.kind` | not set | `device` |
| Profile (`profiles`) | Yes, made on sign-up by `handle_new_user` | No |
| Linked to a family by | `members.user_id` | `devices.user_id` |

- A **profile** holds the display name and avatar (`avatars/<user_id>/avatar.jpg`).
  The name comes from the sign-up metadata `display_name`, else the part of
  the email before the `@`. You can read your own profile and the profiles of
  people who share a family with you, and only edit your own.
- A **member** is someone on the family screen. Kids usually have a member row
  with no account. A member row gets an account only by accepting an invite,
  never by a direct write.
- **Roles** are `parent`, `child` and `other`. Parents manage the family:
  members, invites, rewards and approvals. Everyone can edit their own name,
  color and avatar. A family always keeps at least one parent with an account:
  the last one can't leave, be removed, be demoted or be unlinked.
- **Platform admins** (`platform_admins`) run the service through the admin
  console. Being an admin doesn't make you a member of any family; admins
  don't see families' chats or content through the app, only through the
  `admin_*` functions.

## Invites

Codes look like `K7QM-3XWD`: 8 characters from an alphabet without
look-alikes (no `0`/`O`, `1`/`I`). People can type them in any case, with or
without the dash. They're stored without the dash (`K7QM3XWD`), and
`format_invite_code()` gives the display form.

| | Platform invite | Family invite |
|---|---|---|
| Lets you | Start a new family | Join an existing family |
| Made by | An admin (`admin_create_platform_invite`, or the console's "email invite") | A parent (`create_family_invite`) |
| Uses | `max_uses` (default 1) | Once |
| Expires | 30 days by default (1–365) | 14 days by default (1–60) |
| Email-bound | Optional | Optional |
| Used by | `create_family(..., invite_code)` | `accept_family_invite(code, display_name)` |

The `platform_settings.invite_only` switch (on by default) decides whether
`create_family` needs a platform invite. Admins never need one. Joining a
family always needs a family invite.

### Flow: starting a new family

1. An admin creates a platform invite in the console, optionally for one email
   address. The "email invite" action also sends a Supabase invite email
   carrying the code.
2. The person opens the app (or `homeos://invite/K7QM-3XWD`) and taps
   **Check invite**. `preview_invite(code)` answers, without signing in,
   `{"valid": true, "kind": "platform", ...}`.
3. They create an account. The app passes `invite_code` and `display_name` in
   the sign-up metadata, so the auth hook (below) lets the sign-up through.
4. The app calls `create_family(family_name, my_name, tz, invite_code)`. The
   function checks the invite again and locks it, so two people can't take
   its last use. It counts the use, records a redemption, creates the family
   and makes the caller its first parent.

### Flow: joining a family

1. A parent creates an invite in the iOS app: a role, optionally an existing
   member it's for, and optionally an email. The share sheet sends the code
   and the `homeos://invite/<CODE>` link.
2. The invitee checks it: `preview_invite` returns the family name, the
   role, the inviter's name and the expiry. That's all it reveals; a bad code
   only gets a `reason`.
3. They sign up or sign in, and the app calls `accept_family_invite(code,
   display_name)`.
   - **Invite for an existing member** (e.g. a kid getting their first
     account): the member row is linked to the new account and keeps its name,
     color, role and points. The invite takes that member's role.
   - **Otherwise**: a new member row is created with the invite's role and
     the color `#8E9CE6`. It takes the name `display_name`, else the profile's
     name, else "New member".
4. Parents see pending and accepted invites (`family_invites`) and can revoke
   pending ones (`revoke_family_invite`).

`leave_family(family)` unlinks your account and keeps your member row, so a
kid still shows on the screen with their points.

### Errors the apps show

The RPCs raise short messages meant to be shown as-is, and `preview_invite`
returns the same text in `reason`:

| Message | When |
|---|---|
| `invite code required` | No code given (and one is needed) |
| `invite code not valid` | Unknown, revoked, the wrong kind, or the family is suspended |
| `invite code expired` | Past `expires_at` |
| `invite code already used` | Accepted, out of uses, or already redeemed by you |
| `invite is for a different email` | Email-bound to someone else |
| `already a member of this family` | Accepting an invite to your own family |
| `that member already has an account` | The member row the invite is for got claimed |
| `the last parent can't leave` | `leave_family` by the only parent with an account |
| `a family needs at least one parent with an account` | Removing, demoting or unlinking that parent directly |
| `only a parent can change that` | A kid editing anything but their own name, color or avatar |

## The first admin

Admins can only be added by another admin, so the first one is inserted by
hand in the Supabase SQL editor (it runs as `postgres`).

1. Create your account: sign up in the iOS app, or use Dashboard →
   Authentication → Users → Add user. Do this **before** turning
   on the auth hook. If the hook is already on, first give yourself an
   invite:

   ```sql
   insert into public.platform_invites (code, email, note)
   values (public.normalize_invite_code(public.generate_invite_code()), 'you@example.com', 'bootstrap');
   ```

2. Make yourself an admin:

   ```sql
   insert into public.platform_admins (user_id)
   select id from auth.users where email = 'you@example.com';
   ```

3. Sign in to the admin console. Add other admins from the Users page
   (`admin_set_admin`); the last admin can't be removed.

Local development: `supabase db reset` seeds the codes `LETS-PLAY` (start a
family, 100 uses) and `MEET-THEM` (join the demo family as a parent).

## The auth hook (optional)

`public.hook_before_user_created` rejects sign-ups that don't come with an
open invite while the platform is invite-only. It's a second layer: without
it, anyone can create an account, but they still can't create or join a
family without a code. With it, they can't even create the account.

**It allows a sign-up when:**

- `invite_only` is off,
- the user is a display account (`app_metadata.kind = 'device'`, created by
  `pair-device`),
- `user_metadata.invite_code` matches an open platform or family invite (and
  that invite's email, if it has one), or
- the sign-up email matches an open invite's email. This covers admin email
  invites and Sign in with Apple, where there's no metadata.

Otherwise it returns `{"error": {"http_code": 403, "message": "homeOS is
invite-only. Ask your family for an invite code."}}`.

**To turn it on:**

1. Apply the migrations. They grant `execute` on the function to
   `supabase_auth_admin` only (and `usage` on `public`), and take it away
   from `anon` and `authenticated`.
2. In the Supabase Dashboard, go to **Authentication → Hooks → Before User
   Created**, choose **Postgres function**, and pick
   `public.hook_before_user_created`.
3. Check the payload against the current Supabase docs for the Before User
   Created hook. The function reads `event.user.email`,
   `event.user.user_metadata.invite_code` and `event.user.app_metadata.kind`,
   and answers `{}` to allow or `{"error": {"http_code", "message"}}` to
   reject. If Supabase has renamed any of these, adjust the function in a new
   migration.
4. Try it: sign up without a code (you get the 403 message), then with
   `LETS-PLAY` locally or a fresh invite.

For the local stack (`supabase start`), the CLI reads hooks from
`supabase/config.toml`: add `[auth.hook.before_user_created]` with
`enabled = true` and
`uri = "pg-functions://postgres/public/hook_before_user_created"`. Check the
CLI docs for your version.

## Suspending a family

`admin_set_family_status(family, 'suspended', reason)` takes a family
offline. Its members and displays then see none of its data: every RLS check
goes through `my_family_ids()` and `is_family_parent()`, which leave out
suspended families. Invites to it stop working, and the assistant refuses it.
Admins still see it in the console. Setting `'active'` brings everything back.
Only admins can change `status` and the assistant limit; parents can still
rename their family.

## Assistant limits

| Setting | Where | Default |
|---|---|---|
| Assistant on or off for everyone | `platform_settings.assistant_enabled` (console → Settings) | on |
| Requests per family per day | `platform_settings.assistant_daily_limit` (console → Settings) | 200 |
| A different limit for one family | `families.assistant_daily_limit` (null means the platform default) | null |

- A **request** is one call to the `assistant` function: one `assistant_usage`
  row, written with the service role, holding the model, token counts and
  tool calls. The day is the UTC day. When a family's rows for today reach
  its limit, the assistant answers "We've hit today's assistant limit. Try
  again tomorrow."
- There's no console control for a single family's limit yet. Set it in SQL:
  `update families set assistant_daily_limit = 500 where id = '…';`.
  Parents can't change it themselves.
- **Chats are private.** `assistant_threads` and `assistant_messages` are
  visible only to the person or display that owns the thread, and only while
  they belong to that family. Other family members, including parents, can't
  read them, and neither can admins through the app. Messages are
  append-only; deleting a thread deletes its messages. Usage rows stay, for
  the numbers.

## Admin audit log

Every admin change goes into `admin_audit_log` with the admin's id, an
action (`set_family_status`, `delete_family`, `create_platform_invite`,
`revoke_platform_invite`, `update_settings`, `set_admin`, plus the `admin`
edge function's `invite_email`, `ban_user`, `unban_user` and `delete_user`),
the target and details. Admins read it on the console's Audit page
(`admin_list_audit`).

The `admin` edge function calls `admin_create_platform_invite` with the
admin's own session, so that row names the admin; it writes its own rows for
the other actions. The `admin_*` functions also accept the service role, for
server-side jobs. Called that way there's no `auth.uid()`, so the row's
`admin_id` is empty.

## Testing

`backend/tests/run.sh` starts a throwaway Postgres, applies every migration
on top of a stand-in for Supabase Auth (`tests/stub_auth.sql`), and runs each
`tests/*_test.sql` in a fresh copy of the database. The storage migrations
run only for `storage_test`, which adds `tests/stub_storage.sql`. Run one
file with `run.sh invites`, and add `VERBOSE=1` to see its output.
