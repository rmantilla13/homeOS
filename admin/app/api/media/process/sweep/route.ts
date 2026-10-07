import { handleProcessSweep } from "@/lib/media/processing";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 120;

// Vercel Cron (vercel.json), with Authorization: Bearer <CRON_SECRET>.
export function GET(request: Request) {
  return handleProcessSweep(request);
}
