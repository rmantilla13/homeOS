"use client";

import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from "react";
import { CheckIcon } from "@/components/icons";
import styles from "./interactive.module.css";

// Short confirmations ("User banned.") that outlive the row that triggered
// them; the provider sits above the page, so a refresh doesn't drop them.

type Toast = { id: number; text: string };
const ToastContext = createContext<(text: string) => void>(() => {});

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const nextId = useRef(1);
  const timers = useRef(new Set<ReturnType<typeof setTimeout>>());

  const show = useCallback((text: string) => {
    const id = nextId.current++;
    setToasts((t) => [...t.slice(-2), { id, text }]);
    const timer = setTimeout(() => {
      timers.current.delete(timer);
      setToasts((t) => t.filter((x) => x.id !== id));
    }, 3200);
    timers.current.add(timer);
  }, []);

  useEffect(() => {
    const pending = timers.current;
    return () => pending.forEach(clearTimeout);
  }, []);

  return (
    <ToastContext.Provider value={show}>
      {children}
      <div className={styles.toasts} aria-live="polite">
        {toasts.map((t) => (
          <div key={t.id} className={styles.toast}>
            <CheckIcon size={18} />
            {t.text}
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  );
}

export const useToast = () => useContext(ToastContext);
