import type { Metadata } from "next";
import Link from "next/link";
import { FamilyIcon } from "@/components/icons";
import styles from "./public.module.css";

// Pages for the people who use Ohana Display, outside the admin console and
// its sign-in (lib/site.ts, lib/supabase/proxy.ts).
export const metadata: Metadata = {
  title: { default: "Ohana Display", template: "%s · Ohana Display" },
  robots: { index: true, follow: true },
};

export default function PublicLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <main className={styles.page}>
      <article className={styles.card}>
        <div className={styles.brand}>
          <span className={styles.orb}>
            <FamilyIcon size={22} strokeWidth={2.2} />
          </span>
          <span className={styles.brandText}>Ohana Display</span>
        </div>
        {children}
      </article>
      <nav className={styles.footer} aria-label="Ohana Display">
        <Link href="/privacy">Privacy policy</Link>
        <span aria-hidden="true">·</span>
        <Link href="/support">Help and support</Link>
      </nav>
    </main>
  );
}
