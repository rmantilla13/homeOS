// What server actions hand back to their forms (via useActionState).
export type ActionResult =
  | { ok: true; message?: string; code?: string; expiresAt?: string }
  | { ok: false; error: string; code?: string }
  | null;

export type FormAction = (prev: ActionResult, formData: FormData) => Promise<ActionResult>;
