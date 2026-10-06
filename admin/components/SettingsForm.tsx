"use client";

import { AlertIcon, CheckIcon } from "@/components/icons";
import { useFormAction } from "@/components/useFormAction";
import type { FormAction } from "@/lib/action-result";
import type { Settings } from "@/lib/types";
import styles from "./interactive.module.css";
import ui from "./ui.module.css";

export function SettingsForm({ action, settings }: { action: FormAction; settings: Settings }) {
  const { result, pending, submit, reset } = useFormAction(action);

  return (
    <form onSubmit={submit} onChange={reset} className={ui.stack}>
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
              Counted per UTC day. A family can have its own limit, set in the database
              (families.assistant_daily_limit). 0 blocks the assistant for families without their own limit.
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
