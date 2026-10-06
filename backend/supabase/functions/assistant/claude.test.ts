// `deno test assistant/claude.test.ts`

import { assert, assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import {
  claudeAuthMode,
  claudeCredentials,
  ClaudeAuthError,
  federationSettings,
  fetchWorkloadIdentityToken,
  identityEndpoint,
  withCallerToken,
} from "./claude.ts";

const RULE = "fdrl_01example";
const ORG = "00000000-0000-4000-8000-000000000001";
const ACCOUNT = "svac_01example";

function envOf(values: Record<string, string | undefined>): { get(name: string): string | undefined } {
  return { get: (name) => values[name] };
}

Deno.test("federation settings decide the credential and ignore a leftover API key", () => {
  assertEquals(federationSettings(envOf({})), null);
  assertEquals(claudeAuthMode(envOf({})), "unconfigured");
  assertEquals(claudeAuthMode(envOf({ ANTHROPIC_API_KEY: "sk-ant-test" })), "api_key");

  assertThrows(
    () => claudeAuthMode(envOf({ ANTHROPIC_API_KEY: "sk-ant-test", ANTHROPIC_FEDERATION_RULE_ID: RULE })),
    ClaudeAuthError,
  );

  const credentials = claudeCredentials(envOf({
    ANTHROPIC_API_KEY: "sk-ant-test",
    ANTHROPIC_FEDERATION_RULE_ID: RULE,
    ANTHROPIC_ORGANIZATION_ID: ORG,
    ANTHROPIC_SERVICE_ACCOUNT_ID: ACCOUNT,
  }));
  assertEquals(credentials.mode, "federation");
  if (credentials.mode === "federation") {
    assertEquals(credentials.apiKey, null);
    assertEquals(credentials.authToken, null);
    assertEquals(credentials.settings.ruleId, RULE);
  }

  assertEquals(federationSettings(envOf({
    ANTHROPIC_FEDERATION_RULE_ID: "  ",
    ANTHROPIC_ORGANIZATION_ID: "",
    ANTHROPIC_SERVICE_ACCOUNT_ID: "",
  })), null);
});

Deno.test("identity endpoint and token fetch", async () => {
  assertEquals(identityEndpoint(envOf({})), "https://homeos-admin.vercel.app/api/assistant-identity");
  assertThrows(
    () => identityEndpoint(envOf({ ASSISTANT_IDENTITY_URL: "http://example.com/api/assistant-identity" })),
    ClaudeAuthError,
  );
  assert(
    identityEndpoint(envOf({ ASSISTANT_IDENTITY_URL: "http://127.0.0.1:3000/api/assistant-identity" }))
      .startsWith("http://127.0.0.1:3000/"),
  );

  await assertRejects(() => fetchWorkloadIdentityToken(fetch, envOf({})), ClaudeAuthError);

  const local = envOf({ ASSISTANT_IDENTITY_URL: "https://homeos-admin.vercel.app/api/assistant-identity" });
  const calls: { url: string; authorization: string | null; method: string }[] = [];
  const token = await withCallerToken("caller-jwt", () =>
    fetchWorkloadIdentityToken((input, init) => {
      calls.push({
        url: String(input),
        authorization: new Headers(init?.headers).get("authorization"),
        method: init?.method ?? "GET",
      });
      return Promise.resolve(Response.json({ token: "aaa.bbb.ccc" }));
    }, local)
  );
  assertEquals(token, "aaa.bbb.ccc");
  assertEquals(calls, [{
    url: "https://homeos-admin.vercel.app/api/assistant-identity",
    authorization: "Bearer caller-jwt",
    method: "POST",
  }]);

  await assertRejects(
    () =>
      withCallerToken("caller-jwt", () =>
        fetchWorkloadIdentityToken(() => Promise.resolve(Response.json({ token: "not-a-jwt" })), local)
      ),
    ClaudeAuthError,
  );
  await assertRejects(
    () =>
      withCallerToken("caller-jwt", () =>
        fetchWorkloadIdentityToken(() => Promise.resolve(new Response("no", { status: 401 })), local)
      ),
    ClaudeAuthError,
  );
});
