import type { Metadata } from "next";
import Link from "next/link";
import {
  Badge,
  Card,
  Empty,
  PageHeader,
  Pagination,
  SearchForm,
  StatusBadge,
  pageHref,
  readPage,
  readString,
  ui,
} from "@/components/ui";
import { listFamilies, requireAdmin } from "@/lib/data";
import { formatBytes, formatNumber } from "@/lib/format";
import styles from "./media.module.css";

export const metadata: Metadata = { title: "Media" };

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };

export default async function MediaPage({ searchParams }: Props) {
  await requireAdmin();
  const sp = await searchParams;
  const q = readString(sp.q);
  const page = readPage(sp.page);
  const result = await listFamilies(q || null, page);

  return (
    <>
      <PageHeader
        title="Media"
        subtitle="Storage and item counts for every family. Open one to see its photos and videos."
        actions={<SearchForm label="Search families" placeholder="Search by name or id" defaultValue={q} />}
      />
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
                    Items
                  </th>
                  <th scope="col">Storage</th>
                  <th scope="col">Quota</th>
                </tr>
              </thead>
              <tbody>
                {result.rows.map((f) => {
                  const overStorage = f.storage_bytes > f.storage_limit_bytes;
                  const overItems = f.media_count > f.media_item_limit;
                  const pct = f.storage_limit_bytes <= 0
                    ? (f.storage_bytes > 0 ? 100 : 0)
                    : Math.min(100, (f.storage_bytes / f.storage_limit_bytes) * 100);
                  return (
                    <tr key={f.id}>
                      <td className={ui.primaryCell}>
                        <Link href={`/families/${f.id}/media`}>{f.name}</Link>
                      </td>
                      <td>
                        <StatusBadge status={f.status} />
                      </td>
                      <td className={ui.num}>{formatNumber(f.media_count)}</td>
                      <td>
                        <div className={styles.usage}>
                          <div className={styles.track} aria-hidden="true">
                            <span className={overStorage ? styles.over : undefined} style={{ width: `${pct}%` }} />
                          </div>
                          <span className={overStorage ? styles.overText : undefined}>
                            {formatBytes(f.storage_bytes)} of {formatBytes(f.storage_limit_bytes)}
                          </span>
                        </div>
                      </td>
                      <td>
                        {overStorage ? (
                          <Badge tone="warn">Over storage</Badge>
                        ) : overItems ? (
                          <Badge tone="warn">Over item cap</Badge>
                        ) : (
                          <span className={ui.muted}>{formatNumber(f.media_item_limit)} item cap</span>
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
      <Pagination page={result.page} hasMore={result.hasMore} shown={result.rows.length} href={pageHref("/media", { q })} />
    </>
  );
}
