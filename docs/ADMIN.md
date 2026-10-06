# Admin console

`admin/` is the web console for running homeOS as a platform: families,
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
| `/settings` | Invite-only sign-up, assistant on/off, requests per family per day |
| `/audit` | Every admin action, newest first |

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
  then removes the family's photos from `family-media`; SQL alone
  leaves the files behind). This app then deletes that family's videos from
  the private Blob store. Deleting a user removes their `avatars` folder
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
- **Look.** CSS modules plus the homeOS tokens in `app/globals.css`: warm
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

   That sets `BLOB_STORE_ID` on the project. On Vercel the function uses
   `VERCEL_OIDC_TOKEN` with that store id. For a machine that isn't running
   on Vercel, pull a read-write token too (`npx vercel env pull .env.local`)
   so `BLOB_READ_WRITE_TOKEN` is present. Don't commit either value.
5. Deploy. Every route is dynamic, and `proxy.ts` runs on the Node.js runtime.
6. Make sure the backend side is in place: migrations pushed
   (`supabase db push`, including `20261008000001_video_blob.sql`) and the
   function deployed (`supabase functions deploy admin`). Supabase gives the
   function its service role key automatically.
7. Point the iOS app at this deployment (`Config.mediaAPIURL`) and the
   display at it (`HOMEOS_MEDIA_URL`). Both send the family member's Supabase
   access token to `/api/media/*`.

Optional hardening: turn on Vercel **Deployment Protection** (Vercel
Authentication or a password) so only your team can reach the sign-in page.
That also blocks phones and displays from `/api/media`. Leave those routes
reachable by a family JWT, or video upload and playback stop.

### Invite emails

"Email the invite" calls the `admin` function, which creates a single-use,
30-day platform invite and sends Supabase Auth's **Invite user** email with the
code in the user's metadata. To show the code in the email, edit
**Authentication → Emails → Invite user** and include `{{ .Data.invite_code }}`.
The link in the email goes to the project's Site URL
(**Authentication → URL Configuration**). For custom limits (several uses,
another expiry), create the invite without email and share the code yourself.

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
| "That account isn't a homeOS platform admin" | The account has no `platform_admins` row (see above). |
| "This page couldn't load" | An RPC failed, usually because the platform migrations aren't applied. The server log has the database error. |
| Ban, unban, delete (a user or a family) or email fail | The `admin` edge function isn't deployed or can't be reached. |
| A family was deleted but the audit log shows `delete_family_files` with an error | The rows are gone; some of its photos are still in the `family-media` bucket under the family's id. Remove that folder in **Storage**. |
| Delete family says videos may still be in Blob storage | The rows are gone. In the Vercel Blob store, remove the folder named with that family's id. |
| A banned user still has access for a while | Supabase bans block sign-in and token refresh; an access token that was already issued works until it expires (an hour by default). |

Dates and times in the console are shown in UTC; hover a relative time ("3 h
ago") for the exact timestamp.
