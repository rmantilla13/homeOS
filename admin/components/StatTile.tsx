import Link from "next/link";
import type { ReactNode } from "react";
import styles from "./stat-tile.module.css";

// Label · value · context line. Values use proportional figures.
export function StatTile({
  label,
  value,
  context,
  href,
  icon,
  tone,
}: {
  label: string;
  value: string;
  context?: ReactNode;
  href?: string;
  icon?: ReactNode;
  tone?: "warn";
}) {
  const body = (
    <>
      <div className={styles.top}>
        <span className={styles.label}>{label}</span>
        {icon ? <span className={styles.icon}>{icon}</span> : null}
      </div>
      <div className={styles.value}>{value}</div>
      {context ? <div className={styles.context}>{context}</div> : null}
    </>
  );
  const cls = `${styles.tile} ${tone === "warn" ? styles.warn : ""}`;
  return href ? (
    <Link href={href} className={`${cls} ${styles.link}`}>
      {body}
    </Link>
  ) : (
    <div className={cls}>{body}</div>
  );
}
