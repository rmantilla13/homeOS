"use client";

import { useEffect } from "react";
import { Card, Message, ui } from "@/components/ui";
import { consoleErrorCopy } from "@/lib/errors";

// Next strips the error message in production. DataError puts its sentence in
// `digest` so it still shows; a numeric digest is Next's hash of an unexpected
// throw, and the text for that stays in the server log.
export default function ConsoleError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    console.error(error);
  }, [error]);
  const copy = consoleErrorCopy(error.digest);

  return (
    <Card title="This page couldn't load">
      <div className={ui.stack}>
        <Message tone="error">
          {copy.message}
          {copy.reference ? (
            <>
              {" "}
              Reference: <code>{copy.reference}</code>
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
