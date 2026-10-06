import Link from "next/link";
import type { ReactNode } from "react";
import { AlertIcon, CheckIcon, ChevronLeftIcon, ChevronRightIcon, InfoIcon, SearchIcon } from "@/components/icons";
import { cssColor, formatDateTime, formatRelative } from "@/lib/format";
import styles from "./ui.module.css";

export { styles as ui };

export function PageHeader({
  title,
  subtitle,
  eyebrow,
  actions,
}: {
  title: ReactNode;
  subtitle?: ReactNode;
  eyebrow?: ReactNode;
  actions?: ReactNode;
}) {
  return (
    <header className={styles.pageHeader}>
      <div>
        {eyebrow ? <div className={styles.eyebrow}>{eyebrow}</div> : null}
        <h1 className={styles.pageTitle}>{title}</h1>
        {subtitle ? <p className={styles.pageSubtitle}>{subtitle}</p> : null}
      </div>
      {actions ? <div className={styles.headerActions}>{actions}</div> : null}
    </header>
  );
}

export function Card({
  title,
  subtitle,
  action,
  flush,
  className,
  children,
  id,
}: {
  title?: ReactNode;
  subtitle?: ReactNode;
  action?: ReactNode;
  flush?: boolean;
  className?: string;
  children: ReactNode;
  id?: string;
}) {
  return (
    <section id={id} className={[styles.card, flush ? styles.cardFlush : "", className ?? ""].join(" ")}>
      {title ? (
        <div className={styles.cardHeader}>
          <div>
            <h2 className={styles.cardTitle}>{title}</h2>
            {subtitle ? <p className={styles.cardSubtitle}>{subtitle}</p> : null}
          </div>
          {action}
        </div>
      ) : null}
      {children}
    </section>
  );
}

export type Tone = "neutral" | "accent" | "good" | "warn" | "danger";

export function Badge({ tone = "neutral", plain, children }: { tone?: Tone; plain?: boolean; children: ReactNode }) {
  return (
    <span className={[styles.badge, styles[`tone-${tone}`] ?? "", plain ? styles.badgePlain : ""].join(" ")}>
      {children}
    </span>
  );
}

const STATUS_TONES: Record<string, Tone> = {
  active: "good",
  accepted: "accent",
  used: "neutral",
  expired: "warn",
  revoked: "danger",
  suspended: "danger",
};

export function StatusBadge({ status }: { status: string }) {
  return <Badge tone={STATUS_TONES[status] ?? "neutral"}>{status[0].toUpperCase() + status.slice(1)}</Badge>;
}

const MESSAGE = {
  error: { cls: styles.messageError, Icon: AlertIcon },
  warn: { cls: styles.messageWarn, Icon: AlertIcon },
  ok: { cls: styles.messageOk, Icon: CheckIcon },
  info: { cls: styles.messageInfo, Icon: InfoIcon },
};

export function Message({ tone, children }: { tone: keyof typeof MESSAGE; children: ReactNode }) {
  const { cls, Icon } = MESSAGE[tone];
  return (
    <div className={`${styles.message} ${cls}`} role={tone === "error" ? "alert" : "status"}>
      <Icon size={18} />
      <div>{children}</div>
    </div>
  );
}

// A relative time ("3 days ago") with the exact UTC time on hover.
export function Time({ iso, fallback = "never" }: { iso: string | null | undefined; fallback?: string }) {
  if (!iso) return <span className={styles.muted}>{fallback}</span>;
  return (
    <time dateTime={iso} title={formatDateTime(iso)} className={styles.nowrap}>
      {formatRelative(iso)}
    </time>
  );
}

// Member colors come from families, so only hex colors are drawn; anything
// else gets the empty ring.
export function Swatch({ color }: { color: string }) {
  const safe = cssColor(color);
  return <span className={styles.swatch} style={safe ? { background: safe } : undefined} aria-hidden="true" />;
}

export function Empty({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className={styles.empty}>
      <p className={styles.emptyTitle}>{title}</p>
      {children ? <p>{children}</p> : null}
    </div>
  );
}

// GET search form; the page reads ?q= and resets to page 1.
export function SearchForm({ placeholder, defaultValue, label }: { placeholder: string; defaultValue?: string; label: string }) {
  return (
    <form className={styles.search} role="search" method="get">
      <SearchIcon size={18} />
      <label className="visually-hidden" htmlFor="q">
        {label}
      </label>
      <input
        id="q"
        className={styles.input}
        type="search"
        name="q"
        placeholder={placeholder}
        defaultValue={defaultValue}
        autoComplete="off"
      />
      <button type="submit" className={styles.button}>
        Search
      </button>
    </form>
  );
}

export function Pagination({
  page,
  hasMore,
  href,
  shown,
}: {
  page: number;
  hasMore: boolean;
  href: (page: number) => string;
  shown: number;
}) {
  if (page <= 1 && !hasMore) return null;
  return (
    <nav className={styles.pagination} aria-label="Pagination">
      <span>
        Page {page} · {shown} shown
      </span>
      <div>
        {page > 1 ? (
          <Link className={`${styles.button} ${styles.small}`} href={href(page - 1)}>
            <ChevronLeftIcon size={16} /> Previous
          </Link>
        ) : null}
        {hasMore ? (
          <Link className={`${styles.button} ${styles.small}`} href={href(page + 1)}>
            Next <ChevronRightIcon size={16} />
          </Link>
        ) : null}
      </div>
    </nav>
  );
}

// Builds "?q=..&page=.." links that keep the other parameters.
export function pageHref(path: string, params: Record<string, string | undefined>) {
  return (page: number) => {
    const sp = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) if (v) sp.set(k, v);
    if (page > 1) sp.set("page", String(page));
    const qs = sp.toString();
    return qs ? `${path}?${qs}` : path;
  };
}

export function readPage(value: string | string[] | undefined): number {
  const n = Number(Array.isArray(value) ? value[0] : value);
  return Number.isInteger(n) && n > 0 && n < 100_000 ? n : 1;
}

export function readString(value: string | string[] | undefined): string {
  return (Array.isArray(value) ? value[0] : value)?.trim().slice(0, 200) ?? "";
}
