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
- **Storage**: new family photos and videos go to a private Vercel Blob store
  at `<family_id>/<media_id>.<ext>` (`media_items.file_store = 'blob'`), signed
  by the admin app. Each one's JPEG poster sits next to it at
  `<family_id>/<media_id>-thumb.jpg`. Files already in the `family-media`
  bucket stay there, one folder deep, under a per-family quota and item cap. A
  row can't point at another family's object, and a display can't move itself
  into another family. Profile avatars stay in the `avatars` bucket. See
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
  - `calendar-sync` brings in connected calendars (Google, calendar links)
    and serves the family's own calendar as a subscribable link; see
    Connected calendars below.
  - `delete-account` deletes the caller's own account for the iOS app.
  - `media-jobs` keeps the state of server-made video copies for the admin
    app, behind a shared secret, so the admin app never holds the service
    role key (see Media below).
  - Later: push notifications (APNs) and recurring-chore generation.

### Data model

| Table | Notes |
|---|---|
| `families` | One household |
| `members` | Everyone shown on the screen. Kids need no login (`user_id` is null); parents link to an auth user. A parent can give a member whose account has no photo of its own (usually a kid without a login) a photo |
| `devices` | Paired wall screens; `user_id` is the device's auth user. `family_id` and `user_id` can't be changed after pairing |
| `events` | Calendar events with an optional RRULE for recurrence; many-to-many with members via `event_members`. Events copied from a connected calendar have `source_id` and are read-only |
| `calendar_sources` / `calendar_accounts` | Connected calendars (a Google calendar or a calendar link) and the Google accounts behind them. Refresh tokens and links sit in service-only tables |
| `calendar_feeds` | The token of the family's subscribable calendar link |
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

## Connected calendars

```
 Google Calendar ──OAuth, events.list──┐                       ┌── wall display, iPhone, assistant
 iCloud / Outlook / school ──ICS link──┼─▶ calendar-sync ─▶ events (source_id) ─▶ event_occurrences
                                       │    (edge function)                       │
 Apple / Google / Outlook ◀──feed link─┴──────────────────── the family's own events
```

- **In.** A parent connects a Google account (browser sign-in, read-only
  scope) and picks calendars, or adds a calendar link (`webcal://` or
  `https://`: iCloud public calendars, Outlook, Google's secret address,
  school, team and holiday calendars). `calendar-sync` reads each one,
  expands repeats itself (ical.js for links; Google expands its own), and
  hands one row per occurrence, 60 days back to a year ahead, to
  `calendar_apply_sync`, which updates `events` in place. So the display, the
  iPhone and the assistant need nothing new: imported events come through
  `event_occurrences` with a `source_id`, in the calendar's color or its
  person's, and can't be edited here.
- **Fresh.** pg_cron calls `calendar-sync` every 15 minutes, a paired display
  asks every 15 minutes, and the iPhone asks when it opens; the server skips
  calendars refreshed in the last 10 minutes. Each calendar syncs in its own
  request, within the edge runtime's CPU budget.
- **Private.** Refresh tokens and links stay in service-only tables. A
  calendar can show as "Busy" (no titles or places), and private events
  always do. A parent's Google account leaves with them.
- **Out.** A parent makes a secret link that serves the family's own events
  as ICS, for Apple Calendar, Google Calendar or Outlook to subscribe to.
  Imported events aren't in it, so nothing loops.

## Design system: dynamic color and motion

- **Time-of-day moods.** `DisplayController` publishes a `mood` (morning,
  day, evening or night). `Theme.qml` maps it to a palette (background,
  surfaces, text, accent, glow) and animates every token over about 2
  seconds, so the screen drifts warm → blue → violet → dark through the day.
- **Photo-driven color.** `ColorSampler` computes a representative color for
  each photo or video from its poster (or the photo itself when there is
  none), decoded at about 64 px off the UI thread. It is cached by the item's
  storage path, so signing the URL again doesn't sample it again. The media
  page's featured card, the full-screen viewer background and the photo
  frame's shade take on the colors of what's showing.
- **Motion.** Pages cross-fade and settle when you switch, the navigation
  highlight springs between items, the assistant slides up, chat messages pop
  in, chores celebrate when ticked, and point totals count up or down.

## Screen savers

After two minutes without a touch (`HOMEOS_IDLE_SECONDS`), or when someone
taps the moon, the display switches to a screen saver. The style is chosen on
Media → Screen saver and remembered on the device (`HOMEOS_SCREENSAVER`
overrides it). A video playing in the media viewer counts as a touch, so a
long one isn't cut off:

- **Photos:** one photo at a time, cross-fading, with a slow zoom and drift.
- **Collage:** photos cropped to fill rounded tiles. Its layout is picked
  under Media → Screen saver (or Settings): classic (one large, four small),
  grid (3×2), mosaic (seven tiles of mixed sizes), trio (one large, two
  small) or columns (four tall), or Auto, which takes the next one each time
  the screen saver starts. With fewer photos than tiles it takes a smaller
  layout, so no tile is empty or repeats a photo. Portrait photos go to tall
  tiles when there's a choice. Every few seconds one tile cross-fades to a
  photo that isn't showing and hasn't been for a minute, so photos don't hop
  between tiles.
- **Smart frame:** like Photos, but two portrait photos share the screen
  side by side; a portrait left without a partner stands whole over a
  blurred copy of itself.
- **On this day:** photos taken on this date in earlier years ("2 years ago
  today"), then within three days of it ("this week"); with none, the newest
  photos with their dates. It draws on the photos the display has loaded
  (the newest 200 by date).
- **Video:** family videos full screen and muted, one after another; a
  single video loops. The poster shows until the first frame. A clip that
  fails, or stops moving for 10 seconds, is skipped after a 2-second pause;
  when every clip fails (offline, say), it tries again every 30 seconds.
  Falls back to Photos if there are no videos.
- **Clock:** a big clock, the date and the next three events on the
  time-of-day gradient, no photos. It shifts a few pixels every minute.
- **Today:** the time, today's events, a photo that changes every 15
  seconds and how many chores each person has left, in the app's colors.

The photo styles show the clock, the date and the next event over a shade in
the colors of what's on screen; Clock and Today lay out their own. Photos
are shown upright: the display applies a JPEG's EXIF orientation. Which
photo goes where is in `qml/screensaver/Picks.js`. The first touch only
wakes the screen.

## Sleep

Settings → Sleep turns the screen off after a set time without a touch (5
minutes to 4 hours; never by default), overnight between a bedtime and a
wake-up time, or right away. Overnight, a screen nobody is using goes off
instead of to the screen saver, and the screen saver comes back at the
wake-up time. The screen fades to black and everything under it is hidden,
so nothing redraws. A DSI or eDP backlight goes to zero, and an HDMI panel
goes to standby through DPMS (`PanelPower`, built when Qt's private headers,
`qt6-base-private-dev`, are installed). A tap or the wake word turns it back
on, and the tap goes no further.

## Media

The Media page shows photos and videos newest first: a featured photo, then a
grid grouped by month, filtered by All, Photos or Videos. The full-screen
viewer is edge to edge: media fills the screen, and a blurred copy of the same
image fills any leftover edges. The title, arrows, position dots and video
controls float on top behind soft scrims and fade out after a few seconds; a tap
brings them back. Video plays with QtMultimedia. On Raspberry Pi OS Trixie
(Qt 6.8) that is FFmpeg, and HEVC decodes on the Pi 5's HEVC block through
Raspberry Pi's FFmpeg `drm` hwaccel; the installer checks it first
([PI_SETUP.md](PI_SETUP.md#video-decoding)). On Bookworm (Qt 6.4) it is
GStreamer. In demo mode, sample media is copied next to the binary
(`demo-media/`) or installed to `share/homeos/demo-media`.

The iPhone app makes videos at most 1080p and 30 fps, SDR, mostly HEVC, with
the index at the front so playback starts before the whole file arrives
([IOS.md](IOS.md#photo-and-video-uploads)). The original goes only when that
fails, and then the server makes the same kind of copy: a Vercel Sandbox
runs ffmpeg with presigned URLs for that one video, and the row moves to
`<family_id>/<id>-wall.mp4` once Blob confirms the copy and its size. The
same happens to videos from older app builds. A cron sweep every 10 minutes
catches anything missed and deletes swapped-out originals after six hours
([ADMIN.md](ADMIN.md#big-videos-wall-copies-on-the-server),
[PLATFORM_SPEC.md](PLATFORM_SPEC.md) §1.14). Each photo and video also gets a JPEG poster (at most 256 KiB) at
`<family_id>/<id>-thumb.jpg`, presigned in the same upload ticket as the file;
a poster that fails never fails the upload. The row records `byte_size` (the
file only; posters are not billed), `content_type` and `thumbnail_path`. The
quota is enforced in Postgres (on the row and, where Storage exists, on the
object), not in the app. A signed-in client can change a caption or whether
the photo shows on the frame, and nothing else on the row, so the poster is
set when the row is inserted.

The display signs `storage_path` and `thumbnail_path` (Blob paths through the
admin app, at most 200 per request) and reuses each signed URL for 4 hours of
its 6, so a refresh doesn't make players and images load the file again.
Posters are used for the grid tiles (decoded at 480 px), for a video until
its first frame, for the viewer's blurred backdrop, and for color sampling.
The media list has its own `mediaChanged` signal, sent only when the list
really changes. Rows without a poster still show the photo, or a plain tile
for a video.

Platform admins list media through `admin_list_media` and remove an item
through the `admin` function, which writes the audit log and deletes the
file and the poster from Storage. It doesn't remove Blob objects yet.

## Family assistant

The "Ask Ohana" card on the home screen opens a chat with Claude (Opus 5.5),
running in the `assistant` edge function.

- **Grounded in family data, not trained on it.** Each request builds a fresh
  snapshot of the family's data: members and points, the next 14 days of the
  calendar, today's chores, rewards, the week's meals, open list items, and
  the **family memory**. Nothing is fine-tuned, so answers always reflect
  today's data.
- **Family memory** (`family_memories` table) holds lasting facts the assistant
  saves with its `remember` tool, such as "Leo's favorite snack is apple slices" or
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
DisplayController ─ idle → screen saver → sleep, backlight, presence wake
PanelPower   ─ HDMI panel standby (DPMS) while the screen sleeps
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
- Profile (name, photo), family management (members with names, photos,
  colors and roles; invites), also under Profile → Manage family, and the
  assistant with saved threads. Siri: say "Ask Ohana", then the question.
- Photos and videos are picked with `PhotosPicker` and uploaded to Vercel
  Blob through the admin app (`Config.mediaAPIURL`), with a size, a content
  type and a JPEG poster. Videos are made at most 1080p (mostly HEVC) for
  the wall first. They appear on the wall frame within a minute; the
  display signs them through the same admin app (`HOMEOS_MEDIA_URL`, by
  default `https://ohanaos.co`). Profile photos stay in Supabase. Files
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
