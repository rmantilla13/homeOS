# Ohana platform spec: accounts, invites, assistant v2, voice, admin

This is the contract between the database, the edge functions, the admin
console, the display, the voice service and the iOS app. Names here are
exact. When code and this document disagree, fix one of them so they match.

Existing state (do not break): migrations `20261006000001_core_schema.sql`
(families, members, devices, events, tasks, completions, rewards, points
ledger, lists, meals, media, RLS helpers `my_family_ids()`,
`is_family_member()`, `is_family_parent()`, `my_member_id()`, RPCs
`create_family(family_name, my_name, tz)`, `review_completion(completion,
approve)`, `redeem_reward(reward, member)`, `resolve_redemption(redemption,
fulfilled)`, `adjust_points(member, delta, reason)`),
`20261006000002_storage_realtime.sql` (bucket `family-media`, realtime),
`20261006000003_family_memories.sql`. Edge functions `pair-device` and
`assistant`.

---

## 1. Database (new migrations)

Migrations are added after the existing ones, never edited in place:

- `20261007000001_profiles_admin.sql`: profiles, platform admins, settings, family status
- `20261007000002_invites.sql`: platform and family invites, the new `create_family`, membership RPCs, the auth hook
- `20261007000003_assistant_threads.sql`: threads, messages, usage
- `20261007000004_admin.sql`: admin RPCs, audit log
- `20261007000005_storage_avatars.sql`: `avatars` bucket and policies (Supabase-only, like 000002)
- `20261007000006_review_flags.sql`: `review_completion` and `resolve_redemption`
  raise `approve is required` / `fulfilled is required` on a null flag (a null
  used to cancel a redemption without refunding it)
- `20261007000007_family_guards.sql`: `tasks_guard` and the color format
  checks (§1.8), on tables from 20261006000001
- `20261008000001_media_platform.sql`: per-family storage quotas, media path
  binding, device and membership guards, admin media / limits / revoke RPCs (§1.9)
- `20261008000001_video_blob.sql`: `media_items.file_store` (§1.10)
- `20261008000002_blob_photos.sql`: photos in Blob, extension must match kind (§1.10)
- `20261008000002_media_storage.sql`: the Storage quota trigger and the
  `family-media` policies (Supabase-only, like 000002 and 000005)
- `20261008000003_blob_limits.sql`: per-file cap of 2 GiB and the Blob video types (§1.9, §1.10)

Everything that only exists on Supabase (`storage.*`, `supabase_realtime`,
`supabase_auth_admin` grants) goes in a separate migration or in a
`do $$ ... $$` block guarded by an existence check, so `backend/tests/run.sh`
keeps running on plain Postgres with `backend/tests/stub_auth.sql`.

### 1.1 Profiles

```
public.profiles (
  id            uuid primary key references auth.users on delete cascade,
  display_name  text not null default '',
  avatar_path   text,                 -- object path in bucket `avatars`, e.g. '<user_id>/avatar.jpg'
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
)
```

- **Trigger:** `on_auth_user_created` (after insert on `auth.users`) runs
  `public.handle_new_user()`, which is security definer. It creates the
  profile with `display_name = coalesce(raw_user_meta_data->>'display_name',
  split_part(email,'@',1), '')`. It skips device accounts, where
  `raw_app_meta_data->>'kind' = 'device'`.
- **RLS, select:** your own row, or the profile of anyone who shares a family
  with you (both linked through `members.user_id`).
- **RLS, update:** your own row only.
- `touch_updated_at` trigger.
- **Test stub:** `backend/tests/stub_auth.sql` must grow `auth.users` columns
  `email text`, `raw_user_meta_data jsonb default '{}'`,
  `raw_app_meta_data jsonb default '{}'`, `created_at timestamptz default now()`,
  `last_sign_in_at timestamptz`, `banned_until timestamptz`.

### 1.2 Platform admins and settings

```
public.platform_admins (user_id uuid primary key references auth.users on delete cascade,
                        created_at timestamptz default now(), created_by uuid)
public.platform_settings (id boolean primary key default true check (id),   -- single row
                          invite_only boolean not null default true,
                          assistant_enabled boolean not null default true,
                          assistant_daily_limit int not null default 200,     -- per family per day
                          updated_at timestamptz not null default now(),
                          updated_by uuid)
```

- Seed `platform_settings` with one row.
- `public.is_platform_admin() returns boolean`: stable, security definer,
  checks `auth.uid()`.
- **RLS:** `platform_admins` and `platform_settings` are readable only by
  admins. There are no client write policies; writes go through the admin
  RPCs.
- **Bootstrap:** the first admin is inserted by hand (SQL editor). The steps
  are in `docs/PLATFORM.md`.

### 1.3 Family status (suspension)

- Add to `families`: `status text not null default 'active' check (status in
  ('active','suspended'))`, `suspended_at timestamptz`,
  `suspended_reason text`, and `assistant_daily_limit int` (null means the
  platform default).
- Redefine `my_family_ids()` (`create or replace`) to leave out suspended
  families. Members and devices of a suspended family then see none of its
  data. Admin functions bypass this check.

### 1.4 Invites (invite-only platform)

Codes are human-friendly: 8 characters from
`ABCDEFGHJKLMNPQRSTUVWXYZ23456789`, grouped `XXXX-XXXX`, generated by
`public.generate_invite_code()` using `gen_random_bytes`. They are compared
case-insensitively, with dashes and spaces ignored. Both invite tables store
the normalized form, uppercase with no dash, in `code`.
`public.normalize_invite_code(text)` handles the normalization.

```
public.platform_invites (            -- lets someone create a NEW family
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  email       text,                  -- if set, only this email may redeem (case-insensitive)
  note        text,
  max_uses    int not null default 1 check (max_uses > 0),
  use_count   int not null default 0,
  expires_at  timestamptz not null default now() + interval '30 days',
  created_by  uuid references auth.users on delete set null,
  created_at  timestamptz not null default now(),
  revoked_at  timestamptz
)
public.platform_invite_redemptions (invite_id uuid references platform_invites on delete cascade,
  user_id uuid references auth.users on delete cascade, family_id uuid references families on delete set null,
  redeemed_at timestamptz default now(), primary key (invite_id, user_id))

public.family_invites (              -- lets someone JOIN an existing family
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references families on delete cascade,
  code        text not null unique,
  role        public.member_role not null default 'parent',
  member_id   uuid references members on delete cascade,  -- claim an existing member row (e.g. a kid getting an account)
  email       text,
  invited_by  uuid references auth.users on delete set null default auth.uid(),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null default now() + interval '14 days',
  accepted_by uuid references auth.users on delete set null,
  accepted_at timestamptz,
  revoked_at  timestamptz
)
```

**RLS**

- `platform_invites` and `platform_invite_redemptions`: admins only.
- `family_invites`: parents of the family can select. All writes go through
  RPCs.

**RPCs** (all security definer, with `search_path = public`)

- `create_family(family_name text, my_name text, tz text default 'UTC', invite_code text default null) returns uuid`
  - Drop the old three-argument version first.
  - Requires a signed-in caller.
  - If `platform_settings.invite_only` is on and the caller isn't a platform
    admin, a valid platform invite is required: it must exist, not be
    revoked, not be expired, have `use_count < max_uses`, and match the
    caller's email if the invite names one. The caller's email comes from
    `auth.users`.
  - On success the RPC:
    - increments `use_count`
    - records a redemption
    - creates the family and the caller's member row (`role = parent`, linked to `auth.uid()`)
    - sets `profiles.display_name` if it's empty
  - Errors are short and human-readable: `invite code required`,
    `invite code not valid`, `invite code expired`, `invite code already used`,
    `invite is for a different email`.
- `preview_invite(code text) returns jsonb`
  - Granted to `anon` and `authenticated`.
  - Returns `{ "valid": bool, "kind": "family"|"platform"|null, "family_name": text|null, "role": text|null, "invited_by": text|null, "expires_at": timestamptz|null, "reason": text|null }`.
  - Never returns other families' data beyond the family name.
- `accept_family_invite(code text, display_name text default null) returns uuid` (the family id)
  - Requires a signed-in caller and a valid family invite (not revoked, not
    expired, not accepted, email matches if set).
  - If the caller is already a member of that family, raise
    `already a member of this family`.
  - If `member_id` is set, link that row (`user_id = auth.uid()`); raise if
    it's already linked. Otherwise insert a new member with
    `display_name = coalesce(display_name, profiles.display_name, 'New member')`,
    the invite's role and the default color `#8E9CE6`.
  - Marks the invite accepted and returns the family id.
- `create_family_invite(family uuid, role public.member_role default 'parent', member uuid default null, email text default null, expires_in_days int default 14) returns table (id uuid, code text, expires_at timestamptz)`
  - Parent of `family` only.
  - If `member` is given, it must belong to `family` and have `user_id is null`.
  - `expires_in_days` must be between 1 and 60.
  - Returns the display form of the code (`XXXX-XXXX`).
- `revoke_family_invite(invite uuid) returns void`: parent of the invite's family.
- `leave_family(family uuid) returns void`: unlinks the caller's member row
  (`user_id = null`). Raises `the last parent can't leave` if the caller is
  the only parent with a linked account.

**Member guards** (trigger `members_guard`, before insert, update or delete on members)

- Non-parents may update only their own row, and only `display_name`,
  `color` and `avatar_url`. Changing `role`, `family_id` or `user_id` raises.
  Add an RLS update policy `members_update_self`
  (`using (user_id = auth.uid())`) alongside the existing parent policy.
- Nobody, parents included, may link an account to a row directly (insert or
  update `user_id`), or move a row that has an account to another family:
  `accounts join a family through an invite`. Rows without an account can
  move between families the caller is a parent of.
- Deleting a member, or demoting a parent, raises if it would leave the
  family with no parent linked to an account.
- These checks skip when there's no `auth.uid()` (service role or
  migrations) and for platform admins.

**Auth hook** (optional layer; the RPC checks are the real enforcement)

- `public.hook_before_user_created(event jsonb) returns jsonb`
  - If `invite_only` is off, allow.
  - If `event->'user'->'app_metadata'->>'kind' = 'device'`, allow (the
    display's own account, created by `pair-device`).
  - Otherwise read `event->'user'->'user_metadata'->>'invite_code'`, or
    allow if `email` matches an open invite. Allow if that matches an open
    platform or family invite.
  - Allow returns `{}`. Reject returns
    `{"error": {"http_code": 403, "message": "homeOS is invite-only. Ask your family for an invite code."}}`.
  - Grant execute to `supabase_auth_admin` only, inside a guarded `do` block.
- `docs/PLATFORM.md` explains enabling it under Dashboard → Authentication →
  Hooks → Before User Created, and says to check the payload shape against
  the current Supabase docs.

### 1.5 Assistant threads, messages, usage

```
public.assistant_threads (
  id          uuid primary key default gen_random_uuid(),
  family_id   uuid not null references families on delete cascade,
  owner_id    uuid not null references auth.users on delete cascade default auth.uid(),   -- person or display device
  title       text not null default 'New chat',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  archived    boolean not null default false
)
public.assistant_messages (
  id          bigint generated always as identity primary key,
  thread_id   uuid not null references assistant_threads on delete cascade,
  family_id   uuid not null references families on delete cascade,
  role        text not null check (role in ('user','assistant')),
  content     text not null check (length(content) <= 100000),   -- clients can insert rows the assistant replays
  actions     jsonb not null default '[]',
  mode        text not null default 'chat' check (mode in ('chat','quick')),
  created_by  uuid references auth.users on delete set null default auth.uid(),
  created_at  timestamptz not null default now()
)
public.assistant_usage (            -- written by the assistant function with the service role
  id             bigint generated always as identity primary key,
  family_id      uuid references families on delete cascade,
  user_id        uuid references auth.users on delete set null,
  thread_id      uuid references assistant_threads on delete set null,
  mode           text not null default 'chat',
  model          text not null,
  input_tokens   int not null default 0,
  output_tokens  int not null default 0,
  cache_read_tokens int not null default 0,
  tool_calls     int not null default 0,
  created_at     timestamptz not null default now()
)
```

**RLS**

- Threads: select, insert, update and delete where
  `owner_id = auth.uid() and is_family_member(family_id)`.
- Messages: select and insert where the thread is visible under the same
  rule. Messages can't be updated or deleted; they go when their thread is
  deleted.
- Usage: admins select only; no client writes.

Indexes: `(owner_id, updated_at desc)` on threads, `(thread_id, id)` on
messages, `(family_id, created_at)` on usage.

### 1.6 Admin

`public.admin_audit_log (id bigint identity pk, admin_id uuid, action text not null, target_type text, target_id text, details jsonb default '{}', created_at timestamptz default now())`
is readable by admins only.

Every function below is security definer. Each starts with
`if not is_platform_admin() then raise exception 'admin only'; end if;`, and
every mutation writes an audit row.

| Function | Returns |
|---|---|
| `admin_overview()` | `jsonb {families, families_active_7d, suspended_families, users, devices, devices_seen_24h, members, open_platform_invites, assistant_requests_7d, assistant_tokens_7d, assistant_enabled, media_items, storage_bytes, families_over_quota}` |
| `admin_list_families(search text default null, lim int default 50, off int default 0)` | `table(id uuid, name text, status text, created_at timestamptz, member_count int, parent_count int, device_count int, assistant_requests_30d int, last_activity timestamptz, media_count int, storage_bytes bigint, storage_limit_bytes bigint)`. `storage_limit_bytes` is the effective quota (the family's override, or the platform default). |
| `admin_family_detail(family uuid)` | `jsonb {family, members[], devices[], invites[], usage_by_day[]}`. `family` adds `storage_bytes`, `storage_limit_effective`, `media_count`, `media_item_limit_effective`. `storage_limit_bytes` and `media_item_limit` on that object are the raw overrides (`null` means the platform default). |
| `admin_list_users(search text default null, lim int default 50, off int default 0)` | `table(id uuid, email text, display_name text, created_at timestamptz, last_sign_in_at timestamptz, banned boolean, is_admin boolean, is_device boolean, families jsonb)`. `families` is `[{id,name,role}]`; the search matches email and display name. |
| `admin_set_family_status(family uuid, status text, reason text default null)` | `void` |
| `admin_delete_family(family uuid)` | `void` |
| `admin_create_platform_invite(email text default null, note text default null, max_uses int default 1, expires_in_days int default 30)` | `table(id uuid, code text, expires_at timestamptz)`; `code` is in display form |
| `admin_revoke_platform_invite(invite uuid)` | `void` |
| `admin_list_platform_invites(include_inactive boolean default false)` | `table(id, code, email, note, max_uses, use_count, expires_at, created_at, revoked_at, created_by_email text, status text)`. `status` is one of `active\|used\|expired\|revoked`. |
| `admin_update_settings(invite_only boolean default null, assistant_enabled boolean default null, assistant_daily_limit int default null, storage_limit_bytes bigint default null, media_max_bytes bigint default null, media_item_limit int default null)` | `jsonb` (the new settings); null arguments leave that value unchanged. When `storage.buckets` exists, also sets the `family-media` bucket's `file_size_limit` and `allowed_mime_types`. |
| `admin_list_media(family uuid, only_kind text default null, lim int default 60, off int default 0)` | `table(id, kind, storage_path, thumbnail_path, content_type, byte_size, width, height, duration_seconds, caption, taken_at, created_at, show_on_frame, uploaded_by_name)`. `only_kind` is `photo`, `video`, or null. `lim` is clamped to 1..100. Raises `family not found` or `kind must be photo or video`. |
| `admin_delete_media(item uuid)` | `jsonb {id, family_id, storage_path, thumbnail_path, byte_size, kind}`; deletes the row and audits `delete_media`. Raises `media not found`. Does not delete the Storage objects (the `admin` function does). |
| `admin_revoke_device(device uuid)` | `jsonb {id, family_id, name, user_id, auth_user_removed}`; deletes the `devices` row, tries to delete `auth.users` (swallows `insufficient_privilege`), audits `revoke_device`. Raises `device not found`. |
| `admin_set_family_limits(family uuid, assistant_daily_limit int default null, storage_limit_bytes bigint default null, media_item_limit int default null, use_platform_assistant_limit boolean default false, use_platform_storage_limit boolean default false, use_platform_media_item_limit boolean default false)` | `jsonb` of the raw overrides and the `*_effective` values. A null number leaves that limit alone. A `use_platform_*` flag clears the override (`null` = platform default). A no-op writes no audit row. Raises `family not found`, or `assistant_daily_limit must be between 0 and 1000000`, `storage_limit_bytes must be between 0 and 1099511627776`, `media_item_limit must be between 0 and 1000000`. |
| `admin_get_settings()` | `jsonb` |
| `admin_set_admin(target uuid, make_admin boolean)` | `void`; raises `can't remove the last admin` |
| `admin_usage_by_day(days int default 30)` | `table(day date, requests int, input_tokens bigint, output_tokens bigint, families int)` |
| `admin_list_audit(lim int default 100, off int default 0)` | `table(id, created_at, admin_email, action, target_type, target_id, details)` |

`last_activity` and `families_active_7d` come from `family_last_activity()`:
the latest of the family's own timestamps (devices' `last_seen_at`, edits,
chores, media, points, memories, assistant use). Families write most of these
themselves, so values later than `now() + 10 minutes` are ignored.

`admin_delete_family` deletes rows only. The console deletes a family through
the `admin` function (§2.2), which also removes its Storage files.

### 1.7 Storage: avatars

- Private bucket `avatars`, with objects at `<user_id>/<file>`; at most 5 MB,
  `image/jpeg`, `image/png`, `image/webp` or `image/heic`.
- **Upload, update, delete:** the owner only (the first folder equals `auth.uid()::text`).
- **Read:** the owner, or anyone who shares a family with that user.

### 1.8 Direct-write guards

Family members, kids and the kitchen display included, write shared tables
straight through PostgREST (`tasks_all`, `events_all`, `members_update_self`).
These checks skip, like `members_guard`, when there's no `auth.uid()` and for
platform admins.

- **`tasks_guard`** (before insert or update on `tasks`): only a parent of the
  family may add a chore with `points > 0` and `requires_approval = false`
  (`only a parent can add points that skip approval`), or change a chore's
  `points`, `requires_approval` or `family_id` (`only a parent can change a
  chore's points or approval`). Anyone may still add chores that need approval
  (the assistant's `add_chore`), chores without points, and edit or archive
  them.
- **Colors:** `members.color` and `events.color` must match `^#[0-9A-Fa-f]{6}$`
  (constraints `members_color_hex`, `events_color_hex`). The display, the iOS
  app and the admin console all render them; `#RRGGBB` is the one form all
  three read the same way.
- **Devices:** a display may update its own `devices` row (`devices_touch`);
  it sets `last_seen_at` and may rename itself (§5). `devices_guard` freezes
  `id`, `family_id` and `user_id` (`a display can't move to another family`).
  A signed-in caller who isn't an admin also can't change `created_at`. A
  suspended family can't gain a device (`this family is suspended`), including
  an insert made with the service role.

### 1.9 Media quotas and tenancy

`media_items` gains `byte_size bigint` (null on rows from an older app),
`content_type text` and `thumbnail_path text`. A row's `storage_path` and
`thumbnail_path` must be `<family_id>/<file>` in the lowercase uuid form, one
segment, at most 200 characters, no `..` and no leading dot
(`media_items_path_in_family`, `media_items_thumb_in_family`). The thumbnail,
when set, is a different object.

Allowed types (`allowed_media_types()`): `image/jpeg`, `image/png`,
`image/webp`, `image/heic`, `image/heif`, `image/gif`, `video/mp4`,
`video/quicktime`, `video/webm`, `video/m4v`, `video/x-m4v`,
`video/x-matroska`, `video/mkv`, `video/3gpp`, `video/3gp`, `video/3gpp2`,
`video/3g2`. A null `content_type` is allowed, so old rows still load.
Anything else raises `file type not allowed`.

Quotas:

| Setting | Where | Default |
|---|---|---|
| Storage per family | `platform_settings.storage_limit_bytes`, overridable by `families.storage_limit_bytes` | 5 GiB (`5368709120`) |
| Items per family | `platform_settings.media_item_limit`, overridable by `families.media_item_limit` | 5000 |
| One file | `platform_settings.media_max_bytes` (platform only) | 2 GiB (`2147483648`) |

A null override means the platform default. `0` is a real limit. Caps:
storage `0 .. 1099511627776` (1 TiB), `media_max_bytes` `1 .. 5368709120`,
item limit `0 .. 1000000`. Parents can't change the new family columns
(`only a platform admin can change that`).

`media_items_guard` lets a signed-in client change only `caption` and
`show_on_frame` (`only a caption or the frame can be changed`). `uploaded_by`
must be a member of that family (`that person isn't in this family`). On
insert, a client is refused with `file is too large`, `media item limit
reached` or `storage limit reached`. A null `byte_size` still counts as an
item and doesn't add bytes on the row side. Migrations and the service role
skip the quota. Usage is `greatest(sum(media_items.byte_size), sum of
family-media object sizes)` when `storage.objects` exists, so an old file
without `byte_size` is still billed once Storage is present.

`20261008000002` puts the same checks on `storage.objects` for the
`family-media` bucket: `file size required`, `file type not allowed`, `file
is too large`, `media item limit reached` (object count vs `item limit × 2`,
a file and its thumbnail), `storage limit reached`. The read, upload and
delete policies require a single folder whose name is one of
`my_family_ids()`. There is no admin read policy: an admin's phone must not
be able to open another family's photos. The console signs URLs in the
`admin` function instead.

The same "that person isn't in this family" check covers `events.created_by`,
`event_members.member_id`, `tasks.assignee_id`, `tasks.created_by` and
`list_items.added_by` when that column is set or changed. Moving an
account-less member no longer makes their old rows uneditable.

### 1.10 Photos and videos in Vercel Blob

New photos and new videos go to a private Vercel Blob store so a family
library doesn't fill Supabase Storage. Profile avatars stay in the `avatars`
bucket (§1.7). `media_items.file_store` is `supabase` or `blob` (default
`supabase`). A `blob` photo's `storage_path` ends in `jpg`, `jpeg`, `png`,
`webp`, `heic`, or `gif`; a `blob` video's ends in `mp4`, `mov`, `m4v`,
`webm`, `mkv`, `3gp`, or `3g2` (`media_items_blob_matches_kind`).
`storage_path` stays `<family_id>/<id>.<ext>` in either store. Rows already
in Storage stay `supabase` and keep playing from that bucket.

The admin app (the Vercel project that owns the store) signs upload and
playback URLs. Clients send their Supabase JWT. See §3, Media API. Photos
are capped at 50 MB; videos at 2 GiB.

`admin_delete_family` still deletes rows only. The `admin` function still
empties `family-media/<family_id>/` (files uploaded before Blob). The console
then deletes Blob objects under that same prefix (§3).

---

## 2. Edge functions

All functions answer CORS preflight (`OPTIONS`) with
`Access-Control-Allow-Origin: *`, `Access-Control-Allow-Headers:
authorization, apikey, content-type, x-client-info`, and
`Access-Control-Allow-Methods: POST, OPTIONS`. The admin console calls them
from a browser.

Every function answers with JSON and the CORS headers, errors included
(`{ "error": string }`): 405 for anything but `POST`, 413
`request body too large` above 64 KiB (256 KiB for `assistant`, whose legacy
body carries a conversation), 400 `invalid JSON`, and a JSON 500 for anything
unexpected. `assistant` and `admin` answer 401 when Supabase Auth rejects the
token and 503 (`couldn't check your sign-in; try again in a moment`) when
Auth can't be reached, so clients don't treat an outage as being signed out.

### 2.1 `assistant` (v2)

`POST` with the caller's JWT. Body:

```
{
  "message": "What's for dinner?",      // new user message (preferred), at most 4000 characters
  "thread_id": "uuid" | null,           // continue a thread; omit to start one
  "family_id": "uuid" | null,           // optional: the family a NEW thread is for (people in two families);
                                        // ignored when thread_id is given; default: the caller's first active family
  "mode": "chat" | "quick",             // quick = short spoken answer (wake word, Siri)
  "stream": true | false,
  "messages": [{ "role", "text" }]      // LEGACY: if present and "message" absent, behave like v1 (no persistence)
}
```

Uuids are matched case-insensitively. Legacy turns are clipped to 4000
characters each (the last 20 are kept).

**Behavior, in order**

1. Authenticate the caller (anon key client with the caller's
   `Authorization` header) and load the family snapshot, as v1 does.
2. With the service-role client:
   - read `platform_settings` and the family
   - refuse when `assistant_enabled` is off (`"The assistant is turned off right now."`)
   - refuse when the family is suspended (403)
   - refuse when today's usage rows for the family (UTC day) reach
     `coalesce(families.assistant_daily_limit, platform_settings.assistant_daily_limit)`
     (`"We've hit today's assistant limit. Try again tomorrow."`, still a 200 reply)
   - The request takes its usage row before calling Claude and counts the
     family's rows for today up to its own, so concurrent requests can't all
     slip under the limit; a refused request gives its row back. A gate reply
     in v2 is stored in the thread like any other reply.
3. **Who's asking:** a person gets their `profiles.display_name` and member
   role, added to the system prompt as "You're talking with {name} ({role})".
   A device account (`app_metadata.kind = 'device'`) gets "the family screen
   in the kitchen; could be anyone in the family".
4. **Thread:** create one if `thread_id` is absent, titled from the first ~48
   characters of the message. Otherwise verify the caller owns it (404
   `thread not found` if not, or if it's gone). History is the last 20
   messages for chat and the last 6 for quick, each clipped to 4000
   characters (owners can insert rows directly). Insert the user message
   before calling Claude.
   The family snapshot is bounded (row limits per table, open list items
   only, each value on one line and clipped) and framed in the system prompt
   as data typed by family members, not instructions.
5. **Claude:** `claude-opus-5-5`, `output_config.effort` `low`, adaptive
   thinking omitted (it's the default), and
   `fallbacks: "default"` with beta `server-side-fallback-2026-07-01`.
   Authentication is Anthropic workload identity federation (PLATFORM.md),
   not a long-lived API key. Until `ANTHROPIC_FEDERATION_RULE_ID`,
   `ANTHROPIC_ORGANIZATION_ID` and `ANTHROPIC_SERVICE_ACCOUNT_ID` are all
   set, the function still accepts `ANTHROPIC_API_KEY`. Keep
   v1's tools, add tool `forget` (`{ fact_contains: string }`; deletes
   matching family memories; parents only, otherwise it returns a polite
   refusal), and validate tool inputs before running them. Quick mode appends
   to the system prompt: *"Answer in one or two short sentences meant to be
   spoken aloud. No lists, no markdown, no emoji. Say times and numbers
   naturally."* Its `max_tokens` is 2000; chat uses 16000.
6. Insert the assistant message (`content`, `actions`, `mode`), bump the
   thread's `updated_at`, and fill in the request's usage row (summed tokens
   and tool calls) with the service role. A request that never reached the
   model leaves no usage row. A reply longer than the column allows (100,000
   characters) is stored clipped.

**Response when `stream` is false:**
`{ "reply": string, "actions": [{type, summary}], "thread_id": uuid, "message_id": number }`.
The legacy path returns `{ reply, actions }`.

**Response when `stream` is true:** `Content-Type: text/event-stream`. Each
event is `event: <name>\ndata: <json>\n\n`, in this order:

- `thread`: `{ "thread_id": uuid }` (first)
- `delta`: `{ "text": string }` (zero or more, as text streams)
- `action`: `{ "type": string, "summary": string }` (whenever a tool succeeds)
- `done`: `{ "reply": string, "actions": [...], "thread_id": uuid, "message_id": number }` (last)
- `error`: `{ "message": string }` (terminal, instead of `done`)

**Errors:** 401 without auth (or a token Auth rejects), 400 for a bad body,
403 when the family is suspended or the caller has no family (or isn't in
`family_id`), 404 when `thread_id` isn't the caller's thread (clients then
start a new thread), 413 for a body over 256 KiB, 503 when Supabase Auth
can't be reached, 502 for model API failures (non-stream only; streams end
with an `error` event).

### 2.2 `admin`

`POST` with the caller's JWT. The function verifies the caller with
`rpc('is_platform_admin')` using the caller's client, then uses the service
role for Supabase Auth's admin API and Storage. Body: `{ "action": ..., ... }`.

| `action` | Params | Effect |
|---|---|---|
| `invite_email` | `email`, `note?`, `redirect_to?` | Creates a platform invite (`admin_create_platform_invite` with the admin's own JWT, so `created_by` and the RPC's audit row name the admin) and calls `auth.admin.inviteUserByEmail(email, { data: { invite_code }, redirectTo })`. Returns `{ ok, code, invite_id, expires_at }`; if the email fails, `{ error, code, invite_id }` with Auth's status. |
| `ban_user` | `user_id` | Refuses to ban yourself. `auth.admin.updateUserById(id, { ban_duration: '876000h' })` |
| `unban_user` | `user_id` | `ban_duration: 'none'` |
| `delete_user` | `user_id` | Refuses to delete yourself. `auth.admin.deleteUser`, then removes the user's `avatars/<user_id>/` files |
| `delete_family` | `family_id` | `admin_delete_family` with the admin's own JWT (404 `family not found`), then removes every file under `family-media/<family_id>/`, which SQL can't. Returns `{ ok, files_removed, files_error? }`; a cleanup failure doesn't undo the deletion. Photos and videos in Blob are removed by the admin app after this returns (§3). |
| `sign_media` | `family_id`, `media_ids` (1 to 60 uuids) | Reads those rows with the service role, only where `family_id` matches, and signs `thumbnail_path` when it is `<family_id>/<file>`, otherwise the photo's `storage_path`. Videos with no poster are omitted. URLs last 10 minutes. Returns `{ urls: [{ id, url }] }`. Not audited. Blob rows are signed by `/api/media/urls` instead. |
| `delete_media` | `media_id` | `admin_delete_media` with the admin's own JWT (404 `media not found`), then removes `storage_path` and `thumbnail_path` when each is `<family_id>/<file>`. A missing object is not an error. Returns `{ ok, files_removed, files_error? }`. |
| `revoke_device` | `device_id` | `admin_revoke_device` with the admin's own JWT (404 `device not found`). If SQL couldn't delete the auth user, calls `auth.admin.deleteUser`. Returns `{ ok, auth_user_removed }`, or `{ error, auth_user_removed: false }` with 502 when Auth refuses. |

Every action except `sign_media` writes `admin_audit_log` with the service
role (`delete_family` writes `delete_family_files`, `delete_media` writes
`delete_media_files`, `revoke_device` writes `revoke_device_auth`; the RPCs
write their own rows). Responses are `{ ok: true, ... }`, or `{ error }` with
status 4xx or 5xx (404 for an unknown user, family, media item or device).

### 2.3 `pair-device` (existing)

`claim` looks up the family after the parent check and before it creates a
device user. A missing family is 404 `family not found`. Anything other than
`status = 'active'` is 403 `this family's account is suspended`. The
`devices_guard` trigger refuses the insert anyway, so skipping this check
still can't pair a suspended family. Device users must not get profiles
(see 1.1). The body must be a JSON object, at most 64 KiB.

---

## 3. Admin console (`admin/`)

Next.js (App Router, TypeScript, current stable release) with
`@supabase/ssr` and `@supabase/supabase-js`. Styling uses CSS modules plus a
`globals.css` with the Ohana tokens: canvas `#F1EFEB`, white cards with
radius 20–28, accent `#4F7CF7`, glow gradient `#5B7CF5 → #F07F5A → #F6B94A`,
and Inter, with a dark-mode variant. There's no UI kit dependency.

**Auth:** email and password sign-in through Supabase. Middleware refreshes
the session. Every page except `/login` requires a session and
`is_platform_admin()`. Signed-out visitors are redirected to
`/login?next=<path>` (same-site paths only), signed-in non-admins to
`/login?error=not_admin`. Session cookies are httpOnly.

**Pages**

- `/` Overview: stat tiles from `admin_overview()`, a 30-day requests and
  tokens chart from `admin_usage_by_day` (hand-rolled SVG, no chart library),
  recent audit entries.
- `/families`: searchable table. `/families/[id]` shows the detail, with
  Suspend/Unsuspend (asks for a reason), Delete (typed confirmation; via the
  `admin` function's `delete_family`, so Storage files go too), and the
  members, devices, invites and usage lists.
- `/users`: searchable table with admin, banned and device badges. Actions:
  Make or remove admin, Ban/Unban, Delete (via the `admin` function).
- `/invites`: create a platform invite (email optional, note, max uses,
  expiry), optionally emailing it (`admin` → `invite_email`). The list shows
  status and has copy-code and revoke actions.
- `/settings`: invite-only toggle, assistant enabled, daily limit. Saving
  sends only the values this form changed (null leaves the others), so a
  stale form can't undo another admin's change.
- `/audit`: paginated audit log.

**Media API** (family JWT, not the admin session)

`POST /api/media/upload`, `/api/media/urls`, and `/api/media/delete`.
`admin/proxy.ts` lets `/api/media` through before the platform-admin gate.
The route checks `Authorization: Bearer <supabase access token>` with
`auth.getUser`, then `is_family_member(fid)`.

| Route | Body | Effect |
|---|---|---|
| `/api/media/upload` | `{ family_id, content_type, bytes }` | Member only. `bytes` is an integer from 1 to 50 MB for a photo and 1 to 2 GiB for a video. Photo types: `image/jpeg`, `image/jpg`, `image/png`, `image/webp`, `image/heic`, `image/gif`. Video types: `video/mp4`, `video/quicktime`, `video/m4v`, `video/x-m4v`, `video/webm`, `video/x-matroska`, `video/mkv`, `video/3gpp`, `video/3gp`, `video/3gpp2`, `video/3g2`. Returns `{ id, pathname, upload_url, content_type }`. The client `PUT`s the bytes to `upload_url` (private store, that pathname only, no overwrite), then inserts `media_items` with `file_store = 'blob'`, `kind` `photo` or `video`, and the returned `id` and `pathname`. |
| `/api/media/urls` | `{ paths: string[] }` | At most 200 paths, same order back in `{ urls: string[] }`. A path that isn't `<family_uuid>/<media_uuid>.<photo or video ext>`, or whose folder isn't a family the caller belongs to, comes back as `""`. Playback URLs last 6 hours. The wildcard read token stays on the server. |
| `/api/media/delete` | `{ pathname }` | Member of that folder only, then deletes the blob. `{ ok: true }`. |

Errors are `{ "error": string }`: 400 bad JSON or body, 401 missing or
rejected token, 403 not in the family, 413 body over 64 KiB, 502 Blob
failed, 503 Supabase or Blob isn't configured.
Deployment Protection in front of the whole app blocks phones and displays;
leave `/api/media` reachable by a family JWT.

Blob credentials: on Vercel, connect a private store so the function has
`BLOB_STORE_ID` and `VERCEL_OIDC_TOKEN`. `BLOB_READ_WRITE_TOKEN` is the
long-lived token for local dev. The admin app still has no Supabase service
role key.

Deleting a family calls `delete_family` and then lists and deletes Blob
objects under `<family_id>/`. If Blob credentials are missing, the delete
still succeeds. If Blob cleanup fails after the rows are gone, the console
says the photos and videos may still be in the store.

**Env:** `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY`.
`next build` must succeed without real values (render dynamically and read
env at request time). The service role key is never used in this app.

**Docs:** `docs/ADMIN.md` covers local dev, deploying to Vercel, and
bootstrapping the first admin.

---

## 4. Voice service (`voice/`), runs on the Pi next to the display

A Python 3.11+ package, `homeos_voice`. Everything stays on the device; only
transcribed text leaves it, sent by the display to the assistant.

**Pipeline**

- **Mic:** `sounddevice`, 16 kHz mono int16, in 80 ms frames (1280 samples).
- **Wake word:** `openwakeword` with a configurable model (name or `.onnx`/
  `.tflite` path, threshold 0.5, 2 s refractory). The default is the
  built-in `hey_jarvis` until a custom "Hey Ohana" model is trained;
  `docs/VOICE.md` explains training one. The wake word can be disabled, in
  which case only push-to-talk works.
- **End of speech:** `webrtcvad` (aggressiveness 2), with an energy-based
  fallback. The utterance ends after 700 ms of silence, 8 s at most, or 4 s
  of no speech at all after the wake word.
- **Speech to text:** `faster-whisper`, default model `base.en` with int8
  compute, loaded once. `language="en"` is configurable.
- **Text to speech:** `piper` (the `piper-tts` package, voice
  `en_US-amy-medium`, configurable), falling back to the `espeak-ng` CLI.
  Playback through `sounddevice` or `aplay`. With the display user's PipeWire
  session up, replies use its default sink, so the gear menu's screen-speaker
  switch and volume apply, and a muted sink is not opened. Otherwise playback
  falls back to the panel's HDMI card.
- Heavy dependencies are optional extras (`.[audio]`, `.[stt]`, `.[tts]`,
  `.[wake]`). The core package and the tests need only `websockets` and the
  standard library.

**Server:** an asyncio WebSocket server on `ws://127.0.0.1:8765` (host and
port configurable). JSON text frames:

- **Server → client:**
  - `{"type":"hello","version":"1","wakeword":bool,"wakeword_name":str,"tts":bool,"stt":bool}` on connect
    (followed by the current `state`), and again to every client whenever the
    wake-word setting or the capabilities change (after `set`, a mic plugged
    in or removed). Clients must accept `hello` at any time.
  - `{"type":"state","state":"idle|listening|transcribing|speaking"}`
  - `{"type":"wake","source":"wakeword|button"}`
  - `{"type":"level","rms":0.0-1.0}` (throttled to 15/s, only while listening)
  - `{"type":"transcript","text":str,"final":true}` (empty text means nothing was heard)
  - `{"type":"spoken","id":str}` (TTS finished or stopped)
  - `{"type":"error","message":str}`
- **Client → server:**
  - `{"type":"listen"}` (push-to-talk; same as a wake without the wake word)
  - `{"type":"cancel"}`
  - `{"type":"speak","text":str,"id":str}`
  - `{"type":"stop_speaking"}`
  - `{"type":"set","wakeword_enabled":bool}`
- The wake word is ignored while the service is speaking, so it doesn't hear
  itself, and while a session is already active. Multiple clients are
  allowed, and all of them receive broadcasts.
- **Limits:** frames are at most 64 KiB (larger ones close the connection
  with 1009). `speak.id` is at most 200 characters; `speak.text` past 2,000
  characters is cut at a word break; with 16 replies waiting, a further
  `speak` gets an `error` plus an immediate `spoken`. Every `speak` gets
  exactly one `spoken` with its id. Bad frames get an `error` sent to that
  client only.
- **Origin:** a handshake that carries an `Origin` header is refused with 403
  unless the origin is listed in config `server.allowed_origins` (default
  empty). Browsers always send one, so a web page on the device can't reach
  the mic; the display's `QWebSocket` sends none and must keep it that way.

**Other pieces**

- **Config:** TOML at `/etc/homeos/voice.toml`, with every key optional;
  `voice/voice.example.toml` documents them. CLI:
  `python -m homeos_voice [--config PATH] [--simulate] [--host] [--port] [--log-level]`.
- **Simulate mode:** for development and tests, with no audio hardware or
  models. Commands come from stdin, one per line:
  - `wake <words...>`: emits wake, listening, a few fake levels,
    transcribing, then the transcript
  - `button` / `silence`: same, with an empty transcript
  - `quit`
  Speak requests are logged and answered with `spoken` after
  `0.05 s × words`.
- **Tests:** `voice/tests` (pytest) cover the protocol in simulate mode
  (connect, hello, listen, transcript, speak, spoken, set, cancel), the VAD
  endpointing on synthetic frames, and config parsing.
- **Deploy:**
  - `voice/deploy/homeos-voice.service` (systemd; runs as the same user as
    the display; `After=sound.target`)
  - `voice/deploy/install-voice.sh`: apt `portaudio19-dev libportaudio2
    espeak-ng alsa-utils`, a venv at `/opt/homeos-voice`, pip install with
    extras, model pre-download, a default `/etc/homeos/voice.toml`, and
    enabling the service
- **Docs:** `docs/VOICE.md` covers hardware (a USB mic is needed; the JUNEBOX
  screen has speakers but no mic), privacy, tuning, and wake-word training.

---

## 5. Display (`display/`)

**Streaming assistant**

- `SupabaseClient::streamFunction(name, body, onEvent(QString event, QJsonObject data), onFinished(QString error))`
  parses SSE from `QNetworkReply::readyRead`.
- `Assistant` sends `{message, thread_id, mode, stream: true}`.
- It keeps `threadId` in QSettings (`assistant/threadId`); "New chat" clears it.
  A 404 for a stored thread (deleted from the phone) clears it and resends
  without `thread_id`; a 401 refreshes the session once and resends.
- The last assistant bubble grows with each `delta`, action chips appear on
  `action`, and `done` finalizes. On HTTP or stream errors it shows a
  friendly message.
- Demo mode simulates streaming by chunking the demo answer every 30–60 ms.

**Quick answers**

- `AI.askQuick(text)` uses `mode: quick`, then calls `Voice.speak(reply)`
  when `done` arrives, if voice replies are enabled.

**`VoiceClient`** (C++, Qt WebSockets), registered as the QML singleton `Voice`

- Connects to `HOMEOS_VOICE_URL` (default `ws://127.0.0.1:8765`) and retries
  every 5 s.
- Properties: `available`, `state`, `level`, `wakewordEnabled`,
  `wakewordName`, `transcript`.
- Invokables: `listen()`, `cancel()`, `speak(text)`, `stopSpeaking()`,
  `setWakewordEnabled(bool)`.
- Signals: `woke(source)` and `heard(text)` (final, non-empty).

**Wake-word flow** (from any screen, including the screen saver)

1. On `woke`, wake the display (`Device.wake()`) and show `QuickAnswer.qml`:
   a floating card bottom-centre with a glowing orb that pulses with `level`,
   showing the state label ("Listening…", "Thinking…") and the live
   transcript.
2. On `heard`, call `AI.askQuick(text)` and stream the answer into the card,
   with action chips.
3. Speak the reply, then auto-dismiss 6 s after `spoken`.
4. "Open chat" opens the AssistantPanel on the same thread. Tapping outside
   dismisses the card and stops speech.
5. An empty transcript shows "Sorry, I didn't catch that" and dismisses.

**Push-to-talk:** the mic button in the AssistantPanel and on the Home card
calls `Voice.listen()`. The transcript is sent as a chat message, not quick
mode (a reply still streaming is stopped first). If `!Voice.available`, show
the toast "Voice needs the Ohana voice service (see docs/VOICE.md)"; if the
service has no speech-to-text (`hello.stt` false, e.g. no mic), show "Voice
needs a microphone (see docs/VOICE.md)".

**Check-in:** while live, the display sets `last_seen_at` on its own
`devices` row (the id saved at pairing) at most every 5 minutes; the iOS app
and the admin console show it.

**Media playback:** `HOMEOS_MEDIA_URL` (settings key `media/url`) is the admin
app origin. Rows with `file_store = 'blob'` (new photos and videos) are
signed with `POST /api/media/urls` and the device access token (6 hours,
same as Storage). Rows still in `family-media` stay on `signUrls`. If the
URL is unset, Blob files get an empty `url` and a warning; older Storage
files still play.

**Settings sheet:** a gear button in the nav rail, above the moon, opens
`SettingsSheet.qml` with:

- screen saver style (reuse the picker content)
- dark mode on/off (QSettings `display/darkMode`, default off): a warm near-black canvas, light text, and the same blue accent `#4F7CF7`
- wake word on/off (`Voice.setWakewordEnabled`, disabled when the service is unavailable)
- spoken replies on/off (QSettings `voice/speakReplies`, default on)
- screen speakers on/off and volume, when PipeWire (`wpctl`) is available.
  Off mutes the HDMI sink (remembered). The first time the app sees the sink
  at about full volume it eases it to 50%, because full scale on this panel
  is mostly hiss. Install also asks WirePlumber to start new outputs at 0.5
  and to suspend HDMI audio one second after playback stops
- Wi-Fi: current network, scan, join (saved, open, or a password), radio on/off.
  Joining and the radio go through `/usr/local/libexec/homeos-system` as root
  (`display/deploy/install-pi.sh` installs it and a NOPASSWD sudoers rule).
  The password is written to a root-only file for `nmcli`, not put on the
  command line. Without that helper, listing networks still uses `nmcli`
  directly when the signed-in user is allowed to change Wi-Fi
- about: mode, family name, app version, voice service status, wake word name,
  current Wi-Fi name, IPv4 address
- Restart (quit; systemd starts the app again) and Reboot (the helper;
  confirmation first). Reboot stays disabled when the helper isn't installed
- "Re-pair this display": confirmation, then clears the session

**Build and install**

- CMake adds `WebSockets`. Packages: `qt6-websockets-dev` for the build,
  `libqt6websockets6` at runtime.
- `display/deploy/install-pi.sh` adds those packages and a `--with-voice`
  flag (or `HOMEOS_VOICE=1`) that runs `voice/deploy/install-voice.sh`.

**Simulator check:** run `python -m homeos_voice --simulate`, then pipe
`wake what's for dinner` and confirm the quick card flow in demo mode.

---

## 6. iOS app (`ios/`)

**Onboarding** (invite-only)

- The welcome screen has an invite code field. A deep link
  `ohanaos://invite/<CODE>` prefills it; register the URL scheme in
  `project.yml`.
- "Check invite" calls `preview_invite` and shows "You're invited to
  {family} as {role}" or "This code lets you start a new family".
- Then Create account (email, password, name) or Sign in.
- Sign-up passes `data: ["invite_code": code, "display_name": name]`.
- After auth, a family invite calls `accept_family_invite(code,
  display_name)`; a platform invite goes to Create Family with `invite_code`.
- Signed-in users with no family and no pending code see "Enter an invite
  code".

**Profile:** edit display name and avatar (PhotosPicker, then upload to
`avatars/<uid>/avatar.jpg` and set `profiles.avatar_path`), view account
email, sign out.

**Media upload:** new photos and videos go to the private Blob store (§1.10).
Photos are JPEG (≤ 2560 px). Videos are uploaded as-is. The row sets
`byte_size`, `content_type` and `file_store = blob`. If the row insert fails,
the Blob object just uploaded is removed. Rows already in Storage keep
`thumbnail_path` when they have a poster. The display signs Blob paths
through the media API and Storage paths through Storage.

**Family management**

- Members list. Parents can edit name, color and role, and remove members;
  anyone can edit their own name and color.
- Invites, for parents: create (role, optional "for an existing member"
  picker listing members without accounts, optional email), share (share
  sheet text including the code and the `ohanaos://invite/CODE` link), revoke,
  and see pending and accepted invites.
- Leave family.

**Assistant**

- History is the thread list (`assistant_threads` via PostgREST, ordered by
  `updated_at`), with new chat and delete (swipe).
- A chat streams replies via SSE using `URLSession.bytes`, with the headers
  `Authorization: Bearer <access token>`, `apikey`, and
  `Accept: text/event-stream`, then parses the events in 2.1.
- The dictation mic stays.

**Media**

- Photos are re-encoded as JPEG, then uploaded through the same presigned
  URL as videos.
- Photos and videos upload only when `Config.mediaAPIURL` is the admin app's
  origin. The app asks `POST /api/media/upload` for a presigned URL, `PUT`s
  the bytes, and inserts `media_items` with `file_store = 'blob'`. A video
  `PUT` streams the movie file from disk (`URLSession.upload(for:fromFile:)`);
  a photo `PUT` sends the JPEG in memory. An unset URL fails the upload;
  family media is not written to Supabase Storage. Profile avatars still use
  the `avatars` bucket.
- Playback of a `blob` row calls `POST /api/media/urls`. A row still in
  Storage uses a Storage signed URL. Both are cached for an hour.
- Deleting a blob file calls `POST /api/media/delete` before deleting the row.

**Siri:** `AskOhanaOSIntent: AppIntent`

- `@Parameter question: String`.
- `perform()` calls the assistant with `mode: quick`, `stream: false`, and no
  thread, then returns `.result(dialog:)`.
- An `AppShortcutsProvider` adds phrases such as "Ask \(.applicationName)"
  and "Ask \(.applicationName) a question"; Siri then asks for the question.

**CI:** `.github/workflows/ios.yml` builds the checked-in `OhanaOS.xcodeproj`
for the simulator on `macos-15` with `CODE_SIGNING_ALLOWED=NO`.

**TestFlight:** the checked-in Xcode project is signed for team `92X9CP6C6D`,
version 1.0.0 (build 1), bundle id `com.ohanaos.ohana`. The archive reads the
Supabase URL, anon key and media API origin from `ios/Config/Local.xcconfig`.
`ios/scripts/archive-for-testflight.sh` exports an App Store Connect IPA.
Details are in [IOS.md](IOS.md).

---

## 7. CI (`.github/workflows/`)

- **`ios.yml`:** on push and PR, when `ios/**` or the workflow changes:
  `xcodebuild -project ios/OhanaOS.xcodeproj -scheme OhanaOS -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
  Pick the newest Xcode 16+ with `maxim-lobanov/setup-xcode` or `xcode-select`.
- **`ci.yml`:** jobs on `ubuntu-24.04`
  - `backend`: install PostgreSQL 16 from apt and run `backend/tests/run.sh`
    (it must work as a non-root user and pick a free port)
  - `functions`: `denoland/setup-deno`, `deno check` on each function's `index.ts`,
    then `deno test` in `backend/supabase/functions`
  - `display`: apt Qt 6 packages, build with cmake, `ctest`, then a smoke run with
    `QT_QPA_PLATFORM=offscreen ./homeos-display --demo` for 5 s; it must still be running
  - `admin`: Node 22, `npm ci`, `npm run lint`, `npm run typecheck`, `npm run build`, `npm test`
  - `voice`: Python 3.11, `pip install -e voice[dev]`, `pytest voice`
