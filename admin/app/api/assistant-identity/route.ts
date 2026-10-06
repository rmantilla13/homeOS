// Mints a Vercel OIDC token for the assistant edge function. The function
// runs on Supabase, so it cannot see VERCEL_OIDC_TOKEN itself. Anthropic
// exchanges this token through workload identity federation. The token's
// audience is https://api.anthropic.com, not the Vercel APIs.
//
// Not an admin page: proxy.ts lets it through, and the caller's Supabase
// JWT is checked here. Deployment Protection must not cover this path.

import { getVercelOidcToken } from "@vercel/oidc";
import { demoMode, supabaseProjectUrl, vercelEnv } from "@/lib/env";
import { CallerTokenError, identityMintAllowed, OIDC_AUDIENCE, verifySupabaseUser } from "@/lib/assistant-identity";

export const dynamic = "force-dynamic";

const NO_STORE = { "cache-control": "no-store" };

function json(body: { error: string } | { token: string }, status: number): Response {
  return Response.json(body, { status, headers: NO_STORE });
}

function bearer(request: Request): string {
  const header = request.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(\S+)\s*$/i.exec(header);
  return match?.[1] ?? "";
}

export async function POST(request: Request): Promise<Response> {
  if (demoMode()) return json({ error: "not found" }, 404);
  if (!identityMintAllowed(vercelEnv())) {
    return json({ error: "workload identity is minted on the production deployment" }, 503);
  }
  const project = supabaseProjectUrl();
  if (!project) return json({ error: "Supabase project URL isn't configured" }, 503);

  const token = bearer(request);
  if (!token) return json({ error: "sign in required" }, 401);
  try {
    await verifySupabaseUser(token, project);
  } catch (err) {
    if (!(err instanceof CallerTokenError)) console.error("caller token check failed");
    return json({ error: "sign in required" }, 401);
  }

  try {
    // A new jti on every call so Anthropic's single-use check accepts the
    // next exchange. The in-memory cache keys on jti; skip it anyway.
    const identity = await getVercelOidcToken({
      audience: OIDC_AUDIENCE,
      jti: crypto.randomUUID(),
      skipCache: true,
    });
    if (!identity) return json({ error: "workload identity isn't available" }, 503);
    return json({ token: identity }, 200);
  } catch {
    console.error("workload identity mint failed");
    return json({ error: "workload identity isn't available" }, 503);
  }
}
