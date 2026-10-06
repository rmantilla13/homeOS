import { handleMediaUrls } from "@/lib/media/api";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export function POST(request: Request) {
  return handleMediaUrls(request);
}
