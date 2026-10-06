import type { Metadata } from "next";
import Link from "next/link";
import { accountAction, setAdminAction } from "@/app/(console)/actions";
import { ConfirmAction } from "@/components/ConfirmAction";
import {
  Badge,
  Card,
  Empty,
  PageHeader,
  Pagination,
  SearchForm,
  Time,
  pageHref,
  readPage,
  readString,
  ui,
} from "@/components/ui";
import { listUsers, requireAdmin } from "@/lib/data";
import { formatDate } from "@/lib/format";
import type { UserRow } from "@/lib/types";
import styles from "./users.module.css";

export const metadata: Metadata = { title: "Users" };

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };

export default async function UsersPage({ searchParams }: Props) {
  const admin = await requireAdmin();
  const sp = await searchParams;
  const q = readString(sp.q);
  const result = await listUsers(q || null, readPage(sp.page));

  return (
    <>
      <PageHeader
        title="Users"
        subtitle="Every account: people and the device accounts of paired displays."
        actions={<SearchForm label="Search users" placeholder="Search by email or name" defaultValue={q} />}
      />
      <Card flush>
        {result.rows.length === 0 ? (
          <Empty title={q ? `No users match “${q}”` : "No users yet"}>
            {q ? "Search matches email addresses and display names." : null}
          </Empty>
        ) : (
          <div className={ui.tableWrap}>
            <table className={ui.table}>
              <thead>
                <tr>
                  <th scope="col">User</th>
                  <th scope="col">Families</th>
                  <th scope="col">Joined</th>
                  <th scope="col">Last sign-in</th>
                  <th scope="col" className={ui.num}>
                    <span className="visually-hidden">Actions</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {result.rows.map((u) => (
                  <tr key={u.id}>
                    <td className={ui.primaryCell}>
                      <div className={styles.who}>
                        <span>{u.display_name || u.email || u.id}</span>
                        <span className={ui.badges}>
                          {u.id === admin.id ? <Badge plain>You</Badge> : null}
                          {u.is_admin ? <Badge tone="accent">Admin</Badge> : null}
                          {u.is_device ? <Badge>Display</Badge> : null}
                          {u.banned ? <Badge tone="danger">Banned</Badge> : null}
                        </span>
                      </div>
                      <span className={`${ui.secondaryLine} ${styles.email}`}>{u.is_device ? "Device account" : u.email}</span>
                    </td>
                    <td>
                      {u.families.length === 0 ? (
                        <span className={ui.muted}>None</span>
                      ) : (
                        <span className={styles.families}>
                          {u.families.map((f) => (
                            <Link key={`${f.id}-${f.role}`} href={`/families/${f.id}`} className={styles.family}>
                              {f.name}
                              <span>{f.role}</span>
                            </Link>
                          ))}
                        </span>
                      )}
                    </td>
                    <td className={ui.nowrap}>{formatDate(u.created_at)}</td>
                    <td>
                      <Time iso={u.last_sign_in_at} />
                    </td>
                    <td>
                      <UserActions user={u} self={u.id === admin.id} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        <Pagination page={result.page} hasMore={result.hasMore} shown={result.rows.length} href={pageHref("/users", { q })} />
      </Card>
    </>
  );
}

function UserActions({ user, self }: { user: UserRow; self: boolean }) {
  const who = user.is_device ? user.display_name || "this display" : user.email || user.display_name || "this user";
  const confirmText = user.is_device ? user.display_name || user.id : user.email || user.id;
  return (
    <div className={ui.rowActions}>
      {!user.is_device && !self ? (
        user.is_admin ? (
          <ConfirmAction
            action={setAdminAction}
            fields={{ user_id: user.id, make_admin: "0" }}
            label="Remove admin"
            trigger="small"
            title={`Remove admin access for ${who}?`}
            description="They can keep using Ohana, but can't open this console or call admin functions."
            confirmLabel="Remove admin"
          />
        ) : (
          <ConfirmAction
            action={setAdminAction}
            fields={{ user_id: user.id, make_admin: "1" }}
            label="Make admin"
            trigger="small"
            title={`Make ${who} a platform admin?`}
            description="Admins can see every family, suspend or delete them, manage invites and ban or delete accounts."
            confirmLabel="Make admin"
          />
        )
      ) : null}
      {!self ? (
        user.banned ? (
          <ConfirmAction
            action={accountAction}
            fields={{ user_id: user.id, action: "unban_user" }}
            label="Unban"
            trigger="small"
            title={`Unban ${who}?`}
            description="They can sign in again right away."
            confirmLabel="Unban"
          />
        ) : (
          <ConfirmAction
            action={accountAction}
            fields={{ user_id: user.id, action: "ban_user" }}
            label="Ban"
            trigger="smallDanger"
            tone="danger"
            title={`Ban ${who}?`}
            description={
              user.is_device
                ? "The display can't refresh its session and drops off within the hour. Unban to let it back in."
                : "They can't sign in or refresh their session; an open session ends within the hour. Their family data stays as it is."
            }
            confirmLabel="Ban"
          />
        )
      ) : null}
      {!self ? (
        <ConfirmAction
          action={accountAction}
          fields={{ user_id: user.id, action: "delete_user", expected: confirmText }}
          label="Delete"
          trigger="smallDanger"
          tone="danger"
          title={`Delete ${who}?`}
          description={
            user.is_device ? (
              "Deletes the display's account and unpairs it from its family. The screen will need to be paired again."
            ) : (
              <>
                Deletes the account and profile. Their member rows stay in their families, unlinked, so the family
                screen doesn&apos;t change. <strong>This can&apos;t be undone.</strong>
              </>
            )
          }
          typeToConfirm={{ value: confirmText, label: `Type “${confirmText}” to confirm`, caseInsensitive: true }}
          confirmLabel="Delete account"
        />
      ) : (
        <span className={ui.muted}>—</span>
      )}
    </div>
  );
}
