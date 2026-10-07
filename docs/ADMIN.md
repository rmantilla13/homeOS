# Admin console

`admin/` is the web console for running Ohana as a platform: families,
accounts, invites, assistant usage and platform settings. It's a Next.js app
(App Router, React 19) that talks to the same Supabase project as the display
and the iOS app. The contract it implements is `docs/PLATFORM_SPEC.md` §3.

| Page | What it does |
|---|---|
| `/login` | Email and password sign-in. Only platform admins get past it. |
| `/` | Overview: totals from `admin_overview()`, a 30-day assistant usage chart (`admin_usage_by_day`), recent admin activity |
| `/families` | Search families by name or id |
| `/families/[id]` | Members, displays, family invites and 30-day usage. Suspend (with a reason), reactivate, delete (type the name to confirm) |
| `/users` | Search accounts by email or name. Make or remove admin, ban, unban, delete |
| `/invites` | Create platform invites (optional email lock, note, max uses, expiry), optionally email them; copy, revoke, see status |
| `/settings` | Invite-only sign-up, assistant on/off, requests per family per day, and the display boot video |
| `/audit` | Every admin action, newest first |
| `/privacy`, `/support` | Public: the privacy policy and help page the iOS app links to and App Store Connect lists. No sign-in, indexed. Text in `app/(public)`, contact address and policy date in `lib/site.ts` |

## How it works

- **Sign-in.** Supabase email and password through `@supabase/ssr`; the
  session lives in httpOnly cookies (only the server uses it).
  `admin/proxy.ts` (Next.js 16's name for middleware) refreshes the session
  on every request and sends anyone who isn't signed in to `/login`, and
  anyone who isn't a platform admin to `/login?error=not_admin`. Pages and
  server actions check again (`requireAdmin()` in `lib/data.ts`), and the
  database checks a third time: every `admin_*` RPC starts with
  `is_platform_admin()`.
- **One data module.** Every page and action reads and writes through
  `admin/lib/data.ts`. It calls the `admin_*` RPCs as the signed-in admin, and
  the `admin` edge function for what needs the service role: Supabase Auth's
  admin API (`invite_email`, `ban_user`, `unban_user`, `delete_user`) and
  Storage (`delete_family`, which runs `admin_delete_family` as the admin and
  then removes anything still in `family-media`; SQL alone leaves the files
  behind). This app then deletes that family's photos and videos from the
  private Blob store. Deleting a user removes their `avatars` folder
  the same way. In demo mode the same functions answer from fixtures instead
  (below).
- **No service role key.** The console only ever has the public anon key and
  the admin's own session. The privileged work happens in the `admin` edge
  function, which checks the caller is an admin before using its own service
  role key.
- **Mutations** are server actions (`app/(console)/actions.ts`). Each one
  checks the caller, validates its input, calls `lib/data.ts`, and re-renders
  the page. The RPCs and the edge function write the audit log.
- **Rendering.** Every page renders per request and reads the environment at
  request time, so one build works with any project, and `next build` needs no
  environment at all.
- **Look.** CSS modules plus the Ohana tokens in `app/globals.css`: warm
  canvas, white cards, accent `#4F7CF7`, the blue → coral → amber glow, Inter
  (self-hosted from `@fontsource-variable/inter`), and a dark variant that
  follows the system setting. No UI kit, no chart library: the usage chart is
  hand-drawn SVG (`components/UsageChart.tsx`) with a table view.

```
admin/
├── proxy.ts                  session refresh and admin gate
├── app/
│   ├── login/                sign-in page and action
│   └── (console)/            every signed-in page, layout and server actions
├── components/               UI pieces (shell, tables, dialogs, chart)
└── lib/
    ├── data.ts               the data-access module (Supabase or demo)
    ├── demo/                 demo fixtures and in-memory store
    ├── supabase/             server and proxy clients
    └── env.ts                request-time environment
```

## Local development

Needs Node 20.9 or later (CI uses 22) and a Supabase project with the platform
migrations applied (`backend/supabase/migrations`, including
`20261007000004_admin.sql`) and the `admin` function deployed.

```bash
cd admin
npm ci
cp .env.example .env.local      # then fill in the two values
npm run dev                     # http://localhost:3000
```

With the local Supabase stack (`cd backend && supabase start`), the URL is
`http://127.0.0.1:54321` and `supabase status` prints the anon key. Serve the
functions with `supabase functions serve` so the Users and Invites actions that
go through the `admin` function work.

Checks (CI runs the first three; see `PLATFORM_SPEC.md` §7):

```bash
npm run lint        # ESLint (eslint-config-next)
npm run typecheck   # next typegen && tsc --noEmit
npm run build
npm test            # node --test: sign-in redirects, colors, date formatting (Node 22)
```

## Environment variables

| Variable | Needed | What it is |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | yes | Project URL, e.g. `https://abcd.supabase.co` |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | yes | The anon (public) key. Safe to expose; RLS and the RPCs' admin checks protect the data |
| `NEXT_PUBLIC_ADMIN_DEMO` | no | `1` turns on demo mode. Leave it unset anywhere real admins sign in |

Never add `SUPABASE_SERVICE_ROLE_KEY` here. Nothing in the console reads it.

## Demo mode

Demo mode is for screenshots, design work and trying the console without a
backend:

```bash
NEXT_PUBLIC_ADMIN_DEMO=1 npm run dev
# or a production build
npm run build && NEXT_PUBLIC_ADMIN_DEMO=1 npm start
```

- Sign-in is skipped, and every page serves fixture data: 12 families,
  about 40 accounts and displays, invites in every state, 30 days of
  assistant usage and an audit trail. Names use reserved `example` domains.
- Every action works (suspend, delete, invite, ban, settings and so on) against
  an in-memory copy. Changes show up in the audit log and reset when the
  server restarts.
- A "Demo data" banner is shown on every page, including `/login`.

It's hard to turn on by accident:

- Only the exact value `1` enables it. `true`, `yes` or an empty value don't.
- It's read when each request is served, not baked in at build time, so a
  build made with the flag set doesn't stay in demo mode without it, and the
  reverse. (`lib/env.ts` looks variables up by a runtime key: Next.js inlines
  any `NEXT_PUBLIC_*` it can name at build time, even through an alias. The
  same goes for the Supabase URL and key.)
- In demo mode the console never creates a Supabase client. Even if the flag
  were set on a real deployment, the console would show fixtures, not real
  data, and couldn't change anything real.

To publish a demo, use a separate Vercel project (or a Preview-only variable)
with no Supabase values, never the production project.

## Deploying to Vercel

1. In Vercel, **Add New → Project** and import the repository.
2. Set **Root Directory** to `admin`. The framework preset (Next.js), the
   build command (`next build`) and the output need no changes. Under
   **Settings → Build and Deployment**, use Node.js 22.
3. Add `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` for
   Production (and Preview if previews should reach the same project). Don't
   add `NEXT_PUBLIC_ADMIN_DEMO` to Production.
4. From the `admin` directory, with the project linked
   (`npx vercel link`), create the private video store and connect it:

   ```bash
   npx vercel blob create-store homeos-videos --access private --yes
   ```

   That sets `BLOB_STORE_ID` on the project. On Vercel the function signs
   with the project's OIDC token, which arrives with each request (keep OIDC
   federation on in the project's security settings; it is on by default),
   so `BLOB_STORE_ID` is the only Blob variable Production needs. A
   `BLOB_READ_WRITE_TOKEN` (from connecting the store in **Storage**) also
   works. For a machine that isn't running on Vercel, pull credentials
   (`npx vercel env pull .env.local`) so `VERCEL_OIDC_TOKEN` or
   `BLOB_READ_WRITE_TOKEN` is present. Don't commit either value.
5. Deploy. Every route is dynamic, and `proxy.ts` runs on the Node.js runtime.
6. Make sure the backend side is in place: migrations pushed
   (`supabase db push`, including `20261009000002_video_blob.sql`) and the
   function deployed (`supabase functions deploy admin`). Supabase gives the
   function its service role key automatically.
7. Point the iOS app at this deployment (`MEDIA_API_URL` in
   `ios/Config/*.xcconfig`, read as `Config.mediaAPIURL`) and the display at
   it (`HOMEOS_MEDIA_URL`). The app uses `https://ohanaos.co` when
   `MEDIA_API_URL` is empty or still the example placeholder. Both send the
   family member's Supabase access token to `/api/media/*`.
8. Check the route from anywhere. Without a sign-in it should answer a
   clean 401 in JSON, not a login page, a 404 or a 503:

   ```bash
   curl -s -X POST https://ohanaos.co/api/media/upload \
     -H 'content-type: application/json' \
     -d '{"family_id":"00000000-0000-4000-8000-000000000000","content_type":"image/jpeg","bytes":1}'
   # {"error":"Sign in required."}
   ```

### How a photo or video gets to the frame

1. The phone posts `{family_id, content_type, bytes}` to
   `/api/media/upload` with `Authorization: Bearer <Supabase access token>`.
   The route checks the token and family membership and answers
   `{id, pathname, upload_url, content_type}`. Photos go up as JPEG (at most
   50 MB); videos keep their container (`.mov` is `video/quicktime`, at most
   2 GB). `image/jpg` is signed as `image/jpeg`, the name the database
   accepts.
2. The phone `PUT`s the file straight to `upload_url` (Vercel Blob, valid for
   two hours) with that `Content-Type`. Videos stream from disk.
3. The phone inserts the `media_items` row (`file_store = 'blob'`,
   `storage_path` = `pathname`), where the database checks it. If the PUT or
   the insert fails, the phone deletes the Blob object.
4. Phones and displays ask `/api/media/urls` for playback URLs (up to 200
   paths per request; they last six hours). A path outside the caller's
   families comes back as an empty string.

Every refused media request (4xx or 5xx) writes one `media <route>: <status>
<message>` line to the runtime logs, and every signed upload writes
`media upload: signed <type>, <bytes> bytes`. If the logs show neither while
someone is uploading, the phone isn't reaching this deployment.

The production deployment also answers `POST /api/assistant-identity`. That
is not a console page. The `assistant` edge function calls it with the
signed-in person's Supabase JWT, and the route returns a short-lived Vercel
OIDC token for Anthropic workload identity federation (see
[PLATFORM.md](PLATFORM.md)). It does not use an Anthropic API key, and it
does not take a service role key. `NEXT_PUBLIC_SUPABASE_URL` is the issuer
it trusts. Don't set `NEXT_PUBLIC_ADMIN_DEMO` on this project.

It also answers `POST /api/account/delete`, the iOS app's Delete account. The
route forwards the person's Supabase JWT to the `delete-account` edge
function, which deletes their data and login, and then removes the Blob
photos and videos of any family that went with the account. See
[PLATFORM.md](PLATFORM.md) → "Deleting your account".

Optional hardening: turn on Vercel **Deployment Protection** (Vercel
Authentication or a password) so only your team can reach the sign-in page
at all. Protection also blocks `/api/assistant-identity`, `/api/media`,
`/api/account/delete`, `/privacy` and `/support`. Leave those paths
reachable, or the assistant cannot reach Claude, photo and video upload and
playback stop, Delete account fails, and the App Store links break.

### Invite emails

"Email the invite" calls the `admin` function, which creates a single-use,
30-day platform invite and sends Supabase Auth's **Invite user** email with the
code in the user's metadata. To show the code in the email, edit
**Authentication → Emails → Invite user** and include `{{ .Data.invite_code }}`.
The link in the email opens the iOS app at `ohanaos://auth-callback`, which
signs the person in and starts their family. Add that URL to **Redirect URLs**
under **Authentication → URL Configuration** (see [IOS.md](IOS.md)); without
it Supabase sends the link to the Site URL, `https://ohanaos.co`, which
can't sign anyone in to the app. For custom limits (several uses, another
expiry), create the invite without email and share the code yourself.

## The first admin

Admins are rows in `public.platform_admins`. The first one is added by hand;
after that, admins promote others from the Users page.

1. Create the account. In the Supabase dashboard: **Authentication → Users →
   Add user → Create new user**, with a password and "Auto Confirm User" on.
   Do this before enabling the Before User Created hook. If the hook is
   already on, it only lets invited emails sign up, so first give yourself an
   invite in **SQL Editor**:

   ```sql
   insert into public.platform_invites (code, email, note)
   values (public.normalize_invite_code(public.generate_invite_code()), 'you@example.com', 'bootstrap');
   ```

2. In **SQL Editor**, run:

   ```sql
   insert into public.platform_admins (user_id)
   select id from auth.users where email = 'you@example.com';
   ```

3. Sign in to the console with that email and password.

`docs/PLATFORM.md` covers the rest of the backend setup (invites, the auth
hook, the assistant).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Sign-in page says Supabase isn't configured | One of the two `NEXT_PUBLIC_SUPABASE_*` variables is missing or not a URL. They are read at request time, so restart (or redeploy) after setting them. |
| "That account isn't an Ohana platform admin" | The account has no `platform_admins` row (see above). |
| "This page couldn't load" | An RPC failed, usually because the platform migrations aren't applied. The page shows the database's sentence. A numeric reference means an unexpected crash; that text is in the server log. |
| Ban, unban, delete (a user or a family) or email fail | The `admin` edge function isn't deployed or can't be reached. |
| A family was deleted but the audit log shows `delete_family_files` with an error | The rows are gone; some of its photos are still in the `family-media` bucket under the family's id. Remove that folder in **Storage**. |
| Delete family says photos and videos may still be in Blob storage | The rows are gone. In the Vercel Blob store, remove the folder named with that family's id. |
| The phone says "Media storage isn't configured." | Production has neither `BLOB_STORE_ID` nor `BLOB_READ_WRITE_TOKEN`. Connect the Blob store to the project (step 4) and redeploy. |
| The phone says "Couldn't start the upload." | The function couldn't get a signed URL from Blob. The runtime log line `media upload URL failed:` has the reason, often OIDC turned off with only `BLOB_STORE_ID` set. |
| The phone says the media service "didn't accept your sign-in" | The app and this deployment use different Supabase projects, or the session expired. Check `NEXT_PUBLIC_SUPABASE_URL` here against the app's `SUPABASE_URL`. |
| The phone says the media service "answered HTTP 404" (or another status) | The app's `MEDIA_API_URL` isn't this deployment, or Deployment Protection is in front of `/api/media`. |
| The phone says "Media storage refused the file" | Blob turned down the PUT. The HTTP status and Blob's message follow; a type or size mismatch means the app sent a different file than it asked to sign. |
| No `media upload` lines in the runtime logs while someone uploads | The phone isn't reaching this deployment: check `MEDIA_API_URL` in the build. |
| A banned user still has access for a while | Supabase bans block sign-in and token refresh; an access token that was already issued works until it expires (an hour by default). |

Dates and times in the console are shown in UTC; hover a relative time ("3 h
ago") for the exact timestamp.
