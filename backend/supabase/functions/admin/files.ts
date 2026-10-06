// Storage cleanup for the admin function, kept free of I/O setup so it can be
// unit-tested with a fake bucket (files.test.ts).
//
// Deleting rows in SQL leaves the files behind: Supabase removes objects only
// through the Storage API. So when a family or a person is deleted, the admin
// function empties their folder, family-media/<family_id>/ or
// avatars/<user_id>/. Both layouts are flat ('<folder>/<file>').

// The slice of the Storage client this needs (supabase.storage.from(bucket)).
export interface Bucket {
  list(
    path: string,
    options: { limit: number },
  ): Promise<{ data: { name: string; id: string | null }[] | null; error: { message: string } | null }>;
  remove(paths: string[]): Promise<{ data: unknown[] | null; error: { message: string } | null }>;
}

const PAGE = 100;
const MAX_PAGES = 1000; // 100,000 files: a backstop, never reached by a family

// Removes every file directly in `folder`. Returns how many went, and the
// error that stopped it early, if any.
export async function removeFolder(bucket: Bucket, folder: string): Promise<{ removed: number; error: string | null }> {
  let removed = 0;
  for (let page = 0; page < MAX_PAGES; page++) {
    const { data, error } = await bucket.list(folder, { limit: PAGE });
    if (error) return { removed, error: error.message };
    // Sub-folders come back with no id; there are none in these layouts.
    const files = (data ?? []).filter((f) => f.id !== null).map((f) => `${folder}/${f.name}`);
    if (!files.length) return { removed, error: null };
    const { data: gone, error: removeErr } = await bucket.remove(files);
    if (removeErr) return { removed, error: removeErr.message };
    // Nothing removed means the next listing would be the same page again.
    if (!gone?.length) return { removed, error: "the files couldn't be removed" };
    removed += gone.length;
  }
  return { removed, error: "too many files" };
}
