# iOS app

The iPhone companion to the wall display. It shares the Supabase backend, so a
change on the phone shows up on the wall (and vice versa) on the next refresh.
SwiftUI, iOS 17+, the Observation framework, App Intents, and
[supabase-swift](https://github.com/supabase/supabase-swift) 2.x. The contract
with the backend is [PLATFORM_SPEC.md](PLATFORM_SPEC.md) §6; how accounts,
families and invites fit together is in [PLATFORM.md](PLATFORM.md).

## Build and run

```bash
brew install xcodegen
cd ios && xcodegen && open HomeOS.xcodeproj
```

1. Put your Supabase URL and anon key in `ios/HomeOS/App/Config.swift`.
2. Apply the migrations and deploy the `pair-device` and `assistant` edge
   functions (see the README).
3. In Supabase → Authentication → URL Configuration, add
   `homeos://auth-callback` to **Redirect URLs**. Email confirmations and admin
   email invites then open the app and sign you in. Without it, those links
   land on the Site URL and you sign in in the app by hand.
4. Pick an iPhone simulator or a device and run. Build with Xcode 16 or newer:
   the code relies on its SDK treating every SwiftUI `View` as `@MainActor`.

`project.yml` is the source of truth for the project. Don't edit the generated
`.xcodeproj` or `Info.plist`; change `project.yml` and run `xcodegen` again.
It declares the `homeos` URL scheme, a shared `HomeOS` scheme (for
`xcodebuild`), and the photo library, camera, microphone and speech
recognition usage strings. Siri needs no extra keys or entitlements: App
Shortcuts are found by the App Intents metadata step of a normal build.

## Code map

```
ios/HomeOS/
├── App/
│   ├── HomeOSApp.swift       RootView: loading (with retry) / welcome / family setup / tabs; deep links
│   ├── AskHomeOSIntent.swift Siri: AskHomeOSIntent + HomeOSShortcuts (App Shortcuts)
│   └── Config.swift          Supabase URL and key, bucket names, auth callback URL
├── Models/       Codable rows mirroring the migrations (snake_case keys), invites, profiles,
│                 assistant threads and messages, chat types, InviteCode, DayKey
├── Services/
│   ├── FamilyStore.swift     the one @Observable store: auth, invites, profile, family data, writes, assistant
│   ├── AssistantClient.swift `assistant` function over URLSession: SSE streaming and quick answers
│   ├── MediaTools.swift      thumbnail + average-color cache, avatar cache, upload prep (JPEG, EXIF, video)
│   └── Dictation.swift       SFSpeechRecognizer push-to-talk for the assistant
├── Theme/Theme.swift         tokens, Mood, GlowView, card/pill/tag styles, MemberAvatar/AvatarCircle, SegmentedPill
└── Views/
    ├── Components/           floating tab bar, activity/approval cards, shared bits
    ├── OnboardingViews.swift welcome (invite code, create account, sign in), enter an invite code,
    │                         create family, invite-link sheet
    ├── ProfileView.swift     name, photo, email, family switcher, Siri tip, sign out
    ├── InviteViews.swift     create invite, code card with share/copy, pending and accepted rows
    ├── HomeView.swift        Home + assistant hero card
    ├── AssistantView.swift   streaming chat, thread history
    ├── CalendarView.swift    month / week / day, event detail, add event
    ├── ChoresView.swift      chores board, add chore
    ├── RewardsView.swift     balances, rewards, redemptions, add reward
    ├── MediaView.swift       media grid, viewer, upload
    └── FamilyView.swift      members (edit/remove), invites, lists, meals, memory, displays, leave family
```

## Screens

A floating capsule tab bar sits at the bottom. The selected tab is an accent
pill that slides between tabs. Your avatar at the top of Home and Family opens
your **Profile**.

| Tab | What's there |
|---|---|
| **Home** | Family name and date. The assistant card: glow arch, "How can I help you today?", suggestion chips, and an "Ask homeOS anything" pill with a mic button. Below it: "Waiting for your OK" approvals (parents only), today's chore progress per member, your upcoming activities, and dinner tonight (tap to plan it). |
| **Assistant** (full screen, from Home) | Chat bubbles: yours in the mood accent on the right, homeOS in white on the left. Replies stream in word by word; a typing indicator shows until the first words arrive. Green chips list what the assistant did (`actions`). The clock button opens your earlier chats (tap to reopen, swipe to delete); the pencil starts a new one. Suggestion chips show when the chat is empty, and each starts its own chat. The mic dictates with Apple's speech recognition (`SFSpeechRecognizer`, which may send the audio to Apple) and fills in the text field; you review it, then tap send. |
| **Calendar** | Day / Week / Month switcher. **Month** shows a grid with up to three colored bars per day and today as a filled circle; tap a day to open it in Day view. Your upcoming activities for that month are listed below. **Week** is a 7-column time grid with pastel blocks, member badges, an all-day row and a now line; tap a weekday header to open that day. **Day** is the same grid in a single column with times and places. Tap any event for details or to delete it. The **+** button adds an event (title, place, all-day, start/end, who). |
| **Chores** | **Chores**: approvals first (parents), then one card per member with progress, animated point balance and today's chores. Tap the circle to mark a chore done on someone's behalf. A parent's tap is approved right away; anyone else's waits for a parent. Unassigned chores sit in an "Anyone" card with a picker for who did it. Long-press a chore to undo it or remove the chore (parents). **Rewards**: balance cards (parents get −5/+5), rewards waiting to be handed out (Done or Cancel to refund), and a rewards grid. **Redeem** spends a kid's points through `redeem_reward`. **+** adds a chore or reward. |
| **Media** | All / Photos / Videos filter and a grid grouped by month. Video tiles show a play badge and their length; an eye-slash badge marks items hidden from the wall frame. **+** opens the photo picker for multiple photos and videos. The full-screen viewer swipes between items, plays videos, toggles "On the wall frame", and deletes. Its backdrop takes the current photo's average color. |
| **Family** | Members (tap to edit; parents can add one), invites (parents), lists (tap through to add, check off and clear items), meals for the next 7 days (tap a day to set breakfast, lunch and dinner), family memory (add a fact; parents can remove one), paired wall displays and **Pair a display** (parents), and Profile / Leave family. |

## Onboarding (invite-only)

homeOS is invite-only, so the first screen starts with the invite code.

1. **Welcome.** Type the code (it tidies itself into `XXXX-XXXX`) or open an
   invite link, then **Check invite**. `preview_invite` answers without signing
   in, and the app shows "You're invited to {family} as a {role}" (with who
   invited you and until when), "This code lets you start a new family", or
   the reason the code doesn't work ("Invite code expired", …).
2. **Create account** (name, email, password, at least 8 characters) is
   enabled once the code checks out. Sign-up sends
   `data: ["invite_code": code, "display_name": name]`, which gets it past the
   invite-only auth hook and names the profile. **Sign in** works without a
   code; a checked code rides along.
3. **Right after signing up or in**, with no family yet:
   - a **family invite** is accepted at once with
     `accept_family_invite(code, display_name)`, and the app opens the family;
   - a **platform invite** opens **Create family** (family name, your name),
     which calls `create_family(family_name, my_name, tz, invite_code)`.
4. If email confirmation is on, sign-up ends with "Check your email". The code
   is saved on the phone (and in the account's metadata), so after confirming
   and signing in, step 3 still happens, even on another iPhone.
5. **Signed in with no family and no code** (a fresh account, or after leaving
   a family): "Enter an invite code". A family code shows **Join {family}**; a
   platform code moves on to Create family. Members of a family an admin has
   suspended also land here, because they can no longer see it.

Server errors are shown as they come back from the RPCs (sentence-cased), so
the messages in PLATFORM.md → "Errors the apps show" appear verbatim.

### Deep links

The `homeos` URL scheme is registered in `project.yml`; `HomeOSApp` passes
every URL to `FamilyStore.handleOpenURL`.

| Link | What happens |
|---|---|
| `homeos://invite/<CODE>` | Saves the code as pending. Signed out: prefills Welcome and checks it. No family: prefills "Enter an invite code". In a family already: a sheet offers to join that family (the app switches to it) or start a new one. Dismissing it forgets the code. |
| `homeos://auth-callback…` | Finishes an email link: implicit-grant tokens in the fragment (admin email invites) go to `auth.setSession`, a PKCE `code` (sign-up confirmations) to `auth.session(from:)`. A pending family invite is then accepted as in step 3. Any app or web page can open a `homeos://` link, so tokens are ignored while someone is already signed in ("Sign out first to use that link"); a PKCE code can't be replayed, because it only works with the verifier this iPhone stored at sign-up. |

The parent's share sheet text includes both the link and the code, so the code
still works for someone who opens the message on another device.

## Profile

From the avatar on Home or Family. Edit your display name (`profiles`), and
optionally use it on the family screen too (your `members` row). **Photo**:
pick one with `PhotosPicker`; it's cropped to a 512 px square JPEG, uploaded
to `avatars/<uid>/avatar.jpg` (upsert, lowercase uid to match the storage
policy), and `profiles.avatar_path` is set. **Remove photo** clears both. Also
shows your email, family and role; a family picker when you belong to more
than one; the Siri tip; and **Sign out**.

Member avatars everywhere (`MemberAvatar`) show the photo of the member's
account when there is one, else the initial on the member's color. Photos are
downloaded from the private bucket with the session and cached per path and
`profiles.updated_at`, so a new photo replaces the old one on the next refresh.

## Family management

- **Members.** Tap a member to edit. Parents can change anyone's name, color
  and role, and remove a member (with their chores and points). Everyone else
  can edit only their own name and color; other members aren't tappable for
  them. The server's `members_guard` has the final say: it refuses to remove,
  demote or unlink the last parent with an account, and the error is shown.
- **Invites** (parents). **Invite** opens a form: who it's for ("Someone new"
  with a role, or an existing member without a login, who then claims their row
  and points), an optional email (only that address can use it), and how long
  it works (1–60 days). It calls `create_family_invite`, then shows the code
  with **Share** (share sheet text with the code and the
  `homeos://invite/CODE` link) and **Copy code**. The Family tab lists pending
  invites (share, copy, revoke via `revoke_family_invite`) and the last few
  accepted ones (who joined and when). A member without a login has an
  "Invite {name} to get a login" button in their editor.
- **Leave family** calls `leave_family`: your account is unlinked, your member
  row stays on the screen with its points. The last parent can't leave.

Everything the app loads is filtered to the family on screen, so someone in two
families sees one at a time; the choice is remembered on the phone.

## Assistant

- **Threads.** History is `assistant_threads` (your own, in this family, not
  archived), newest first. Opening one loads its last 200 messages. Delete is
  a swipe; messages go with the thread. A new chat has no thread id until the
  first reply's `thread` event names it.
- **Streaming.** `AssistantClient.stream` POSTs
  `{message, thread_id?, family_id, mode: "chat", stream: true}` to
  `<SUPABASE_URL>/functions/v1/assistant` with `Authorization: Bearer <access
  token>`, `apikey` and `Accept: text/event-stream`, and reads the body with
  `URLSession.bytes`. It splits lines itself (`AsyncBytes.lines` drops the
  blank lines that end SSE events) and parses `thread`, `delta`, `action`,
  `done` and `error`. Deltas grow the last bubble, actions add chips, `done`
  replaces the text with the final reply. If the stream drops before `done`
  (or cuts `done` off mid-way), whatever arrived stays; with nothing, you get
  "I couldn't reach homeOS".
  Non-200 answers show the function's `{error}` message (401 asks you to sign
  in again; 403 covers a suspended family or no family).
- After a reply that did something (actions), the app reloads the family data.
- The dictation mic is unchanged.

## Siri

`AskHomeOSIntent` (`App/AskHomeOSIntent.swift`) is an `AppIntent` with one
parameter, `question`. `perform()` calls the assistant with `mode: "quick"`,
`stream: false` and no thread (`AssistantClient.quickAnswer`), and returns the
reply as both the spoken dialog and the intent's value, so Shortcuts can use
it. It runs without opening the app, using the session saved in the keychain;
signed out, Siri says "Sign in to homeOS on your iPhone first." It asks you to
unlock the iPhone first (`authenticationPolicy = .requiresAuthentication`), so
a locked phone doesn't read out the family's plans.

`HomeOSShortcuts` (an `AppShortcutsProvider`) registers "Ask homeOS", "Ask
homeOS a question" and "Ask my family assistant in homeOS". A String parameter
can't be part of a phrase, so Siri then asks "What would you like to ask
homeOS?". Each Siri question starts its own thread, which then shows up in the
app's chat history. The Profile screen shows a `SiriTipView` for it.

## CI

`.github/workflows/ios.yml` runs on pushes and pull requests that touch
`ios/**` or the workflow. On `macos-15` it selects the newest stable Xcode
(`maxim-lobanov/setup-xcode`, failing if that's older than 16), installs
XcodeGen with Homebrew, runs `xcodegen generate`, and builds:

```bash
xcodebuild -project HomeOS.xcodeproj -scheme HomeOS -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Swift packages are checked out into `.spm` and cached on the hash of
`project.yml` (no `Package.resolved` is committed, so a fresh run resolves the
newest supabase-swift 2.x). When the build fails, the full `xcodebuild` log is
uploaded as the `xcodebuild-log` artifact.

## Design

The colors match the wall display (`display/qml/Theme.qml`): a warm off-white
canvas (`#F1EFEB`), white cards with a 28 pt radius, and a blue accent
(`#4F7CF7`). Member colors come from `members.color`. Tags put the member color
at 28% opacity behind darker text of the same hue. Dark mode uses the
display's night palette.

**Mood.** The accent and the glow follow the time of day: coral in the morning
(5:00–11:00), blue in the day (11:00–17:00), violet in the evening
(17:00–21:00) and a dim indigo at night. `MoodProvider` checks the clock every
minute and eases between palettes. It sets SwiftUI's `tint`, so system
controls follow the mood too.

**Motion.** `matchedGeometryEffect` slides the tab bar pill, the segmented
controls and the color picker ring. Chore completion uses springs and a symbol
bounce, and point balances roll with `.numericText`. List inserts and removals
have transitions, and the glow slowly breathes. The onboarding, invite and
profile screens reuse the glow header, pills and cards.

## Data notes

- Pull to refresh reloads everything. Realtime subscriptions aren't wired up
  yet.
- Opening the app offline with an expired access token doesn't sign you out:
  supabase-swift then reports no initial session, but the saved one is still
  in the keychain, so the loading screen shows the error and **Try again**. A
  refresh the server refuses (revoked, banned) still lands on the welcome
  screen.
- Every query names the family on screen (`family_id`); `list_items` has no
  family column, so it's filtered through its list
  (`lists!inner(family_id)`). The newest 500 items load, so a long history of
  checked-off items can't hide new ones.
- Events load from 45 days back to 120 days ahead. Recurring events (`rrule`)
  aren't expanded yet; only the first occurrence shows.
- Chores count as due today from a simple read of their RRULE: `FREQ=DAILY`, or
  `FREQ=WEEKLY;BYDAY=…`. A one-time chore stays up until it's done. Completions
  use the phone's local date for `for_date`.
- A parent marking a chore done inserts the completion and then calls
  `review_completion(approve: true)`. A rejected completion from earlier the
  same day is deleted first, because of the unique key on (task, member, date).
  Only parents may delete completions (RLS), so anyone else retrying a rejected
  chore is asked to get a parent to undo it first.
- Photos are re-encoded as JPEG (at most 2560 px on the long side) before
  upload, so the display never has to decode HEIC. `taken_at` comes from EXIF
  `DateTimeOriginal`. Videos are uploaded as-is, with `duration_seconds`, size
  and creation date read through `AVURLAsset` from the file on disk. The picker
  hands the app a movie file; the upload streams that file to Blob
  (`URLSession.upload(for:fromFile:)`) instead of reading the whole clip into
  memory. `Config.mediaAPIURL` is the admin app's origin; until it's
  set, the upload fails and nothing is written to Storage. Photo type sent
  is `image/jpeg`. Video types are `video/quicktime` (`.mov`), `video/mp4`,
  `video/m4v`, `video/webm`, `video/x-matroska`, `video/3gpp`, and
  `video/3gpp2`. Profile avatars still use the `avatars` bucket.
- Signed URLs (1 hour) are cached per storage path. Blob files
  (`file_store = blob`) use `POST /api/media/urls` on that same origin.
  Rows still in Storage use a Storage signed URL. Thumbnails, average colors
  and avatars are cached in memory for the session.
- UUIDs sent to the `assistant` function are lowercase, because it compares
  ids as strings.
- The app sends `family_id` (the family on screen) to the `assistant`
  function alongside the spec's fields, so people in two families get answers
  about the one they're looking at. The function accepts it as optional.
- The app can't read `platform_settings`, so it always asks for an invite
  before Create account, even if an admin turns `invite_only` off.

## Unverified

The code was written without an Xcode toolchain. Every file passes a
tree-sitter Swift parse, and a cross-reference check (every `store.…`,
`Theme.…`, `InviteCode.…` member and its argument labels, and the memberwise
inits of the app's own views and models) finds no mismatches. All
supabase-swift calls were checked against the v2.55.3 source (what
`from: 2.20.0` resolves to today). The new models were checked against real
output of the migrations (a throwaway Postgres running `preview_invite`,
`accept_family_invite`, `create_family_invite`, `create_family`, and the
`profiles`, `family_invites`, `assistant_threads` and `assistant_messages`
rows), and the SSE line handling against the `assistant` function's event
format. CI has built it since commit 2a50d0d; it hasn't been run against a
live project yet. Calls added by the review after that build, to check first
if CI breaks: `FunctionsError.httpError` in `FamilyStore.message(for:)`,
`auth.currentSession` plus `try await auth.session` with `catch is URLError`
in `FamilyStore.start()`, `auth.currentSession` in `completeAuthCallback`, the
`lists!inner(family_id)` filter on `list_items` in `refresh()`, and
`if case .error = event` at the end of `AssistantClient.stream`. The riskiest
calls from the first build:

- `@Environment(FamilyStore.self) private var store: FamilyStore?` (the
  optional observable environment initializer) in `MemberAvatar`,
  `Theme/Theme.swift:282`.
- App Intents in `App/AskHomeOSIntent.swift`: `static let description:
  IntentDescription?` (line 8; whether the requirement is optional),
  `authenticationPolicy = .requiresAuthentication` (line 10),
  `@Parameter(title:requestValueDialog:)` with a string literal (line 12),
  `ParameterSummary` (line 15), `.result(value:dialog:)` with
  `IntentDialog(stringLiteral:)` (line 33), and
  `AppShortcut(intent:phrases:shortTitle:systemImageName:)` (line 41).
- `SiriTipView(intent:)` in a `Form` row, `Views/ProfileView.swift:97`.
- `URLSession.shared.bytes(for:)` and iterating `AsyncBytes` byte by byte,
  `Services/AssistantClient.swift:58` and `:72`; and the `@MainActor` event
  callback awaited from the nonisolated `stream` method (`:56`).
- `ShareLink(item: String) { label }`, `Views/InviteViews.swift:152` and
  `:211`.
- The `@Observable` stored property with a `private(set)` initializer reading
  `UserDefaults` (`pendingInviteCode`), `Services/FamilyStore.swift:45`.
- Decoding a scalar RPC result (`uuid`) straight into `UUID`,
  `Services/FamilyStore.swift:418` and `:442`.
- From before: `supabase.storage.from(_:).remove(paths:)`
  (`Services/FamilyStore.swift:499`, `:1034`; it exists in 2.55.3),
  `AVAudioApplication.requestRecordPermission()` as `async -> Bool` (iOS 17,
  `Services/Dictation.swift:101`), the `AVAsyncProperty` loads in
  `MediaTools.videoMetadata(at:)` (`Services/MediaTools.swift:200`–`:215`), and
  `nonisolated init()` on the `@Observable @MainActor` `Dictation` class
  (`Services/Dictation.swift:20`).

## Next

- Realtime subscriptions for live updates while the app is open.
- Sign in with Apple.
- RRULE expansion for recurring events.
- Scanning the pairing QR code with `DataScannerViewController`.
- A unit-test target (SSE parsing, invite code formatting) once CI runs tests.
