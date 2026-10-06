import type { Metadata } from "next";
import Link from "next/link";
import {
  Card,
  Empty,
  Message,
  PageHeader,
  Pagination,
  SearchForm,
  StatusBadge,
  Time,
  pageHref,
  readPage,
  readString,
  ui,
} from "@/components/ui";
import { listFamilies, requireAdmin } from "@/lib/data";
import { formatDate, formatNumber } from "@/lib/format";

export const metadata: Metadata = { title: "Families" };

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };

export default async function FamiliesPage({ searchParams }: Props) {
  await requireAdmin();
  const sp = await searchParams;
  const q = readString(sp.q);
  const deleted = readString(sp.deleted);
  const result = await listFamilies(q || null, readPage(sp.page));

  return (
    <>
      <PageHeader
        title="Families"
        subtitle="Every household on homeOS. Open one to see its people, displays and invites."
        actions={<SearchForm label="Search families" placeholder="Search by name or id" defaultValue={q} />}
      />
      {deleted ? (
        <div style={{ marginBottom: 20 }}>
          <Message tone="ok">Deleted {deleted} and everything in it.</Message>
        </div>
      ) : null}
      <Card flush>
        {result.rows.length === 0 ? (
          <Empty title={q ? `No families match “${q}”` : "No families yet"}>
            {q ? "Try part of the name, or paste a family id." : "Families appear once someone redeems a platform invite."}
          </Empty>
        ) : (
          <div className={ui.tableWrap}>
            <table className={ui.table}>
              <thead>
                <tr>
                  <th scope="col">Family</th>
                  <th scope="col">Status</th>
                  <th scope="col" className={ui.num}>
                    Members
                  </th>
                  <th scope="col" className={ui.num}>
                    Parents
                  </th>
                  <th scope="col" className={ui.num}>
                    Displays
                  </th>
                  <th scope="col" className={ui.num}>
                    Assistant (30 d)
                  </th>
                  <th scope="col">Last activity</th>
                  <th scope="col">Created</th>
                </tr>
              </thead>
              <tbody>
                {result.rows.map((f) => (
                  <tr key={f.id}>
                    <td className={ui.primaryCell}>
                      <Link href={`/families/${f.id}`}>{f.name}</Link>
                    </td>
                    <td>
                      <StatusBadge status={f.status} />
                    </td>
                    <td className={ui.num}>{formatNumber(f.member_count)}</td>
                    <td className={ui.num}>{formatNumber(f.parent_count)}</td>
                    <td className={ui.num}>{formatNumber(f.device_count)}</td>
                    <td className={ui.num}>{formatNumber(f.assistant_requests_30d)}</td>
                    <td>
                      <Time iso={f.last_activity} />
                    </td>
                    <td className={ui.nowrap}>{formatDate(f.created_at)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
        <Pagination page={result.page} hasMore={result.hasMore} shown={result.rows.length} href={pageHref("/families", { q })} />
      </Card>
    </>
  );
}
