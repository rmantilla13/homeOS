# Architecture

```
 ┌──────────────────┐        ┌──────────────────────────────┐        ┌──────────────────┐
 │  iOS app (Swift) │◀──────▶│  Supabase (cloud backend)    │◀──────▶│ Wall display     │
 │  parents & kids  │  HTTPS │  Postgres + RLS              │ HTTPS  │ Qt 6 / QML / C++ │
 │  feed the screen │  + WS  │  Auth · Storage · Realtime   │  + WS  │ Raspberry Pi 5   │
 └──────────────────┘        │  Edge Functions (pairing,    │        │ local cache      │
                             │  push, recurring jobs)       │        └──────────────────┘
                             └──────────────────────────────┘
```

## Backend: Supabase

- **Postgres** holds all family data, and row-level security scopes every row
  to a family (`backend/supabase/migrations`).
- **Auth** has two kinds of users: people (iOS app, Sign in with Apple or
  email) and devices (one auth user per wall screen, created at pairing).
- **Storage**: the `family-media` bucket stores photos and videos under
  `<family_id>/<media_id>.<ext>`.
- **Realtime**: the display subscribes to row changes, so the screen updates
  as soon as a phone edits something.
- **Edge Functions**:
  - `pair-device` binds a new screen to a family.
  - `assistant` is the family AI, described below.
  - Later: push notifications (APNs), recurring-chore generation, and
    calendar sync with Google and iCloud.

### Data model

| Table | Notes |
|---|---|
| `families` | One household |
| `members` | Everyone shown on the screen. Kids need no login (`user_id` is null); parents link to an auth user |
| `devices` | Paired wall screens; `user_id` is the device's auth user |
| `events` | Calendar events with an optional RRULE for recurrence; many-to-many with members via `event_members` |
| `tasks` | Chores and to-dos: assignee, points, recurrence, due date, and whether a parent must approve |
| `task_completions` | A task completed on a date; when approved, it posts points |
| `rewards` / `reward_redemptions` | The reward catalog and claims |
| `points_ledger` | Append-only point history; `member_points` is a view of balances |
| `lists` / `list_items` | Shopping and other checklists |
| `meal_plans` | One row per day and meal |
| `media_items` | Metadata for photos and videos in Storage |

Points are never edited directly. They are written only by database
functions (`approve_completion`, `redeem_reward`), so balances can't drift.

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
viewer swipes between items and plays video with QtMultimedia. On the Pi that
runs through GStreamer, which uses hardware HEVC decode. In demo mode, sample
media is copied next to the binary (`demo-media/`) or installed to
`share/homeos/demo-media`.

## Family assistant

The "Ask homeOS" card on the home screen opens a chat with Claude (Opus 5.5),
running in the `assistant` edge function.

- **Grounded in family data, not trained on it.** Each request builds a fresh
  snapshot of the family's data: members and points, the next 14 days of the
  calendar, today's chores, rewards, the week's meals, open list items, and
  the **family memory**. Nothing is fine-tuned, so answers always reflect
  today's data.
- **Family memory** (`family_memories` table) holds lasting facts the assistant
  saves with its `remember` tool, such as "Leo is allergic to peanuts" or
  "soccer carpool is with the Parks". Parents can delete memories.
- **Tools:** `add_event`, `add_list_item`, `add_chore`, `set_meal`, `remember`.
  Points, approvals and rewards are deliberately not exposed, so a child at the
  screen can't award themselves points.
- **Privacy:** the function queries Postgres with the caller's own JWT, so
  row-level security limits the assistant to that family. The Anthropic API key
  lives only in the function's secrets and never reaches a device.
- **Demo mode:** the display answers a few common questions (today, tomorrow,
  dinner, chores, points, adding to the grocery list) from the sample data, so
  the screen works without a backend.
- **Voice:** the mic button is in place; speech-to-text comes later (whisper.cpp
  running locally on the Pi, or a cloud speech service).

## Display app: `display/`

Qt 6 with QML for the UI and C++ for data, networking and hardware.

```
QML screens  ─ Home · Calendar · Tasks · Rewards · Photos · Planner · PhotoFrame
     │
FamilyStore  ─ demo / pairing / live modes; exposes display-ready rows to QML
     │
SupabaseClient ─ REST (PostgREST) today; Realtime WebSocket next
     │
DisplayController ─ idle → photo frame, backlight, presence wake
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

SwiftUI with the `supabase-swift` SDK; the Xcode project is generated by
XcodeGen.

- Tabs: Today, Calendar, Chores, Rewards and Photos.
- Photos and videos are picked with `PhotosPicker` and uploaded to Storage;
  they appear on the wall frame within seconds.
- Parents approve chore completions and manage rewards.
- **Pair a display**: the screen shows a 6-digit code and a QR code; the app
  sends it to `pair-device`.

## Device pairing flow

1. An unpaired display creates a `pairing_codes` row: a short code that
   expires after 10 minutes.
2. The display shows the code and its QR code.
3. A parent in the iOS app scans or types it, and the app calls the
   `pair-device` function with their JWT.
4. The function checks that the parent belongs to the family, creates the
   device auth user and the `devices` row, and marks the code claimed.
5. The display polls the code and receives its device session. It stores the
   refresh token on disk, and RLS then treats it as a member of that family.
