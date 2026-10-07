import { handleAccountDelete } from "@/lib/account";
import { deleteFamilyBlobs } from "@/lib/media/cleanup";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export function POST(request: Request) {
  return handleAccountDelete(request, deleteFamilyBlobs);
}
