// Unit tests for the pairing gate: `deno test pair-device/`.

import { assertEquals } from "jsr:@std/assert@1";
import { pairingBlock } from "./pairing.ts";

Deno.test("pairingBlock: only an active family can take a display", () => {
  assertEquals(pairingBlock("active"), null);
  assertEquals(pairingBlock(null), { status: 404, error: "family not found" });
  assertEquals(pairingBlock(undefined), { status: 404, error: "family not found" });
  assertEquals(pairingBlock("suspended"), { status: 403, error: "this family's account is suspended" });
});
