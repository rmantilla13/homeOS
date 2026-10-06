# homeOS admin console

The web console for platform admins: families, accounts, invites, assistant
usage and settings. Next.js (App Router) + Supabase.

```bash
npm ci
cp .env.example .env.local   # Supabase URL and anon key
npm run dev                  # http://localhost:3000

NEXT_PUBLIC_ADMIN_DEMO=1 npm run dev   # fixture data, no backend, no sign-in
```

Setup, demo mode, Vercel deployment and bootstrapping the first admin:
[docs/ADMIN.md](../docs/ADMIN.md).
