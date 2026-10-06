import "server-only";
import { createServerClient } from "@supabase/ssr";
import type { SupabaseClient } from "@supabase/supabase-js";
import { cookies } from "next/headers";
import type { SupabaseConfig } from "@/lib/env";

// A per-request client acting as the signed-in admin (their JWT from the
// session cookies). Row-level security and the admin_* RPCs' own
// is_platform_admin() checks apply to everything it does.
export async function createSupabaseServerClient(config: SupabaseConfig): Promise<SupabaseClient> {
  const cookieStore = await cookies();
  return createServerClient(config.url, config.anonKey, {
    cookies: {
      getAll() {
        return cookieStore.getAll();
      },
      setAll(cookiesToSet) {
        try {
          for (const { name, value, options } of cookiesToSet) cookieStore.set(name, value, options);
        } catch {
          // Server Components can't set cookies. The proxy refreshes the
          // session on every request, so a missed write here is harmless.
        }
      },
    },
  });
}
