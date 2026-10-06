"use client";

import { useState } from "react";
import { CopyButton } from "@/components/CopyButton";
import { AlertIcon } from "@/components/icons";
import { useFormAction } from "@/components/useFormAction";
import type { FormAction } from "@/lib/action-result";
import { formatDate } from "@/lib/format";
import styles from "./interactive.module.css";
import ui from "./ui.module.css";

// Creates a platform invite (lets someone start a new family). With "Email
// it" on, the admin edge function creates the invite and Supabase Auth sends
// the email; that path always makes a single-use, 30-day invite.
export function InviteForm({ action }: { action: FormAction }) {
  const [hasEmail, setHasEmail] = useState(false);
  const [emailing, setEmailing] = useState(false);
  const { result, pending, submit } = useFormAction(action, (_result, form) => {
    form.reset();
    setHasEmail(false);
    setEmailing(false);
  });
  const sending = emailing && hasEmail;

  return (
    <div className={ui.stack}>
      <form onSubmit={submit} className={styles.formGrid}>
        <div className={ui.field}>
          <label className={ui.label} htmlFor="invite-email">
            Email <span className={ui.muted}>(optional)</span>
          </label>
          <input
            id="invite-email"
            name="email"
            type="email"
            className={ui.input}
            placeholder="name@example.com"
            autoComplete="off"
            onChange={(e) => setHasEmail(e.target.value.trim() !== "")}
          />
          <span className={ui.hint}>If set, only this email can redeem the code.</span>
        </div>
        <div className={ui.field}>
          <label className={ui.label} htmlFor="invite-note">
            Note <span className={ui.muted}>(optional)</span>
          </label>
          <input id="invite-note" name="note" className={ui.input} maxLength={500} placeholder="Who it's for, where it was shared" />
          <span className={ui.hint}>Only admins see this.</span>
        </div>
        <div className={ui.field}>
          <label className={ui.label} htmlFor="invite-uses">
            Max uses
          </label>
          <input
            id="invite-uses"
            name="max_uses"
            type="number"
            min={1}
            max={10000}
            defaultValue={1}
            required
            className={ui.input}
            disabled={sending}
          />
          <span className={ui.hint}>Each use creates one new family.</span>
        </div>
        <div className={ui.field}>
          <label className={ui.label} htmlFor="invite-days">
            Expires after (days)
          </label>
          <input
            id="invite-days"
            name="expires_in_days"
            type="number"
            min={1}
            max={365}
            defaultValue={30}
            required
            className={ui.input}
            disabled={sending}
          />
          <span className={ui.hint}>Between 1 and 365 days.</span>
        </div>
        <div className={`${styles.span2} ${styles.formFooter}`}>
          <label className={styles.checkboxRow}>
            <input
              type="checkbox"
              name="send_email"
              disabled={!hasEmail}
              checked={sending}
              onChange={(e) => setEmailing(e.target.checked)}
            />
            <span>
              Email the invite to this address
              <span className={ui.secondaryLine}>Sent by Supabase Auth. Emailed invites are single-use and last 30 days.</span>
            </span>
          </label>
          <button type="submit" className={`${ui.button} ${ui.primary}`} disabled={pending}>
            {pending ? "Creating…" : sending ? "Create and email" : "Create invite"}
          </button>
        </div>
      </form>

      {result && !result.ok ? (
        <div className={`${ui.message} ${ui.messageError}`} role="alert">
          <AlertIcon size={18} />
          <div>
            {result.error}
            {result.code ? (
              <>
                {" "}
                Code: <strong className="mono">{result.code}</strong>
              </>
            ) : null}
          </div>
        </div>
      ) : null}

      {result?.ok && result.code ? (
        <div className={styles.result} role="status">
          <div className={ui.label}>{result.message ?? "Invite created."} Share this code:</div>
          <div className={styles.resultCode}>
            {result.code}
            <CopyButton text={result.code} ariaLabel={`Copy invite code ${result.code}`} />
          </div>
          <div className={styles.resultMeta}>
            App link: <code>homeos://invite/{result.code}</code>{" "}
            <CopyButton text={`homeos://invite/${result.code}`} label="Copy link" ariaLabel="Copy app link" />
            {result.expiresAt ? <> · expires {formatDate(result.expiresAt)}</> : null}
          </div>
        </div>
      ) : null}
    </div>
  );
}
