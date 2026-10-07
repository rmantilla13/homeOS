# Architecture

```
 ┌──────────────────┐        ┌──────────────────────────────┐        ┌──────────────────┐
 │  iOS app (Swift) │◀──────▶│  Supabase (cloud backend)    │◀──────▶│ Wall display     │
 │  parents & kids  │  HTTPS │  Postgres + RLS              │ HTTPS  │ Qt 6 / QML / C++ │
 │  feed the screen │  + SSE │  Auth · Storage · Realtime   │  + SSE │ Raspberry Pi 5   │
 └──────────────────┘        │  Edge Functions: assistant,  │        └────────┬─────────┘
                             │  admin, pair-device          │                 │ ws://127.0.0.1
 ┌──────────────────┐        │                              │        ┌────────┴─────────┐
 │ Admin console    │◀──────▶│                              │        │ Voice service    │
 │ Next.js, admins  │  HTTPS └──────────────────────────────┘        │ wake word, STT,  │
 └──────────────────┘                                                │ TTS (on the Pi)  │
                                                                     └──────────────────┘
```

[PLATFORM_SPEC.md](PLATFORM_SPEC.md) is the contract between these parts: table,
RPC, endpoint, event and message names. Change it first when a shape changes.

## Backend: Supabase

- **Postgres** holds all family data, and row-level security scopes every row
  to a family (`backend/supabase/migrations`).
- **Auth** has two kinds of users: people (iOS app, email) and devices (one
  auth user per wall screen, created at pairing).
- **Invite-only accounts:** a new person needs a platform invite to start a
  family, or a family invite (from a parent) to join one. Each person has a
  `profiles` row. Platform admins can suspend families, which hides their
  data from members and displays. See [PLATFORM.md](PLATFORM.md).
- **Storage**: new family photos and videos go to a private Vercel Blob
  store at `<family_id>/<media_id>.<ext>` (`media_items.file_store = 'blob'`),
  signed by the admin app. Files already in the `family-media` bucket stay
  there, one folder deep, under a per-family quota and item cap. A row can't
  point at another family's object, and a display can't move itself into
  another family. Profile avatars stay in the `avatars` bucket. See
  [PLATFORM.md](PLATFORM.md).
- **Realtime**: the display subscribes to row changes, so the screen updates
  as soon as a phone edits something.
- **Edge Functions**:
  - `pair-device` binds a new screen to a family.
  - `assistant` is the family AI, described below.
  - `admin` does what needs Supabase Auth's admin API (emailed invites, ban,
    delete user, remove media files, revoke a display) after checking that
    the caller is a platform admin. Listing and deleting media rows stays in
    SQL; signing a thumbnail URL is the function, because admins are not
    family members and have no Storage read policy.
  - Later: push notifications (APNs), recurring-chore generation, and
    calendar sync with Google and iCloud.

### Data model

| Table | Notes |
|---|---|
| `families` | One household |
| `members` | Everyone shown on the screen. Kids need no login (`user_id` is null); parents link to an auth user |
| `devices` | Paired wall screens; `user_id` is the device's auth user. `family_id` and `user_id` can't be changed after pairing |
| `events` | Calendar events with an optional RRULE for recurrence; many-to-many with members via `event_members` |
| `tasks` | Chores and to-dos: assignee, points, recurrence, due date, and whether a parent must approve |
| `task_completions` | A task completed on a date; when approved, it posts points |
| `rewards` / `reward_redemptions` | The reward catalog and claims |
| `points_ledger` | Append-only point history; `member_points` is a view of balances |
| `lists` / `list_items` | Shopping and other checklists |
| `meal_plans` | One row per day and meal |
| `media_items` | Metadata for photos and videos: kind, size, type, store (`blob` or `supabase`), and an optional thumbnail path in the same family folder |
| `profiles` | One per person with an account: display name, avatar |
| `platform_invites` / `family_invites` | Invite codes to start a family, or to join one (optionally as an existing member) |
| `assistant_threads` / `assistant_messages` | Saved assistant conversations, private to the person who started them |
| `assistant_usage` | Requests and tokens per family and day, for the daily limit and the admin charts |
| `platform_admins` / `platform_settings` / `admin_audit_log` | Who runs the platform, global switches (invite-only, assistant on/off, daily limit, storage quota, per-file cap, item cap) and a log of every admin action |

Points are never edited directly. They are written only by database
functions (`approve_completion`, `redeem_reward`), so balances can't drift.
Guard triggers also stop non-parents from setting what a chore is worth or
letting it skip approval, so a child (or the kitchen display) can't award
themselves points.

## Design system: dynamic color and motion

- **Time-of-day moods.** `DisplayController` publishes a `mood` (morning,
  day, evening or night). `Theme.qml` maps it to a palette (background,
  surfaces, text, accent, glow) and animates every token over about 2
  seconds, so the screen drifts warm → blue → violet → dark through the day.
- **Photo-driven color.** `ColorSampler` computes a representative color for
  each photo or video poster, off the UI thread and cached. The media page's
  featured card, the full-screen viewer background and the photo frame's
  shade take on the colors of what's showing.
- **Motion.** Pages cross-fade and settle when you switch, the navigation
  highlight springs between items, the assistant slides up, chat messages pop
  in, chores celebrate when ticked, and point totals count up or down.

## Screen savers

After two minutes without a touch (`HOMEOS_IDLE_SECONDS`), or when someone
taps the moon, the display switches to a screen saver. The style is chosen on
Media → Screen saver and remembered on the device (`HOMEOS_SCREENSAVER`
overrides it):

- **Photos:** one photo at a time, cross-fading, with a slow zoom and drift.
- **Collage:** one large and four small tiles; a random tile swaps to a new
  photo every few seconds.
- **Video:** family videos full screen and muted, one after another. Falls
  back to Photos if there are no videos.

Every style shows the clock, the date and the next event over a shade in the
colors of what's on screen. The first touch only wakes the screen.

## Media

The Media page shows photos and videos newest first: a featured photo, then a
grid grouped by month, filtered by All, Photos or Videos. The full-screen
viewer is edge to edge: media fills the screen, and a blurred copy of the same
image fills any leftover edges. The title, arrows, position dots and video
controls float on top behind soft scrims and fade out after a few seconds; a tap
brings them back. Video plays with QtMultimedia. On the Pi that
runs through GStreamer, which uses hardware HEVC decode. In demo mode, sample
media is copied next to the binary (`demo-media/`) or installed to
`share/homeos/demo-media`.

Uploads from the iPhone record `byte_size`, `content_type` and a JPEG poster
at `<family_id>/<id>-thumb.jpg`. The quota is enforced in Postgres (on the
row and, where Storage exists, on the object), not in the app. A signed-in
client can change a caption or whether the photo shows on the frame, and
nothing else on the row. The display still signs `storage_path` and ignores
the extra columns. Platform admins list media through `admin_list_media` and
remove an item through the `admin` function, which writes the audit log and
deletes the file and the poster.

## Family assistant

The "Ask Ohana" card on the home screen opens a chat with Claude (Opus 5.5),
running in the `assistant` edge function.

- **Grounded in family data, not trained on it.** Each request builds a fresh
  snapshot of the family's data: members and points, the next 14 days of the
  calendar, today's chores, rewards, the week's meals, open list items, and
  the **family memory**. Nothing is fine-tuned, so answers always reflect
  today's data.
- **Family memory** (`family_memories` table) holds lasting facts the assistant
  saves with its `remember` tool, such as "Leo is allergic to peanuts" or
  "soccer carpool is with the Parks". Parents can delete memories.
- **Tools:** `add_event`, `add_list_item`, `add_chore`, `set_meal`, `remember`,
  and `forget` (parents only). Points, approvals and rewards are deliberately
  not exposed, so a child at the screen can't award themselves points.
- **Threads:** conversations are saved per person (`assistant_threads`), so the
  iPhone shows past chats and the display picks up where it left off.
- **Streaming:** replies stream to the display and the iPhone as server-sent
  events (`thread`, `delta`, `action`, then `done` or `error`).
- **Quick mode:** short spoken-style answers for the wake word and Siri
  ("Ask Ohana").
- **Limits:** platform admins can switch the assistant off and set a daily
  request limit per family. Request, history and family-snapshot sizes are
  capped so one family can't run up costs.
- **Privacy:** the function queries Postgres with the caller's own JWT, so
  row-level security limits the assistant to that family. Claude is reached
  through Anthropic workload identity federation: the admin deployment mints
  a short-lived Vercel OIDC token, and the function exchanges it for a
  short-lived Anthropic token. No Anthropic API key is required once that
  is set up, and neither token reaches a device. See [PLATFORM.md](PLATFORM.md).
- **Demo mode:** the display answers a few common questions (today, tomorrow,
  dinner, chores, points, adding to the grocery list) from the sample data, so
  the screen works without a backend.
- **Voice:** see the voice service below.

## Voice: `voice/`

A Python service on the Pi, next to the display. It needs a USB microphone
(the panel has speakers but no mic).

- **Wake word** (openWakeWord) → the display shows a quick-answer card that
  listens, streams the answer, speaks it, and then dismisses itself.
- **Push-to-talk:** the mic buttons on the display send what you say to the
  chat instead.
- Speech-to-text (faster-whisper) and text-to-speech (Piper) run locally.
  Audio never leaves the device; only the transcript goes to the assistant.
- The display talks to it over a WebSocket on `127.0.0.1`. Connections from
  web pages are refused, so a browser on the device can't turn the mic on.
- `--simulate` mode needs no audio hardware. See [VOICE.md](VOICE.md).

## Display app: `display/`

Qt 6 with QML for the UI and C++ for data, networking and hardware.

```
QML screens  ─ Home · Calendar · Tasks · Rewards · Media · Planner · Games · screen savers
             ─ AssistantPanel · QuickAnswer · SettingsSheet
     │
FamilyStore  ─ demo / pairing / live modes; exposes display-ready rows to QML
Assistant    ─ streaming chat and quick answers (ChatModel)
VoiceClient  ─ WebSocket to the voice service: wake, transcripts, speech
     │
SupabaseClient ─ REST (PostgREST) and streamed function calls (SSE)
     │
DisplayController ─ idle → screen saver, backlight, presence wake
SystemController ─ Wi-Fi, screen speakers (mute and volume), restart, reboot
```

- **Kiosk mode**: runs full screen with `-platform eglfs`, one app per device,
  and systemd restarts it if it crashes.
- **Offline first**: the last good state will be cached in SQLite and
  completions queued and replayed when the network returns. This is planned;
  see the roadmap.
- **Touch first**: hit targets of at least 64 px, no hover states, and large
  type readable from across the room.
- **Kid mode**: kids tap their own avatar to see their chores and points, with
  no login. Approvals and reward management are for parents and stay in the
  iOS app.

## iOS app: `ios/`

SwiftUI with the `supabase-swift` SDK. Open the checked-in
`ios/OhanaOS.xcodeproj` (team `92X9CP6C6D`). The app name is Ohana Display;
the project and company are OhanaOS. `xcodegen generate` replaces it.

- Tabs: Today, Calendar, Chores, Rewards and Photos.
- Invite-only onboarding: enter an invite code or open an `ohanaos://invite/<CODE>`
  link, then create an account and start or join a family.
- Profile (name, photo), family management (members, roles, invites) and the
  assistant with saved threads. Siri: say "Ask Ohana", then the question.
- Photos and videos are picked with `PhotosPicker` and uploaded to Vercel
  Blob through the admin app (`Config.mediaAPIURL`), with a size and a
  content type. They appear on the wall frame within seconds once the
  display has `HOMEOS_MEDIA_URL`. Profile photos stay in Supabase. Files
  already in Storage keep playing from that bucket.
- Parents approve chore completions and manage rewards.
- **Pair a display**: the screen shows a 6-digit code and a QR code; the app
  sends it to `pair-device`.

## Device pairing flow

1. An unpaired display creates a `pairing_codes` row: a short code that
   expires after 10 minutes.
2. The display shows the code and its QR code.
3. A parent in the iOS app scans or types it, and the app calls the
   `pair-device` function with their JWT.
4. The function checks that the parent belongs to the family and that the
   family is active (a suspended family is refused), creates the device auth
   user and the `devices` row, and marks the code claimed. The database
   refuses the device row too if the family is suspended, or if something
   later tries to point that display at a different family.
5. The display polls the code and receives its device session. It stores the
   refresh token on disk, and RLS then treats it as a member of that family.

## Admin console: `admin/`

A Next.js app for platform admins: an overview of families, people and
assistant use; suspending or deleting families; banning users; issuing
platform invites; global settings; and the audit log. Every page and action
checks platform-admin rights on the server, and the database checks them
again. It never holds a service-role key. See [ADMIN.md](ADMIN.md).
