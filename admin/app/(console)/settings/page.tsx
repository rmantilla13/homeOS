import type { Metadata } from "next";
import { updateSettingsAction } from "@/app/(console)/actions";
import { BootVideoForm } from "@/components/BootVideoForm";
import { SettingsForm } from "@/components/SettingsForm";
import { Card, Message, PageHeader, Time, ui } from "@/components/ui";
import { DataError, getBootVideo, getSettings, isDemo, requireAdmin } from "@/lib/data";

export const metadata: Metadata = { title: "Settings" };

export default async function SettingsPage() {
  await requireAdmin();
  const [settings, boot, demo] = await Promise.all([
    getSettings(),
    getBootVideo().then(
      (video) => ({ video, error: null as string | null }),
      (err: unknown) => {
        if (!(err instanceof DataError)) throw err;
        const stale = /action must be/.test(err.message);
        return {
          video: null,
          error: stale
            ? "The admin function on Supabase is older than this console, so the boot video could not be loaded. Apply backend/supabase/migrations/20261008000004_boot_video.sql in the SQL editor, then run supabase functions deploy admin. The switches below still save."
            : err.message,
        };
      },
    ),
    isDemo(),
  ]);
  const video = boot.video;

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
          subtitle={
            boot.error
              ? "The console could not read the current clip."
              : video
                ? "Replaces the built-in clip on the next reboot."
                : "Displays are using the built-in clip."
          }
        >
          {boot.error ? <Message tone="error">{boot.error}</Message> : <BootVideoForm video={video} demo={demo} />}
        </Card>
      </div>
    </>
  );
}
