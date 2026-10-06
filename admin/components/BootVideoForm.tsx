"use client";

import { useRef, useState } from "react";
import {
  commitBootVideoAction,
  prepareBootVideoUploadAction,
  removeBootVideoAction,
  saveDemoBootVideoAction,
} from "@/app/(console)/actions";
import { ConfirmAction } from "@/components/ConfirmAction";
import { AlertIcon, CheckIcon } from "@/components/icons";
import { Time } from "@/components/ui";
import type { ActionResult } from "@/lib/action-result";
import type { BootVideo } from "@/lib/types";
import styles from "./boot-video.module.css";
import ui from "./ui.module.css";

const MAX_BYTES = 20 * 1024 * 1024;
const MIN_SECONDS = 0.5;
const MAX_SECONDS = 12;

function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

function isMp4(file: File): boolean {
  const type = file.type.toLowerCase();
  if (type && type !== "video/mp4" && !type.startsWith("video/mp4;")) return false;
  return type.startsWith("video/mp4") || file.name.toLowerCase().endsWith(".mp4");
}

function readDuration(file: File): Promise<number> {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file);
    const video = document.createElement("video");
    video.preload = "metadata";
    const done = (result: number | Error) => {
      URL.revokeObjectURL(url);
      if (result instanceof Error) reject(result);
      else resolve(result);
    };
    video.onloadedmetadata = () => done(video.duration);
    video.onerror = () => done(new Error("That file isn't a video we can play."));
    video.src = url;
  });
}

export function BootVideoForm({ video, demo }: { video: BootVideo | null; demo: boolean }) {
  const inputRef = useRef<HTMLInputElement>(null);
  const [file, setFile] = useState<File | null>(null);
  const [localPreview, setLocalPreview] = useState<string | null>(null);
  const [pending, setPending] = useState(false);
  const [result, setResult] = useState<ActionResult>(null);

  const preview = localPreview ?? video?.preview_url ?? null;

  function replaceFile(next: File | null) {
    setFile(next);
    if (!next && inputRef.current) inputRef.current.value = "";
    setLocalPreview((prev) => {
      if (prev) URL.revokeObjectURL(prev);
      return next ? URL.createObjectURL(next) : null;
    });
  }

  async function upload() {
    if (!file || pending) return;
    setPending(true);
    setResult(null);
    try {
      if (!isMp4(file)) {
        setResult({ ok: false, error: "Choose an MP4 file." });
        return;
      }
      if (file.size > MAX_BYTES) {
        setResult({ ok: false, error: "Boot video must be 20 MB or smaller." });
        return;
      }
      const seconds = await readDuration(file);
      if (!Number.isFinite(seconds) || seconds < MIN_SECONDS || seconds > MAX_SECONDS) {
        setResult({ ok: false, error: "Boot video must be a silent MP4 between 0.5 and 12 seconds." });
        return;
      }
      const saved = demo
        ? await saveDemoBootVideoAction(file.size, Math.round(seconds * 1000))
        : await uploadToStorage(file);
      setResult(saved);
      if (saved?.ok) replaceFile(null);
    } catch (err) {
      setResult({ ok: false, error: err instanceof Error ? err.message : "Something went wrong. Try again." });
    } finally {
      setPending(false);
    }
  }

  return (
    <div className={ui.stack}>
      {preview ? (
        <div className={styles.preview}>
          <video key={preview} src={preview} controls preload="auto" aria-label="Boot video preview" />
        </div>
      ) : (
        <p className={ui.hint}>Displays play the built-in clip until you upload one.</p>
      )}

      {video && !file ? (
        <p className={styles.meta}>
          <span>{formatBytes(video.byte_size)}</span>
          <span>{(video.duration_ms / 1000).toFixed(1)} seconds</span>
          <span>
            Updated <Time iso={video.updated_at} />
          </span>
        </p>
      ) : null}

      <div className={styles.actions}>
        <label className={`${ui.button} ${file ? "" : ui.primary}`}>
          {file ? "Choose a different MP4" : "Choose MP4"}
          <input
            ref={inputRef}
            className={styles.file}
            type="file"
            accept="video/mp4,.mp4"
            disabled={pending}
            onChange={(event) => {
              setResult(null);
              replaceFile(event.target.files?.[0] ?? null);
            }}
          />
        </label>
        {file ? (
          <button type="button" className={`${ui.button} ${ui.primary}`} disabled={pending} onClick={() => void upload()}>
            {pending ? "Uploading…" : "Upload"}
          </button>
        ) : null}
        {video ? (
          <ConfirmAction
            action={removeBootVideoAction}
            fields={{}}
            label="Remove"
            title="Use the built-in boot video?"
            description="Within six hours each display drops its copy, and the clip installed on the Pi plays from its next reboot."
            confirmLabel="Remove video"
            tone="danger"
            trigger="danger"
          />
        ) : null}
        {file ? <span className={styles.chosen}>{file.name}</span> : null}
      </div>

      <p className={ui.hint}>
        One silent MP4 for every display, up to 12 seconds and 20 MB. Each display downloads it within six hours
        and plays it from its next reboot. A file copied to /etc/homeos/boot.mp4 on a Pi still wins over this one.
      </p>

      <div aria-live="polite">
        {result && !result.ok ? (
          <span className={`${ui.message} ${ui.messageError}`}>
            <AlertIcon size={18} /> {result.error}
          </span>
        ) : result?.ok ? (
          <span className={`${ui.message} ${ui.messageOk}`}>
            <CheckIcon size={18} /> {result.message}
          </span>
        ) : null}
      </div>
    </div>
  );
}

async function uploadToStorage(file: File): Promise<ActionResult> {
  const ticket = await prepareBootVideoUploadAction();
  if (!ticket.ok) return ticket;
  // The token in the signed URL authorizes the PUT. Only a legacy anon key
  // (a JWT) may also ride as the bearer token: sb_publishable_ keys are not
  // JWTs, and Storage rejects them in Authorization.
  const headers: Record<string, string> = { "Content-Type": "video/mp4", apikey: ticket.apikey };
  if (ticket.apikey.startsWith("eyJ")) headers.Authorization = `Bearer ${ticket.apikey}`;
  const response = await fetch(ticket.signedUrl, { method: "PUT", headers, body: file });
  if (!response.ok) return { ok: false, error: "The upload didn't finish. Try again." };
  return commitBootVideoAction(ticket.path);
}
