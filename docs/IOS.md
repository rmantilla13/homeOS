# iOS app

The iPhone companion to the wall display. It shares the Supabase backend, so a
change on the phone shows up on the wall (and vice versa) on the next refresh.
SwiftUI, iOS 17+, the Observation framework, App Intents, and
[supabase-swift](https://github.com/supabase/supabase-swift) 2.x. The contract
with the backend is [PLATFORM_SPEC.md](PLATFORM_SPEC.md) §6; how accounts,
families and invites fit together is in [PLATFORM.md](PLATFORM.md).

## Build and run

```bash
open ios/OhanaOS.xcodeproj
```

1. Put your Supabase URL and anon key in `ios/Config/Local.xcconfig`
   (copy `Local.xcconfig.example`) or, for a simulator-only run, in
   `ios/OhanaOS/App/Config.swift`. `Local.xcconfig` wins when it is filled in.
   Photos and videos upload through the production admin app,
   `https://ohanaos.co` (`MEDIA_API_URL` in `ios/Config/Defaults.xcconfig`).
   Set `MEDIA_API_URL` in `Local.xcconfig` only to test another deployment.
2. Apply the migrations and deploy the `pair-device` and `assistant` edge
   functions (see the README).
3. In Supabase → Authentication → URL Configuration, add
   `ohanaos://auth-callback` to **Redirect URLs**. Email confirmations and admin
   email invites then open the app and sign you in. Without it, those links
   land on the Site URL and you sign in in the app by hand.
4. Pick an iPhone simulator or a device and run. Build with Xcode 16 or newer:
   the code relies on its SDK treating every SwiftUI `View` as `@MainActor`.

The app name on the Home Screen is **Ohana Display**. The Xcode project, the
software name (`CFBundleName`), and the company are **OhanaOS**. The bundle
id is `com.ohanaos.ohana`.

`ios/OhanaOS.xcodeproj` is the project Xcode opens. It is already signed for
team `92X9CP6C6D`, bundle id `com.ohanaos.ohana`, version 1.0.0 (1). The shared
scheme, `Package.resolved` (supabase-swift 2.55.3), and `Info.plist` are in
the repo. Xcode's personal UI state (`xcuserdata`, `UserInterfaceState.xcuserstate`)
stays on your Mac. `project.yml` describes the same target, minus the
archive-only **Check Release Config** build phase. Regenerating with XcodeGen
replaces the checked-in project, so open the `.xcodeproj` instead.
Siri needs no extra keys or entitlements: App Shortcuts are found by the App
Intents metadata step of a normal build.

## Code map

```
ios/OhanaOS/
├── App/
│   ├── OhanaOSApp.swift      RootView: loading (with retry) / welcome / family setup / tabs; deep links
│   ├── AskOhanaOSIntent.swift Siri: AskOhanaOSIntent + OhanaOSShortcuts (App Shortcuts)
│   └── Config.swift          Supabase URL and key (Local.xcconfig or the fallbacks), bucket names, auth callback URL,
│                             privacy policy and support URLs
├── Models/       Codable rows mirroring the migrations (snake_case keys), invites, profiles,
│                 assistant threads and messages, chat types, InviteCode, DayKey
├── Services/
│   ├── FamilyStore.swift     the one @Observable store: auth, invites, profile, family data, writes, assistant,
│   │                         account deletion
│   ├── AssistantClient.swift `assistant` function over URLSession: SSE streaming and quick answers
│   ├── MediaTools.swift      thumbnail + average-color cache, avatar cache, upload prep (JPEG, EXIF, posters, video optimizing)
│   ├── Dictation.swift       SFSpeechRecognizer push-to-talk for the assistant
│   └── DemoData.swift        Debug only: demo mode for screenshots (sample family, photos drawn in code)
├── Theme/Theme.swift         tokens, Mood, GlowView, card/pill/tag styles, MemberAvatar/AvatarCircle, SegmentedPill
└── Views/
    ├── Components/           floating tab bar, activity/approval cards, shared bits
    ├── OnboardingViews.swift welcome (invite code, create account, sign in), enter an invite code,
    │                         create family, invite-link sheet
    ├── ProfileView.swift     name, photo, email, manage family link, family switcher, assistant switch,
    │                         Siri tip, privacy and support links, sign out, delete account
    ├── InviteViews.swift     create invite, code card with share/copy, pending and accepted rows
    ├── HomeView.swift        Home + assistant hero card
    ├── AssistantView.swift   streaming chat, thread history, AI consent sheet
    ├── CalendarView.swift    month / week / day, event detail, add and edit event
    ├── ChoresView.swift      chores board, add chore
    ├── RewardsView.swift     balances, rewards, redemptions, add reward
    ├── MediaView.swift       media grid, viewer, upload
    └── FamilyView.swift      members (add/edit/remove, photos), manage family, invites, lists, meals,
                              memory, displays, leave family
```

## Screens

A floating capsule tab bar sits at the bottom. The selected tab is an accent
pill that slides between tabs. Your avatar at the top of Home and Family opens
your **Profile**.

| Tab | What's there |
|---|---|
| **Home** | Family name and date. The assistant card: glow arch, "How can I help you today?", suggestion chips, and an "Ask Ohana anything" pill with a mic button. Below it: "Waiting for your OK" approvals (parents only), today's chore progress per member, your upcoming activities, and dinner tonight (tap to plan it). |
| **Assistant** (full screen, from Home) | Chat bubbles: yours in the mood accent on the right, Ohana in white on the left. Replies stream in word by word; a typing indicator shows until the first words arrive. Green chips list what the assistant did (`actions`). The clock button opens your earlier chats (tap to reopen, swipe to delete); the pencil starts a new one. Suggestion chips show when the chat is empty, and each starts its own chat. The mic dictates with Apple's speech recognition (`SFSpeechRecognizer`, which may send the audio to Apple) and fills in the text field; you review it, then tap send. Before a person's first question goes out, the app asks for permission (see Assistant → AI consent). |
| **Calendar** | Day / Week / Month switcher. **Month** shows a grid with up to three colored bars per day and today as a filled circle; tap a day to open it in Day view. Your upcoming activities for that month are listed below. **Week** is a 7-column time grid with pastel blocks, member badges, an all-day row and a now line; tap a weekday header to open that day. **Day** is the same grid in a single column with times and places. Tap any event for details, to edit it (title, place, all-day, start/end, who), or to delete it. A repeating event shows on every day it repeats, and editing or deleting one repeat changes them all. Events from a connected calendar say where they're from and can't be edited here. The **+** button adds an event; **↻** opens Connected calendars. |
| **Chores** | **Chores**: approvals first (parents), then one card per member with progress, animated point balance and today's chores. Tap the circle to mark a chore done on someone's behalf. On a chore that needs a parent's OK, a parent's tap is approved right away and anyone else's waits for a parent; other chores count at once. Unassigned chores sit in an "Anyone" card with a picker for who did it. Long-press a chore to undo it or remove the chore (parents). Parents can unfold **Other chores** at the bottom: the ones not due today (another day's repeat, or a rule that has run out), with their repeat and who they're for; long-press one to remove it. **Rewards**: balance cards (parents get −5/+5), rewards waiting to be handed out (Done or Cancel to refund), and a rewards grid. **Redeem** spends a kid's points through `redeem_reward`. **+** adds a chore or reward. |
| **Media** | All / Photos / Videos filter and a grid grouped by month. Video tiles show a play badge and their length; an eye-slash badge marks items hidden from the wall frame. **+** opens the photo picker for multiple photos and videos. While they upload, a banner shows which item is going, what it is doing and a **Cancel** button. **Select** checks items in the grid (or Select all) and deletes them together after a confirmation. The full-screen viewer swipes between items, plays videos, toggles "On the wall frame", and deletes the one on screen after a confirmation. Its backdrop takes the current photo's average color. |
| **Family** | Members (tap to edit; parents can add one), invites (parents), lists (tap through to add, check off and clear items), meals for the next 7 days (tap a day to set breakfast, lunch and dinner), family memory (add a fact; parents can remove one), paired wall displays and **Pair a display** (parents), and Profile / Leave family. |

## Onboarding (invite-only)

Ohana is invite-only, so the first screen starts with the invite code.

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
   suspended also land here, because they can no longer see it. Sign out and
   **Delete account** are at the bottom.

The welcome screen links the privacy policy under its Create account / Sign in
button.

Server errors are shown as they come back from the RPCs (sentence-cased), so
the messages in PLATFORM.md → "Errors the apps show" appear verbatim.

### Deep links

The `ohanaos` URL scheme is registered in `project.yml`; `OhanaOSApp` passes
every URL to `FamilyStore.handleOpenURL`.

| Link | What happens |
|---|---|
| `ohanaos://invite/<CODE>` | Saves the code as pending. Signed out: prefills Welcome and checks it. No family: prefills "Enter an invite code". In a family already: a sheet offers to join that family (the app switches to it) or start a new one. Dismissing it forgets the code. |
| `ohanaos://auth-callback…` | Finishes an email link: implicit-grant tokens in the fragment (admin email invites) go to `auth.setSession`, a PKCE `code` (sign-up confirmations) to `auth.session(from:)`. A pending family invite is then accepted as in step 3. Any app or web page can open an `ohanaos://` link, so tokens are ignored while someone is already signed in ("Sign out first to use that link"); a PKCE code can't be replayed, because it only works with the verifier this iPhone stored at sign-up. |

The parent's share sheet text includes both the link and the code, so the code
still works for someone who opens the message on another device.

## Profile

From the avatar on Home or Family. Edit your display name (`profiles`), and
optionally use it on the family screen too (your `members` row). **Photo**:
pick one with `PhotosPicker`; it's cropped to a 512 px square JPEG, uploaded
to `avatars/<uid>/avatar.jpg` (upsert, lowercase uid to match the storage
policy), and `profiles.avatar_path` is set. **Remove photo** clears both. Also
shows your email, family and role; a family picker when you belong to more
than one; **Manage family** (see Family management); the **Assistant**
switch (see Assistant → AI consent); **Connected calendars** (below); the Siri tip; **Privacy policy** and
**Help and support** (`https://ohanaos.co/privacy` and `/support`, `Config`);
and **Sign out**.

**Delete account** sits below Sign out. Its alert says what happens for the
family on screen: if nobody else in it has a login, the family is deleted
too (calendar, chores, photos, displays); otherwise the family keeps your
name on its screen, your points and what you added. `FamilyStore.deleteAccount`
posts to `/api/account/delete` on `Config.mediaAPIURL`'s origin with your
session, then signs out on the phone. The admin app runs the
`delete-account` edge function and clears that family's photos and videos
from Blob; the rules are in [PLATFORM.md](PLATFORM.md) → "Deleting your
account". A refusal is shown as the server words it, for example "You're the
only parent with a login in The Smiths. Make someone else there a parent
first".

Member avatars everywhere (`MemberAvatar`) show the photo of the member's
account when there is one, else the photo a parent set for the member
(`members.avatar_path`), else the initial on the member's color. Photos are
downloaded from the private bucket with the session and cached per path and
`profiles.updated_at`, so a new photo replaces the old one on the next
refresh. Member photos get a new file name each time, so the path alone
versions them.

## Connected calendars

Profile → Connected calendars, or **↻** on the Calendar tab
(`Views/CalendarSyncView.swift`, `Services/CalendarSync.swift`). The server
side is the `calendar-sync` function ([PLATFORM.md](PLATFORM.md) →
Connected calendars).

- **Showing in Ohana**: each calendar with its color, where it's from
  (Google and the account, or a link's host), its person, Busy only, how many
  events and when it last updated, or why it didn't. Everyone sees the list;
  parents tap a calendar to rename it, choose who it's for and its color,
  show it as Busy, turn it off, sync it, or remove it. **Sync now** and
  pull to refresh sync them all. When the app loads and a calendar hasn't
  been tried for 15 minutes, it asks the server to catch up (at most every
  10 minutes) and reloads if events changed.
- **Connect Google Calendar** (parents): Google's sign-in opens in an
  `ASWebAuthenticationSession` sheet through SwiftUI's
  `webAuthenticationSession`, and the function sends it back to
  `ohanaos://google-calendar` with a code, which the app sends to
  `google_finish` with its own session. Then **Choose calendars** lists the
  account's calendars with the main one ticked. The parent who connected an
  account can choose more calendars or sign in again (when Google stopped
  accepting Ohana); other parents see who connected it, can't turn Busy off
  on its calendars, and can disconnect it.
- **Add a calendar link** (parents): a `webcal://` or `https://` link, an
  optional name, who it's for, Busy, and a color, with where to find the
  link in iCloud, Google, Outlook and on school or team sites. The server
  reads the calendar before saving, so a bad link stays in the form with the
  reason.
- **Show Ohana in other calendars** (parents): create the family's calendar
  link, add it to Apple Calendar (`webcal://`, which opens Calendar's
  Subscribe sheet) or Google Calendar (`calendar.google.com/calendar/r?cid=`),
  copy it for Outlook, share it, make a new one, or stop sharing.

`FamilyEvent.sourceId` (`event_occurrences.source_id`) marks an imported
event: its details show "From <calendar>" and its description, and have no
Edit or Delete. Loading the calendars fails quietly (a log line), so the app
works against a server without calendar sync yet.

## Family management

- **Manage family** (Profile → Family, `ManageFamilyView`) lists everyone on
  the family screen with their role and whether they have a login. Parents
  get **Add a member** and **Invite someone** there too. The Family tab's
  member strip opens the same editors.
- **Adding** (parents): name, role, color and an optional photo. The photo
  is uploaded first, under the new member's client-made id, and the row is
  inserted with its `avatar_path`; if the insert fails the file is deleted.
  Either way nothing is half-added, and a failure keeps the sheet open.
- **Members.** Tap a member to edit. Parents can change anyone's name, color
  and role, and remove a member (with their chores, points and photo).
  Everyone else can edit only their own name, color and photo; other members
  aren't tappable for them. The server's `members_guard` has the final say:
  it refuses to remove, demote or unlink the last parent with an account, and
  the error is shown.
- **Photos.** The camera badge on the editor's circle, or **Add a photo** /
  **Choose a new photo** / **Remove photo**, stage a change that **Save**
  applies. Your own photo is your profile photo (as in Profile). A parent
  sets the photo of a member without a login: it's cropped to a 512 px square
  JPEG, uploaded to `avatars/<family_id>/<member_id>-<random>.jpg`, and
  `members.avatar_path` is set; then the old file is deleted. A member with a
  login chooses their own photo, so their editor says so instead. See
  PLATFORM_SPEC.md §1.7.
- **Invites** (parents). **Invite** opens a form: who it's for ("Someone new"
  with a role, or an existing member without a login, who then claims their row
  and points), an optional email (only that address can use it), and how long
  it works (1–60 days). It calls `create_family_invite`, then shows the code
  with **Share** (share sheet text with the code and the
  `ohanaos://invite/CODE` link) and **Copy code**. The Family tab lists pending
  invites (share, copy, revoke via `revoke_family_invite`) and the last few
  accepted ones (who joined and when). A member without a login has an
  "Invite {name} to get a login" button in their editor.
- **Leave family** calls `leave_family`: your account is unlinked, your member
  row stays on the screen with its points. The last parent can't leave.

Everything the app loads is filtered to the family on screen, so someone in two
families sees one at a time; the choice is remembered on the phone.

## Assistant

- **AI consent.** Guideline 5.1.2(i) asks for explicit permission before
  personal data goes to a third-party AI. Before a person's first question,
  the app shows a sheet, "Before you ask Ohana" (`AIConsentSheet` in
  `AssistantView.swift`). It says the assistant is AI, that the question and
  the family details it needs to answer (names, calendar, chores and points,
  rewards, meals, lists and family memory) are sent to Anthropic, which
  makes the Claude model, and that nothing is sent until you allow it. It
  links the privacy policy. **Allow** stores the answer and sends the
  question you were about to ask; **Not now** sends nothing and keeps your
  text. The answer is kept per account on each iPhone, as a `UserDefaults`
  bool at `ohanaos.aiConsent.<user id, lowercased>`. `FamilyStore` exposes
  `hasAIConsent` (false when signed out), `allowAI()` and `revokeAI()`, and
  `ask` sends nothing without consent. Every way of sending goes through
  the sheet: the Home "Ask Ohana anything" pill and suggestion chips, the
  assistant screen's send button and its chips, and dictation then send.
  Opening the assistant screen or reading old chats needs no consent.
  Profile → **Assistant** has the toggle "Send questions to the AI
  assistant"; turning it off revokes the answer. Deleting the account
  clears it too.
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
  "I couldn't reach Ohana".
  Non-200 answers show the function's `{error}` message (401 asks you to sign
  in again; 403 covers a suspended family or no family).
- After a reply that did something (actions), the app reloads the family data.
- Dictation only fills in the text field. Sending it goes through the AI consent sheet like a typed question.

## Siri

`AskOhanaOSIntent` (`App/AskOhanaOSIntent.swift`) is an `AppIntent` with one
parameter, `question`. `perform()` calls the assistant with `mode: "quick"`,
`stream: false` and no thread (`AssistantClient.quickAnswer`), and returns the
reply as both the spoken dialog and the intent's value, so Shortcuts can use
it. It runs without opening the app, using the session saved in the keychain;
signed out, Siri says "Sign in to Ohana Display on your iPhone first." If the
signed-in person hasn't allowed the assistant on this iPhone (see Assistant →
AI consent), Siri says "Open Ohana Display and allow the assistant first."
and doesn't call the assistant. It asks you to unlock the iPhone first
(`authenticationPolicy = .requiresAuthentication`), so a locked phone doesn't
read out the family's plans.

`OhanaOSShortcuts` (an `AppShortcutsProvider`) registers "Ask Ohana Display", "Ask
Ohana Display a question" and "Ask my family assistant in Ohana Display",
because those phrases use the app name. A String parameter
can't be part of a phrase, so Siri then asks "What would you like to ask
Ohana?". Each Siri question starts its own thread, which then shows up in the
app's chat history. The Profile screen shows a `SiriTipView` for it.

## Demo mode (screenshots)

Debug builds have a demo mode for the App Store screenshots.
`Services/DemoData.swift` and every hook that reads it are inside `#if DEBUG`,
so Release and TestFlight builds contain none of it. Launch arguments turn it
on; they land in `UserDefaults`' argument domain.

| Argument | Values | What it does |
|---|---|---|
| `-OhanaDemo YES` | | Loads a sample family. Supabase and the network are never called. |
| `-OhanaScreen <name>` | `home` (default), `assistant`, `calendar-week`, `calendar-month`, `chores`, `rewards`, `media`, `family` | What is on screen at launch. `assistant` opens the chat over Home. `rewards` is the Rewards side of Chores. |
| `-OhanaMood <name>` | `morning`, `day` (the default in demo mode), `evening`, `night` | Pins the time-of-day palette, so screenshots don't follow the clock. |

The family is The Rivera Family. Sofia, the signed-in parent, and Marco both
have logins. Maya (9) has a login and Leo (6) doesn't. Every date is relative
to today: this week's school pickups, soccer, piano, a dentist visit, a
birthday party, family dinner and an all-day apple-picking trip, plus the
weeks around it. The pickups, piano and soccer are repeating events, one
row per repeat, as `event_occurrences` returns them. Today's chores are
partly done, with one waiting for a parent's OK. Demo mode doesn't call
`chores_due`: the phone works out which chores are up from their own rules
(`demoDueTaskIds`, daily or weekly on named days), which puts every one of
them on today. There are rewards and balances with one redemption to hand out,
a grocery list, dinners for the next 7 days, family memory, a paired display,
invites, two assistant chats (the open one is on the Assistant screen), and
14 photos and 2 videos. The pictures are drawn in code and go into the same
thumbnail and average-color cache the grid and the viewer read. The week and
day grids start at 8:00 whatever the time.

Taps change only what's on the phone (a chore marked done, an approval, an
item checked off) or do nothing. Pull to refresh, sign out, invites and
display pairing send nothing. An upload shows an alert saying demo mode
sends nothing. The AI consent sheet never shows: demo mode counts as
allowed. A new question to the assistant gets a reply saying this is a
demo. Demo videos have no file to play.

To try it in Xcode, add `-OhanaDemo YES` (and, say, `-OhanaScreen media`)
under Product → Scheme → Edit Scheme → Run → Arguments. In a booted
simulator:

```bash
xcrun simctl launch booted com.ohanaos.ohana -OhanaDemo YES -OhanaScreen calendar-week -OhanaMood day
```

CI relaunches the Debug simulator build once per screen with these arguments
and saves each screen as a PNG (CI → App Store screenshots).

## CI

`.github/workflows/ios.yml` runs on pull requests that touch `ios/**` or the
workflow, and on demand (Actions → iOS → Run workflow). It does not run on
pushes to `main`: macOS runners use minutes at ten times the Linux rate. On
`macos-15` it selects the newest stable Xcode (`maxim-lobanov/setup-xcode`,
failing if that's older than 16), then works on the checked-in project,
unsigned:

1. `plutil -lint` on the project file, `Info.plist`, the privacy manifest and
   `ExportOptions.plist`, and `bash -n` on the scripts.
2. A Debug simulator build:

   ```bash
   xcodebuild -project OhanaOS.xcodeproj -scheme OhanaOS -sdk iphonesimulator \
     -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
   ```

3. A check that the built `Info.plist` has `MediaAPIURL` `https://ohanaos.co`,
   bundle id `com.ohanaos.ohana`, `ITSAppUsesNonExemptEncryption` false, and
   that `PrivacyInfo.xcprivacy` is in the app.
4. An unsigned Release archive for `generic/platform=iOS` with stand-in
   Supabase values, the same build a TestFlight upload uses. It checks the
   archive's `MediaAPIURL`, then archives once more with no Supabase values and
   expects **Check Release Config** to stop it.

Swift packages are checked out into `.spm` and cached on the hash of
`Package.resolved` (supabase-swift 2.55.3). When a step fails, the
`xcodebuild` logs are uploaded as the `xcodebuild-log` artifact. macOS jobs
only start while the GitHub account's billing and Actions spending limit
allow it. Otherwise each run fails in seconds with "recent account payments
have failed or your spending limit needs to be increased".

Two more macOS workflows use the same setup. `.github/workflows/testflight.yml`
uploads a build to TestFlight, on demand only (see TestFlight → Upload from
GitHub Actions). `.github/workflows/screenshots.yml` takes the App Store
screenshots.

### App Store screenshots

`.github/workflows/screenshots.yml` runs on the same pull requests as the iOS
workflow, and on demand (Actions → App Store screenshots → Run workflow). A
pull request that touches `ios/**` therefore runs two macOS jobs.

It builds the Debug app for the simulator once, unsigned and with no
Supabase values: demo mode uses a built-in family and never calls the
network. Then it takes two sets of the same screens, one for each iPhone size
App Store Connect asks for:

| Folder | Simulator | Size |
|---|---|---|
| `6.9-inch` | iPhone 17 Pro Max, or iPhone 16 Pro Max | 1320×2868 |
| `6.3-inch` | iPhone 17 Pro, or iPhone 16 Pro | 1206×2622 |

Both use the newest iOS runtime that is no newer than the selected Xcode's
simulator SDK and has a device for each set, so a beta runtime on the image
is never used. For each set the job creates a fresh simulator, boots it, and
sets light appearance and a 9:41 status bar with full Wi-Fi, cellular and
battery. For each screen it relaunches the app with `-OhanaDemo YES
-OhanaScreen <screen> -OhanaMood day`, waits 6 seconds for images and
animations, and saves a PNG. It flattens any alpha channel, because App Store
Connect refuses one. Then it deletes the simulator. The files, the same in
both folders:

| File | Screen |
|---|---|
| `01-home.png` | Home |
| `02-assistant.png` | Assistant |
| `03-calendar-week.png` | Calendar, Week |
| `04-calendar-month.png` | Calendar, Month |
| `05-chores.png` | Chores |
| `06-rewards.png` | Chores → Rewards |
| `07-media.png` | Media |
| `08-family.png` | Family |

The job fails if a set doesn't have all 8 files, if a PNG isn't a size App
Store Connect takes for its slot (1320×2868 or 1290×2796 for 6.9-inch,
1206×2622 or 1179×2556 for 6.3-inch), if a PNG still has an alpha channel,
or if two PNGs in a set are identical, which means demo mode didn't load.
The run's summary page lists each file and its size, and the PNGs are in its
**app-store-screenshots** artifact, in the folders `6.9-inch` and `6.3-inch`
(Artifacts, at the bottom of the summary page; kept 30 days). Upload them as
described in [APP_STORE.md](APP_STORE.md) → 7. Screenshots (the medium
display size, 6.3-inch, is required).

## TestFlight

Upload from a Mac with **Xcode 26 or newer**, or from GitHub Actions (see
"Upload from GitHub Actions" below). App Store Connect has required the iOS 26
SDK since April 2026. In Xcode → Settings → Accounts, sign in with an Apple ID
on team `92X9CP6C6D`. The first archive needs an Admin or the Account Holder,
because Xcode creates the Apple Distribution certificate. The text App Store
Connect asks for, field by field, for TestFlight and for the App Store, is in
[APP_STORE.md](APP_STORE.md).

1. **Register the bundle id.** developer.apple.com → Certificates, Identifiers
   & Profiles → Identifiers → **+** → App IDs → App. Use Description
   `Ohana Display` and an Explicit Bundle ID of `com.ohanaos.ohana`. Add no
   capabilities: the app has no entitlements, app groups or push.
2. **Create the app record.** App Store Connect → Apps → **+** → New App.
   Set Platform to iOS and Name to `Ohana Display`. If that name is taken,
   pick another; the Home Screen name stays Ohana Display. Primary Language:
   English (U.S.). Bundle ID: `com.ohanaos.ohana`. SKU: `ohanaos-ios`. Then,
   under App Information, set the primary category to Lifestyle. A record
   made earlier for the old id `com.homeos.app` does not match this build.
   Either create the new record, or set `OHANAOS_BUNDLE_ID = com.homeos.app`
   in `Local.xcconfig` to keep the old one.
3. **Fill in `ios/Config/Local.xcconfig`.** Copy
   `ios/Config/Local.xcconfig.example` (the copy is gitignored). Write each URL
   as `https:/$()/host`.
   - `SUPABASE_URL`: `https:/$()/<project-ref>.supabase.co`
   - `SUPABASE_ANON_KEY`: the anon (publishable) key. Archives refuse a
     `service_role` or `sb_secret_` key.
   - `MEDIA_API_URL`: leave it out, and the default is `https://ohanaos.co`.
     Delete an empty `MEDIA_API_URL =` line, or one with the old
     `your-admin-app.vercel.app` placeholder. Archives refuse both.
   - `OHANAOS_TEAM_ID` and `OHANAOS_BUNDLE_ID`: set these only to change the
     team or bundle id. The old names `HOMEOS_TEAM_ID` and `HOMEOS_BUNDLE_ID`
     are ignored.
4. **Archive and upload.** From the repo root:

   ```bash
   ios/scripts/archive-for-testflight.sh --upload
   ```

   The script checks those values, then archives Release. The build number is
   the UTC time as `YYYYMMDD.HHMM`, so every upload is new and higher. Use
   `OHANA_BUILD_NUMBER=<n>` to override it. The script then checks the
   archived `Info.plist`. It exports with `ios/Config/ExportOptions.plist`
   (`app-store-connect`, automatic signing, your team) and uploads. Without
   `--upload`, it writes `ios/build/export/Ohana.ipa` for the Transporter
   app. The version stays `1.0.0` (`MARKETING_VERSION`); raise it in Xcode
   (target → General → Version) for the next release. In Xcode itself,
   Product → Archive runs the same check (the **Check Release Config** build
   phase). Then use Organizer → Distribute App → TestFlight & App Store, and
   keep **Manage Version and Build Number** checked. If the archive stops with
   "Your team has no devices", run the app on your iPhone from Xcode once.
   With no Apple ID signed in to Xcode, set `ASC_KEY_PATH` (the `.p8` file),
   `ASC_KEY_ID` and `ASC_ISSUER_ID` to sign in with an App Store Connect API
   key instead. The archive is then ad hoc signed, and the export uses the
   key to sign with the cloud-managed Apple Distribution certificate.
5. **Add internal testers.** App Store Connect → Apps → Ohana Display →
   TestFlight → Internal Testing → **+**. Create a group (for example,
   `Family`) and turn on automatic distribution. Add testers. They must be
   users under Users and Access (up to 100). Processing takes about 5–30
   minutes. Then testers get an email and install through the TestFlight app.
   Internal builds skip Beta App Review.
6. **Before anyone outside the team installs it,** deploy what the app's
   newer screens call, or Delete account answers with an error:
   - the migration `20261010000001_account_deletion.sql` (`supabase db push`)
     and `supabase functions deploy delete-account`;
   - the admin app on Vercel, for `/api/account/delete`, `/privacy` and
     `/support`. Open `https://ohanaos.co/privacy` and `/support` signed out
     to check them. Both say to write to `support@ohanaos.co`
     (`admin/lib/site.ts`): make sure that mailbox exists, or change it there.
7. **Fill in Test Information** (App Store Connect → Ohana Display →
   TestFlight → Test Information). External testers and Beta App Review need
   it. Use the text in [APP_STORE.md](APP_STORE.md) → 1. TestFlight → Test
   Information.
8. **Give Beta App Review a way in.** The app is invite-only, so the
   reviewer needs an account that is already in a family:
   1. Create a platform invite in the admin console (Invites).
   2. In the app, sign up with that code as, for example,
      `appreview@<your domain>` with a password you don't use elsewhere.
      Confirm the email if confirmation is on.
   3. Create a family named `App Review` and add a few events, chores,
      rewards and a photo, so each tab has something to show.
   4. Invite your own account into that family as a second parent and
      accept it. Then the reviewer can try **Delete account** without taking
      the family with them; recreate the review account afterwards if they
      do.
   5. Create a second platform invite for reviewers to try sign-up, with a
      few uses and 90 days, so it outlasts both reviews. Its code goes in
      place of `<XXXX-XXXX>` in both sets of Review Notes
      ([APP_STORE.md](APP_STORE.md), sections 1 and 5).
   6. In Test Information → Beta App Review Information, turn on **Sign-in
      required**, enter that email and password, and add your name, phone
      and email as the contact. For **Notes**, use the Review Notes block in
      [APP_STORE.md](APP_STORE.md), section 1.
9. **Add external testers.** TestFlight → External Testing → **+** to
   create a group, add the build, then **Submit for Review**. The first build
   of each version is reviewed (usually within a day or two); later builds of
   that version usually go out without another review. Testers join by email
   or a public link (up to 10,000).

Export compliance is already answered (see below), so no build waits on
"Missing Compliance".

What the binary already answers, so the upload is not blocked on them:

- App icon, the same house-on-gradient mark as `admin/app/icon.svg`, full
  bleed at 1024 px with no transparency (`OhanaOS/Assets.xcassets`).
- Launch screen color, the warm canvas `#F1EFEB` (night `#121317`).
- Export compliance: only standard HTTPS, so `ITSAppUsesNonExemptEncryption`
  is false and App Store Connect does not ask again on each build.
- Privacy manifest (`OhanaOS/PrivacyInfo.xcprivacy`). The app reads
  `UserDefaults` for the pending invite, the family on screen and each
  account's AI consent (reason `CA92.1`). It does not track. Data linked to
  the account, for the app to function: email, name, user id, photos and
  videos, other content (events, chores, rewards, lists, meals, memory,
  chat), and other usage data (one `assistant_usage` row per assistant
  request, with the user id and token counts). Use those same answers in the
  App Store Connect privacy questionnaire ([APP_STORE.md](APP_STORE.md),
  section 4). Dictation uses Apple's speech recognizer and is not stored by
  Ohana Display. The Swift packages (supabase-swift 2.55.3 and its
  dependencies) call no required-reason API, and swift-crypto ships its own
  manifest.
- AI consent (guideline 5.1.2(i)): before a person's first assistant
  question, the app asks once per account on each iPhone, names Anthropic
  and says what is sent. Siri sends nothing until the person has allowed
  it in the app. See Assistant → AI consent.
- Account deletion (guideline 5.1.1(v)): Profile → Delete account, and on
  "Enter an invite code" for accounts without a family. It deletes the
  account on the server, not only the session.
- A privacy policy link in the app (welcome screen and Profile) and a
  support page, both on `https://ohanaos.co`.
- Usage descriptions: photo library, microphone and speech recognition
  (dictation), and camera. The camera text is for scanning the display's
  pairing code, which the app doesn't request yet. The app uses no local
  network, notifications or location.
- iPhone only, portrait, iOS 17.0 or later, HTTPS only (no App Transport
  Security exceptions).
- An archive can't ship a placeholder or a secret. The **Check Release
  Config** phase (`ios/scripts/check-release-config.sh`) runs only for
  archives. It fails on an empty or placeholder `SUPABASE_URL`,
  `SUPABASE_ANON_KEY` or `MEDIA_API_URL`, and on a `service_role` or
  `sb_secret_` key.
- A build with no Supabase URL stays on the loading screen and says it is
  not connected, instead of opening Welcome against a placeholder host.

Signing is automatic. Unsigned CI (`CODE_SIGNING_ALLOWED=NO`) does not need a
team. A device run uses the team in `Local.xcconfig`, or `92X9CP6C6D` by
default.

### Upload from GitHub Actions

`.github/workflows/testflight.yml` archives and uploads on a `macos-15`
runner, so no Mac is needed. It runs only on demand. Steps 1 and 2 above
(bundle id and app record) still come first: an upload does not create the
app record.

1. **Create an App Store Connect API key.** App Store Connect → Users and
   Access → Integrations → App Store Connect API → Team Keys → **+**. Name
   it, for example `GitHub Actions`, and give it the **Admin** role. No Apple
   ID is signed in on the runner, so Xcode uses the key to create the Apple
   Distribution certificate and provisioning profiles in the cloud
   (cloud-managed signing), and that needs Admin. Download the `.p8` file
   (`AuthKey_<Key ID>.p8`). App Store Connect offers the download only once.
   The **Issuer ID** is shown on that page above the list of keys, and the
   **Key ID** in the key's row.
2. **Add the repository secrets.** GitHub → the repository → Settings →
   Secrets and variables → Actions → **New repository secret**:

   | Secret | Value |
   |---|---|
   | `SUPABASE_URL` | `https://<project-ref>.supabase.co`, written normally, with no path. The workflow refuses a path or spaces, and writes it into `Local.xcconfig` as `https:/$()/…`. |
   | `SUPABASE_ANON_KEY` | the anon (publishable) key |
   | `ASC_KEY_ID` | the Key ID |
   | `ASC_ISSUER_ID` | the Issuer ID |
   | `ASC_API_KEY_P8` | the whole `.p8` file, `-----BEGIN PRIVATE KEY-----` to `-----END PRIVATE KEY-----`, or its base64 (`base64 -i AuthKey_<Key ID>.p8 \| pbcopy`) |

3. **Run it.** Actions → TestFlight → Run workflow. Leave **Build number**
   empty to use the UTC time (`YYYYMMDD.HHMM`), or enter a number higher
   than the last upload. The build shows up in TestFlight once processing
   finishes; then carry on from step 5 above.

The workflow selects the newest stable Xcode and stops if it is older than
26. It checks that every secret is set and names any that are missing. It
writes `ios/Config/Local.xcconfig` and the key file (`$RUNNER_TEMP/AuthKey.p8`,
readable only by the runner user), then runs
`ios/scripts/archive-for-testflight.sh --upload` with `ASC_KEY_PATH`,
`ASC_KEY_ID` and `ASC_ISSUER_ID` set. Both files are deleted at the end, also
after a failure. The key is never printed, and GitHub masks the secrets in
the run log. A failed run uploads the `xcodebuild-log` artifact: the
script's output and the export logs. Artifacts are not masked, so it shows
the Supabase URL, which ships in the app anyway, and the API Key ID and
Issuer ID, which are useless without the .p8 file. One upload runs at a
time; a second run waits for the first.

With the API key, the archive is ad hoc signed, as Xcode Cloud does, and
never contacts the developer website. So the runner needs no development
certificate and the team needs no registered device. The export then uses
the key to sign with the cloud-managed Apple Distribution certificate and an
App Store profile. On a Mac with an Apple ID signed in, the script signs the
archive for development, as Xcode does, and re-signs it at export.

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
- Events come from `event_occurrences(fid, range_start, range_end)`, 45 days
  back to 120 days ahead. The server expands repeating events in the family's
  time zone and returns one row per repeat, so a weekly practice shows every
  week. PostgREST stops a response at 1000 rows, so the app reads the window a
  page at a time (`.range`) until a page comes back short.
  `FamilyEvent.eventId` is the stored event, and every write names it; `id`
  (event plus start) only tells the repeats apart on screen. Editing a repeat
  moves the whole series: its stored start goes as many calendar days as that
  repeat did, at the new time of day, and keeps the new length, so a date moved
  across a DST change keeps its local time and an all-day series stays at
  midnight. Deleting one removes every repeat, past and future.
- Chores due today come from `chores_due(fid, day)` with the phone's local
  date. The server follows each repeating chore's rule from its due date (or
  the day it was added); a one-time chore stays up until it's done. Only
  today's are loaded, so on a new day the app reloads when it comes to the
  foreground, at the significant time change (midnight), or when the network
  comes back (`NWPathMonitor`). Until that load gets through, nothing counts as
  due, and Home and Chores say "Today's chores haven't loaded yet" instead of
  "No chores today". Parents find the chores that aren't due today under
  **Other chores**. Completions use the phone's local date for `for_date`.
- A parent marking a chore done inserts the completion and then calls
  `review_completion(approve: true)`. A rejected completion from earlier the
  same day is deleted first, because of the unique key on (task, member, date).
  Only parents may delete completions (RLS), so anyone else retrying a rejected
  chore is asked to get a parent to undo it first.
- Photos are re-encoded as JPEG (at most 2560 px on the long side) before
  upload, so the display never has to decode HEIC. `taken_at` comes from EXIF
  `DateTimeOriginal`. New photos and videos go to the private Blob store.
  The row records `byte_size` (the file only), `content_type`,
  `thumbnail_path` (when the poster went up) and `file_store = blob`.
  Videos are optimized for the wall first (see
  [Photo and video uploads](#photo-and-video-uploads)). `duration_seconds`
  and the creation date are read through `AVURLAsset` from the original, and
  the size from the file that is uploaded. The picker hands the app a movie
  file; the upload streams the file to Blob
  (`URLSession.upload(for:fromFile:)`) instead of reading the whole clip into
  memory. `Config.mediaAPIURL` is the admin app's origin: `https://ohanaos.co`
  unless `Local.xcconfig` sets another. Photo type sent is
  `image/jpeg`. Video types are `video/quicktime` (`.mov`), `video/mp4`,
  `video/m4v`, `video/webm`, `video/x-matroska`, `video/3gpp`, and
  `video/3gpp2`. If inserting the row fails, the Blob object just uploaded is
  removed, and the media API removes its poster with it. Deleting (one item
  in the viewer, or several from Select) removes a Blob object and its
  poster through the media API, then each `media_items` row with the
  signed-in member's session. Rows still in Storage then lose the file and
  poster from `family-media`. That is the family RLS path, not the admin
  console. Profile avatars still use the `avatars` bucket.
- Signed URLs (1 hour) are cached per path, for files and posters alike.
  Blob files (`file_store = blob`) use `POST /api/media/urls` on that same
  origin; opening Media signs every Blob row's poster and file up front, up
  to 200 paths per request. Rows still in Storage use a Storage signed URL.
  Thumbnails, average colors and avatars are cached in memory for the
  session.
- UUIDs sent to the `assistant` function are lowercase, because it compares
  ids as strings.
- The app sends `family_id` (the family on screen) to the `assistant`
  function alongside the spec's fields, so people in two families get answers
  about the one they're looking at. The function accepts it as optional.
- The app can't read `platform_settings`, so it always asks for an invite
  before Create account, even if an admin turns `invite_only` off.

## Photo and video uploads

Everything goes to the private Blob store through the admin app
(`Config.mediaAPIURL`). The wall panel is 1920×1200 and the Pi 5 decodes HEVC
in hardware ([HARDWARE.md](HARDWARE.md)), so videos are made right for it on
the phone, before they upload. The code is `MediaTools.prepareVideo` and
`MediaView.upload`.

**Videos**

- The picker hands over the original file
  (`preferredItemEncoding: .current`) instead of transcoding it first.
- A clip the wall already plays well goes as it is: HEVC or H.264, 8-bit
  SDR, at most 1920 px on the long side, at most 31 fps and at most 16 Mb/s,
  in a `.mov`, `.mp4` or `.m4v`. If its index (`moov`) comes after the
  media, it is first copied into a new `.mov` with the index first (no
  re-encode), so the wall can start playing before the whole file has
  arrived.
- Anything else is exported with `AVAssetExportPresetHEVC1920x1080` to an
  `.mp4` with the index first: HEVC, at most 1080p. HDR and 10-bit clips are
  rendered as SDR Rec. 709. Clips above 31 fps are capped at 30 fps.
- If the HEVC export fails, the app tries H.264 1080p
  (`AVAssetExportPreset1920x1080`). It does the same when the HEVC file
  still comes out HDR.
- If the export is at least 90% of the original's size and the original
  plays well on the wall, the original goes instead (with its index moved
  first if needed).
- If optimizing fails in any other way, the original is uploaded as it is.
- One file is stored per item: the optimized file takes the original's
  place, and no copy of the original is kept. Blob items uploaded before
  this keep their original file and have no poster; adding a clip again
  gives it both.
- Every export, the index-first copy included, drops location metadata
  (`.forSharing()`); the date was read before.
- iOS stops exports in the background, so an export only starts while Ohana
  is the active app. An export that fails while Ohana isn't active, or with
  `AVError.operationInterrupted`, fails that item with "A video stopped
  optimizing when Ohana left the screen. Keep Ohana open while videos
  upload, then add it again." There is no fallback for that item: a large
  original couldn't upload in the background either.
- Debug builds print one line per video: what was done, the codec, bit
  depth, transfer function, size, frame rate, bitrate, file size before and
  after, and the time it took.

**Posters**

- Each upload carries a JPEG poster of at most 256 KiB
  (`MediaTools.posterMaxBytes`, the admin app's `THUMB_MAX_BYTES`). A
  photo's is 480 px. A video's is up to 960 px, from the file that is
  uploaded: the first of a few early frames that isn't nearly black. If the
  JPEG is too big, the quality steps down, and for a video then the size
  (to 640 px).
- The upload request sends `thumbnail_bytes`. The poster is `PUT` to the
  ticket's `thumbnail.upload_url` before the file, and `thumbnail_path` is
  set in the insert: the database doesn't let a member set it later. A
  poster that isn't signed or doesn't go up never fails the upload; that row
  just has no poster.
- The grid shows the poster when the row has one, and otherwise the photo
  or a frame from the video, as before. The viewer shows a video's poster
  under a spinner until its player is ready.

**Order, progress and Cancel**

- Items upload one at a time; the next item is fetched from Photos and
  optimized while the current one uploads.
- The banner shows "Uploading 2 of 5", what the current item is doing
  ("Getting the video from Photos…", "Optimizing for the wall display…
  40%", "Uploading 12 MB of 48 MB", "Saving…"), and the next item's
  optimizing progress. The bar counts an optimized video's export as 40% of
  the item and its bytes as the rest. Bytes sent are reported at most every
  100 ms.
- **Cancel** stops the export or upload in progress and the one being
  prepared, and deletes their temp files. A file that is already up still
  gets its row. The grid then refreshes, and the "N of M didn't upload"
  message is not shown.
- At the start of each batch, `.mov`, `.mp4` and `.m4v` files left in the
  temp folder for more than a day (after a crash or a force quit) are
  deleted.

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
`if case .error = event` at the end of `AssistantClient.stream`. Added with
server-side repeats: `.range(from:to:)` after `rpc(_:params:)` in
`FamilyStore.eventOccurrences` (2.55.3 defines it on
`PostgrestTransformBuilder`, which `rpc`'s `PostgrestFilterBuilder`
inherits), and the `NWPathMonitor` feeding an `AsyncStream<Void>` in
`App/OhanaOSApp.swift`. Demo mode (`Services/DemoData.swift` and its
`#if DEBUG` hooks) has not been compiled or run yet. Check first:
`nonisolated private static func mood(at:)` in `MoodProvider`,
`await DemoMedia.fullImage(for:)` in `MediaPage`, the local `Series` struct
in `DemoFamily` and the `FamilyEvent(eventId:…)` initializer, and that
`-OhanaScreen assistant` opens the chat over Home. The AI consent gate
(`AIConsentSheet`, `FamilyStore.hasAIConsent`, the check in
`AskOhanaOSIntent.perform`) has not been compiled either. The riskiest
calls from the first build:

- `@Environment(FamilyStore.self) private var store: FamilyStore?` (the
  optional observable environment initializer) in `MemberAvatar`
  (`Theme/Theme.swift`).
- App Intents in `App/AskOhanaOSIntent.swift`: `static let description:
  IntentDescription?` (whether the requirement is optional),
  `authenticationPolicy = .requiresAuthentication`,
  `@Parameter(title:requestValueDialog:)` with a string literal,
  `ParameterSummary`, `.result(value:dialog:)` with
  `IntentDialog(stringLiteral:)`, and
  `AppShortcut(intent:phrases:shortTitle:systemImageName:)`.
- `SiriTipView(intent:)` in a `Form` row in `Views/ProfileView.swift`.
- `URLSession.shared.bytes(for:)` and iterating `AsyncBytes` byte by byte in
  `AssistantClient.stream`; and the `@MainActor` event callback awaited from
  that nonisolated method.
- `ShareLink(item: String) { label }` in `Views/InviteViews.swift` (two
  places).
- The `@Observable` stored property with a `private(set)` initializer reading
  `UserDefaults` (`pendingInviteCode` in `FamilyStore`).
- Decoding a scalar RPC result (`uuid`) straight into `UUID` in
  `FamilyStore.acceptInvite` and `FamilyStore.createFamily`.
- From before: `supabase.storage.from(_:).remove(paths:)` (in
  `FamilyStore.removeAvatar` and `removeStoredFiles`; it exists in 2.55.3),
  `AVAudioApplication.requestRecordPermission()` as `async -> Bool` (iOS 17,
  `Dictation`), the `AVAsyncProperty` loads in `MediaTools.videoMetadata(at:)`,
  and `nonisolated init()` on the `@Observable @MainActor` `Dictation` class.

Connected calendars came after those builds too (both new files pass the
tree-sitter parse). Calls to check first if CI breaks:
`@Environment(\.webAuthenticationSession)` and
`authenticate(using:callbackURLScheme:)` with `catch let error as
ASWebAuthenticationSessionError where error.code == .canceledLogin` in
`ConnectedCalendarsView.connectGoogle`; `if` around `ToolbarItem` in
`.toolbar` (`ConnectedCalendarsView`, `EventDetailView`); and
`supabase.functions.invoke` decoding into local `Decodable` structs (2.55.3's
`invoke<T: Decodable>(_:options:decoder:)` with a plain `JSONDecoder`). On a
device: connect a Google account (and cancel once), add an iCloud public
calendar link, turn Busy on and off, and subscribe to the family link in
Apple Calendar.

Video optimizing, posters and upload progress came after those builds and
have not run on an iPhone yet. Calls to check first if CI breaks:
`PhotosPicker(...preferredItemEncoding: .current)`
(`Views/MediaView.swift:71`); `track.load` with three keys and
`format.extensions[.transferFunction]?.propertyListRepresentation`
(`Services/MediaTools.swift:338`–`:344`);
`AVMutableVideoComposition.videoComposition(withPropertiesOf:)` (`:476`);
`metadataItemFilter = .forSharing()` (`:531`); `await session.export()`
with `cancelExport()` in a cancellation handler (`:544`); and
`URLSession.upload(for:from:delegate:)` and `upload(for:fromFile:delegate:)`
(`Services/FamilyStore.swift:1274` and `:1294`). On a device, try a 4K60 HDR
portrait clip, a 1080p SDR clip, a Slo-Mo clip, an H.264 clip, photos,
Cancel during an export, and leaving Ohana during an export. The debug line
for each video shows whether the HEVC preset writes 8-bit, the size of a
portrait clip, and the bitrate.

## Next

- Realtime subscriptions for live updates while the app is open.
- Sign in with Apple.
- Scanning the pairing QR code with `DataScannerViewController`.
- A unit-test target (SSE parsing, invite code formatting) once CI runs tests.
