// Run with `npm test` (Node 22 strips the TypeScript types itself).
import assert from "node:assert/strict";
import { test } from "node:test";
import { safeNextPath } from "../lib/paths.ts";

// Where a browser would actually end up after redirecting to `path`.
const landing = (path) => new URL(path, "https://admin.example/login").origin;

test("keeps same-site paths", () => {
  for (const path of ["/", "/families", "/families?q=a%20b&page=2", "/families/0f0e/x#top", "/users?q=a@b.example"]) {
    assert.equal(safeNextPath(path), path);
  }
});

test("refuses anything that leaves the site", () => {
  const attacks = [
    "//evil.example",
    "/\\evil.example",
    "\\\\evil.example",
    "/\t/evil.example",
    "/\n/evil.example",
    "/\r\n/evil.example",
    "/\u0000/evil.example",
    "https://evil.example",
    "javascript:alert(1)",
    "evil.example",
    "",
  ];
  for (const value of attacks) {
    const path = safeNextPath(value);
    assert.equal(path, "/", JSON.stringify(value));
    assert.equal(landing(path), "https://admin.example");
  }
});

test("never loops back to the sign-in page", () => {
  for (const value of ["/login", "/login?next=/x", "/login/", "/./login", "/x/../login"]) {
    assert.equal(safeNextPath(value), "/", value);
  }
});

test("ignores non-strings", () => {
  for (const value of [null, undefined, 42, ["/families"], {}]) assert.equal(safeNextPath(value), "/");
});
