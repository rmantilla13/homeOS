// Where to send someone after sign-in. Only same-site paths are accepted, so
// /login?next=//evil.example can't turn the login form into an open redirect.
export function safeNextPath(value: unknown): string {
  if (typeof value !== "string" || !value.startsWith("/") || value.startsWith("//") || value.includes("\\")) {
    return "/";
  }
  if (value === "/login" || value.startsWith("/login?") || value.startsWith("/login/")) return "/";
  return value;
}
