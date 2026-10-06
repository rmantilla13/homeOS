import { Shell } from "@/components/Shell";
import { isDemo, requireAdmin } from "@/lib/data";

// Everything but /login lives here and needs a platform admin. Pages check
// again (layouts don't re-run on every navigation), and so does the database.
export default async function ConsoleLayout({ children }: { children: React.ReactNode }) {
  const admin = await requireAdmin();
  return (
    <Shell email={admin.email} demo={await isDemo()}>
      {children}
    </Shell>
  );
}
