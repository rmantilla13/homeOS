// Storage and the platform_boot_video row for the admin function. The service
// role stays here: the console and the Pi never see it. Reads are not audited
// (opening Settings would flood the log); upload and remove are.

import type { SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { json } from "../_shared/http.ts";
import {
  assessBootVideo,
  BOOT_BUCKET,
  BOOT_MAX_BYTES,
  BOOT_OBJECT,
  BOOT_URL_SECONDS,
  isPendingBootPath,
  newPendingBootPath,
} from "./boot-video.ts";

type Audit = (
  adminId: string,
  action: string,
  targetType: string,
  targetId: string,
  details: Record<string, unknown>,
) => Promise<void>;

export function absoluteStorageUrl(supabaseUrl: string, signedUrl: string): string {
  if (/^https?:\/\//i.test(signedUrl)) return signedUrl;
  const root = supabaseUrl.replace(/\/$/, "");
  if (signedUrl.startsWith("/storage/")) return `${root}${signedUrl}`;
  if (signedUrl.startsWith("/")) return `${root}/storage/v1${signedUrl}`;
  return `${root}/storage/v1/${signedUrl}`;
}

type BootRow = { byte_size: number; duration_ms: number; updated_at: string };

export async function getBootVideo(service: SupabaseClient, supabaseUrl: string): Promise<Response> {
  const { data, error } = await service.from("platform_boot_video")
    .select("byte_size, duration_ms, updated_at")
    .eq("id", true)
    .maybeSingle();
  if (error) return json({ error: error.message }, 500);
  const row = data as BootRow | null;
  if (!row) return json({ video: null });

  const { data: signed, error: signErr } = await service.storage.from(BOOT_BUCKET)
    .createSignedUrl(BOOT_OBJECT, BOOT_URL_SECONDS);
  if (signErr) console.error("boot video sign failed:", signErr.message);
  const preview = signed?.signedUrl ? absoluteStorageUrl(supabaseUrl, signed.signedUrl) : null;
  return json({
    video: {
      byte_size: row.byte_size,
      duration_ms: row.duration_ms,
      updated_at: row.updated_at,
      preview_url: preview,
    },
  });
}

export async function createBootVideoUpload(service: SupabaseClient, supabaseUrl: string): Promise<Response> {
  const path = newPendingBootPath();
  const { data, error } = await service.storage.from(BOOT_BUCKET).createSignedUploadUrl(path);
  if (error || !data?.signedUrl || !data.token) return json({ error: error?.message ?? "couldn't start the upload" }, 500);
  return json({
    path,
    signed_url: absoluteStorageUrl(supabaseUrl, data.signedUrl),
    token: data.token,
  });
}

async function readPending(service: SupabaseClient, path: string): Promise<Uint8Array | Response> {
  const { data, error } = await service.storage.from(BOOT_BUCKET).download(path);
  if (error || !data) return json({ error: "that upload wasn't found. Choose the video again." }, 400);
  if (data.size > BOOT_MAX_BYTES) {
    await service.storage.from(BOOT_BUCKET).remove([path]);
    return json({ error: "boot video must be 20 MB or smaller" }, 400);
  }
  return new Uint8Array(await data.arrayBuffer());
}

export async function commitBootVideo(
  service: SupabaseClient,
  adminId: string,
  path: string,
  audit: Audit,
): Promise<Response> {
  if (!isPendingBootPath(path)) return json({ error: "that upload wasn't found. Choose the video again." }, 400);
  const downloaded = await readPending(service, path);
  if (downloaded instanceof Response) return downloaded;
  const verdict = assessBootVideo(downloaded);
  if ("error" in verdict) {
    await service.storage.from(BOOT_BUCKET).remove([path]);
    return json({ error: verdict.error }, 400);
  }

  const { error: upErr } = await service.storage.from(BOOT_BUCKET).upload(BOOT_OBJECT, downloaded, {
    contentType: "video/mp4",
    upsert: true,
  });
  if (upErr) return json({ error: upErr.message }, 500);

  const updatedAt = new Date().toISOString();
  const { error: rowErr } = await service.from("platform_boot_video").upsert({
    id: true,
    byte_size: downloaded.byteLength,
    duration_ms: verdict.durationMs,
    updated_at: updatedAt,
    updated_by: adminId,
  });
  if (rowErr) return json({ error: rowErr.message }, 500);

  const pending = await service.storage.from(BOOT_BUCKET).remove([path]);
  if (pending.error) console.error("boot video pending cleanup failed:", pending.error.message);

  await audit(adminId, "set_boot_video", "boot_video", BOOT_OBJECT, {
    bucket: BOOT_BUCKET,
    byte_size: downloaded.byteLength,
    duration_ms: verdict.durationMs,
  });
  return json({
    ok: true,
    video: {
      byte_size: downloaded.byteLength,
      duration_ms: verdict.durationMs,
      updated_at: updatedAt,
    },
  });
}

export async function removeBootVideo(service: SupabaseClient, adminId: string, audit: Audit): Promise<Response> {
  const { error: rmErr } = await service.storage.from(BOOT_BUCKET).remove([BOOT_OBJECT]);
  if (rmErr) return json({ error: rmErr.message }, 500);
  const { error } = await service.from("platform_boot_video").delete().eq("id", true);
  if (error) return json({ error: error.message }, 500);
  await audit(adminId, "remove_boot_video", "boot_video", BOOT_OBJECT, { bucket: BOOT_BUCKET });
  return json({ ok: true });
}
