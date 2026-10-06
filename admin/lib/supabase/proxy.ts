import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { demoMode, supabaseConfig } from "@/lib/env";

// Runs before every page: refreshes the Supabase session (writing rotated
// tokens back as cookies) and keeps everyone but platform admins on /login.
// Pages and server actions check again (lib/data.ts); this is the fast path.
export async function updateSession(request: NextRequest): Promise<NextResponse> {
  if (demoMode()) return NextResponse.next({ request });

  const { pathname, search } = request.nextUrl;
  const onLogin = pathname === "/login";
  const config = supabaseConfig();
  if (!config) return onLogin ? NextResponse.next({ request }) : redirectTo(request, "/login?error=config");

  let response = NextResponse.next({ request });
  const supabase = createServerClient(config.url, config.anonKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet, headers) {
        for (const { name, value } of cookiesToSet) request.cookies.set(name, value);
        response = NextResponse.next({ request });
        for (const { name, value, options } of cookiesToSet) response.cookies.set(name, value, options);
        for (const [key, value] of Object.entries(headers)) response.headers.set(key, value);
      },
    },
  });

  // Nothing may run between creating the client and this call: it is what
  // refreshes an expired session.
  const { data: claims } = await supabase.auth.getClaims();
  if (!claims?.claims) {
    if (onLogin) return response;
    const next = pathname === "/" ? "" : `?next=${encodeURIComponent(pathname + search)}`;
    return redirectTo(request, `/login${next}`, response);
  }

  const { data: isAdmin, error } = await supabase.rpc("is_platform_admin");
  if (error || isAdmin !== true) {
    return onLogin ? response : redirectTo(request, "/login?error=not_admin", response);
  }
  return onLogin ? redirectTo(request, "/", response) : response;
}

// A redirect that keeps any refreshed session cookies and no-cache headers.
function redirectTo(request: NextRequest, path: string, carry?: NextResponse): NextResponse {
  const redirect = NextResponse.redirect(new URL(path, request.url));
  if (carry) {
    for (const cookie of carry.cookies.getAll()) redirect.cookies.set(cookie);
    for (const key of ["cache-control", "expires", "pragma"]) {
      const value = carry.headers.get(key);
      if (value) redirect.headers.set(key, value);
    }
  }
  return redirect;
}
