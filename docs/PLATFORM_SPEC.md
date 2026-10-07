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
- `20261008000002_media_storage.sql`: the Storage quota trigger and the
  `family-media` policies (Supabase-only, like 000002 and 000005)
- `20261008000004_boot_video.sql`: `platform_boot_video` (service role
  only) and the private `boot-video` bucket, where anon and displays may read
  `current.mp4` and nothing else. Safe to run again (§2, §3)
- `20261009000001_wall_create_rewards.sql`: split `rewards` RLS so a paired
  display (or a parent) may insert; parents still update and delete (§1.8, §5)
- `20261009000002_video_blob.sql`: `media_items.file_store` (§1.10)
- `20261009000003_blob_photos.sql`: photos in Blob, extension must match kind (§1.10)
- `20261009000004_blob_limits.sql`: per-file cap of 2 GiB and the Blob video types (§1.9, §1.10)
- `20261010000001_account_deletion.sql`: `delete_my_account()`, deleting your
  own account from the iOS app (§1.11). Safe to run again
- `20261010000002_recurrence.sql`: `rrule_occurs_on`, `rrule_days`,
  `event_occurrences` and `chores_due` (§1.12). Safe to run again
- `20261011000001_member_photos.sql`: `members.avatar_url` becomes
  `avatar_path`, kept in the family's folder by `members_avatar_guard`;
  `can_read_avatar` also reads family folders; `can_write_member_photo` (§1.7)
- `20261011000002_storage_member_photos.sql`: the member photo policies on
  the `avatars` bucket (Supabase-only, like 000005)

`20261009000002` to `20261009000004` were `20261008000001` to `20261008000003`. Two of those
versions were shared with `media_platform` and `media_storage`, and Supabase
keys migrations by version, so they moved after the others in the same order.
They are safe to run again on a database where they were pasted into the SQL
editor. Every version is unique; keep it that way.

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
  `color` and `avatar_path`. Changing `role`, `family_id` or `user_id` raises.
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

- Private bucket `avatars`; at most 5 MB, `image/jpeg`, `image/png`,
  `image/webp` or `image/heic`. Two kinds of folder:
  - **Profile photos** at `<user_id>/<file>` (`profiles.avatar_path`).
    Upload, update, delete: the owner only (the first folder equals
    `auth.uid()::text`). Read: the owner, or anyone who shares a family with
    that user.
  - **Member photos** at `<family_id>/<file>` (`members.avatar_path`), for
    members without a login. Upload, update, delete: a parent of that family
    (`can_write_member_photo`: exactly one level down, family active). Read:
    anyone in the family, its displays included (`is_family_member`).
- `members_avatar_guard` (before insert or update) raises `that photo isn't
  in this family's folder` unless a new or changed `avatar_path` is
  `<family_id>/<file>` for the row's own family. Moving an account-less
  member doesn't re-check it.
- Clients show a member's profile photo when their account has one, else
  their member photo. The iOS app writes each member photo to a new file
  (`<member_id>-<random>.jpg`) and then deletes the old one, so a cached
  copy is never stale; it deletes the file when it removes the photo or the
  member. Deleting a family empties `avatars/<family_id>/` (§2.2, §2.4).

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
  them. The wall display always sets `requires_approval = true` when
  `points > 0`.
- **Rewards RLS** (`20261009000001_wall_create_rewards.sql`): `rewards_insert`
  allows a parent of the family, or a paired display (`devices.user_id =
  auth.uid()` for an active family). `rewards_update` and `rewards_delete`
  stay parent-only (archive / edit from iOS).
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

A `blob` row's poster is `<family_id>/<id>-thumb.jpg` (JPEG, at most
256 KiB), set in the insert because `media_items_guard` freezes
`thumbnail_path` afterwards. No migration pins that name;
`media_items_thumb_in_family` keeps it in the family's folder and apart from
the file. `byte_size` is the file's size only: posters are not billed and
can't push a file over the per-file cap.

`admin_delete_family` still deletes rows only. The `admin` function still
empties `family-media/<family_id>/` (files uploaded before Blob) and
`avatars/<family_id>/` (member photos). The console then deletes Blob
objects under that same prefix (§3).

### 1.11 Deleting your own account

App Store guideline 5.1.1(v): an app that creates accounts must let people
delete them. `delete_my_account()` (security definer, `authenticated` only)
works on the caller, in one transaction:

1. Refuses `not signed in`; a display's account (`a display can't delete its
   account; unpair it instead`); a platform admin (`platform admins can't
   delete their account here; ask another admin to remove your admin access
   first`).
2. For each family the caller is linked to, locks the family row. If nobody
   else there has an account, the family is marked to go. Otherwise a parent
   with no other linked parent is refused: `you're the only parent with a
   login in {family}. Make someone else there a parent first`.
3. Deletes the marked families (everything cascades, displays included) and
   unlinks the caller's member rows in the rest (`user_id = null`, as
   `leave_family` does: the row, points and history stay).
4. Audits `delete_own_account` (target the user id; details
   `families_deleted` and `device_accounts` counts, no email).
5. Tries `delete from auth.users` for the caller and the deleted families'
   display accounts. The profile, assistant threads and invite redemptions go
   by cascade; rows they created for a family keep a null author.

Returns `{ families_deleted: uuid[], device_users: uuid[], auth_user_removed }`.
`auth_user_removed` is false when SQL may not touch `auth.users`; the
`delete-account` function (§2.4) then deletes them through Auth. Calling it
again after that is harmless.

### 1.12 Repeats: events and chores

`events.rrule` and `tasks.rrule` are worked out in one place, the database.
The display, the iOS app and the assistant call these functions instead of
reading RRULEs themselves. The two demo modes, which call no server, are the
only exceptions: the display's, whose chores are all `FREQ=DAILY`, and the
iOS app's (Debug builds only), whose chores repeat daily or weekly on named
days.

| Function | Returns |
|---|---|
| `rrule_occurs_on(rule text, dtstart date, day date, dtstart_is_instance boolean default true)` | `boolean`: whether `day` is an occurrence of the series anchored at the local date `dtstart`. Immutable, reads no tables. |
| `rrule_days(rule text, dtstart date, from_day date, to_day date, dtstart_is_instance boolean default true)` | `setof date`: the occurrences in `[from_day, to_day]`, in order. Same rules as `rrule_occurs_on`, which is `exists (rrule_days(rule, dtstart, day, day, …))`. It parses the rule once per call, which is why `event_occurrences` uses it. |
| `event_occurrences(fid uuid, range_start timestamptz, range_end timestamptz)` | `table(id uuid, family_id uuid, title text, description text, location text, starts_at timestamptz, ends_at timestamptz, all_day boolean, rrule text, color text, created_by uuid, series_starts_at timestamptz, series_ends_at timestamptz, member_ids uuid[])`, ordered by `starts_at`, then `all_day` desc, then `id` |
| `chores_due(fid uuid, day date)` | `setof tasks`, ordered by `created_at` |

All four can be executed by `authenticated` only. `event_occurrences` and
`chores_due` are `stable` and security invoker, so RLS on `events`,
`event_members`, `tasks`, `task_completions` and `families` applies:
another family's id returns no rows.

**`dtstart_is_instance`:** with `true` (events: the stored start really is
the first instance, as in RFC 5545) `dtstart` always occurs, even when it
doesn't match BYDAY and the like, and it counts toward COUNT. With `false`
(chores: the anchor is only a creation or due date) just the days that
match the pattern occur and count. Everything else is the same: a day before
`dtstart` never occurs, and INTERVAL counts from dtstart's day, week, month
or year.

**Supported RRULE subset.** An optional leading `RRULE:`, then
`;`-separated `KEY=VALUE` parts, case-insensitive, whitespace ignored.

- No rule, a blank rule, or a missing or unknown `FREQ`: `dtstart` only.
- `FREQ`: `DAILY`, `WEEKLY`, `MONTHLY`, `YEARLY`. `HOURLY`, `MINUTELY` and
  `SECONDLY` count as every day (INTERVAL is ignored; the BY parts still
  filter).
- `INTERVAL` (default 1): DAILY, days since dtstart; WEEKLY, whole weeks
  between the WKST-aligned week starts of dtstart and the day; MONTHLY,
  months; YEARLY, years. The difference must be a multiple of INTERVAL.
- `WKST` (default `MO`): only matters for WEEKLY with an INTERVAL.
- `BYDAY`: `MO` to `SU`, optionally with a signed ordinal (`2TU`, `-1FR`,
  `+1MO`). DAILY and WEEKLY: a list of weekdays, ordinals ignored; WEEKLY
  without BYDAY uses dtstart's weekday. MONTHLY: a bare weekday is every
  such day of the month, `n` the nth, `-n` the nth from the end. YEARLY: the
  same, within the BYMONTH months (or dtstart's month).
- `BYMONTHDAY`: day numbers, negative from the end of the month (`-1` is the
  last day). MONTHLY and YEARLY with neither BYDAY nor BYMONTHDAY use
  dtstart's day of the month and skip months without it (a series on the
  31st skips 30-day months; Feb 29 happens only in leap years). With both
  BYDAY and BYMONTHDAY a day must match both (`BYDAY=FR;BYMONTHDAY=13`).
- `BYMONTH`: 1 to 12, a filter for any FREQ. YEARLY without BYMONTH stays in
  dtstart's month.
- `UNTIL`: `YYYYMMDD` or `YYYYMMDDTHHMMSS[Z]`. The date as written is the
  last day that can occur; the time and `Z` are ignored.
- `COUNT`: only the first COUNT occurrences, counted from dtstart. Counting
  stops at the COUNTth, at the day asked about, or 200 years after dtstart
  (later occurrences of a COUNT series don't happen).
- Not supported, and ignored: `BYSETPOS`, `BYYEARDAY`, `BYWEEKNO`, `BYHOUR`,
  `BYMINUTE`, `BYSECOND` and any other part. There are no EXDATE or RDATE
  columns.
- A bad value in a known part (`INTERVAL=abc`, `COUNT=0`, `UNTIL=20261340`,
  `BYDAY=MO,XX`, `BYMONTH=13`) never raises; that part counts as absent. An
  INTERVAL below 1 is 1.
- A dtstart outside the years 1 to 9999, or an infinite one, has no days.
  `rrule_days` raises `range can't be longer than 3660 days` when asked
  about more days than that at once.

Where this differs from RFC 5545: YEARLY with BYDAY or BYMONTHDAY but no
BYMONTH stays in dtstart's month (RFC: the whole year), and UNTIL compares
dates, so `UNTIL=20261020T000000Z` still includes Oct 20.

**`event_occurrences`**

- Raises `range_end must be after range_start` (also for a missing bound)
  and `range can't be longer than 400 days`.
- One row per occurrence that overlaps the window: `starts_at < range_end
  and (ends_at > range_start or starts_at >= range_start)`, so a zero-length
  event counts when it starts inside the window.
- `id` is the stored event; updates, deletes and `event_members` use it.
  `starts_at` and `ends_at` are this occurrence; `series_starts_at` and
  `series_ends_at` are the stored row (what an edit changes). `member_ids` is
  the event's `event_members` in the members' `sort_order`, `{}` when none.
- A non-repeating event (null or blank `rrule`) is its stored row.
- A repeating event is expanded in the family's time zone
  (`families.timezone`; a zone Postgres doesn't know falls back to UTC). The
  local date of the stored start is dtstart. Each local day `d` with
  `rrule_occurs_on(rrule, dtstart, d, true)` gives an occurrence that starts
  on `d` at the stored local start time and lasts the stored local
  (wall-clock) length. A 4:30pm practice stays at 4:30pm across DST, an
  all-day event that ends at 23:59:59 still ends at 23:59:59 on the day the
  clocks change, and the first occurrence is exactly the stored row. An
  occurrence that began before `range_start` and is still going is included
  (looking back at most 800 days).
- Local times the clocks skip or repeat follow RFC 5545: a repeat whose start
  falls in the skipped hour starts when the clocks jump and keeps its length
  (02:00–03:00 on the spring-forward day becomes 03:00–04:00), and a time
  that happens twice is the first of the two (01:15 on the fall-back day is
  01:15 daylight time).
- A repeating event with an infinite `starts_at` or `ends_at` is left out
  rather than failing the call.
- Past one-off events are filtered out before the per-row RLS check, so the
  cost follows the window and the repeating events, not the family's whole
  history.

**`chores_due`**

- The family's non-archived chores that are due on `day`, a family-local
  date. Raises `day is required`.
- One-time chore (null or blank `rrule`): due once `due_date` is null or
  `<= day`, until a completion with `for_date < day` that isn't `rejected`
  exists. A finished chore still shows on the day it was done, then
  disappears; a rejected try leaves it up.
- Repeating chore: `rrule_occurs_on(rrule, coalesce(due_date, local date of
  created_at), day, false)`. A weekends chore added on a Wednesday isn't due
  that Wednesday. One with an infinite due date is never due.

**Clients**

- Display (live mode): `event_occurrences` over its calendar window, and
  `chores_due(fid, today)` as today's chores.
- iOS: `event_occurrences` from 45 days back to 120 days ahead, paged past
  PostgREST's 1000-row cap. An occurrence is identified by `id` and
  `starts_at`; editing one occurrence of a repeating event moves the whole
  series by the same number of calendar days, to the edited local time,
  keeping its local length. `chores_due(fid, today)` decides what's due
  today.
- Assistant: `event_occurrences` from a day ago to 14 days ahead, and
  `chores_due` for the family's today.

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
unexpected. `assistant`, `admin` and `delete-account` answer 401 when Supabase Auth rejects the
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
| `delete_family` | `family_id` | `admin_delete_family` with the admin's own JWT (404 `family not found`), then removes every file under `family-media/<family_id>/` and the member photos under `avatars/<family_id>/`, which SQL can't. Returns `{ ok, files_removed, files_error? }` (both folders counted); a cleanup failure doesn't undo the deletion. Photos and videos in Blob are removed by the admin app after this returns (§3). |
| `sign_media` | `family_id`, `media_ids` (1 to 60 uuids) | Reads those rows with the service role, only where `family_id` matches, and signs `thumbnail_path` when it is `<family_id>/<file>`, otherwise the photo's `storage_path`. Videos with no poster are omitted. URLs last 10 minutes. Returns `{ urls: [{ id, url }] }`. Not audited. It signs from Storage only, so a Blob row's poster gets no URL here; phones and displays sign Blob rows with `/api/media/urls`. |
| `delete_media` | `media_id` | `admin_delete_media` with the admin's own JWT (404 `media not found`), then removes `storage_path` and `thumbnail_path` when each is `<family_id>/<file>`. A missing object is not an error. Returns `{ ok, files_removed, files_error? }`. It removes from Storage only: a Blob row's file and poster stay in the Blob store. |
| `revoke_device` | `device_id` | `admin_revoke_device` with the admin's own JWT (404 `device not found`). If SQL couldn't delete the auth user, calls `auth.admin.deleteUser`. Returns `{ ok, auth_user_removed }`, or `{ error, auth_user_removed: false }` with 502 when Auth refuses. |
| `get_boot_video` | — | Reads `platform_boot_video` with the service role and, when a row exists, signs `boot-video/current.mp4` for 10 minutes. Returns `{ video: null }` or `{ video: { byte_size, duration_ms, updated_at, preview_url } }`. Not audited. |
| `create_boot_video_upload` | — | Returns `{ path, signed_url, token }` for a new `boot-video/pending/<uuid>.mp4`. The browser PUTs the file there. The service role key stays in the function. |
| `commit_boot_video` | `path` | `path` must be that pending object. Downloads it, requires a silent MP4 of 0.5–12 seconds and at most 20 MB, copies it to `current.mp4`, and upserts `platform_boot_video`. Anything else is deleted and answered 400. Audits `set_boot_video`. |
| `remove_boot_video` | — | Deletes `current.mp4` and the row. Displays fall back to the built-in clip. Audits `remove_boot_video`. |

Every action except `sign_media` and `get_boot_video` writes `admin_audit_log` with the service
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

### 2.4 `delete-account`

`POST` with the person's JWT; the body is ignored. Called by the admin app's
`/api/account/delete` (§3), not by the phone directly. It authenticates the
caller (401, or 503 when Auth is down), then:

1. `rpc('delete_my_account')` with the caller's own client. A refusal
   (`P0001`) is a 400 with the function's message; anything else a 500.
2. With the service role: empties `avatars/<user_id>/`, and
   `family-media/<family_id>/` and `avatars/<family_id>/` for each deleted
   family. These go before step 3, because a retry finds no families left to
   name.
3. If `auth_user_removed` is false: `auth.admin.deleteUser` for each display
   account, then the caller (a 404 counts as removed).

Returns `{ ok: true, families_deleted, files_error? }`. If Auth refuses the
caller, 502 `your data is deleted, but your login couldn't be removed yet;
try again in a moment` with `families_deleted`. A file or display cleanup
failure is logged and doesn't fail the request. `verify_jwt = false`, like
the other functions.

---

## 3. Admin console (`admin/`)

Next.js (App Router, TypeScript, current stable release) with
`@supabase/ssr` and `@supabase/supabase-js`. Styling uses CSS modules plus a
`globals.css` with the Ohana tokens: canvas `#F1EFEB`, white cards with
radius 20–28, accent `#4F7CF7`, glow gradient `#5B7CF5 → #F07F5A → #F6B94A`,
and Inter, with a dark-mode variant. There's no UI kit dependency.

**Auth:** email and password sign-in through Supabase. Middleware refreshes
the session. Every page except `/login`, `/privacy` and `/support` requires a
session and `is_platform_admin()`. Signed-out visitors are redirected to
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
- `/settings`: invite-only toggle, assistant enabled, daily limit, and the
  platform boot video (preview, upload, remove). Saving settings sends only
  the values this form changed (null leaves the others), so a stale form
  can't undo another admin's change. The boot video is one silent MP4 for
  every display, stored in the private `boot-video` bucket.
- `/audit`: paginated audit log.
- `/privacy` and `/support` (public, `app/(public)`, `lib/site.ts`): the
  privacy policy and help page the iOS app links to and App Store Connect
  lists. Indexed, unlike the console.

**Media API** (family JWT, not the admin session)

`POST /api/media/upload`, `/api/media/urls`, and `/api/media/delete`.
`admin/proxy.ts` lets `/api/media` through before the platform-admin gate.
The route checks `Authorization: Bearer <supabase access token>` with
`auth.getUser`, then `is_family_member(fid)`.

| Route | Body | Effect |
|---|---|---|
| `/api/media/upload` | `{ family_id, content_type, bytes, thumbnail_bytes? }` | Member only. `bytes` is an integer from 1 to 50 MB for a photo and 1 to 2 GiB for a video. Photo types: `image/jpeg`, `image/jpg`, `image/png`, `image/webp`, `image/heic`, `image/gif`. Video types: `video/mp4`, `video/quicktime`, `video/m4v`, `video/x-m4v`, `video/webm`, `video/x-matroska`, `video/mkv`, `video/3gpp`, `video/3gp`, `video/3gpp2`, `video/3g2`. Returns `{ id, pathname, upload_url, content_type }`. With `thumbnail_bytes` an integer from 1 to 262144 (256 KiB), the reply also has `thumbnail: { pathname, upload_url, content_type }`: a presigned `PUT` for `<family_id>/<id>-thumb.jpg`, `image/jpeg`, at most that size, no overwrite. Any other `thumbnail_bytes` is ignored with a logged warning, and a poster that can't be signed is logged and left out; neither fails the upload. The client `PUT`s the poster and the bytes (private store, that pathname only, no overwrite), then inserts `media_items` with `file_store = 'blob'`, `kind` `photo` or `video`, the returned `id` and `pathname`, and `thumbnail_path` when the poster went up. |
| `/api/media/urls` | `{ paths: string[] }` | At most 200 paths, same order back in `{ urls: string[] }`. A path that isn't `<family_uuid>/<media_uuid>.<photo or video ext>` or a poster `<family_uuid>/<media_uuid>-thumb.jpg`, or whose folder isn't a family the caller belongs to, comes back as `""`. Names match without regard to case and are signed in lowercase. Playback URLs last 6 hours. The wildcard read token stays on the server. |
| `/api/media/delete` | `{ pathname }` | A file's path only: a poster's path on its own gets 400 (`That isn't a media path.`). Member of that folder only. Deletes the poster `<family_id>/<id>-thumb.jpg` first (a missing one is fine; any other error is logged and doesn't stop the file), then the file (a missing one is fine; any other error is 502). `{ ok: true }`. |

Errors are `{ "error": string }`: 400 bad JSON or body, 401 missing or
rejected token, 403 not in the family, 413 body over 64 KiB, 502 Blob
failed, 503 Supabase or Blob isn't configured.
Deployment Protection in front of the whole app blocks phones and displays;
leave `/api/media`, `/api/account/delete`, `/privacy` and `/support` reachable.

**Account API** (the person's JWT)

`POST /api/account/delete`, also let through before the admin gate. It sends
the bearer token (and the anon key as `apikey`) to the `delete-account`
function (§2.4), then deletes Blob objects under `<family_id>/` for each id in
`families_deleted`, also when the function answered 502. It passes the
function's status and `{ error }` through and answers
`{ ok: true, families_deleted, files_left? }`. A Blob failure doesn't fail the
request; it sets `files_left` and is logged. 401 without a token, 503 when
Supabase isn't configured or the function can't be reached.

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

**Sync:** while live, the display loads its tables every 60 s. A sync that
fails (no network yet after a reboot, Wi-Fi dropped, a table that errors) is
tried again after 2 s, then 4, 8, … up to 60 s; a sync where every request
succeeds ends the retries. When NetworkManager reports the network up (Qt's
`QNetworkInformation`), an offline display syncs at once. At boot,
`homeos-stop-bootscreen` keeps the boot video up until the backend's host
name resolves, for at most `HOMEOS_BOOT_NETWORK_WAIT` seconds (default 30,
at most 60, only while the video plays), so the app opens connected.

**Media playback:** `HOMEOS_MEDIA_URL` (settings key `media/url`) is the admin
app origin. Rows with `file_store = 'blob'` (new photos and videos) are
signed with `POST /api/media/urls` and the device access token (6 hours,
same as Storage), at most 200 paths per request. Rows still in
`family-media` stay on `signUrls`. When it is unset, not an http(s) URL
with a host, or the `YOUR-ADMIN` placeholder, the display uses
`https://ohanaos.co`, the iOS app's `Config.defaultMediaAPIURL`; the log
says which (`media service:`).

- Both `storage_path` and `thumbnail_path` are signed; each row gets `url`
  and `thumbUrl`. A signed URL is reused for 4 of its 6 hours, so a refresh
  doesn't make players and images load the file again; only new or due paths
  are signed. If signing again fails, the old URL stays until 5.5 hours,
  then it is dropped. A `""` from a good reply (a missing poster, an older
  admin app) is asked again after 15 minutes. A path already being signed
  isn't asked for twice. Re-pairing forgets the URLs and colors.
- Posters: grid tiles use the poster (`tileUrl`, decoded at 480 px); a
  video shows its poster until its first frame, in the viewer and the screen
  saver; the viewer's blurred backdrop and `ColorSampler` use it too. Colors
  are cached by `storage_path` (demo media, which has none, by its file
  URL). A failed sample is retried after 10 minutes, or at once when the row
  gets a different URL (signed again, or a poster at last).
- `photos` and `media` notify on `mediaChanged`, sent only when the
  decorated list changes, so reloading other tables doesn't rebuild the
  grid.
- A video playing in the viewer calls `Device.keepAwake()` (every 30 s, or
  half the idle time if that is shorter, and when it starts or stops), so
  the idle timer doesn't close it. It never wakes a sleeping screen.
- The video screen saver sets the player's source in code, never bound to
  `Store`: a new URL string would restart the clip. A single video loops
  while its URL is unchanged. A clip that fails, or whose position stops
  moving for 10 s, moves on after 2 s; while every clip fails it tries
  again every 30 s.
- Under eglfs the app sets `QT_FFMPEG_DECODING_HW_DEVICE_TYPES=drm` unless
  `display.env` sets it (`,` is CPU only), and logs
  `homeOS display: video decoding: ...` and `homeOS display: drawing on ...`
  at start. See `docs/PI_SETUP.md`, Video decoding.
- Photos render upright: every photo `Image` sets `autoTransform: true`, so
  a JPEG with pixels stored sideways and an EXIF orientation shows as the
  phone shows it. The iOS app also redraws such photos upright before upload.
- Each media row carries `aspect` (width / height from the row, upright; 0
  when unknown). The screen savers treat below 0.9 as portrait and above
  1.1 as landscape.

**Screen saver styles** (`Device.screensaver`, QSettings
`display/screensaver`): `photos` (default), `collage`, `frame`, `memories`,
`video`, `clock`, `today`. `qml/screensaver/Picks.js` decides which photo
goes where, and `tst_savers` tests it:

- Collage: `TURNS` (classic, grid, mosaic, trio, columns) advance by one
  each time the screen saver starts. `layout(turn, n)` falls back to a
  smaller layout when there are fewer photos than tiles. `pick()` never
  takes a photo on screen or one that left less than 60 s ago, prefers the
  tile's shape, then the photo off screen longest (new photos first, newest
  first). A tile changes every 4 s, big tiles less often, never the same
  tile twice in a row. A deleted photo is replaced; a URL signed again
  keeps the tile as it is.
- Smart frame: `frames()` pairs each portrait photo with the next unpaired
  portrait; landscape and unknown photos go alone.
- On this day: `memories()` takes photos whose anniversary this year (or
  next or last, around New Year) is within 3 days of today, same day first.
  With none, the newest photos and their date labels.
- Clock and Today hide the shared clock overlay and draw their own.

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

**Wall create flows** (Calendar, Chores, Rewards)

- `FamilyStore::addEvent(title, location, startsAt, endsAt, allDay, memberIds)`
  inserts into `events`, then `event_members` for each id. Demo mode keeps
  the row locally. Optimistic UI, then `loadLive()` on success.
- `FamilyStore::addTask(title, icon, assigneeId, points, requiresApproval,
  rrule)` inserts into `tasks`. When `points > 0`, the display forces
  `requires_approval = true` so `tasks_guard` accepts a device write.
- `FamilyStore::addReward(title, icon, cost)` inserts into `rewards`
  (`rewards_insert` allows the paired display). Parents still archive from
  iOS.
- Each screen exposes a `+` control that opens a touch form (`FormDialog`).

**Build and install**

- CMake adds `WebSockets`. Packages: `qt6-websockets-dev` for the build,
  `libqt6websockets6` at runtime.
- `display/deploy/install-pi.sh` adds those packages and a `--with-voice`
  flag (or `HOMEOS_VOICE=1`) that runs `voice/deploy/install-voice.sh`.
  It also masks `getty@tty1` / `autovt@tty1` so a failed or slow kiosk start
  cannot leave a login prompt on the panel; recovery unmasks them (see
  `docs/PI_SETUP.md`).

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
email, links to `https://ohanaos.co/privacy` and `/support`, sign out, and
**Delete account**: an alert that says what goes and what stays for the
family on screen, then `POST /api/account/delete` on `Config.mediaAPIURL`'s
origin (§3) and a local sign-out. "Enter an invite code" (signed in, no
family) has Delete account too, and the welcome screen links the privacy
policy.

**Media upload:** new photos and videos go to the private Blob store (§1.10).
Photos are JPEG (≤ 2560 px). A video that already fits the wall goes as it
is (HEVC or H.264, 8-bit SDR, long side ≤ 1920 px, ≤ 31 fps, ≤ 16 Mb/s;
index moved to the front if needed). Anything else is exported as HEVC
1080p, SDR, ≤ 30 fps, with H.264 1080p as the fallback and the original as
the last resort (`docs/IOS.md`, Photo and video uploads). Each item carries
a JPEG poster of at most 256 KiB. The row sets `byte_size` (the file only),
`content_type`, `thumbnail_path` when the poster went up, and
`file_store = blob`. If the row insert fails, the Blob object just uploaded
and its poster are removed. Rows already in Storage keep `thumbnail_path`
when they have a poster. The display signs Blob paths
through the media API and Storage paths through Storage.

**Family management**

- Members list, on the Family tab and in Profile → Manage family. Parents
  can add members (name, role, color, optional photo), edit anyone's name,
  color and role, set or remove the photo of a member without a login
  (§1.7), and remove members; anyone can edit their own name and color, and
  their own photo, which is their profile photo.
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
  origin. The app asks `POST /api/media/upload` for a presigned URL (and one
  for the poster, by sending `thumbnail_bytes`), `PUT`s the poster and then
  the bytes, and inserts `media_items` with `file_store = 'blob'`. A video
  `PUT` streams the movie file from disk (`URLSession.upload(for:fromFile:)`);
  a photo `PUT` sends the JPEG in memory. An unset URL fails the upload;
  family media is not written to Supabase Storage. Profile avatars still use
  the `avatars` bucket.
- Items upload one at a time; the next is fetched from Photos and optimized
  meanwhile. The banner shows the current item's step (getting it from
  Photos, optimizing with a percentage, bytes sent) and Cancel. Cancel stops
  a running export or upload, still refreshes the list, and shows no
  failure summary.
- Playback of a `blob` row calls `POST /api/media/urls`. A row still in
  Storage uses a Storage signed URL. Both are cached for an hour. Opening
  Media signs every Blob row's poster and file up front, up to 200 paths
  per request. The grid uses the poster when there is one.
- Deleting a blob file calls `POST /api/media/delete` (which removes its
  poster too) before deleting the row.

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

- **`ios.yml`:** on PRs that change `ios/**` or the workflow, and on
  `workflow_dispatch` (not on push: macOS minutes cost 10x):
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
  - `pi-install`: `install-pi.sh --with-voice` in a `debian:trixie` container
    (Qt 6.8, Python 3.13), then a smoke run and preview mode. Runs when
    `display/deploy/**`, `voice/deploy/**`, `display/CMakeLists.txt`,
    `voice/pyproject.toml` or `ci.yml` change, and on pull requests into
    `main` that touch `display/**` or `voice/**`
