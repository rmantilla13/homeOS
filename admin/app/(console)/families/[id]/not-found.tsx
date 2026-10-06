import Link from "next/link";
import { Card, Empty } from "@/components/ui";

export default function FamilyNotFound() {
  return (
    <Card>
      <Empty title="That family doesn't exist">
        It may have been deleted. <Link href="/families">Back to families</Link>
      </Empty>
    </Card>
  );
}
