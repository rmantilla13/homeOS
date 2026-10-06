import type { Metadata } from "next";
import { AuditTable } from "@/components/AuditTable";
import { Card, PageHeader, Pagination, pageHref, readPage } from "@/components/ui";
import { listAudit, requireAdmin } from "@/lib/data";

export const metadata: Metadata = { title: "Audit log" };

type Props = { searchParams: Promise<Record<string, string | string[] | undefined>> };

export default async function AuditPage({ searchParams }: Props) {
  await requireAdmin();
  const result = await listAudit(readPage((await searchParams).page));

  return (
    <>
      <PageHeader
        title="Audit log"
        subtitle="Every admin action, newest first: who did it, to what, and when (UTC)."
      />
      <Card flush>
        <AuditTable entries={result.rows} />
        <Pagination page={result.page} hasMore={result.hasMore} shown={result.rows.length} href={pageHref("/audit", {})} />
      </Card>
    </>
  );
}
