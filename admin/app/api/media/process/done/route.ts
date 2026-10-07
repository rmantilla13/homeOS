import { handleProcessDone } from "@/lib/media/processing";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";
export const maxDuration = 60;

// The sandbox making a wall copy reports here. The body carries a token only
// this app can make; see lib/media/processing.ts.
export function POST(request: Request) {
  return handleProcessDone(request);
}
