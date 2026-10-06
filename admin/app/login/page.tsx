import type { Metadata } from "next";
import Link from "next/link";
import { LoginForm } from "@/components/LoginForm";
import { DemoBanner } from "@/components/Shell";
import { FamilyIcon } from "@/components/icons";
import { Message, readString, ui } from "@/components/ui";
import { NOT_ADMIN, isDemo } from "@/lib/data";
import { safeNextPath } from "@/lib/paths";
import { signInAction } from "./actions";
import styles from "./login.module.css";

export const metadata: Metadata = { title: "Sign in" };

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };

const ERRORS: Record<string, string> = {
  not_admin: `${NOT_ADMIN} Sign in with an admin account, or ask an admin to add you.`,
  config:
    "Supabase isn't configured. Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY and restart (see docs/ADMIN.md).",
};

export default async function LoginPage({ searchParams }: Props) {
  const sp = await searchParams;
  const demo = await isDemo();
  const code = readString(sp.error);
  const error = Object.hasOwn(ERRORS, code) ? ERRORS[code] : undefined; // not ?error=__proto__
  const next = safeNextPath(readString(sp.next));

  return (
    <>
      {demo ? <DemoBanner /> : null}
      <main className={styles.page}>
        <div className={styles.glow} aria-hidden="true" />
        <div className={styles.card}>
          <div className={styles.brand}>
            <span className={styles.orb}>
              <FamilyIcon size={24} strokeWidth={2.2} />
            </span>
            <span className={styles.brandText}>
              homeOS <span>Admin</span>
            </span>
          </div>
          <h1 className={styles.title}>Sign in</h1>
          <p className={styles.subtitle}>For homeOS platform admins only.</p>

          <div className={ui.stack}>
            {sp.signed_out ? <Message tone="ok">You&apos;re signed out.</Message> : null}
            {error ? <Message tone="error">{error}</Message> : null}
            {demo ? (
              <>
                <Message tone="info">
                  Demo mode is on, so there&apos;s no sign-in. Everything in the console is fixture data.
                </Message>
                <Link href="/" className={`${ui.button} ${ui.primary}`} style={{ height: 46 }}>
                  Open the demo console
                </Link>
              </>
            ) : (
              <LoginForm action={signInAction} next={next} />
            )}
          </div>
        </div>
        <p className={styles.footer}>Access is limited to accounts listed in platform_admins.</p>
      </main>
    </>
  );
}
