// Presigned Vercel Blob URLs for one object. The media routes sign uploads
// for phones; processing.ts signs for the sandbox that makes a wall copy.

import { issueSignedToken, presignUrl } from "@vercel/blob";

// A PUT for exactly this pathname, type and size. Phones never overwrite
// (ids are fresh, so a second PUT to the same name is a replay); a wall-copy
// job may, because a retry writes the same `-wall.mp4` again.
export async function presignedPut(
  pathname: string,
  contentType: string,
  bytes: number,
  validUntil: number,
  allowOverwrite = false,
): Promise<string> {
  const issued = await issueSignedToken({
    pathname,
    operations: ["put"],
    validUntil,
    allowedContentTypes: [contentType],
    maximumSizeInBytes: bytes,
  });
  const { presignedUrl } = await presignUrl(issued, {
    access: "private",
    operation: "put",
    pathname,
    validUntil,
    allowedContentTypes: [contentType],
    maximumSizeInBytes: bytes,
    allowOverwrite,
    addRandomSuffix: false,
  });
  return presignedUrl;
}

export async function presignedGet(pathname: string, validUntil: number): Promise<string> {
  const issued = await issueSignedToken({ pathname, operations: ["get"], validUntil });
  const { presignedUrl } = await presignUrl(issued, { access: "private", operation: "get", pathname, validUntil });
  return presignedUrl;
}
