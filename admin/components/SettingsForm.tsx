"use client";

import { AlertIcon, CheckIcon } from "@/components/icons";
import { useFormAction } from "@/components/useFormAction";
import type { FormAction } from "@/lib/action-result";
import { bytesToGiB, bytesToMiB } from "@/lib/format";
import type { Settings } from "@/lib/types";
import styles from "./interactive.module.css";
import ui from "./ui.module.css";

export function SettingsForm({ action, settings }: { action: FormAction; settings: Settings }) {
  const { result, pending, submit, reset } = useFormAction(action);

  return (
    // Remounted when the saved settings change, so the switches show what's
    // saved now (including other admins' changes) rather than stale defaults.
    <form key={settings.updated_at ?? ""} onSubmit={submit} onChange={reset} className={ui.stack}>
      {/* The values this form started from; the action saves only what changed. */}
      <input type="hidden" name="was_invite_only" value={String(settings.invite_only)} />
      <input type="hidden" name="was_assistant_enabled" value={String(settings.assistant_enabled)} />
      <input type="hidden" name="was_assistant_daily_limit" value={String(settings.assistant_daily_limit)} />
      <input type="hidden" name="was_storage_limit_bytes" value={String(settings.storage_limit_bytes)} />
      <input type="hidden" name="was_media_max_bytes" value={String(settings.media_max_bytes)} />
      <input type="hidden" name="was_media_item_limit" value={String(settings.media_item_limit)} />
      <div>
        <div className={styles.switchRow}>
          <label className={styles.switchText} htmlFor="invite_only">
            <span className={styles.switchLabel}>Invite-only sign-up</span>
            <span className={styles.switchHint}>
              New families need a platform invite, and new accounts need a platform or family invite code. Turn off to
              let anyone sign up and create a family.
            </span>
          </label>
          <input
            id="invite_only"
            name="invite_only"
            type="checkbox"
            role="switch"
            className={styles.switch}
            defaultChecked={settings.invite_only}
          />
        </div>
        <div className={styles.switchRow}>
          <label className={styles.switchText} htmlFor="assistant_enabled">
            <span className={styles.switchLabel}>Family assistant</span>
            <span className={styles.switchHint}>
              When off, the assistant answers every family with “The assistant is turned off right now.” Use it to stop
              all model spend at once.
            </span>
          </label>
          <input
            id="assistant_enabled"
            name="assistant_enabled"
            type="checkbox"
            role="switch"
            className={styles.switch}
            defaultChecked={settings.assistant_enabled}
          />
        </div>
        <div className={styles.switchRow}>
          <label className={styles.switchText} htmlFor="assistant_daily_limit">
            <span className={styles.switchLabel}>Assistant requests per family per day</span>
            <span className={styles.switchHint}>
              Counted per UTC day. A family can have its own limit, set on its page. 0 blocks the assistant for
              families without their own limit.
            </span>
          </label>
          <input
            id="assistant_daily_limit"
            name="assistant_daily_limit"
            type="number"
            min={0}
            max={1000000}
            step={1}
            required
            className={ui.input}
            style={{ width: 120, flex: "none" }}
            defaultValue={settings.assistant_daily_limit}
          />
        </div>
        <div className={styles.switchRow}>
          <label className={styles.switchText} htmlFor="storage_gib">
            <span className={styles.switchLabel}>Storage per family</span>
            <span className={styles.switchHint}>
              Gibibytes (1 GB here is 1024³ bytes). A family can have its own quota. 0 blocks new uploads for families
              on the default.
            </span>
          </label>
          <input
            id="storage_gib"
            name="storage_gib"
            type="number"
            min={0}
            max={1024}
            step={0.1}
            required
            className={ui.input}
            style={{ width: 120, flex: "none" }}
            defaultValue={bytesToGiB(settings.storage_limit_bytes)}
          />
        </div>
        <div className={styles.switchRow}>
          <label className={styles.switchText} htmlFor="media_max_mib">
            <span className={styles.switchLabel}>Largest file</span>
            <span className={styles.switchHint}>Mebibytes. Applies to every family. Photos and their posters count separately.</span>
          </label>
          <input
            id="media_max_mib"
            name="media_max_mib"
            type="number"
            min={1}
            max={5120}
            step={1}
            required
            className={ui.input}
            style={{ width: 120, flex: "none" }}
            defaultValue={bytesToMiB(settings.media_max_bytes)}
          />
        </div>
        <div className={styles.switchRow}>
          <label className={styles.switchText} htmlFor="media_item_limit">
            <span className={styles.switchLabel}>Items per family</span>
            <span className={styles.switchHint}>
              How many photos and videos a family can keep. A poster is not a separate item. 0 blocks new uploads for
              families on the default.
            </span>
          </label>
          <input
            id="media_item_limit"
            name="media_item_limit"
            type="number"
            min={0}
            max={1000000}
            step={1}
            required
            className={ui.input}
            style={{ width: 120, flex: "none" }}
            defaultValue={settings.media_item_limit}
          />
        </div>
      </div>

      <div className={styles.formFooter}>
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
        <button type="submit" className={`${ui.button} ${ui.primary}`} disabled={pending}>
          {pending ? "Saving…" : "Save settings"}
        </button>
      </div>
    </form>
  );
}
