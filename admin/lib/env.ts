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

// Private Blob store for family photos and videos. On Vercel, OIDC plus BLOB_STORE_ID is
// enough. A read-write token is what local dev and presigned uploads use when
// OIDC isn't present. Either pair counts as configured.
// A deployed function gets its OIDC token with each request (the
// x-vercel-oidc-token header, which @vercel/blob reads through @vercel/oidc),
// not in process.env, so on Vercel the store id is enough. VERCEL_OIDC_TOKEN
// in the environment is the `vercel env pull` case for local runs.
export function blobReady(): boolean {
  const token = read("BLOB_READ_WRITE_TOKEN")?.trim();
  const storeId = read("BLOB_STORE_ID")?.trim();
  const oidc = Boolean(read("VERCEL_OIDC_TOKEN")?.trim()) || read("VERCEL") === "1";
  return Boolean(token || (storeId && oidc));
}

export function supabaseConfig(): SupabaseConfig | null {
  const url = supabaseProjectUrl();
  const anonKey = read("NEXT_PUBLIC_SUPABASE_ANON_KEY")?.trim();
  if (!url || !anonKey) return null;
  return { url, anonKey };
}

// Server-made wall copies of videos (lib/media/processing.ts). The secret is
// shared with the media-jobs edge function; without it, or when it's shorter
// than 32 characters, video processing is off and uploads work as before.
export function mediaJobsSecret(): string | null {
  const secret = read("MEDIA_JOBS_SECRET")?.trim();
  return secret && secret.length >= 32 ? secret : null;
}

// Vercel sends `Authorization: Bearer <CRON_SECRET>` with each cron request.
export function cronSecret(): string | null {
  return read("CRON_SECRET")?.trim() || null;
}

// Where a sandbox reports back. Deployment URLs (*.vercel.app) sit behind
// Vercel Authentication, so the production domain is the default.
export function mediaCallbackOrigin(): string | null {
  const explicit = read("MEDIA_CALLBACK_ORIGIN")?.trim();
  const production = read("VERCEL_PROJECT_PRODUCTION_URL")?.trim();
  const origin = explicit || (production ? `https://${production}` : "");
  try {
    return origin ? new URL(origin).origin : null;
  } catch {
    return null;
  }
}

// vCPUs per sandbox (1 or an even number up to 8; each brings 2 GB of memory).
export function mediaSandboxVcpus(): number {
  const n = Number(read("MEDIA_SANDBOX_VCPUS"));
  return Number.isInteger(n) && n >= 1 && n <= 8 && (n === 1 || n % 2 === 0) ? n : 8;
}

// Passed to the worker: where it gets ffmpeg when the sandbox image has none.
export function mediaFfmpegEnv(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const name of ["MEDIA_FFMPEG_URL", "MEDIA_FFMPEG_SHA256"]) {
    const value = read(name)?.trim();
    if (value) env[name] = value;
  }
  return env;
}
