// Whether a family may receive a new display. Kept out of index.ts so the
// claim path can be unit-tested without standing the function up.

/** A reason to refuse pairing, or null when the family is active. */
export function pairingBlock(status: string | null | undefined): { status: number; error: string } | null {
  if (status == null) return { status: 404, error: "family not found" };
  if (status !== "active") return { status: 403, error: "this family's account is suspended" };
  return null;
}
