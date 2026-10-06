import "server-only";
import { del, list } from "@vercel/blob";
import { blobReady } from "@/lib/env";
import { DataError } from "@/lib/errors";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const LEFT_BEHIND =
  "The family is deleted, but its videos may still be in Blob storage. Remove that family's folder from the Blob store.";

// After admin_delete_family removes the rows and the family-media folder.
// Photos are already gone. Videos are objects under `<family_id>/`.
// Missing Blob credentials skip this (a family of only photos still deletes).
// A cleanup failure does not undo the deletion.
export async function deleteFamilyBlobs(familyId: string): Promise<void> {
  if (!blobReady()) {
    console.warn(`Blob storage isn't configured; videos for family ${familyId} were not removed.`);
    return;
  }
  if (!UUID.test(familyId)) throw new DataError(LEFT_BEHIND);
  const prefix = `${familyId.toLowerCase()}/`;
  try {
    const pathnames: string[] = [];
    let cursor: string | undefined;
    do {
      const page = await list({ prefix, cursor, limit: 1000 });
      for (const blob of page.blobs) {
        if (blob.pathname.startsWith(prefix)) pathnames.push(blob.pathname);
      }
      cursor = page.hasMore ? page.cursor : undefined;
    } while (cursor);
    for (let i = 0; i < pathnames.length; i += 100) {
      await del(pathnames.slice(i, i + 100));
    }
  } catch (err) {
    console.error(`blob cleanup for ${familyId} failed:`, err);
    throw new DataError(LEFT_BEHIND);
  }
}
