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
