import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { deleteFamilyAction, setFamilyStatusAction } from "@/app/(console)/actions";
import { ConfirmAction } from "@/components/ConfirmAction";
import { CopyButton } from "@/components/CopyButton";
import { ChevronLeftIcon } from "@/components/icons";
import { Badge, Card, Empty, Message, PageHeader, StatusBadge, Swatch, Time, ui } from "@/components/ui";
import { UsageChart } from "@/components/UsageChart";
import { getFamilyDetail, requireAdmin } from "@/lib/data";
import { formatDate, formatNumber, plural } from "@/lib/format";
import type { FamilyDetail, Member } from "@/lib/types";
import styles from "./family.module.css";

type Props = { params: Promise<{ id: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { id } = await params;
  const detail = await getFamilyDetail(id).catch(() => null);
  return { title: detail?.family.name ?? "Family" };
}

export default async function FamilyPage({ params }: Props) {
  await requireAdmin();
  const { id } = await params;
  const detail = await getFamilyDetail(id);
  if (!detail) notFound();
  const { family, members, devices, invites, usage_by_day } = detail;
  const suspended = family.status === "suspended";
  const parents = members.filter((m) => m.role === "parent").length;

  return (
    <>
      <PageHeader
        eyebrow={
          <Link href="/families">
            <ChevronLeftIcon size={14} /> Families
          </Link>
        }
        title={
          <span className={styles.title}>
            {family.name} <StatusBadge status={family.status} />
          </span>
        }
        subtitle={
          <>
            Created {formatDate(family.created_at)} · {family.timezone} · last active <Time iso={family.last_activity} />
          </>
        }
        actions={<FamilyActions detail={detail} />}
      />

      {suspended ? (
        <div className={styles.notice}>
          <Message tone="warn">
            <strong>Suspended</strong>
            {family.suspended_at ? (
              <>
                {" "}
                <Time iso={family.suspended_at} />
              </>
            ) : null}
            . Its members and displays can&apos;t see any of its data.
            {family.suspended_reason ? <> Reason: {family.suspended_reason}</> : null}
          </Message>
        </div>
      ) : null}

      <div className={styles.top}>
        <Card title="Details">
          <dl className={ui.definition}>
            <div>
              <dt>Family id</dt>
              <dd className={styles.idRow}>
                <code className={styles.id}>{family.id}</code>
                <CopyButton text={family.id} ariaLabel="Copy family id" />
              </dd>
            </div>
            <div>
              <dt>People</dt>
              <dd>
                {plural(members.length, "member")}, {plural(parents, "parent")}
              </dd>
            </div>
            <div>
              <dt>Displays</dt>
              <dd>{formatNumber(devices.length)}</dd>
            </div>
            <div>
              <dt>Assistant daily limit</dt>
              <dd>
                {family.assistant_daily_limit != null
                  ? `${formatNumber(family.assistant_daily_limit)} (family override)`
                  : family.assistant_daily_limit_effective != null
                    ? `${formatNumber(family.assistant_daily_limit_effective)} (platform default)`
                    : "Platform default"}
              </dd>
            </div>
          </dl>
        </Card>
        <Card title="Assistant usage" subtitle="Last 30 days (UTC)">
          <UsageChart days={usage_by_day} height={110} label={`${family.name} assistant usage`} />
        </Card>
      </div>

      <div className={ui.stack}>
        <Card title="Members" subtitle="Everyone shown on the family screen. Kids usually have no account." flush>
          {members.length === 0 ? <Empty title="No members" /> : <MembersTable members={members} />}
        </Card>

        <Card title="Displays" subtitle="Paired wall screens. Each signs in as its own device account." flush>
          {devices.length === 0 ? (
            <Empty title="No displays paired yet" />
          ) : (
            <div className={ui.tableWrap}>
              <table className={ui.table}>
                <thead>
                  <tr>
                    <th scope="col">Display</th>
                    <th scope="col">Last seen</th>
                    <th scope="col">Paired</th>
                  </tr>
                </thead>
                <tbody>
                  {devices.map((d) => (
                    <tr key={d.id}>
                      <td className={ui.primaryCell}>
                        {d.name}
                        <span className={ui.secondaryLine}>
                          <Link href={`/users?q=${d.user_id}`}>Device account</Link>
                        </span>
                      </td>
                      <td>
                        <Time iso={d.last_seen_at} />
                      </td>
                      <td className={ui.nowrap}>{formatDate(d.created_at)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </Card>

        <Card title="Family invites" subtitle="Invites parents created to bring people into this family." flush>
          {invites.length === 0 ? (
            <Empty title="No family invites" />
          ) : (
            <div className={ui.tableWrap}>
              <table className={ui.table}>
                <thead>
                  <tr>
                    <th scope="col">Code</th>
                    <th scope="col">Status</th>
                    <th scope="col">Role</th>
                    <th scope="col">For</th>
                    <th scope="col">Invited by</th>
                    <th scope="col">Created</th>
                    <th scope="col">Expires</th>
                  </tr>
                </thead>
                <tbody>
                  {invites.map((i) => {
                    const claims = i.member_id ? members.find((m) => m.id === i.member_id) : null;
                    return (
                      <tr key={i.id}>
                        <td>
                          <span className={ui.code}>{i.code}</span>
                        </td>
                        <td>
                          <StatusBadge status={i.status} />
                        </td>
                        <td>
                          <RoleBadge role={i.role} />
                        </td>
                        <td>
                          {i.email ?? <span className={ui.muted}>Anyone with the code</span>}
                          {claims ? <span className={ui.secondaryLine}>Links to {claims.display_name}</span> : null}
                        </td>
                        <td className={ui.nowrap}>{i.invited_by_email ?? <span className={ui.muted}>—</span>}</td>
                        <td className={ui.nowrap}>{formatDate(i.created_at)}</td>
                        <td className={ui.nowrap}>
                          {i.status === "accepted" ? (
                            <span className={ui.muted}>Accepted {formatDate(i.accepted_at)}</span>
                          ) : (
                            formatDate(i.expires_at)
                          )}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </Card>
      </div>
    </>
  );
}

function RoleBadge({ role }: { role: string }) {
  return (
    <Badge tone={role === "parent" ? "accent" : "neutral"} plain>
      {role[0].toUpperCase() + role.slice(1)}
    </Badge>
  );
}

function MembersTable({ members }: { members: Member[] }) {
  return (
    <div className={ui.tableWrap}>
      <table className={ui.table}>
        <thead>
          <tr>
            <th scope="col">Name</th>
            <th scope="col">Role</th>
            <th scope="col">Account</th>
            <th scope="col">Added</th>
          </tr>
        </thead>
        <tbody>
          {members.map((m) => (
            <tr key={m.id}>
              <td className={ui.primaryCell}>
                <span className={styles.member}>
                  <Swatch color={m.color} />
                  {m.display_name}
                </span>
                {m.profile_name && m.profile_name !== m.display_name ? (
                  <span className={ui.secondaryLine}>Profile: {m.profile_name}</span>
                ) : null}
              </td>
              <td>
                <RoleBadge role={m.role} />
              </td>
              <td>
                {m.user_id ? (
                  <Link href={`/users?q=${encodeURIComponent(m.email ?? m.user_id)}`}>{m.email ?? "Linked account"}</Link>
                ) : (
                  <span className={ui.muted}>No account</span>
                )}
              </td>
              <td className={ui.nowrap}>{formatDate(m.created_at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function FamilyActions({ detail }: { detail: FamilyDetail }) {
  const { family, members, devices } = detail;
  const suspended = family.status === "suspended";
  return (
    <>
      {suspended ? (
        <ConfirmAction
          action={setFamilyStatusAction}
          fields={{ family_id: family.id, status: "active" }}
          label="Reactivate"
          trigger="primary"
          title={`Reactivate ${family.name}?`}
          description="Its members and displays get their data back right away."
          reason={{ name: "reason", label: "Note for the audit log (optional)", placeholder: "e.g. Confirmed with the family by email" }}
          confirmLabel="Reactivate family"
        />
      ) : (
        <ConfirmAction
          action={setFamilyStatusAction}
          fields={{ family_id: family.id, status: "suspended" }}
          label="Suspend"
          title={`Suspend ${family.name}?`}
          description="Members and displays lose access to the family's data immediately, and the assistant stops answering for it. Nothing is deleted; you can reactivate it at any time."
          reason={{ name: "reason", label: "Reason", required: true, placeholder: "Shown to other admins and kept in the audit log" }}
          confirmLabel="Suspend family"
          tone="danger"
        />
      )}
      <ConfirmAction
        action={deleteFamilyAction}
        fields={{ family_id: family.id }}
        label="Delete"
        trigger="danger"
        tone="danger"
        title={`Delete ${family.name}?`}
        description={
          <>
            This permanently deletes the family and all of its data:{" "}
            <strong>
              {plural(members.length, "member")} and {plural(devices.length, "display")}
            </strong>{" "}
            (with their display accounts), calendar, chores, rewards, lists, photos and videos, and assistant
            history. People keep their own accounts. <strong>This can&apos;t be undone.</strong>
          </>
        }
        typeToConfirm={{ value: family.name, label: `Type “${family.name}” to confirm` }}
        confirmLabel="Delete family"
      />
    </>
  );
}
