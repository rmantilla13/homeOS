// Environment, read at request time. Next.js inlines `process.env.NEXT_PUBLIC_*`
// at build time wherever it can see the name, including through an alias like
// `const env = process.env` (Turbopack follows those), which would freeze demo
// mode or one Supabase project into the build. A lookup by a key passed in at
// run time can't be inlined, so the same build works with whatever the server
// is started with (and `next build` needs nothing).
function read(name: string): string | undefined {
  return process.env[name];
}

export type SupabaseConfig = { url: string; anonKey: string };

// Demo mode serves fixture data with no sign-in. Only the exact value "1"
// enables it ("true", "yes" or a stray space do not), and demo mode never
// creates a Supabase client, so it can't reach real data even if misset.
export function demoMode(): boolean {
  return read("NEXT_PUBLIC_ADMIN_DEMO") === "1";
}

// Not read as process.env.VERCEL_ENV: Next would inline the build machine's
// value and the production deployment would refuse to mint.
export function vercelEnv(): string | undefined {
  return read("VERCEL_ENV");
}

// The project URL alone. The assistant identity route uses it as the JWT
// issuer and does not need the anon key. Looked up by name so Next doesn't
// inline one project's URL into the build.
export function supabaseProjectUrl(): string | null {
  const url = read("NEXT_PUBLIC_SUPABASE_URL")?.trim();
  if (!url) return null;
  try {
    new URL(url);
  } catch {
    return null;
  }
  return url;
}

export function supabaseConfig(): SupabaseConfig | null {
  const url = supabaseProjectUrl();
  const anonKey = read("NEXT_PUBLIC_SUPABASE_ANON_KEY")?.trim();
  if (!url || !anonKey) return null;
  return { url, anonKey };
}
