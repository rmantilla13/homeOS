"use client";

import { useEffect } from "react";
import { Card, Message, ui } from "@/components/ui";

// Server errors reach the browser without their message in production, so
// this points at the usual causes; the details are in the server log.
export default function ConsoleError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    console.error(error);
  }, [error]);

  return (
    <Card title="This page couldn't load">
      <div className={ui.stack}>
        <Message tone="error">
          The backend didn&apos;t answer as expected. Check that the platform migrations and the admin RPCs are deployed
          (docs/ADMIN.md), then try again.
          {error.digest ? (
            <>
              {" "}
              Reference: <code>{error.digest}</code>
            </>
          ) : null}
        </Message>
        <div>
          <button type="button" className={`${ui.button} ${ui.primary}`} onClick={reset}>
            Try again
          </button>
        </div>
      </div>
    </Card>
  );
}
