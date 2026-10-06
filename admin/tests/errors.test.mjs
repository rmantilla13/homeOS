import assert from "node:assert/strict";
import { test } from "node:test";
import { DataError, consoleErrorCopy } from "../lib/errors.ts";

test("a database sentence survives the production error page", () => {
  const err = new DataError("Could not find the function public.admin_overview in the schema cache");
  assert.equal(err.digest, err.message);
  assert.deepEqual(consoleErrorCopy(err.digest), { message: err.message, reference: null });
});

test("a numeric Next digest stays a reference", () => {
  const copy = consoleErrorCopy("4057501313");
  assert.match(copy.message, /platform migrations/);
  assert.equal(copy.reference, "4057501313");
  assert.equal(consoleErrorCopy("4057501313@E123").reference, "4057501313@E123");
  assert.equal(consoleErrorCopy(undefined).reference, null);
});
