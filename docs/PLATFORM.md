# Platform: accounts, invites, admins

homeOS is invite-only. This page covers how accounts and families fit
together, how invites work from end to end, how to make the first platform
admin and turn on the sign-up hook, and the assistant's limits. The exact
names live in [PLATFORM_SPEC.md](PLATFORM_SPEC.md); the SQL is in
`backend/supabase/migrations/20261007*.sql` and `20261008*.sql`.

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
  people who share a family with you, and only edit your own. The private
  `avatars` bucket takes images (JPEG, PNG, WebP, HEIC) up to 5 MB.
- A **member** is someone on the family screen. Kids usually have a member row
  with no account. A member row gets an account only by accepting an invite,
  never by a direct write, and a row with an account can't be moved to
  another family.
- **Roles** are `parent`, `child` and `other`. Parents manage the family:
  members, invites, rewards and approvals. Everyone can edit their own name,
  color and avatar. A family always keeps at least one parent with an account:
  the last one can't leave, be removed, be demoted or be unlinked.
- **Chores** can be added by anyone in the family, the kitchen display (and
  so the assistant) included, but only parents decide what one is worth:
  setting or changing `points` on a chore that skips approval, or turning
  approval off, is parent-only (`tasks_guard`). A kid's chore with points
  waits for a parent's approval like any other.
- **Colors** on members and events are `#RRGGBB`; anything else is refused.
- **Platform admins** (`platform_admins`) run the service through the admin
  console. Being an admin doesn't make you a member of any family; admins
  don't see families' chats or content through the app, only through the
  `admin_*` functions. There is no Storage policy that lets an admin read
  `family-media`. The console asks the `admin` function for a short-lived
  thumbnail URL instead.
- A **display** can rename itself and update `last_seen_at`. It can't change
  which family it belongs to or which auth user it is. Pairing a suspended
  family is refused.

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

Email-bound invites trust the email on the account (`auth.users.email`).
Keep **Confirm email** on (Dashboard → Authentication → Sign In / Providers →
Email); without it, someone could sign up with an address they don't own and
use an invite meant for it.

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
| `only a parent can add points that skip approval` | A kid or display adding a chore with points and no approval |
| `only a parent can change a chore's points or approval` | A kid or display changing those on an existing chore |

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
Never load `seed.sql` into a hosted project: anyone who reads this repo
knows those codes.

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
Only admins can change `status`, the assistant limit and the storage quotas;
parents can still rename their family. `pair-device` refuses a suspended
family before it creates a device account (`this family's account is
suspended`), and the `devices` trigger refuses the insert even if that check
is skipped.

## Storage quotas

| Setting | Where | Default |
|---|---|---|
| Storage per family | `platform_settings.storage_limit_bytes` | 5 GiB |
| A different storage limit for one family | `families.storage_limit_bytes` (null means the platform default; 0 means nothing new) | null |
| Items per family | `platform_settings.media_item_limit` | 5,000 |
| A different item cap for one family | `families.media_item_limit` (same null / 0 rules) | null |
| Largest single file | `platform_settings.media_max_bytes` | 512 MiB |

Set a family's overrides with `admin_set_family_limits`. Pass
`use_platform_storage_limit => true` (or the matching flag for the assistant
limit or the item cap) to clear an override. The iPhone writes `byte_size`,
`content_type` and a thumbnail path; an older app that omits `byte_size` can
still upload, and the object size is what gets billed once Storage is
present. A file that isn't an image or video the app uploads, a path outside
`<family_id>/<file>`, or an upload past the quota is refused by the database.
Removing an item is `admin_delete_media` plus the `admin` function's
`delete_media`, which also deletes the file and the thumbnail and writes
`delete_media` and `delete_media_files` to the audit log.

## Revoking a display

`admin_revoke_device(device)` deletes the `devices` row and, when the role
may, the display's auth user, so its refresh token stops working. The
console calls the `admin` function's `revoke_device`, which finishes the
auth deletion when SQL can't and writes `revoke_device_auth`. A second
revoke answers `device not found`.

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
- A single family's limit is `admin_set_family_limits(family,
  assistant_daily_limit => 500)`, or `use_platform_assistant_limit => true`
  to follow the platform default again. Parents can't change it themselves.
- **Chats are private.** `assistant_threads` and `assistant_messages` are
  visible only to the person or display that owns the thread, and only while
  they belong to that family. Other family members, including parents, can't
  read them, and neither can admins through the app. Messages are
  append-only and at most 100,000 characters each; deleting a thread deletes
  its messages. Usage rows stay, for
  the numbers.

## Claude authentication

The assistant calls Claude from the `assistant` edge function (Supabase
Deno), not from the admin app and not from the voice service. That runtime
does not receive a Vercel OIDC token: Vercel injects `VERCEL_OIDC_TOKEN`
only into Vercel builds, functions and `vercel env pull`. Supabase Edge
Functions are also not Deno Deploy, so Deno's own OIDC issuer is not
available there.

Login is [Anthropic workload identity federation](https://platform.claude.com/docs/en/manage-claude/workload-identity-federation).
The identity provider is the Vercel project `homeos-admin` (team
`rickymantilla`, team issuer). On each Claude call the edge function asks
`https://homeos-admin.vercel.app/api/assistant-identity` for a short-lived
OIDC token, forwarding the family member's Supabase JWT so the route can
check it against the project's public JWKS. The function then exchanges
that token at Anthropic. Nothing in this flow is an `sk-ant-` API key.

Until the three federation settings below are saved, the function still
uses `ANTHROPIC_API_KEY` if that secret exists, so a deploy of this code
does not by itself turn Claude off. When the three settings are present the
API key is ignored. Remove it after a federated chat works.

These steps need a human in the Claude Console (admin, owner, or primary
owner). This repo cannot create the issuer, the service account or the
rule.

1. In Vercel, open **homeos-admin → Settings → Security**. Under **Secure
   backend access with OIDC federation**, the issuer mode must be **Team**.
   The issuer is then `https://oidc.vercel.com/rickymantilla`. Save if you
   change it. Confirm `NEXT_PUBLIC_SUPABASE_URL` and
   `NEXT_PUBLIC_SUPABASE_ANON_KEY` are set for Production (the console
   needs both; the identity route needs the URL as the JWT issuer). Do not
   set `NEXT_PUBLIC_ADMIN_DEMO`. Do not add a service role key. In
   Supabase, **Authentication → JWT Keys** must use an asymmetric key
   (ES256 or RS256) so `…/auth/v1/.well-known/jwks.json` publishes a public
   key. A legacy HS256 secret cannot be checked from Vercel, and it is not
   copied there. Redeploy
   the admin app so `POST /api/assistant-identity` is live. Leave
   Deployment Protection off, or exclude that path (see
   [ADMIN.md](ADMIN.md)).
2. In the Claude Console, open **Settings → Organization** and copy the
   organization UUID.
3. Open **Settings → Workload identity** and choose **Connect workload**.
4. Choose **Custom OIDC** (not GitHub, AWS, Google Cloud, Entra or
   Kubernetes).
5. Issuer URL: `https://oidc.vercel.com/rickymantilla`. Leave JWKS on
   **Discovery**. Choose **Verify issuer** and wait until it can fetch
   `https://oidc.vercel.com/rickymantilla/.well-known/jwks`.
6. Set the issuer's **maximum JWT lifetime** (`max_jwt_lifetime_seconds`)
   to **7200** (2 hours). The default is 3600, and a production Vercel
   function token lasts 2 hours, so the default rejects it. The Connect
   wizard may not show this field; if so, create the issuer, then open it
   and edit the maximum. Leave `check_jti` on. The identity route asks
   Vercel for a new token, with a new `jti`, on every exchange.
7. Service account name: `homeos-assistant`. Rule name: `homeos-assistant`.
   OAuth scope: `workspace:inference` (Messages, including streaming). If a
   later call returns 403 because a beta on the Messages API is outside
   that scope, change the rule's scope to `workspace:developer`.
8. Match conditions, all of them:
   - Subject: `owner:rickymantilla:project:homeos-admin:environment:production`
   - Audience: `https://api.anthropic.com`
   - Claims: `environment` = `production`, `project_id` =
     `prj_6gsWzg7O9AxhTdcKSObkB2SxBQ8V`
9. Enable the rule in the workspace that should pay for the family
   assistant (the default workspace is enough). Note the rule id
   (`fdrl_…`), the service account id (`svac_…`) and, only if the rule is
   enabled in more than one workspace, the workspace id (`wrkspc_…`).
10. The wizard listens for a successful exchange for 15 minutes. Finish
    steps 11–13 in that window, or re-run the test from the rule's page
    afterwards. The resources stay either way.
11. In the Supabase dashboard, **Edge Functions → Secrets** (or
    `supabase secrets set`, reading the values from a prompt or a file
    that is not committed). Set:
    - `ANTHROPIC_FEDERATION_RULE_ID` = the `fdrl_…` id
    - `ANTHROPIC_ORGANIZATION_ID` = the organization UUID
    - `ANTHROPIC_SERVICE_ACCOUNT_ID` = the `svac_…` id
    - `ANTHROPIC_WORKSPACE_ID` = the `wrkspc_…` id, only when step 9 needed it
    Do not set `ANTHROPIC_IDENTITY_TOKEN`. The function fetches a new OIDC
    token on each exchange. Deploy the function so it picks up the
    secrets: `supabase functions deploy assistant`.
12. Send a chat from the display or the iPhone. The Claude Console's
    workload-identity test (or the rule's authentication history) should
    show the exchange.
13. Remove the old key. `supabase secrets unset ANTHROPIC_API_KEY`, then
    in the Claude Console delete it under **Settings → API keys**. A key
    left in Supabase secrets is ignored while the three federation
    settings are set, and it would be used again if those settings were
    removed.

## Admin audit log

Every admin change goes into `admin_audit_log` with the admin's id, an
action (`set_family_status`, `delete_family`, `create_platform_invite`,
`revoke_platform_invite`, `update_settings`, `set_admin`, `delete_media`,
`revoke_device`, `set_family_limits`, plus the `admin` edge function's
`invite_email`, `ban_user`, `unban_user`, `delete_user`,
`delete_family_files`, `delete_media_files` and `revoke_device_auth`), the
target and details. Signing a thumbnail URL is not logged. Admins read it on the
console's Audit page (`admin_list_audit`).

SQL can't remove files from Storage. The console deletes a family through the
`admin` function's `delete_family`, which runs `admin_delete_family` and then
empties `family-media/<family_id>/`; deleting a user empties
`avatars/<user_id>/`. Calling `admin_delete_family` or `admin_delete_media`
directly (SQL editor) leaves the files; remove them in Storage yourself.

The `admin` edge function calls `admin_create_platform_invite` and
`admin_delete_family` with the admin's own session, so those rows name the
admin; it writes its own rows for the other actions. The `admin_*` functions also accept the service role, for
server-side jobs. Called that way there's no `auth.uid()`, so the row's
`admin_id` is empty.

## Applying these migrations

Production already has the `20261006` and `20261007` migrations. Apply the
new ones in order, and don't edit them in place:

1. `backend/supabase/migrations/20261008000001_media_platform.sql`
2. `backend/supabase/migrations/20261008000002_media_storage.sql`

Then redeploy the `admin` and `pair-device` edge functions so the console can
sign and delete media, revoke a display's auth user, and so pairing refuses
a suspended family before creating an account. No new secrets or environment
variables. The iOS app should be updated too: until it is, uploads still
work, they just don't send `byte_size` or a thumbnail (Storage still bills
the object).

## Testing

`backend/tests/run.sh` starts a throwaway Postgres, applies every migration
on top of a stand-in for Supabase Auth (`tests/stub_auth.sql`), and runs each
`tests/*_test.sql` in a fresh copy of the database. The storage migrations
run only for `storage_test`, which adds `tests/stub_storage.sql`. Run one
file with `run.sh invites`, and add `VERBOSE=1` to see its output.
`concurrency_test` races two sessions for the same invite through `dblink`
(Postgres contrib, part of the `postgresql-16` package); it's skipped when
dblink isn't installed.
