# Platform: accounts, invites, admins

Ohana is invite-only. This page covers how accounts and families fit
together, how invites work from end to end, how to make the first platform
admin and turn on the sign-up hook, and the assistant's limits. The exact
names live in [PLATFORM_SPEC.md](PLATFORM_SPEC.md); the SQL is in
`backend/supabase/migrations/20261007*.sql` to `20261009*.sql`.

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
  another family. Parents can give a member a photo
  (`avatars/<family_id>/<file>`, in `members.avatar_path`), which everyone in
  the family can see; a member whose account has a profile photo shows that
  one instead.
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
2. The person opens the app (or `ohanaos://invite/K7QM-3XWD`) and taps
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
   and the `ohanaos://invite/<CODE>` link.
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
| `that photo isn't in this family's folder` | Setting `members.avatar_path` to anything but `<family_id>/<file>` for the member's own family |
| `only a parent can add points that skip approval` | A kid or display adding a chore with points and no approval |
| `only a parent can change a chore's points or approval` | A kid or display changing those on an existing chore |
| `you're the only parent with a login in {family}. Make someone else there a parent first` | `delete_my_account` by the last parent of a family where others have logins |

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

Otherwise it returns `{"error": {"http_code": 403, "message": "homeOS is invite-only. Ask your family for an invite code."}}`.

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
| Largest single file | `platform_settings.media_max_bytes` | 2 GiB |

Set a family's overrides with `admin_set_family_limits`. Pass
`use_platform_storage_limit => true` (or the matching flag for the assistant
limit or the item cap) to clear an override. The iPhone writes `byte_size`
(the file only; posters are not billed), `content_type` and a thumbnail
path; an older app that omits `byte_size` can still upload, and the object
size is what gets billed once Storage is present. A file that isn't an
image or video the app uploads, a path outside `<family_id>/<file>`, or an
upload past the quota is refused by the database. Removing an item is
`admin_delete_media` plus the `admin` function's `delete_media`, which also
deletes the file and the thumbnail from Storage and writes `delete_media`
and `delete_media_files` to the audit log. For a Blob row it doesn't touch
the Blob store: the file and poster stay there until the family is
deleted.

## Revoking a display

`admin_revoke_device(device)` deletes the `devices` row and, when the role
may, the display's auth user, so its refresh token stops working. The
console calls the `admin` function's `revoke_device`, which finishes the
auth deletion when SQL can't and writes `revoke_device_auth`. A second
revoke answers `device not found`.

## Deleting your account

People delete their own account in the iOS app: Profile → **Delete account**,
or the same button on "Enter an invite code" when they have no family. The App
Store requires this of any app that creates accounts (guideline 5.1.1(v)).
The phone calls the admin app's `POST /api/account/delete`, which calls the
`delete-account` edge function and then clears Blob files.
`delete_my_account()` does the database part:

- **The only login in a family:** the family goes with everything in it,
  its displays and their accounts included, and its member photos
  (`avatars/<family_id>/`).
- **A family others still use:** the member row stays, unlinked, with its
  points and history, as with `leave_family`. A parent can remove it.
- **The last parent of a family where others have logins:** refused. Make
  someone else a parent first.
- **Always:** the login, the profile, the profile photo
  (`avatars/<user_id>/`) and their assistant chats.

Displays and platform admins can't delete themselves this way: unpair the
display, or remove the admin row first. Each deletion writes
`delete_own_account` to the audit log with the user id and counts, and no
email. Deploy the `delete-account` function and the admin app together with
the migration; an app build that has the button gets an error until they're
live.

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

## Connected calendars

Families can bring other calendars onto the family calendar, and show the
family calendar in other apps (PLATFORM_SPEC.md §1.13, §2.5). Calendar links
work as soon as the `calendar-sync` function is deployed; Google sign-in and
the 15-minute schedule need the setup below.

| | What happens |
|---|---|
| **Calendar link** (iCloud public calendar, Outlook published calendar, Google's secret iCal address, school, team or holiday calendars) | A parent pastes the `webcal://` or `https://` link in the iOS app. The function reads it before saving it, so a page that isn't a calendar is refused with a reason. The link itself is never shown again or sent to phones or displays (anyone with it can read that calendar); parents see its host. |
| **Google Calendar** | A parent signs in to Google in a browser sheet (read-only calendar access) and picks calendars; the app finishes the sign-in with that parent's own session, so only the person who started it can. Ohana stores the account's email and a refresh token, and can't change anything in Google Calendar. Only that parent can add more of its calendars or turn Busy off on them; any parent can **Disconnect** it, which revokes Ohana's access at Google unless the same Google account is connected in another family. |
| **What families see** | Imported events on the wall display, in the app and to the assistant, in the calendar's color (or its person's), 60 days back to a year ahead, at most 5,000 per calendar. They can't be edited or deleted in Ohana. A calendar can show as **Busy** only (times without titles or places); events marked private in their own calendar always do. |
| **Out** | A parent makes a secret link for Apple Calendar, Google Calendar or Outlook to subscribe to. It carries the family's own events, not imported ones. **Make a new link** stops the old one working. Those apps refresh it on their own schedule (Google can take several hours). |
| **When a parent leaves** | Their Google accounts, and those calendars' events, leave the family with them (leaving, or deleting their account). Calendar links and the shared link stay with the family. |

### Setup

1. Apply `20261012000001_calendar_sync.sql` (`supabase db push`, see
   Applying these migrations) and deploy the function:
   `supabase functions deploy calendar-sync`. `config.toml` already sets
   `verify_jwt = false` for it: Google's redirect and calendar apps don't
   send a Supabase token, and the function checks every caller itself.
2. **Google sign-in** (optional; links work without it). In the Google Cloud
   console, in a project for Ohana:
   1. Enable the **Google Calendar API** (APIs & Services → Library).
   2. Google Auth Platform → **Branding**: app name Ohana Display, support
      email, home page `https://ohanaos.co`, privacy policy
      `https://ohanaos.co/privacy`. **Data access**: add the scope
      `https://www.googleapis.com/auth/calendar.readonly` (plus `openid` and
      `email`, which are non-sensitive).
   3. **Clients** → Create client → **Web application**. Authorized redirect
      URI: `https://<project-ref>.supabase.co/functions/v1/calendar-sync/google/callback`.
   4. `supabase secrets set GOOGLE_CLIENT_ID=<client id> GOOGLE_CLIENT_SECRET=<client secret>`.
      Behind a custom domain, also set `GOOGLE_REDIRECT_URI` to the URI you
      registered. `CALENDAR_APP_REDIRECT` (default `ohanaos://google-calendar`)
      is where the browser goes back to the app.
   5. **Audience.** While the app is in *Testing*, only the Google accounts
      listed as test users (up to 100) can connect, and Google expires their
      refresh tokens after 7 days, so those parents see "Google needs you to
      connect this account again" weekly. `calendar.readonly` is a sensitive
      scope: publishing to everyone needs Google's verification (the privacy
      policy already carries the Limited Use statement Google asks for).
3. **Every 15 minutes.** Without this, calendars still refresh when a paired
   display is on (it asks every 15 minutes) or someone opens the app. With it:
   1. `supabase secrets set CALENDAR_CRON_SECRET=$(openssl rand -hex 32)`
      (at least 16 characters).
   2. Dashboard → Database → Extensions: enable `pg_cron` and `pg_net`.
   3. In the SQL editor, with your project URL and the same secret:

      ```sql
      select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
      select vault.create_secret('<CALENDAR_CRON_SECRET>', 'calendar_cron_secret');
      select cron.schedule('calendar-sync', '*/15 * * * *', $$
        select net.http_post(
          url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url')
                 || '/functions/v1/calendar-sync',
          headers := jsonb_build_object(
            'Content-Type', 'application/json',
            'Authorization', 'Bearer ' || (select decrypted_secret from vault.decrypted_secrets
                                           where name = 'calendar_cron_secret')),
          body := '{"action": "sync_due"}'::jsonb,
          timeout_milliseconds := 150000);
      $$);
      ```

      Each run syncs up to 50 calendars that haven't been tried for 14
      minutes, each in its own function request. `select * from
      cron.job_run_details order by start_time desc limit 5` shows the runs;
      `net._http_response` the answers (`{"synced": n, "failed": n}`).

### When a calendar doesn't sync

The app shows the reason under the calendar (`calendar_sources.last_error`)
and keeps its last good events:

| Message | Meaning |
|---|---|
| That calendar link doesn't exist anymore. | 404 or 410: the calendar was unpublished, or the link was replaced (iCloud and Outlook do that when sharing is turned off and on). Add the new link. |
| The calendar link needs a sign-in. Use a public or secret link instead. | 401 or 403: a link that only works signed in. |
| That link didn't return a calendar. | A web page, not ICS. Look for the Subscribe / iCal link. |
| That calendar is too big to sync (over 5 MB). / … Try a link to a smaller calendar. | Over 5 MB, or more than about a second of work to read. |
| Google needs you to connect this account again. | Google refused the token: revoked in the Google account, password changed, or a Testing-mode token over 7 days old. Sign in again from the app; the same account row is reused. |
| Something went wrong syncing this calendar. Ohana will try again soon. | Anything unexpected; Dashboard → Edge Functions → calendar-sync → Logs has the detail. |

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

SQL can't remove files from Storage, and it can't remove Blob objects either.
The console deletes a family through the `admin` function's `delete_family`,
which runs `admin_delete_family` and then empties `family-media/<family_id>/`
(files uploaded before Blob) and `avatars/<family_id>/` (member photos). The
console then deletes photos and videos from the private Blob store under the
same prefix. Deleting one item runs `admin_delete_media` and then removes
that row's Storage objects. Deleting a user empties `avatars/<user_id>/`.
Calling `admin_delete_family` or `admin_delete_media` directly (SQL editor)
leaves the files; remove them in Storage, and the family's folder in Blob,
yourself.

The `admin` edge function calls `admin_create_platform_invite` and
`admin_delete_family` with the admin's own session, so those rows name the
admin; it writes its own rows for the other actions. The `admin_*` functions also accept the service role, for
server-side jobs. Called that way there's no `auth.uid()`, so the row's
`admin_id` is empty.

## Applying these migrations

Production has the `20261006` and `20261007` migrations and items 1 to 9
below (checked with `supabase migration list` on 2026-10-07); item 10 isn't
applied yet. Apply the new ones in order, and don't edit them in place:

1. `backend/supabase/migrations/20261008000001_media_platform.sql`
2. `backend/supabase/migrations/20261008000002_media_storage.sql`
3. `backend/supabase/migrations/20261008000004_boot_video.sql`
4. `backend/supabase/migrations/20261009000001_wall_create_rewards.sql`
5. `backend/supabase/migrations/20261009000002_video_blob.sql`
6. `backend/supabase/migrations/20261009000003_blob_photos.sql`
7. `backend/supabase/migrations/20261009000004_blob_limits.sql`
8. `backend/supabase/migrations/20261010000001_account_deletion.sql`, then
   `supabase functions deploy delete-account` and redeploy the admin app
   (`/api/account/delete`, `/privacy`, `/support`). Safe to run again.
9. `backend/supabase/migrations/20261010000002_recurrence.sql`. Safe to run again.
10. `backend/supabase/migrations/20261011000001_member_photos.sql` and
    `20261011000002_storage_member_photos.sql`, then redeploy the `admin` and
    `delete-account` functions, so deleting a family also empties its member
    photos. An app build with member photos gets an error when saving one
    until these are live; everything else keeps working.
11. `backend/supabase/migrations/20261012000001_calendar_sync.sql`, then
    `supabase functions deploy calendar-sync` and the setup under Connected
    calendars. It replaces `event_occurrences` (one more column,
    `source_id`); older app and display builds read it as before. An app
    build with connected calendars shows none until this is live, without
    an error.

`supabase db push` does this. 5 to 7 used to be `20261008000001` to
`20261008000003` and shared versions with 1 and 2. They and 3 (`boot_video`)
are safe to run again if you pasted them into the SQL editor before; a
re-run of 3 also removes the anon read on `platform_boot_video` that its
first draft granted. If you pasted 1, 2 or 4 by hand, record it first so the
push skips it, for example
`supabase migration repair --status applied 20261008000001`.

If 5 to 7 are already on the database, 3 and 4 sort before them and
`supabase db push` stops with "Found local migration files to be inserted
before the last migration on remote database". Run
`supabase db push --include-all` to apply them.

`20261008000003` was briefly the boot video's version on its branch. If
`supabase migration list` shows it only on the remote, look up its name with
`select name from supabase_migrations.schema_migrations where version = '20261008000003'`.
If that is `boot_video` or `blob_limits`, run
`supabase migration repair --status reverted 20261008000003`; the push then
runs the renamed file, which is safe to run again. Anything else is a
migration this branch does not have: merge it first.

Then redeploy the `admin` and `pair-device` edge functions so the console can
sign and delete media, revoke a display's auth user, and so pairing refuses
a suspended family before creating an account. Create the private Blob store
and set `BLOB_STORE_ID` (see [ADMIN.md](ADMIN.md)). Point the iOS app at this
deployment (`Config.mediaAPIURL`) and the display at it (`HOMEOS_MEDIA_URL`).
An older app build still uploads to Storage without `byte_size`; Storage
bills that object. New uploads go to Blob and send `byte_size`.

## Testing

`backend/tests/run.sh` starts a throwaway Postgres, applies every migration
on top of a stand-in for Supabase Auth (`tests/stub_auth.sql`), and runs each
`tests/*_test.sql` in a fresh copy of the database. The storage migrations
run only for the tests in `supabase_tests` (`storage_test`, `boot_video_test`
and `member_photos_test`), on top of `tests/stub_storage.sql`. Run one
file with `run.sh invites`, and add `VERBOSE=1` to see its output.
`concurrency_test` races two sessions for the same invite through `dblink`
(Postgres contrib, part of the `postgresql-16` package); it's skipped when
dblink isn't installed.
