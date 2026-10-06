import type { Metadata } from "next";
import { updateSettingsAction } from "@/app/(console)/actions";
import { SettingsForm } from "@/components/SettingsForm";
import { Card, PageHeader, Time } from "@/components/ui";
import { getSettings, requireAdmin } from "@/lib/data";

export const metadata: Metadata = { title: "Settings" };

export default async function SettingsPage() {
  await requireAdmin();
  const settings = await getSettings();

  return (
    <>
      <PageHeader title="Settings" subtitle="Platform-wide switches. Every change is written to the audit log." />
      <Card
        title="Platform"
        subtitle={
          settings.updated_at ? (
            <>
              Last changed <Time iso={settings.updated_at} />
            </>
          ) : undefined
        }
      >
        <SettingsForm action={updateSettingsAction} settings={settings} />
      </Card>
    </>
  );
}
