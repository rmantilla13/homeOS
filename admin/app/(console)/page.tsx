import type { Metadata } from "next";
import Link from "next/link";
import { AuditTable } from "@/components/AuditTable";
import { DisplayIcon, FamilyIcon, InviteIcon, SparkIcon, UsersIcon } from "@/components/icons";
import { StatTile } from "@/components/StatTile";
import { Card, PageHeader } from "@/components/ui";
import { UsageChart } from "@/components/UsageChart";
import { getOverview, getUsageByDay, listAudit, requireAdmin } from "@/lib/data";
import { formatCompact, formatDate, formatNumber, plural } from "@/lib/format";
import styles from "./page.module.css";

export const metadata: Metadata = { title: "Overview" };

export default async function OverviewPage() {
  await requireAdmin();
  const [o, usage, audit] = await Promise.all([getOverview(), getUsageByDay(30), listAudit(1, 8)]);
  const activeShare = o.families ? Math.round((o.families_active_7d / o.families) * 100) : 0;

  return (
    <>
      <PageHeader
        eyebrow={formatDate(new Date().toISOString())}
        title="Overview"
        subtitle="Families, people and assistant use across homeOS."
      />

      <div className={styles.tiles}>
        <StatTile
          label="Families"
          value={formatNumber(o.families)}
          href="/families"
          icon={<FamilyIcon size={18} />}
          context={o.suspended_families ? `${formatNumber(o.suspended_families)} suspended` : "None suspended"}
          tone={o.suspended_families ? "warn" : undefined}
        />
        <StatTile
          label="Active this week"
          value={formatNumber(o.families_active_7d)}
          context={`${activeShare}% of families`}
        />
        <StatTile label="Users" value={formatNumber(o.users)} href="/users" icon={<UsersIcon size={18} />} context="People with an account" />
        <StatTile label="Family members" value={formatNumber(o.members)} context="Shown on family screens" />
        <StatTile label="Displays" value={formatNumber(o.devices)} icon={<DisplayIcon size={18} />} context="Paired wall screens" />
        <StatTile
          label="Open invites"
          value={formatNumber(o.open_platform_invites)}
          href="/invites"
          icon={<InviteIcon size={18} />}
          context="Platform invites not yet used"
        />
        <StatTile
          label="Assistant requests"
          value={formatNumber(o.assistant_requests_7d)}
          icon={<SparkIcon size={18} />}
          context="Last 7 days"
        />
        <StatTile label="Assistant tokens" value={formatCompact(o.assistant_tokens_7d)} context="Last 7 days, input + output" />
      </div>

      <div className={styles.columns}>
        <Card title="Assistant usage" subtitle={`Last 30 days (UTC) · ${plural(usage.length, "day")}`}>
          <UsageChart days={usage} label="Assistant usage, last 30 days" />
        </Card>
        <Card
          title="Recent admin activity"
          flush
          action={
            <Link href="/audit" className={styles.viewAll}>
              View all
            </Link>
          }
        >
          <AuditTable entries={audit.rows} compact />
        </Card>
      </div>
    </>
  );
}
