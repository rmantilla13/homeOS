// An error whose message is fine to show to an admin (RPC and edge function
// errors are short, human-readable sentences by contract). `digest` is the
// one field Next.js keeps on a production error page, so the sentence travels
// with it instead of being replaced by a hash.
export class DataError extends Error {
  readonly digest: string;
  readonly inviteCode?: string;

  constructor(message: string, inviteCode?: string) {
    super(message);
    this.name = "DataError";
    this.digest = message;
    this.inviteCode = inviteCode;
  }
}

// Next's own digest is an unsigned 32-bit hash, sometimes with an @E code.
const HASH_DIGEST = /^\d{1,10}(?:@E\d+)?$/;

const GENERIC =
  "The backend didn't answer as expected. Check that the platform migrations and the admin RPCs are deployed (docs/ADMIN.md), then try again.";

// A DataError's digest is the sentence. Anything else is Next's hash, and the
// real text is only in the server log.
export function consoleErrorCopy(digest?: string): { message: string; reference: string | null } {
  if (digest && !HASH_DIGEST.test(digest)) return { message: digest, reference: null };
  return { message: GENERIC, reference: digest ?? null };
}
