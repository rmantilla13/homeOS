// An error whose message is fine to show to an admin (RPC and edge function
// errors are short, human-readable sentences by contract).
export class DataError extends Error {
  constructor(
    message: string,
    readonly inviteCode?: string,
  ) {
    super(message);
    this.name = "DataError";
  }
}
