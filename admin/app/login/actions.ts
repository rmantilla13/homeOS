"use server";

import { redirect } from "next/navigation";
import type { ActionResult } from "@/lib/action-result";
import { signIn } from "@/lib/data";
import { safeNextPath } from "@/lib/paths";

export async function signInAction(_prev: ActionResult, fd: FormData): Promise<ActionResult> {
  const email = String(fd.get("email") ?? "").trim();
  const password = String(fd.get("password") ?? "");
  if (!email || !password) return { ok: false, error: "Enter your email and password." };

  const { error } = await signIn(email, password);
  if (error) return { ok: false, error };
  redirect(safeNextPath(fd.get("next")));
}
