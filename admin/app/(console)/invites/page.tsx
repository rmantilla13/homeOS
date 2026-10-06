import type { Metadata } from "next";
import Link from "next/link";
import { createInviteAction, revokeInviteAction } from "@/app/(console)/actions";
import { ConfirmAction } from "@/components/ConfirmAction";
import { CopyButton } from "@/components/CopyButton";
import { InviteForm } from "@/components/InviteForm";
import { Card, Empty, PageHeader, StatusBadge, Time, ui } from "@/components/ui";
import { listPlatformInvites, requireAdmin } from "@/lib/data";
import { formatDate, formatNumber } from "@/lib/format";
import styles from "./invites.module.css";

export const metadata: Metadata = { title: "Invites" };

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };

export default async function InvitesPage({ searchParams }: Props) {
  await requireAdmin();
  const all = (await searchParams).all === "1";
  const invites = await listPlatformInvites(all);

  return (
    <>
      <PageHeader
        title="Invites"
        subtitle="homeOS is invite-only. A platform invite lets someone start a new family; families invite their own people from the app."
      />
      <div className={ui.stack}>
        <Card title="New platform invite">
          <InviteForm action={createInviteAction} />
        </Card>

        <Card
          flush
          title={all ? "All platform invites" : "Open platform invites"}
          subtitle={all ? "Including used, expired and revoked invites." : "Invites that can still be redeemed."}
          action={
            <Link href={all ? "/invites" : "/invites?all=1"} className={styles.toggle}>
              {all ? "Show open only" : "Show all"}
            </Link>
          }
        >
          {invites.length === 0 ? (
            <Empty title={all ? "No invites yet" : "No open invites"}>
              {all ? "Create one above." : "Create one above, or show all to see used and expired ones."}
            </Empty>
          ) : (
            <div className={ui.tableWrap}>
              <table className={ui.table}>
                <thead>
                  <tr>
                    <th scope="col">Code</th>
                    <th scope="col">Status</th>
                    <th scope="col">For</th>
                    <th scope="col" className={ui.num}>
                      Uses
                    </th>
                    <th scope="col">Expires</th>
                    <th scope="col">Created</th>
                    <th scope="col" className={ui.num}>
                      <span className="visually-hidden">Actions</span>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {invites.map((i) => (
                    <tr key={i.id}>
                      <td>
                        <span className={ui.code}>{i.code}</span>
                      </td>
                      <td>
                        <StatusBadge status={i.status} />
                      </td>
                      <td className={styles.forCell}>
                        {i.email ?? <span className={ui.muted}>Anyone with the code</span>}
                        {i.note ? <span className={ui.secondaryLine}>{i.note}</span> : null}
                      </td>
                      <td className={ui.num}>
                        {formatNumber(i.use_count)} / {formatNumber(i.max_uses)}
                      </td>
                      <td className={ui.nowrap}>
                        {i.status === "revoked" ? (
                          <span className={ui.muted}>Revoked {formatDate(i.revoked_at)}</span>
                        ) : (
                          <Time iso={i.expires_at} />
                        )}
                      </td>
                      <td className={ui.nowrap}>
                        {formatDate(i.created_at)}
                        <span className={ui.secondaryLine}>{i.created_by_email ?? "—"}</span>
                      </td>
                      <td>
                        <div className={ui.rowActions}>
                          {i.status === "active" ? (
                            <>
                              <CopyButton text={i.code} ariaLabel={`Copy invite code ${i.code}`} />
                              <ConfirmAction
                                action={revokeInviteAction}
                                fields={{ invite_id: i.id }}
                                label="Revoke"
                                trigger="smallDanger"
                                tone="danger"
                                title={`Revoke ${i.code}?`}
                                description="The code stops working right away. Families already created with it aren't affected."
                                confirmLabel="Revoke invite"
                              />
                            </>
                          ) : null}
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </Card>
      </div>
    </>
  );
}
