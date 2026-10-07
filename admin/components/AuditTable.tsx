import Link from "next/link";
import { Badge, Empty, Time, ui, type Tone } from "@/components/ui";
import { describeAction } from "@/lib/format";
import type { AuditEntry } from "@/lib/types";

const TONES: Record<string, Tone> = {
  delete_family: "danger",
  delete_family_files: "danger",
  delete_user: "danger",
  delete_own_account: "danger",
  ban_user: "danger",
  revoke_platform_invite: "warn",
  set_family_status: "warn",
  create_platform_invite: "accent",
  invite_email: "accent",
  update_settings: "neutral",
  set_admin: "accent",
  unban_user: "good",
};

function tone(e: AuditEntry): Tone {
  if (e.action === "set_family_status") return e.details.status === "suspended" ? "warn" : "good";
  if (e.action === "set_admin") return e.details.make_admin ? "accent" : "warn";
  return TONES[e.action] ?? "neutral";
}

const str = (v: unknown) => (typeof v === "string" && v ? v : null);

// What the entry was about, linked where the console has a page for it.
function Target({ e }: { e: AuditEntry }) {
  const d = e.details;
  switch (e.target_type) {
    case "family": {
      // Status changes don't record the name; the id prefix still tells families apart.
      const label = str(d.name) ?? `Family ${e.target_id?.slice(0, 8) ?? ""}`.trim();
      return e.action === "delete_family" || e.action === "delete_family_files" || !e.target_id ? (
        <span>{label}</span>
      ) : (
        <Link href={`/families/${e.target_id}`}>{label}</Link>
      );
    }
    case "user": {
      const email = str(d.email);
      return e.action === "delete_user" || e.action === "delete_own_account" ? (
        <span>{email ?? e.target_id}</span>
      ) : (
        <Link href={`/users?q=${encodeURIComponent(email ?? e.target_id ?? "")}`}>{email ?? "User"}</Link>
      );
    }
    case "platform_invite":
      return (
        <Link href="/invites?all=1">
          {str(d.code) ? <span className="mono">{str(d.code)}</span> : "Invite"}
          {str(d.email) && e.action !== "revoke_platform_invite" ? ` for ${d.email}` : ""}
        </Link>
      );
    case "settings":
      return <Link href="/settings">Platform settings</Link>;
    default:
      return <span className={ui.muted}>{e.target_id ?? "—"}</span>;
  }
}

const SKIP = new Set(["name", "email", "code", "status", "make_admin", "expires_at", "demo"]);

function detailText(e: AuditEntry): string {
  return Object.entries(e.details)
    .filter(([k, v]) => !SKIP.has(k) && v !== null && v !== undefined && v !== "")
    .map(([k, v]) => {
      const key = k.replaceAll("_", " ");
      if (typeof v === "boolean") return `${key}: ${v ? "yes" : "no"}`;
      if (typeof v === "object") return `${key}: ${JSON.stringify(v)}`;
      return `${key}: ${String(v)}`;
    })
    .join(" · ");
}

export function AuditTable({ entries, compact }: { entries: AuditEntry[]; compact?: boolean }) {
  if (entries.length === 0) return <Empty title="Nothing yet">Admin actions show up here as they happen.</Empty>;
  return (
    <div className={ui.tableWrap}>
      <table className={ui.table}>
        <thead>
          <tr>
            <th scope="col">Action</th>
            <th scope="col">Target</th>
            {compact ? null : <th scope="col">Details</th>}
            {compact ? null : <th scope="col">Admin</th>}
            {compact ? null : (
              <th scope="col" className={ui.num}>
                When
              </th>
            )}
          </tr>
        </thead>
        <tbody>
          {entries.map((e) => {
            const details = detailText(e);
            return (
              <tr key={e.id}>
                <td>
                  <Badge tone={tone(e)}>{describeAction(e.action, e.details)}</Badge>
                </td>
                <td className={compact ? `${ui.primaryCell} ${ui.wrapAnywhere}` : ui.primaryCell}>
                  <Target e={e} />
                  {compact ? (
                    <span className={ui.secondaryLine}>
                      <Time iso={e.created_at} />
                      {e.admin_email ? ` · ${e.admin_email}` : ""}
                    </span>
                  ) : null}
                </td>
                {compact ? null : <td className={ui.muted}>{details || "—"}</td>}
                {compact ? null : <td className={ui.nowrap}>{e.admin_email ?? <span className={ui.muted}>system</span>}</td>}
                {compact ? null : (
                  <td className={ui.num}>
                    <Time iso={e.created_at} />
                  </td>
                )}
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
