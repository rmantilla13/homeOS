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

// Private Blob store for family photos and videos. On Vercel, OIDC plus BLOB_STORE_ID is
// enough. A read-write token is what local dev and presigned uploads use when
// OIDC isn't present. Either pair counts as configured.
export function blobReady(): boolean {
  const token = read("BLOB_READ_WRITE_TOKEN")?.trim();
  const storeId = read("BLOB_STORE_ID")?.trim();
  const oidc = read("VERCEL_OIDC_TOKEN")?.trim();
  return Boolean(token || (storeId && oidc));
}

export function supabaseConfig(): SupabaseConfig | null {
  const url = read("NEXT_PUBLIC_SUPABASE_URL")?.trim();
  const anonKey = read("NEXT_PUBLIC_SUPABASE_ANON_KEY")?.trim();
  if (!url || !anonKey) return null;
  try {
    new URL(url);
  } catch {
    return null;
  }
  return { url, anonKey };
}
