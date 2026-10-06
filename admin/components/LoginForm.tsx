"use client";

import { AlertIcon } from "@/components/icons";
import { useFormAction } from "@/components/useFormAction";
import type { FormAction } from "@/lib/action-result";
import ui from "./ui.module.css";

export function LoginForm({ action, next }: { action: FormAction; next: string }) {
  const { result, pending, submit } = useFormAction(action);
  return (
    <form onSubmit={submit} className={ui.stack}>
      <input type="hidden" name="next" value={next} />
      <div className={ui.field}>
        <label className={ui.label} htmlFor="email">
          Email
        </label>
        <input id="email" name="email" type="email" autoComplete="username" required className={ui.input} autoFocus />
      </div>
      <div className={ui.field}>
        <label className={ui.label} htmlFor="password">
          Password
        </label>
        <input id="password" name="password" type="password" autoComplete="current-password" required className={ui.input} />
      </div>
      {result && !result.ok ? (
        <div className={`${ui.message} ${ui.messageError}`} role="alert">
          <AlertIcon size={18} />
          <div>{result.error}</div>
        </div>
      ) : null}
      <button type="submit" className={`${ui.button} ${ui.primary}`} disabled={pending} style={{ height: 46 }}>
        {pending ? "Signing in…" : "Sign in"}
      </button>
    </form>
  );
}
