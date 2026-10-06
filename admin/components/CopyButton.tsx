"use client";

import { useEffect, useState } from "react";
import { CheckIcon, CopyIcon } from "@/components/icons";
import styles from "./interactive.module.css";

export function CopyButton({ text, label = "Copy", ariaLabel }: { text: string; label?: string; ariaLabel?: string }) {
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!copied) return;
    const t = setTimeout(() => setCopied(false), 1600);
    return () => clearTimeout(t);
  }, [copied]);

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
    } catch {
      // Clipboard blocked (http, permissions): let the admin copy by hand.
      window.prompt("Copy this:", text);
    }
  }

  return (
    <button
      type="button"
      className={`${styles.copy} ${copied ? styles.copied : ""}`}
      onClick={copy}
      aria-label={ariaLabel ?? `${label} ${text}`}
    >
      {copied ? <CheckIcon size={15} /> : <CopyIcon size={15} />}
      {copied ? "Copied" : label}
    </button>
  );
}
