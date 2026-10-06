import assert from "node:assert/strict";
import { generateKeyPair, SignJWT } from "jose";
import { test } from "node:test";
import {
  CallerTokenError,
  identityMintAllowed,
  OIDC_AUDIENCE,
  supabaseAuthIssuer,
  verifyAgainst,
} from "../lib/assistant-identity.ts";

const ISSUER = "https://abcd.supabase.co/auth/v1";

test("issuer is the project's auth server", () => {
  assert.equal(supabaseAuthIssuer("https://abcd.supabase.co"), ISSUER);
  assert.equal(supabaseAuthIssuer("https://abcd.supabase.co/auth/v1"), ISSUER);
  assert.equal(supabaseAuthIssuer("http://127.0.0.1:54321"), "http://127.0.0.1:54321/auth/v1");
  assert.equal(supabaseAuthIssuer("http://evil.example"), null);
  assert.equal(supabaseAuthIssuer("https://user:pw@abcd.supabase.co"), null);
  assert.equal(supabaseAuthIssuer("not a url"), null);
});

test("only production and development mint a token", () => {
  assert.equal(identityMintAllowed("production"), true);
  assert.equal(identityMintAllowed("development"), true);
  assert.equal(identityMintAllowed("preview"), false);
  assert.equal(identityMintAllowed(undefined), false);
});

test("audience is the Anthropic API", () => {
  assert.equal(OIDC_AUDIENCE, "https://api.anthropic.com");
});

test("a user access token verifies and other roles do not", async () => {
  const { publicKey, privateKey } = await generateKeyPair("ES256");
  const sign = (role) =>
    new SignJWT({ role })
      .setProtectedHeader({ alg: "ES256" })
      .setIssuer(ISSUER)
      .setAudience("authenticated")
      .setSubject("00000000-0000-4000-8000-000000000002")
      .setIssuedAt()
      .setExpirationTime("2m")
      .sign(privateKey);

  await verifyAgainst(await sign("authenticated"), ISSUER, publicKey);
  await assert.rejects(verifyAgainst(await sign("service_role"), ISSUER, publicKey), CallerTokenError);
  await assert.rejects(verifyAgainst(await sign("anon"), ISSUER, publicKey), CallerTokenError);
  await assert.rejects(verifyAgainst(await sign("authenticated"), "https://other.supabase.co/auth/v1", publicKey), CallerTokenError);
});
