// Where to send someone after sign-in. Only same-site paths are accepted, so
// /login?next=//evil.example can't turn the login form into an open redirect.
// Browsers drop tabs and newlines from URLs and read "\" as "/", so "/\t/evil"
// would become "//evil": anything with a control character or a backslash is
// refused too, and what's left must still resolve to this origin.
const ORIGIN = "http://same-site.invalid";

export function safeNextPath(value: unknown): string {
  if (typeof value !== "string" || !value.startsWith("/") || value.startsWith("//")) return "/";
  if (/[\u0000-\u001f\u007f\\]/.test(value)) return "/";
  let url: URL;
  try {
    url = new URL(value, ORIGIN);
  } catch {
    return "/";
  }
  if (url.origin !== ORIGIN || url.pathname === "/login" || url.pathname.startsWith("/login/")) return "/";
  return value;
}
