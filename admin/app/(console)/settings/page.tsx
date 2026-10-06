import type { Metadata } from "next";
import { updateSettingsAction } from "@/app/(console)/actions";
import { BootVideoForm } from "@/components/BootVideoForm";
import { SettingsForm } from "@/components/SettingsForm";
import { Card, PageHeader, Time, ui } from "@/components/ui";
import { getBootVideo, getSettings, isDemo, requireAdmin } from "@/lib/data";

export const metadata: Metadata = { title: "Settings" };

export default async function SettingsPage() {
  await requireAdmin();
  const [settings, video, demo] = await Promise.all([getSettings(), getBootVideo(), isDemo()]);

  return (
    <>
      <PageHeader
        title="Settings"
        subtitle="Platform-wide switches and the boot video every display plays. Every change is written to the audit log."
      />
      <div className={ui.stack}>
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
        <Card
          title="Boot video"
          subtitle={video ? "Replaces the built-in clip on the next reboot." : "Displays are using the built-in clip."}
        >
          <BootVideoForm video={video} demo={demo} />
        </Card>
      </div>
    </>
  );
}
