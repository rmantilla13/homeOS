// Claude authentication for the assistant edge function.
//
// The function runs on Supabase's Deno runtime, which does not receive
// VERCEL_OIDC_TOKEN (that exists only on Vercel) and is not Deno Deploy, so
// @deno/oidc cannot mint a token either. Anthropic workload identity
// federation is the login: this module exchanges a short-lived Vercel OIDC
// JWT for a short-lived Anthropic access token. The admin app mints the
// Vercel JWT (POST /api/assistant-identity) after checking the caller's
// Supabase session. No long-lived Anthropic API key is required once the
// federation settings below are present.
//
// A leftover ANTHROPIC_API_KEY is ignored while federation is configured
// (the SDK would otherwise prefer it). It is used only when the federation
// settings are absent, so deploying this code before the one-time console
// setup does not take the assistant down. Unset the key after a federated
// call succeeds. See docs/PLATFORM.md.

import { AsyncLocalStorage } from "node:async_hooks";
import Anthropic from "npm:@anthropic-ai/sdk@^0.131.0";
import { oidcFederationProvider } from "npm:@anthropic-ai/sdk@^0.131.0/lib/credentials/oidc-federation";

// Must match the audience the admin route requests and the federation rule.
const FEDERATION_AUDIENCE_URL = "https://api.anthropic.com";
const DEFAULT_IDENTITY_URL = "https://homeos-admin.vercel.app/api/assistant-identity";

const callerToken = new AsyncLocalStorage<string>();

type EnvGet = { get(name: string): string | undefined };

function readEnv(env: EnvGet | undefined, name: string): string | undefined {
  const value = (env ?? Deno.env).get(name)?.trim();
  return value ? value : undefined;
}

export class ClaudeAuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ClaudeAuthError";
  }
}

export interface FederationSettings {
  ruleId: string;
  organizationId: string;
  serviceAccountId: string;
  workspaceId?: string;
}

// All three ids together, or none. A partial set is a mistake, not a cue to
// fall back to an API key. `env` is for tests; production reads Deno.env.
export function federationSettings(env?: EnvGet): FederationSettings | null {
  const ruleId = readEnv(env, "ANTHROPIC_FEDERATION_RULE_ID");
  const organizationId = readEnv(env, "ANTHROPIC_ORGANIZATION_ID");
  const serviceAccountId = readEnv(env, "ANTHROPIC_SERVICE_ACCOUNT_ID");
  const workspaceId = readEnv(env, "ANTHROPIC_WORKSPACE_ID");
  if (!ruleId && !organizationId && !serviceAccountId && !workspaceId) return null;
  if (!ruleId || !organizationId || !serviceAccountId) {
    throw new ClaudeAuthError("Claude federation settings are incomplete");
  }
  if (!ruleId.startsWith("fdrl_") || !serviceAccountId.startsWith("svac_")) {
    throw new ClaudeAuthError("Claude federation settings are incomplete");
  }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(organizationId)) {
    throw new ClaudeAuthError("Claude federation settings are incomplete");
  }
  if (workspaceId && !workspaceId.startsWith("wrkspc_")) {
    throw new ClaudeAuthError("Claude federation settings are incomplete");
  }
  return { ruleId, organizationId, serviceAccountId, workspaceId };
}

export type ClaudeCredentials =
  | { mode: "federation"; apiKey: null; authToken: null; settings: FederationSettings }
  | { mode: "api_key"; apiKey: string }
  | { mode: "unconfigured" };

// What the Anthropic client is given. Federation forces apiKey and authToken
// to null so a leftover ANTHROPIC_API_KEY cannot shadow the exchange.
export function claudeCredentials(env?: EnvGet): ClaudeCredentials {
  const settings = federationSettings(env);
  if (settings) return { mode: "federation", apiKey: null, authToken: null, settings };
  const apiKey = readEnv(env, "ANTHROPIC_API_KEY");
  if (apiKey) return { mode: "api_key", apiKey };
  return { mode: "unconfigured" };
}

export function claudeAuthMode(env?: EnvGet): "federation" | "api_key" | "unconfigured" {
  return claudeCredentials(env).mode;
}

// The signed-in caller's JWT, so the identity route can check it. Held only
// for the request that is talking to Claude.
export function withCallerToken<T>(token: string, fn: () => Promise<T>): Promise<T> {
  return callerToken.run(token, fn);
}

export function identityEndpoint(env?: EnvGet): string {
  const raw = readEnv(env, "ASSISTANT_IDENTITY_URL") ?? DEFAULT_IDENTITY_URL;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new ClaudeAuthError("workload identity endpoint is not a URL");
  }
  const local = url.hostname === "localhost" || url.hostname === "127.0.0.1";
  if (url.protocol !== "https:" && !(url.protocol === "http:" && local)) {
    throw new ClaudeAuthError("workload identity endpoint must be https");
  }
  return url.toString();
}

function looksLikeJwt(token: string): boolean {
  if (token.length > 16 * 1024) return false;
  const parts = token.split(".");
  return parts.length === 3 && parts.every((part) => part.length > 0);
}

// Asks the admin deployment for a fresh Vercel OIDC token (aud api.anthropic.com).
export async function fetchWorkloadIdentityToken(fetchImpl: typeof fetch = fetch, env?: EnvGet): Promise<string> {
  const bearer = callerToken.getStore();
  if (!bearer) throw new ClaudeAuthError("no caller for the workload identity token");
  const url = identityEndpoint(env);
  let res: Response;
  try {
    res = await fetchImpl(url, {
      method: "POST",
      headers: { authorization: `Bearer ${bearer}`, accept: "application/json" },
      signal: AbortSignal.timeout(10_000),
    });
  } catch (err) {
    console.error("workload identity request failed:", err instanceof Error ? err.name : "error");
    throw new ClaudeAuthError("workload identity endpoint unreachable");
  }
  if (!res.ok) {
    console.error(`workload identity endpoint status ${res.status}`);
    await res.body?.cancel().catch(() => {});
    throw new ClaudeAuthError("workload identity endpoint refused");
  }
  let body: unknown;
  try {
    body = await res.json();
  } catch {
    throw new ClaudeAuthError("workload identity endpoint returned nothing usable");
  }
  const token = body && typeof body === "object" && "token" in body && typeof (body as { token: unknown }).token === "string"
    ? (body as { token: string }).token
    : "";
  if (!looksLikeJwt(token)) throw new ClaudeAuthError("workload identity endpoint returned nothing usable");
  return token;
}

export function createClaudeClient(): Anthropic {
  const credentials = claudeCredentials();
  if (credentials.mode === "federation") {
    const { settings } = credentials;
    // apiKey and authToken must be null, not omitted: an omitted key makes
    // the SDK read ANTHROPIC_API_KEY from the environment and ignore federation.
    return new Anthropic({
      apiKey: credentials.apiKey,
      authToken: credentials.authToken,
      credentials: oidcFederationProvider({
        identityTokenProvider: () => fetchWorkloadIdentityToken(),
        federationRuleId: settings.ruleId,
        organizationId: settings.organizationId,
        serviceAccountId: settings.serviceAccountId,
        workspaceId: settings.workspaceId,
        baseURL: FEDERATION_AUDIENCE_URL,
        fetch,
      }),
    });
  }
  if (credentials.mode === "api_key") return new Anthropic({ apiKey: credentials.apiKey });
  throw new ClaudeAuthError("Claude federation is not configured");
}

let client: Anthropic | null = null;

export function claude(): Anthropic {
  if (!client) client = createClaudeClient();
  return client;
}
