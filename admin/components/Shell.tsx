import Link from "next/link";
import type { ReactNode } from "react";
import { signOutAction } from "@/app/(console)/actions";
import { FamilyIcon, SignOutIcon } from "@/components/icons";
import { NavLinks } from "@/components/NavLinks";
import { ToastProvider } from "@/components/Toast";
import styles from "./shell.module.css";

export function Brand() {
  return (
    <Link href="/" className={styles.brand}>
      <span className={styles.orb}>
        <FamilyIcon size={20} strokeWidth={2.2} />
      </span>
      <span className={styles.brandText}>
        <span className={styles.brandName}>Ohana</span>
        <span className={styles.brandRole}>Admin</span>
      </span>
    </Link>
  );
}

export function DemoBanner() {
  return (
    <div className={styles.demoBanner} role="note">
      <span className={styles.demoPill}>Demo data</span>
      <span>
        <strong>Sign-in is off and nothing here is real.</strong> Fixture data from NEXT_PUBLIC_ADMIN_DEMO=1; changes
        reset when the server restarts.
      </span>
    </div>
  );
}

export function Shell({ email, demo, children }: { email: string; demo: boolean; children: ReactNode }) {
  return (
    <div className={styles.shell}>
      <aside className={styles.sidebar}>
        <div className={styles.sidebarInner}>
          <Brand />
          <NavLinks />
          <div className={styles.account}>
            <span className={styles.accountLabel}>Signed in as</span>
            <span className={styles.accountEmail} title={email}>
              {email}
            </span>
            <form action={signOutAction}>
              <button type="submit" className={styles.signOut}>
                <SignOutIcon size={18} />
                Sign out
              </button>
            </form>
          </div>
        </div>
      </aside>
      <div className={styles.main}>
        {demo ? <DemoBanner /> : null}
        <main className={styles.content}>
          <ToastProvider>{children}</ToastProvider>
        </main>
      </div>
    </div>
  );
}
