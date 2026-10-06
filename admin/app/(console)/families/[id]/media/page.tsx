import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { deleteMediaAction } from "@/app/(console)/actions";
import { ConfirmAction } from "@/components/ConfirmAction";
import { ChevronLeftIcon, MediaIcon } from "@/components/icons";
import { Badge, Empty, PageHeader, Pagination, pageHref, readPage, readString, ui } from "@/components/ui";
import { getFamilyDetail, listMedia, requireAdmin, signMedia } from "@/lib/data";
import { formatBytes, formatDate, plural } from "@/lib/format";
import type { MediaKind } from "@/lib/types";
import styles from "./media.module.css";

type Props = {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

function kindOf(value: string): MediaKind | null {
  return value === "photo" || value === "video" ? value : null;
}

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { id } = await params;
  const detail = await getFamilyDetail(id).catch(() => null);
  return { title: detail ? `${detail.family.name} media` : "Media" };
}

export default async function FamilyMediaPage({ params, searchParams }: Props) {
  await requireAdmin();
  const { id } = await params;
  const sp = await searchParams;
  const detail = await getFamilyDetail(id);
  if (!detail) notFound();
  const kind = kindOf(readString(sp.kind));
  const page = readPage(sp.page);
  const result = await listMedia(id, kind, page);
  const signed = await signMedia(id, result.rows.map((item) => item.id));
  const urls = new Map(signed.map((s) => [s.id, s.url]));
  const href = pageHref(`/families/${id}/media`, { kind: kind ?? undefined });

  return (
    <>
      <PageHeader
        eyebrow={
          <Link href={`/families/${id}`}>
            <ChevronLeftIcon size={14} /> {detail.family.name}
          </Link>
        }
        title="Media"
        subtitle={
          <>
            {plural(detail.family.media_count ?? result.rows.length, "item")}
            {detail.family.storage_bytes != null ? <> · {formatBytes(detail.family.storage_bytes)} stored</> : null}
            . Removing an item deletes the file and writes the audit log.
          </>
        }
        actions={
          <nav className={styles.filters} aria-label="Kind">
            <Filter href={`/families/${id}/media`} current={kind == null}>All</Filter>
            <Filter href={`/families/${id}/media?kind=photo`} current={kind === "photo"}>Photos</Filter>
            <Filter href={`/families/${id}/media?kind=video`} current={kind === "video"}>Videos</Filter>
          </nav>
        }
      />

      {result.rows.length === 0 ? (
        <Empty title={kind ? `No ${kind === "photo" ? "photos" : "videos"}` : "No media yet"}>
          {kind ? <Link href={`/families/${id}/media`}>Show everything</Link> : "Uploads from the family's phones land here."}
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
                  <p className={styles.caption}>{label}</p>
                  <p className={ui.muted}>
                    {item.byte_size == null ? "Size unknown" : formatBytes(item.byte_size)}
                    {item.uploaded_by_name ? ` · ${item.uploaded_by_name}` : ""}
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
                    description="The photo or video is deleted from this family's storage. This can't be undone."
                    confirmLabel="Remove"
                  />
                </div>
              </li>
            );
          })}
        </ul>
      )}
      <Pagination page={result.page} hasMore={result.hasMore} shown={result.rows.length} href={href} />
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
