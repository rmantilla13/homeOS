import type { Metadata } from "next";
import Link from "next/link";
import { deleteMediaAction } from "@/app/(console)/actions";
import { ConfirmAction } from "@/components/ConfirmAction";
import { MediaIcon } from "@/components/icons";
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
import { getOverview, listAllMedia, listFamilies, requireAdmin, signMedia } from "@/lib/data";
import { formatBytes, formatDate, formatNumber, plural } from "@/lib/format";
import type { MediaKind, MediaLibraryItem } from "@/lib/types";
import styles from "./media.module.css";

export const metadata: Metadata = { title: "Media" };

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };

function kindOf(value: string): MediaKind | null {
  return value === "photo" || value === "video" ? value : null;
}

export default async function MediaPage({ searchParams }: Props) {
  await requireAdmin();
  const sp = await searchParams;
  if (readString(sp.view) === "families") return <FamilyQuotas q={readString(sp.q)} page={readPage(sp.page)} />;
  const kind = kindOf(readString(sp.kind));
  const page = readPage(sp.page);
  const [result, overview] = await Promise.all([
    listAllMedia(kind, page),
    kind ? Promise.resolve(null) : getOverview(),
  ]);
  const urls = await signByFamily(result.rows);

  return (
    <>
      <PageHeader
        title="Media"
        subtitle={
          kind
            ? `${kind === "photo" ? "Photos" : "Videos"} from every family.`
            : <>{plural(overview?.media_items ?? 0, "item")} across every family. Open a name to see only that family.</>
        }
        actions={<KindNav kind={kind} />}
      />

      {result.rows.length === 0 ? (
        <Empty title={kind ? `No ${kind === "photo" ? "photos" : "videos"}` : "No media yet"}>
          {kind ? <Link href="/media">Show everything</Link> : "Uploads from families' phones show up here."}
        </Empty>
      ) : (
        <ul className={styles.grid}>
          {result.rows.map((item) => {
            const url = urls.get(item.id);
            const label = item.caption?.trim() || (item.kind === "video" ? "Video" : "Photo");
            return (
              <li key={item.id} className={styles.tile}>
                <div className={styles.frame}>
                  {url ? (
                    // Posters are signed by us (or a demo gradient). The path never comes from the page URL.
                    // eslint-disable-next-line @next/next/no-img-element
                    <img src={url} alt={label} />
                  ) : (
                    <span className={styles.placeholder}>
                      <MediaIcon size={28} />
                      {item.kind === "video" ? "No poster" : "No preview"}
                    </span>
                  )}
                  <span className={styles.kind}>
                    <Badge tone={item.kind === "video" ? "accent" : "neutral"} plain>
                      {item.kind === "video" ? "Video" : "Photo"}
                    </Badge>
                  </span>
                </div>
                <div className={styles.meta}>
                  <p className={styles.family}>
                    <Link href={`/families/${item.family_id}/media`}>{item.family_name}</Link>
                  </p>
                  <p className={styles.caption}>{label}</p>
                  <p className={ui.muted}>
                    {item.kind === "video" ? "Video" : "Photo"}
                    {" · "}
                    {item.byte_size == null ? "Size unknown" : formatBytes(item.byte_size)}
                    {" · "}
                    {formatDate(item.taken_at ?? item.created_at)}
                  </p>
                  <ConfirmAction
                    action={deleteMediaAction}
                    fields={{ media_id: item.id }}
                    label="Remove"
                    trigger="smallDanger"
                    tone="danger"
                    title={`Remove ${label}?`}
                    description={`This deletes the file from ${item.family_name}. It can't be undone.`}
                    confirmLabel="Remove"
                  />
                </div>
              </li>
            );
          })}
        </ul>
      )}
      <Pagination
        page={result.page}
        hasMore={result.hasMore}
        shown={result.rows.length}
        href={pageHref("/media", { kind: kind ?? undefined })}
      />
    </>
  );
}

// sign_media takes one family. Group the page so each call stays inside that contract.
async function signByFamily(rows: MediaLibraryItem[]): Promise<Map<string, string>> {
  const byFamily = new Map<string, string[]>();
  for (const item of rows) {
    const ids = byFamily.get(item.family_id) ?? [];
    ids.push(item.id);
    byFamily.set(item.family_id, ids);
  }
  const signed = await Promise.all([...byFamily.entries()].map(([familyId, ids]) => signMedia(familyId, ids)));
  return new Map(signed.flat().map((s) => [s.id, s.url]));
}

function KindNav({ kind }: { kind: MediaKind | null }) {
  return (
    <nav className={styles.filters} aria-label="Media">
      <Filter href="/media" current={kind == null}>All</Filter>
      <Filter href="/media?kind=photo" current={kind === "photo"}>Photos</Filter>
      <Filter href="/media?kind=video" current={kind === "video"}>Videos</Filter>
      <Filter href="/media?view=families" current={false}>By family</Filter>
    </nav>
  );
}

async function FamilyQuotas({ q, page }: { q: string; page: number }) {
  const result = await listFamilies(q || null, page);
  return (
    <>
      <PageHeader
        title="Media"
        subtitle="Storage and item counts for every family. Open one to see its photos and videos."
        actions={
          <>
            <nav className={styles.filters} aria-label="Media">
              <Filter href="/media" current={false}>All</Filter>
              <Filter href="/media?kind=photo" current={false}>Photos</Filter>
              <Filter href="/media?kind=video" current={false}>Videos</Filter>
              <Filter href="/media?view=families" current>By family</Filter>
            </nav>
            <SearchForm
              label="Search families"
              placeholder="Search by name or id"
              defaultValue={q}
              hidden={{ view: "families" }}
            />
          </>
        }
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
      <Pagination
        page={result.page}
        hasMore={result.hasMore}
        shown={result.rows.length}
        href={pageHref("/media", { view: "families", q })}
      />
    </>
  );
}

function Filter({ href, current, children }: { href: string; current: boolean; children: string }) {
  return (
    <Link href={href} className={current ? styles.filterOn : styles.filter} aria-current={current ? "page" : undefined}>
      {children}
    </Link>
  );
}
