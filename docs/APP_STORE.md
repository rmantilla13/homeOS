# App Store and TestFlight copy

Everything App Store Connect asks for to put Ohana Display in front of
external TestFlight testers and then on the App Store, field by field. Copy
each grey block as it is: the copy button at its top right keeps the line
breaks. How to build and upload, and the demo account, are in
[IOS.md](IOS.md) → TestFlight. The counts at the end were checked with a
script.

The app as it ships: iPhone only, portrait, iOS 17 or later, version 1.0.0,
bundle id `com.ohanaos.ohana`, team `92X9CP6C6D`. Every claim here was
checked against the code, the privacy manifest
(`ios/OhanaOS/PrivacyInfo.xcprivacy`) and the privacy policy
(`admin/app/(public)/privacy/page.tsx`), and every rule against Apple's
pages as of 2026-10-07 (Sources, at the bottom).

Things the copy deliberately doesn't claim, because the app doesn't do
them: notifications, widgets, live updates (changes show after a refresh),
writing to other calendars (connected calendars are read-only), offline use, an iPad or Android
app, a web app for families, or end-to-end encryption.

## 1. TestFlight → Test Information

App Store Connect → Apps → Ohana Display → TestFlight → Test Information
(under Additional). External testers and Beta App Review need it. Apple's
help pages give no limits for these TestFlight fields. Everything below is
far shorter than the 4,000 characters the matching App Store fields allow.

**Invitation Experience.** Leave **App Information** checked. Until a version
is approved for the App Store there's nothing for it to pull in.

**Beta App Description** (required)

```text
Ohana Display keeps a family's calendar, chores and points, rewards, meal plans, shopping lists and photos in one place, on everyone's iPhone and on an Ohana wall display at home if the family has one. It includes an AI assistant, built on Anthropic's Claude, that answers questions about your family's plans and can add things for you, and you can ask it through Siri ("Ask Ohana Display").

Ohana Display is invite-only: you need an invite code from your family, or from us, to create an account. This beta covers the iPhone app. The wall display is separate hardware and isn't needed to test.
```

**Feedback Email**: `support@ohanaos.co`. It is also the reply-to address on
tester invitations.

**Marketing URL**: `https://ohanaos.co/support`

**Privacy Policy URL**: `https://ohanaos.co/privacy`

### Beta App Review Information

| Field | Value |
|---|---|
| First name | `<owner first name>` |
| Last name | `<owner last name>` |
| Phone number | `<+country code and number>`, for example `+1 555 010 0000`. The field needs the plus sign. |
| Email | `<owner email>` |
| Sign-in required | On |
| User name | `<appreview@your-domain>`, the account from [IOS.md](IOS.md) → TestFlight, step 8 |
| Password | `<that account's password>`. The demo account must not expire, so leave it alone while the build is in review. |

**Review Notes**. Replace `<XXXX-XXXX>` with a real code first (section 8,
step 3).

```text
Ohana Display is invite-only: a new account needs an invite code from a family or from us. The account above is already a parent in a demo family called "App Review", with sample events, chores, rewards and photos, so you can sign in without a code. To try sign-up instead, use invite code <XXXX-XXXX>; it starts a new family.

The wall display is separate hardware. The app works without one, so please skip Family > Pair a display.

The assistant ("Ask Ohana anything" on Home) is AI, built on Anthropic's Claude. The first time you ask the assistant, the app explains that the question and family details go to Anthropic and asks for permission; Profile has a switch to turn it off. Siri: say "Ask Ohana Display", then a question. Siri answers once you've allowed the assistant in the app.

Delete account is under Profile (tap the avatar at the top of Home), at the bottom. The demo family has a second parent, so deleting the demo account doesn't delete the family. If you delete it, tell us and we'll recreate it.
```

### What to Test (build of 1.0.0)

TestFlight → the build under iOS Builds → Test Details → What to Test. Each
build has its own. The build numbers look like `20261007.1430` (the upload
time in UTC); they are all version 1.0.0.

**What to Test**

```text
First external build of Ohana Display 1.0.0.

You need an invite code to sign up. Ask whoever invited you to this beta, or write to support@ohanaos.co.

Please try:
1. Sign up with your code, then join your family or create one.
2. Calendar: add an event, edit it, and switch between Day, Week and Month. Parents: tap ↻ to bring in a Google, iCloud or school calendar.
3. Chores: check one off. If the chore needs a parent's OK, a kid's check-off waits for it. Parents can add chores with +.
4. Rewards: redeem points for a reward. Parents can add rewards with +.
5. Media: add a few photos and a short video, then open the viewer.
6. Family: add to a list and plan a meal. Parents can also invite someone.
7. Assistant: the first time, it asks before anything goes to the AI. Then ask "What's on this week?", and ask it to add something.
8. Siri: say "Ask Ohana Display", then your question.
9. Parents with a wall display: pair it from Family > Pair a display.

Known gap: other people's changes appear after you pull to refresh.

Send feedback from the TestFlight app, or email support@ohanaos.co.
```

## 2. App Store listing (version 1.0.0)

Name and subtitle are under **App Information**. The rest is on the
**1.0.0 Prepare for Submission** page.

**App Name** (2 to 30 characters)

```text
Ohana Display
```

If App Store Connect says the name is taken, use one of these. They keep
"Ohana Display" up front, so the App Store name still matches the name on
the Home Screen (guideline 2.3.8 asks for the two to be similar). The Home
Screen name stays Ohana Display either way.

**App Name, fallback 1**

```text
Ohana Display: Family Planner
```

If you use fallback 1, use these Keywords instead, so "planner" isn't
repeated:

```text
kitchen,organizer,schedule,rewards,points,meal,grocery,list,photo,frame,assistant,household,wall,hub
```

**App Name, fallback 2**

```text
Ohana Display by OhanaOS
```

**Subtitle** (30 characters)

```text
Family calendar & chore chart
```

**Promotional Text** (170 characters; can be changed later without a new
version)

```text
One calendar, chore chart, meal plan and set of photos for the whole family, on everyone's iPhone and your wall display if you have one. Invite-only: you'll need a code.
```

**Description** (4,000 characters, plain text)

```text
Ohana Display keeps your family's week in one place: the calendar, chores and points, rewards, meal plans, shopping lists and photos. Everyone in the family sees it on their own iPhone, and on the Ohana wall display at home if you have one.

INVITE-ONLY FOR NOW
To join, you need an invite code from someone in your family, or an invite email from us. To start a new family, ask for a code at support@ohanaos.co. A parent invites the other grown-ups and can give older kids their own login. Younger kids don't need an account to have their own chores, points and color.

CALENDAR
• Month, week and day views, color-coded by person
• Add events with a place, times and who's going
• Tap any event to change or delete it
• Bring in Google, iCloud, Outlook, school and team calendars, or show them as Busy
• See the family calendar in Apple Calendar, Google Calendar or Outlook

CHORES AND POINTS
• A card for each person with today's chores and progress
• Chores can need a parent's OK before the points count
• Points add up as chores get done

REWARDS
• Parents set the rewards, like a movie night or a trip for ice cream
• Redeem points for a reward; a parent marks it done once it's handed out

PHOTOS AND VIDEOS
• Add photos and videos from your library
• Choose which ones show in the wall display's photo frame
• Stored privately and shown through links that expire

MEALS, LISTS AND FAMILY MEMORY
• Plan breakfast, lunch and dinner for the week ahead
• Shared lists, like groceries, that anyone in the family can add to and check off
• Save the things that matter, like routines or who carpools with whom

THE OHANA ASSISTANT (AI)
Ask about your calendar, chores, meals and lists in plain words, by typing or by talking. The assistant is AI, built on Anthropic's Claude. It answers from your family's own information, and it can add events, chores, list items and meals for you, then tells you what it did. Like any AI, it can get things wrong, so check anything important. Other people in your family can't see your chats with it.

SIRI
Say "Ask Ohana Display", then your question, for a quick spoken answer. Siri asks you to unlock your iPhone first, so a locked phone doesn't read out your family's plans.

THE WALL DISPLAY IS OPTIONAL
The app works fully on its own. If your family also has an Ohana wall display, a touchscreen for the kitchen or hallway, a parent pairs it from the Family tab with the 6-digit code it shows, and what you add on your phone shows up there too.

MADE FOR THE WHOLE HOUSE
• Colors follow the time of day, from a coral morning to a violet evening
• Dark mode
• In more than one family? Switch between them from your profile

PRIVACY
• No ads, no tracking and no analytics, and we don't sell your data
• What your family adds is shared with the people in your family, your paired displays and the companies that run Ohana for us, named in our privacy policy
• When you use the assistant, your question and the family details it needs to answer it go to Anthropic, the AI provider. The app asks for your permission before your first question. We don't use your family's content to train AI models.
• Dictation uses Apple's speech recognition
• Delete your account in the app: tap your avatar, then Delete account

Questions or feedback? Write to support@ohanaos.co.
```

**Keywords** (100 bytes, commas, no spaces). The name, the subtitle and the
developer name are already searchable, so their words (ohana, display,
family, calendar, chore, chart, OhanaOS) and the category names aren't
repeated. "kids" is left out on purpose: guideline 2.3.8 reserves "For Kids"
wording for the Kids category, and the app isn't in it.

```text
planner,organizer,schedule,rewards,points,meal,grocery,list,photo,frame,assistant,household,wall,hub
```

| Field | Value |
|---|---|
| Support URL | `https://ohanaos.co/support` |
| Marketing URL | `https://ohanaos.co/support` |
| Privacy Policy URL | `https://ohanaos.co/privacy` (App Store Connect keeps it under App Privacy) |
| Copyright | `2026 OhanaOS` (App Store Connect adds the © itself) |
| Primary category | Lifestyle (matches `LSApplicationCategoryType` in `Info.plist`) |
| Secondary category | Productivity |
| Version release | **Manually release this version.** After approval the version waits in Pending Developer Release, so launch day is yours, after the backend checks in section 8. |
| What's New in This Version | Not needed: App Store Connect has no such field for the first version. Every later version needs it. |
| App previews (video) | None |

## 3. Age rating

App Information → Age Ratings → **Set Up Age Ratings** (Edit, once set).
The questionnaire has the in-app controls and capabilities first, then one
page per group, then Age Categories and Override. In the first step, No
means leave the box unchecked. Apple asks you to count what an AI assistant
can say. The assistant here is told to answer from the
family's data and to keep it kid-safe, and it can't browse the web.

| Question | Answer | Why |
|---|---|---|
| **In-app controls** | | |
| Parental Controls | Yes (check it) | Parents set each member's role. On chores that need a parent's OK, children's check-offs wait for one, and only parents can add chores and rewards, invite, pair a display or remove family memory. It doesn't change the rating. |
| Age Assurance | No | The app doesn't check anyone's age. |
| **Capabilities** | | |
| Unrestricted Web Access | No | No in-app browser. The privacy policy and help links open ohanaos.co in Safari, as does any link in an assistant reply, and the assistant has no web tools. |
| User-Generated Content | No | Apple's definition is broadly distributed content. What a family adds reaches only that invite-only family and its paired displays. |
| Social Media | No | No feed, likes, follows or discovery. |
| Social Media Disabled for Users Under 13 | No | No social media at all. |
| Messaging and Chat | No | Members can't message each other. Assistant chats are between one person and the AI, and other people in the family can't see them. |
| Advertising | No | No ads. |
| **Mature Themes** | | |
| Profanity or Crude Humor | None | Not in the app; the assistant is told to keep it kid-safe. |
| Horror/Fear Themes | None | Not in the app. |
| Alcohol, Tobacco, or Drug Use or References | None | Not in the app. |
| **Medical or Wellness** | | |
| Medical or Treatment Information | None | The app gives no medical guidance. |
| Health or Wellness Topics | None | Meal plans are just what's for each meal; no diet, calorie or exercise advice. |
| **Sexuality or Nudity** | | |
| Mature or Suggestive Themes | None | Not in the app. |
| Sexual Content or Nudity | None | Not in the app. |
| Graphic Sexual Content and Nudity | None | Not in the app. |
| **Violence** | | |
| Cartoon or Fantasy Violence | None | Not in the app. |
| Realistic Violence | None | Not in the app. |
| Prolonged Graphic or Sadistic Realistic Violence | None | Not in the app. |
| Guns or Other Weapons | None | Not in the app. |
| **Chance-Based Activities** | | |
| Gambling | No | No betting of any kind. |
| Simulated Gambling | None | None. |
| Contests | None | Chore points are a family's own tally that parents control. There are no rankings, leaderboards or competitions. |
| Loot Boxes | No | Nothing for sale, nothing random. |
| **Age Categories and Override** | Not Applicable | Don't pick Made for Kids: the Kids category forbids links out of the app without a parental gate and sending children's data to third parties such as the AI provider. No override needed. |
| Age Suitability URL (optional) | Leave empty | |

**Expected rating: 4+** in every region (AL on the Brazil storefront).

Two answers are judgment calls. If App Review reads the family's shared
photos and notes as user-generated content, answering Yes keeps 4+
everywhere except Brazil (A6), and guideline 1.2 then expects ways to
filter, report and block content. If you count chore points as contests,
Infrequent keeps 4+; Frequent would make the app 13+.

## 4. App Privacy (the nutrition label)

App Store Connect → App Privacy → Get Started (Edit, later). "Do you or your
third-party partners collect data from this app?" **Yes.** Then pick these
types. All six match `ios/OhanaOS/PrivacyInfo.xcprivacy` and the privacy
policy.

| Data type (group) | What it is in Ohana Display | Linked to the user | Used for tracking | Purposes |
|---|---|---|---|---|
| Name (Contact Info) | Your display name; names of family members on the family screen | Yes | No | App Functionality |
| Email Address (Contact Info) | Your sign-in email; an invite can name the invitee's email; the email of a Google account a parent connects for calendars | Yes | No | App Functionality |
| User ID (Identifiers) | Your account id | Yes | No | App Functionality |
| Photos or Videos (User Content) | Photos and videos you add to Media, and your profile photo | Yes | No | App Functionality |
| Other User Content (User Content) | Events (including copies from calendars a parent connects), chores, rewards, lists, meals, family memory, and your assistant chats | Yes | No | App Functionality |
| Other Usage Data (Usage Data) | One row per assistant request (who asked, token counts), kept to enforce each family's daily limit | Yes | No | App Functionality |

The last row is `NSPrivacyCollectedDataTypeOtherUsageData` in
`PrivacyInfo.xcprivacy` (linked, not tracking, App Functionality). The
privacy policy covers it under "Usage counts". The `assistant_usage` rows
carry the user id, so it is linked.

The consent screen (section 8, step 4) doesn't change these answers. It
decides whether a question is sent at all, not what is sent.

Not collected, so leave unchecked:

- **Audio Data.** Dictation runs through Apple's speech recognizer
  (`SFSpeechRecognizer`) and only the text reaches Ohana. Apple's rule:
  "You are not responsible for disclosing data collected by Apple." The
  same goes for Siri.
- Location, Contacts, Health and Fitness, Financial Info, Sensitive Info,
  Browsing and Search History, Purchases, Device ID (the app never reads
  the advertising identifier), Product Interaction, Advertising Data,
  Diagnostics (no crash or analytics SDK), Customer Support (support
  happens by email, outside the app), Surroundings, Body.

Nothing is used for tracking, so the product page will have no "Data Used
to Track You" section, only "Data Linked to You" with the types above.
Leave the optional **User Privacy Choices URL** empty.

## 5. App Review Information (App Store submission)

On the 1.0.0 page, under App Review Information.

| Field | Value |
|---|---|
| Sign-in required | On |
| User name | `<appreview@your-domain>` |
| Password | `<that account's password>`. Apple says the demo account must not expire, so leave it alone while the version is in review. |
| First name | `<owner first name>` |
| Last name | `<owner last name>` |
| Phone number | `<+country code and number>` |
| Email | `<owner email>` |
| Attachment | None |

**Notes** (4,000 bytes). Replace `<XXXX-XXXX>` with the same code as in
section 1.

```text
Ohana Display is invite-only: a new account needs an invite code from a family or from us. The demo account above is already a parent in a demo family called "App Review", so no code is needed to sign in. Each tab has sample events, chores, rewards and photos.

The wall display is separate hardware: a touchscreen for the home that runs our own software. The app works fully without it, and you don't need one to review the app. Only Family > Pair a display needs a display, so please skip it. We can send a short video of pairing if you'd like one.

Delete account: tap the avatar at the top of Home (or Family) to open Profile. Delete account is at the bottom, below Sign out. The demo family has a second parent, so deleting the demo account doesn't delete the family. If you delete it, tell us and we'll recreate it.

The assistant ("Ask Ohana anything" on Home) is AI. It runs on Anthropic's Claude through our server, answers from the family's own data, and can add events, chores, list items and meals. Our privacy policy names Anthropic as a service provider. The first time you ask the assistant, the app explains that the question and family details go to Anthropic and asks for permission; Profile has a switch to turn it off.

Siri: say "Ask Ohana Display", then a question. Siri asks you to unlock the iPhone first. Until you've allowed the assistant in the app, Siri says to open the app and allow it first, and sends nothing.

The microphone in the assistant is for dictation. It uses Apple's speech recognition and asks for microphone and speech recognition access. The camera usage text is for a later feature (scanning a display's pairing code); this version never asks for the camera.

No in-app purchases, ads or tracking.

To try sign-up, use invite code <XXXX-XXXX>; it starts a new family. Anyone can ask for a code at support@ohanaos.co.
```

## 6. Other questions

| Question | Answer |
|---|---|
| Export compliance | Nothing to answer. `Info.plist` sets `ITSAppUsesNonExemptEncryption` to false (the app uses only standard HTTPS), so App Store Connect doesn't ask, for TestFlight builds or for the App Store. |
| Content rights: does the app contain, show or access third-party content? | **No.** It shows only what the family adds, and the assistant's replies. |
| Advertising Identifier (IDFA), if asked | **No.** No ad SDKs; the app doesn't use AdSupport or App Tracking Transparency. |
| Sign in with Apple | Not required. Guideline 4.8 asks for an equivalent login only when an app uses a third-party or social login, and says another login service is not required if "your app exclusively uses your company's own account setup and sign-in systems". Ohana Display has only its own email and password accounts. |
| Pricing | Free is what the app is built for: there are no in-app purchases. The price is the owner's call (Pricing and Availability → Price Schedule). |
| Availability | The owner's call. Two suggestions. Leave out China mainland: it needs an ICP filing number, and generative AI services there need their own approval. Under the same page, turn off availability on Apple silicon Macs and Apple Vision Pro until the app has been tried there; it's built and tested for iPhone in portrait only. |
| Digital Goods and Services questionnaire (App Information; only if it appears) | "Can customers consume digital goods and services in this app?" **No.** Nothing is sold in the app. Revisit if a paid plan is ever added. |
| EU Digital Services Act trader status | The owner declares it. App Store Connect asks on the first submission even if the app isn't offered in the EU. A trader's address, phone and email are shown on the EU product page. |
| Accessibility Nutrition Labels | Voluntary for now. Skip, or fill in once VoiceOver and Larger Text have been checked. |
| License agreement | Apple's standard license agreement. |
| Made for Kids | No (see section 3). |

## 7. Screenshots

**Required sizes.** Apple requires at least one screenshot for "iPhone
with Dynamic Island (medium display)" (iPhone 14 Pro to iPhone 18 Pro):
1206 × 2622 or 1179 × 2556 portrait. The screenshots workflow makes two
sets of the same 8 screens, each on its own simulator, so nothing needs
resizing. Upload both.

| Folder in the artifact | Size | App Store Connect slot | Simulator |
|---|---|---|---|
| `6.3-inch` | 1206 × 2622 | iPhone with Dynamic Island (medium display). Required. | iPhone 17 Pro, or iPhone 16 Pro |
| `6.9-inch` | 1320 × 2868 | iPhone with Dynamic Island (large display), which takes 1260 × 2736, 1290 × 2796 or 1320 × 2868 | iPhone 17 Pro Max, or iPhone 16 Pro Max |

App Store Connect scales these down for the older iPhone sizes. The
foldable iPhone Duo has its own slot, which Apple doesn't mark as required.

**Limits.** 1 to 10 screenshots per size, `.png`, `.jpg` or `.jpeg`, with no
alpha channel or transparency. The workflow flattens any alpha channel and
fails if one is left.

**Where.** The 1.0.0 page → Product Page Information → App Previews and
Screenshots → iPhone → **View All Sizes in Media Manager**. Drag each
folder's files into its slot, in the order below.

**Where they come from.** The **App Store screenshots** GitHub Actions
workflow (`.github/workflows/screenshots.yml`; Actions → App Store
screenshots → Run workflow). It builds the app once. Then it opens each
screen in demo mode on a 6.9-inch simulator, and again on a 6.3-inch one,
at 9:41 with full bars, in light appearance and the day colors. The PNGs
are in the run's **app-store-screenshots** artifact, in the folders
`6.9-inch` and `6.3-inch` (kept 30 days). The run fails if a file has the
wrong size or an alpha channel, or if two screenshots in a set are the
same, which means demo mode didn't load. Demo mode shows a built-in family,
which keeps real people's data out of the screenshots (guideline 2.3.9).

The set of 8, in order, with the same file names in both folders. The
captions are short enough to set as a headline above each screenshot later,
if you want framed marketing images. The raw screenshots work as they are;
anything added to them must still show the app in use and suit a 4+
audience.

| # | File | Screen | Caption |
|---|---|---|---|
| 1 | `01-home.png` | Home: assistant card, today's chores, upcoming, dinner | Your family's day at a glance |
| 2 | `02-assistant.png` | Assistant chat | Ask the AI assistant |
| 3 | `03-calendar-week.png` | Calendar, Week | Everyone's week, by color |
| 4 | `04-calendar-month.png` | Calendar, Month | The whole month on one screen |
| 5 | `05-chores.png` | Chores | Chores, points and a parent's OK |
| 6 | `06-rewards.png` | Chores → Rewards | Points turn into rewards |
| 7 | `07-media.png` | Media | Photos and videos for the wall |
| 8 | `08-family.png` | Family: members, invites, lists, meals | Invites, lists and meal plans |

## 8. What the owner still does by hand

In order. [IOS.md](IOS.md) → TestFlight has the detail for steps 1 to 5.

1. Register the bundle id and create the app record (IOS.md steps 1 and 2).
   Upload a build with the TestFlight workflow (IOS.md → Upload from
   GitHub Actions).
2. Deploy what the app calls (IOS.md step 6): the account-deletion
   migration, the `delete-account` function and the admin app. Open
   `https://ohanaos.co/privacy` and `/support` signed out, and make sure
   `support@ohanaos.co` receives mail.
3. Create the review account and its "App Review" family with sample
   events, chores, rewards and photos, plus a second parent (IOS.md step 8).
   Then create a platform invite in the admin console (Invites) for
   reviewers to try sign-up: a few uses and 90 days, so it outlasts both
   reviews. Put its code in place of `<XXXX-XXXX>` in both sets of Notes
   (sections 1 and 5).
4. AI consent is done. Guideline 5.1.2(i) reads: "You must clearly disclose
   where personal data will be shared with third parties, including with
   third-party AI, and obtain explicit permission before doing so." Before a
   person's first assistant question, the app shows "Before you ask Ohana".
   It says the assistant is AI, that the question and the family details it
   needs to answer (names, calendar, chores and points, rewards, meals, lists
   and family memory) go to Anthropic, which makes the Claude model, and
   that nothing is sent until the person allows it. It links the privacy
   policy. **Allow** sends the question; **Not now** sends nothing and keeps
   the text. It asks once per account on each iPhone, and every way of
   sending a question goes through it: the Home pill and chips, the
   assistant's send button and chips, and dictation. Profile → Assistant has
   a switch to turn it off. Siri sends nothing until the person has allowed
   it in the app. Before that, it says "Open Ohana Display and allow the
   assistant first." Submit a build that has the consent screen; uploads
   made before it went in don't.
5. Fill in Test Information (section 1), create an external group, add the
   build and **Submit for Review**. Send invite codes to external testers
   yourself; TestFlight can't.
6. App Information: subtitle, categories, content rights, age rating
   (section 3), the Digital Goods and Services questionnaire if it shows,
   and the EU trader status.
7. App Privacy: the Privacy Policy URL and the data types (section 4), then
   **Publish**. The build you submit must already have the usage-data entry
   in `PrivacyInfo.xcprivacy`. It went in with the consent screen, so a
   build with one has the other.
8. Pricing and Availability (section 6).
9. On the 1.0.0 page: both screenshot sets (section 7), promotional text,
   description, keywords, support and marketing URLs, copyright, the build,
   App Review Information (section 5) and the manual release option.
10. Before submitting: the Support URL must lead to contact details "as may
    be required by local law". The support page has an email only; add a
    postal address or phone there if your storefronts need one.
11. Outside App Store Connect: kids can have logins and use the assistant,
    and Anthropic's usage policy sets extra requirements for products that
    minors use. Read that section before launch.
12. **Add for Review**, then **Submit to App Review**. After approval,
    **Release This Version** when you're ready.

## Character counts

Counted with a Python script over the grey blocks above: characters (what
App Store Connect counts for text fields) and UTF-8 bytes (what it counts
for Keywords and App Review Notes). "Assumed" marks the TestFlight fields,
whose limits Apple doesn't publish. Captions have no Apple limit; 32
characters is ours, so they fit as a headline. Both sets of Notes are
counted with the `<XXXX-XXXX>` placeholder; a real code is 2 characters
shorter.

| Field | Limit | Characters | Bytes |
|---|---|---|---|
| Beta App Description | 4,000 chars (assumed) | 595 | 595 |
| TestFlight Review Notes | 4,000 bytes (assumed) | 1,019 | 1,019 |
| What to Test | 4,000 chars (assumed) | 1,036 | 1,036 |
| App Name | 30 chars | 13 | 13 |
| App Name, fallback 1 | 30 chars | 29 | 29 |
| App Name, fallback 2 | 30 chars | 24 | 24 |
| Subtitle | 30 chars | 29 | 29 |
| Promotional Text | 170 chars | 169 | 169 |
| Description | 4,000 chars | 3,147 | 3,191 |
| Keywords | 100 bytes | 100 | 100 |
| Keywords, with fallback 1 | 100 bytes | 100 | 100 |
| App Review Notes | 4,000 bytes | 1,862 | 1,862 |
| Caption 1 (01-home.png) | 32 chars (ours) | 29 | 29 |
| Caption 2 (02-assistant.png) | 32 chars (ours) | 20 | 20 |
| Caption 3 (03-calendar-week.png) | 32 chars (ours) | 25 | 25 |
| Caption 4 (04-calendar-month.png) | 32 chars (ours) | 29 | 29 |
| Caption 5 (05-chores.png) | 32 chars (ours) | 32 | 32 |
| Caption 6 (06-rewards.png) | 32 chars (ours) | 24 | 24 |
| Caption 7 (07-media.png) | 32 chars (ours) | 30 | 30 |
| Caption 8 (08-family.png) | 32 chars (ours) | 29 | 29 |

## Sources

Apple pages read on 2026-10-07:

- Screenshot specifications: https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications
- Upload app previews and screenshots: https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots
- Platform version information (Promotional Text, Description, Keywords, URLs, Copyright, What's New, version release, App Review Information): https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information
- App information (Name, Subtitle, Privacy Policy URL, Category, Content Rights, ICP filing, DSA): https://developer.apple.com/help/app-store-connect/reference/app-information/app-information
- Provide test information (TestFlight): https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information
- Set an app age rating: https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating
- Age ratings values and definitions: https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions
- Updated age ratings in App Store Connect (AI assistants count toward the rating): https://developer.apple.com/news/?id=ks775ehf
- Age rating questionnaire now includes social media questions: https://developer.apple.com/news/?id=tlur8uvi
- App privacy details: https://developer.apple.com/app-store/app-privacy-details/
- App Review Guidelines (last updated June 8, 2026; 1.2, 2.1, 2.3.7 to 2.3.10, 4.8, 5.1.1, 5.1.2): https://developer.apple.com/app-store/review/guidelines/
- Select an App Store version release option: https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/select-an-app-store-version-release-option
- Complete the Digital Goods and Services questionnaire: https://developer.apple.com/help/app-store-connect/manage-app-information/complete-the-digital-goods-and-services-questionnaire
- EU Digital Services Act trader requirements: https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements
- Overview of Accessibility Nutrition Labels: https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels

Anthropic's usage policy: https://www.anthropic.com/legal/aup
