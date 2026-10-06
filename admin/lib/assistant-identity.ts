// Checks that a bearer token is a user session for this Supabase project,
// using the project's public JWKS. The assistant edge function forwards the
// caller's JWT; a valid one is enough to mint a Vercel OIDC token whose
// audience is Anthropic. The token is not an Anthropic API key.

import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";

// Audience the federation rule matches, and the audience requested from Vercel.
export const OIDC_AUDIENCE = "https://api.anthropic.com";

export class CallerTokenError extends Error {
  constructor() {
    super("sign-in could not be verified");
    this.name = "CallerTokenError";
  }
}

// Supabase Auth's issuer for a project URL. Local http is only loopback.
export function supabaseAuthIssuer(projectUrl: string): string | null {
  let url: URL;
  try {
    url = new URL(projectUrl.trim());
  } catch {
    return null;
  }
  if (url.username || url.password) return null;
  const loopback = url.hostname === "localhost" || url.hostname === "127.0.0.1";
  if (url.protocol === "https:") {
    // fine
  } else if (url.protocol === "http:" && loopback) {
    // local supabase
  } else {
    return null;
  }
  return `${url.origin}/auth/v1`;
}

// Production and local `vercel dev` can mint. Preview deployments must not:
// their OIDC subject is a different environment than the production rule.
export function identityMintAllowed(vercelEnv: string | undefined): boolean {
  return vercelEnv === "production" || vercelEnv === "development";
}

const jwksByIssuer = new Map<string, JWTVerifyGetKey>();

function jwksFor(issuer: string): JWTVerifyGetKey {
  let jwks = jwksByIssuer.get(issuer);
  if (!jwks) {
    jwks = createRemoteJWKSet(new URL(`${issuer}/.well-known/jwks.json`));
    jwksByIssuer.set(issuer, jwks);
  }
  return jwks;
}

export async function verifyAgainst(token: string, issuer: string, key: JWTVerifyGetKey | CryptoKey): Promise<void> {
  let role: unknown;
  try {
    const { payload } = await jwtVerify(token, key, { issuer, audience: "authenticated" });
    role = payload.role;
  } catch {
    throw new CallerTokenError();
  }
  if (role !== "authenticated") throw new CallerTokenError();
}

export async function verifySupabaseUser(token: string, projectUrl: string): Promise<void> {
  const issuer = supabaseAuthIssuer(projectUrl);
  if (!issuer) throw new CallerTokenError();
  await verifyAgainst(token, issuer, jwksFor(issuer));
}
