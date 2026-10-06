"use client";

import { useCallback, useId, useRef, useState, type ReactNode } from "react";
import { AlertIcon } from "@/components/icons";
import { useToast } from "@/components/Toast";
import { useFormAction } from "@/components/useFormAction";
import type { FormAction } from "@/lib/action-result";
import styles from "./interactive.module.css";
import ui from "./ui.module.css";

type Props = {
  action: FormAction;
  fields: Record<string, string>; // hidden inputs sent with the form
  label: ReactNode; // the button that opens the dialog
  title: string;
  description?: ReactNode;
  confirmLabel: string;
  tone?: "default" | "danger";
  trigger?: "button" | "small" | "smallDanger" | "danger" | "primary";
  reason?: { name: string; label: string; required?: boolean; placeholder?: string };
  typeToConfirm?: { value: string; label: string; caseInsensitive?: boolean };
};

const TRIGGERS = {
  button: ui.button,
  primary: `${ui.button} ${ui.primary}`,
  danger: `${ui.button} ${ui.dangerOutline}`,
  small: `${ui.button} ${ui.small}`,
  smallDanger: `${ui.button} ${ui.small} ${ui.dangerOutline}`,
};

// A button that opens a confirmation dialog, optionally asking for a reason
// or a typed confirmation, and submits a server action from it.
export function ConfirmAction(props: Props) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  const titleId = useId();
  const [session, setSession] = useState(0); // new form state on every open

  const open = () => {
    setSession((s) => s + 1);
    dialogRef.current?.showModal();
  };
  const close = useCallback(() => dialogRef.current?.close(), []);

  return (
    <>
      <button type="button" className={TRIGGERS[props.trigger ?? "button"]} onClick={open}>
        {props.label}
      </button>
      <dialog
        ref={dialogRef}
        className={styles.dialog}
        aria-labelledby={titleId}
        onClick={(e) => {
          if (e.target === e.currentTarget) close(); // backdrop click
        }}
      >
        {session > 0 ? (
          <ConfirmForm key={session} {...props} titleId={titleId} close={close} />
        ) : null}
      </dialog>
    </>
  );
}

function ConfirmForm({
  action,
  fields,
  title,
  description,
  confirmLabel,
  tone = "default",
  reason,
  typeToConfirm,
  titleId,
  close,
}: Props & { titleId: string; close: () => void }) {
  const [typed, setTyped] = useState("");
  const toast = useToast();
  const inputId = useId();
  const { result: state, pending, submit } = useFormAction(action, (result) => {
    close();
    if (result?.ok && result.message) toast(result.message);
  });

  const typedOk =
    !typeToConfirm ||
    (typeToConfirm.caseInsensitive
      ? typed.trim().toLowerCase() === typeToConfirm.value.trim().toLowerCase()
      : typed.trim() === typeToConfirm.value.trim());

  return (
    <form onSubmit={submit}>
      <div className={tone === "danger" ? styles.dangerRule : styles.accentRule} />
      <div className={styles.dialogBody}>
        <h2 id={titleId} className={styles.dialogTitle}>
          {title}
        </h2>
        {description ? <div className={styles.dialogText}>{description}</div> : null}
        {Object.entries(fields).map(([name, value]) => (
          <input key={name} type="hidden" name={name} value={value} />
        ))}
        {reason ? (
          <div className={ui.field}>
            <label className={ui.label} htmlFor={`${inputId}-reason`}>
              {reason.label}
            </label>
            <textarea
              id={`${inputId}-reason`}
              name={reason.name}
              className={ui.input}
              required={reason.required}
              maxLength={500}
              placeholder={reason.placeholder}
              autoFocus
            />
          </div>
        ) : null}
        {typeToConfirm ? (
          <div className={ui.field}>
            <label className={ui.label} htmlFor={`${inputId}-confirm`}>
              {typeToConfirm.label}
            </label>
            <input
              id={`${inputId}-confirm`}
              name="confirm"
              className={ui.input}
              value={typed}
              onChange={(e) => setTyped(e.target.value)}
              autoComplete="off"
              spellCheck={false}
              autoFocus={!reason}
            />
          </div>
        ) : null}
        {state && !state.ok ? (
          <div className={`${ui.message} ${ui.messageError}`} role="alert">
            <AlertIcon size={18} />
            <div>{state.error}</div>
          </div>
        ) : null}
        <div className={styles.dialogActions}>
          <button type="button" className={ui.button} onClick={close}>
            Cancel
          </button>
          <button
            type="submit"
            className={`${ui.button} ${tone === "danger" ? ui.danger : ui.primary}`}
            disabled={pending || !typedOk}
          >
            {pending ? "Working…" : confirmLabel}
          </button>
        </div>
      </div>
    </form>
  );
}
