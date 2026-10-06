// Which Storage object an admin may sign or delete for one family.
// Kept free of I/O so media.test.ts can pin the rules.
//
// Objects live at `<family_id>/<file>`: one segment, no `..`, no leading
// dot, and the folder is that family's id in lowercase. Anything else is
// refused here even if a row names it, so a bad path can't be signed.

import { isUuid } from "../_shared/http.ts";

export type SignableMedia = {
  kind: string;
  storage_path: string;
  thumbnail_path: string | null;
};

/** The path when it is an object in this family's folder, otherwise null. */
export function mediaObjectPath(familyId: string, path: string | null | undefined): string | null {
  if (!isUuid(familyId) || typeof path !== "string" || path.length === 0) return null;
  const folder = familyId.toLowerCase();
  const slash = path.indexOf("/");
  if (slash !== folder.length || path.indexOf("/", slash + 1) !== -1) return null;
  const file = path.slice(slash + 1);
  if (file.length === 0 || file.length > 200 || file.includes("..") || file.startsWith(".")) return null;
  if (path !== `${folder}/${file}`) return null;
  return path;
}

/**
 * The object to show in the console: the thumbnail when there is one,
 * otherwise the photo itself. Videos without a poster have nothing to sign.
 */
export function signableMediaPath(familyId: string, row: SignableMedia): string | null {
  const thumb = mediaObjectPath(familyId, row.thumbnail_path);
  if (thumb) return thumb;
  if (row.kind === "photo") return mediaObjectPath(familyId, row.storage_path);
  return null;
}
