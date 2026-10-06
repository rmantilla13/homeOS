// HTTP helpers shared by the edge functions. The admin console calls the
// functions from a browser, so every response carries the CORS headers and
// OPTIONS preflights are answered directly.

export const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

export const json = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

export const preflight = (): Response => new Response("ok", { headers: corsHeaders });

export const MAX_BODY_BYTES = 64 * 1024;

// The request's JSON body, read with a size cap so a huge body can't exhaust
// the worker's memory. Gives back a ready 413 or 400 response instead when it's
// too big or not JSON.
export async function readJson(req: Request, maxBytes = MAX_BODY_BYTES): Promise<{ body: unknown } | { error: Response }> {
  const tooBig = () => ({ error: json({ error: "request body too large" }, 413) });
  if (Number(req.headers.get("Content-Length")) > maxBytes) return tooBig();
  const chunks: Uint8Array[] = [];
  let size = 0;
  if (req.body) {
    const reader = req.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > maxBytes) {
        await reader.cancel().catch(() => {});
        return tooBig();
      }
      chunks.push(value);
    }
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const c of chunks) {
    bytes.set(c, offset);
    offset += c.byteLength;
  }
  try {
    return { body: JSON.parse(new TextDecoder().decode(bytes)) };
  } catch {
    return { error: json({ error: "invalid JSON" }, 400) };
  }
}

// Who the bearer token belongs to, checked with Supabase Auth. Auth's own 4xx
// (bad or expired token) is a 401; Auth being unreachable or failing is a 503,
// so clients don't treat an outage as being signed out.
export async function authenticate<User>(
  client: { auth: { getUser(jwt: string): Promise<{ data: { user: User | null }; error: { status?: number } | null }> } },
  token: string,
): Promise<{ user: User } | { error: Response }> {
  const { data, error } = await client.auth.getUser(token);
  if (data.user) return { user: data.user };
  const status = error?.status ?? 0;
  if (error && !(status >= 400 && status < 500)) {
    console.error("auth check failed:", status, error);
    return { error: json({ error: "couldn't check your sign-in; try again in a moment" }, 503) };
  }
  return { error: json({ error: "sign in required" }, 401) };
}

// The caller's JWT from `Authorization: Bearer <jwt>`, or null.
export function bearerToken(req: Request): string | null {
  const match = req.headers.get("Authorization")?.match(/^Bearer\s+(\S+)\s*$/i);
  return match ? match[1] : null;
}

// Thrown inside a handler to answer with a specific status and `{ error }`.
export class HttpError extends Error {
  constructor(readonly status: number, message: string) {
    super(message);
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export const isUuid = (value: unknown): value is string => typeof value === "string" && UUID.test(value);
