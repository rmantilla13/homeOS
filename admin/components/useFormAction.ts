"use client";

import { useState, useTransition, type FormEvent } from "react";
import type { ActionResult, FormAction } from "@/lib/action-result";

// Submits a form to a server action without React's automatic form reset, so
// a failed submit keeps what the admin typed. `onSuccess` runs once per
// successful result.
export function useFormAction(action: FormAction, onSuccess?: (result: ActionResult, form: HTMLFormElement) => void) {
  const [result, setResult] = useState<ActionResult>(null);
  const [pending, startTransition] = useTransition();

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = event.currentTarget;
    const data = new FormData(form);
    startTransition(async () => {
      const next = await action(null, data);
      setResult(next);
      if (next?.ok) onSuccess?.(next, form);
    });
  }

  return { result, pending, submit, reset: () => setResult(null) };
}
