# iOS app

The iPhone companion to the wall display. It shares the Supabase backend, so a
change on the phone shows up on the wall (and vice versa) on the next refresh.
SwiftUI, iOS 17+, the Observation framework, and
[supabase-swift](https://github.com/supabase/supabase-swift) 2.x.

## Build and run

```bash
brew install xcodegen
cd ios && xcodegen && open HomeOS.xcodeproj
```

1. Put your Supabase URL and anon key in `ios/HomeOS/App/Config.swift`.
2. Deploy the `pair-device` and `assistant` edge functions (see the README).
3. Pick an iPhone simulator or a device and run. Build with Xcode 16 or newer:
   the code relies on its SDK treating every SwiftUI `View` as `@MainActor`.

`project.yml` is the source of truth for the project. Don't edit the generated
`.xcodeproj` or `Info.plist`; change `project.yml` and run `xcodegen` again.
It declares the photo library, camera, microphone and speech recognition usage
strings.

## Code map

```
ios/HomeOS/
├── App/          HomeOSApp (RootView: loading / sign-in / create family / tabs), Config
├── Models/       Codable rows mirroring the migrations (snake_case keys), chat types, DayKey
├── Services/
│   ├── FamilyStore.swift   the one @Observable store: auth, queries, writes, assistant chat
│   ├── MediaTools.swift    thumbnail + average-color cache, upload prep (JPEG, EXIF, video metadata)
│   └── Dictation.swift     SFSpeechRecognizer push-to-talk for the assistant
├── Theme/Theme.swift       tokens, Mood, GlowView, card/pill/tag styles, MemberAvatar, SegmentedPill
└── Views/
    ├── Components/         floating tab bar, activity/approval cards, shared bits
    ├── HomeView.swift      Home + assistant hero card
    ├── AssistantView.swift assistant chat
    ├── CalendarView.swift  month / week / day, event detail, add event
    ├── ChoresView.swift    chores board, add chore
    ├── RewardsView.swift   balances, rewards, redemptions, add reward
    ├── MediaView.swift     media grid, viewer, upload
    ├── FamilyView.swift    members, lists, meals, memory, displays, pairing
    └── OnboardingViews.swift
```

## Screens

A floating capsule tab bar sits at the bottom. The selected tab is an accent
pill that slides between tabs.

| Tab | What's there |
|---|---|
| **Home** | Family name and date. The assistant card: glow arch, "How can I help you today?", suggestion chips, and an "Ask homeOS anything" pill with a mic button. Below it: "Waiting for your OK" approvals (parents only), today's chore progress per member, your upcoming activities, and dinner tonight (tap to plan it). |
| **Assistant** (full screen, from Home) | Chat bubbles: yours in blue on the right, homeOS in white on the left. Green chips list what the assistant did (`actions`). There's a typing indicator, suggestion chips when the chat is empty, a text field, and a send or mic button. The mic dictates with on-device speech recognition and fills in the text field; you review it, then tap send. The conversation stays on the phone until you start a new one. |
| **Calendar** | Day / Week / Month switcher. **Month** shows a grid with up to three colored bars per day and today as a filled circle; tap a day to open it in Day view. Your upcoming activities for that month are listed below. **Week** is a 7-column time grid with pastel blocks, member badges, an all-day row and a now line; tap a weekday header to open that day. **Day** is the same grid in a single column with times and places. Tap any event for details or to delete it. The **+** button adds an event (title, place, all-day, start/end, who). |
| **Chores** | **Chores**: approvals first (parents), then one card per member with progress, animated point balance and today's chores. Tap the circle to mark a chore done on someone's behalf. A parent's tap is approved right away; anyone else's waits for a parent. Unassigned chores sit in an "Anyone" card with a picker for who did it. Long-press a chore to undo it or remove the chore (parents). **Rewards**: balance cards (parents get −5/+5), rewards waiting to be handed out (Done or Cancel to refund), and a rewards grid. **Redeem** spends a kid's points through `redeem_reward`. **+** adds a chore or reward. |
| **Media** | All / Photos / Videos filter and a grid grouped by month. Video tiles show a play badge and their length; an eye-slash badge marks items hidden from the wall frame. **+** opens the photo picker for multiple photos and videos. The full-screen viewer swipes between items, plays videos, toggles "On the wall frame", and deletes. Its backdrop takes the current photo's average color. |
| **Family** | Members (parents can add one and pick a color), lists (tap through to add, check off and clear items), meals for the next 7 days (tap a day to set breakfast, lunch and dinner), family memory (add a fact; parents can remove one), paired wall displays and **Pair a display** (parents), and sign out. |

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
have transitions, and the glow slowly breathes.

## Data notes

- Pull to refresh reloads everything. Realtime subscriptions aren't wired up
  yet.
- Events load from 45 days back to 120 days ahead. Recurring events (`rrule`)
  aren't expanded yet; only the first occurrence shows.
- Chores count as due today from a simple read of their RRULE: `FREQ=DAILY`, or
  `FREQ=WEEKLY;BYDAY=…`. A one-time chore stays up until it's done. Completions
  use the phone's local date for `for_date`.
- A parent marking a chore done inserts the completion and then calls
  `review_completion(approve: true)`. A rejected completion from earlier the
  same day is deleted first, because of the unique key on (task, member, date).
- Photos are re-encoded as JPEG (at most 2560 px on the long side) before
  upload, so the display never has to decode HEIC. `taken_at` comes from EXIF
  `DateTimeOriginal`. Videos are uploaded as-is, with `duration_seconds`, size
  and creation date read through `AVURLAsset`.
- Signed URLs (1 hour) are cached per storage path. Thumbnails and average
  colors are cached in memory for the session.

## Unverified

The code was written without an Xcode toolchain. Every file passes a
tree-sitter Swift parse, so the syntax is valid, but it hasn't been
type-checked or run. Expect a short round of compile fixes. These are the
calls to check first:

- `supabase.functions.invoke(_:options:)` decoding straight into
  `AssistantReply` (the generic `-> T: Decodable` overload) in
  `FamilyStore.ask`.
- `supabase.storage.from(_:).remove(paths:)` in `FamilyStore.deleteMedia`.
- `AVAudioApplication.requestRecordPermission()` as `async -> Bool` (iOS 17) in
  `Dictation.authorize`.
- `AVAsyncProperty` loads (`.duration`, `.naturalSize` + `.preferredTransform`,
  `.creationDate`, `.dateValue`) in `MediaTools.videoMetadata`.
- `nonisolated init()` on the `@Observable @MainActor` `Dictation` class.

## Next

- Realtime subscriptions for live updates while the app is open.
- Sign in with Apple.
- RRULE expansion for recurring events.
- Scanning the pairing QR code with `DataScannerViewController`.
- Streaming large video uploads from disk instead of loading them into memory.
