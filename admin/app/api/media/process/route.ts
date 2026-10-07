import { handleMediaProcess } from "@/lib/media/api";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
// Starting a sandbox takes a few seconds.
export const maxDuration = 60;

export function POST(request: Request) {
  return handleMediaProcess(request);
}
