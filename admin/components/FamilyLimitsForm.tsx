"use client";

import { AlertIcon, CheckIcon } from "@/components/icons";
import { useFormAction } from "@/components/useFormAction";
import type { FormAction } from "@/lib/action-result";
import { bytesToGiB, formatBytes, formatNumber } from "@/lib/format";
import type { Family } from "@/lib/types";
import styles from "./interactive.module.css";
import ui from "./ui.module.css";

// Per-family overrides. A checked "platform default" clears the family's own
// number. The hidden was_* values are the raw overrides (empty when unset),
// so saving compares bytes, not the rounded field the admin is looking at.
export function FamilyLimitsForm({ action, family }: { action: FormAction; family: Family }) {
  const { result, pending, submit, reset } = useFormAction(action);
  const storageDefault = family.storage_limit_bytes == null;
  const itemsDefault = family.media_item_limit == null;
  const assistantDefault = family.assistant_daily_limit == null;
  const storageShown = family.storage_limit_bytes ?? family.storage_limit_effective ?? 0;
  const itemsShown = family.media_item_limit ?? family.media_item_limit_effective ?? 0;
  const assistantShown = family.assistant_daily_limit ?? family.assistant_daily_limit_effective ?? 0;

  return (
    <form onSubmit={submit} onChange={reset} className={ui.stack}>
      <input type="hidden" name="family_id" value={family.id} />
      <input type="hidden" name="was_assistant" value={family.assistant_daily_limit ?? ""} />
      <input type="hidden" name="was_storage" value={family.storage_limit_bytes ?? ""} />
      <input type="hidden" name="was_items" value={family.media_item_limit ?? ""} />

      <LimitRow
        id="storage_gib"
        name="storage_gib"
        useName="use_platform_storage"
        label="Storage"
        hint={`Platform default is ${formatBytes(family.storage_limit_effective ?? storageShown)}. 0 blocks new uploads.`}
        unit="GB"
        min={0}
        max={1024}
        step={0.1}
        defaultValue={bytesToGiB(storageShown)}
        useDefault={storageDefault}
      />
      <LimitRow
        id="media_item_limit"
        name="media_item_limit"
        useName="use_platform_items"
        label="Items"
        hint={`Platform default is ${formatNumber(family.media_item_limit_effective ?? itemsShown)}. A photo and its poster count as one.`}
        min={0}
        max={1000000}
        step={1}
        defaultValue={String(itemsShown)}
        useDefault={itemsDefault}
      />
      <LimitRow
        id="assistant_daily_limit"
        name="assistant_daily_limit"
        useName="use_platform_assistant"
        label="Assistant requests per day"
        hint={`Platform default is ${formatNumber(family.assistant_daily_limit_effective ?? assistantShown)}, UTC.`}
        min={0}
        max={1000000}
        step={1}
        defaultValue={String(assistantShown)}
        useDefault={assistantDefault}
      />

      <div className={styles.formFooter}>
        <div aria-live="polite">
          {result && !result.ok ? (
            <span className={`${ui.message} ${ui.messageError}`}>
              <AlertIcon size={18} /> {result.error}
            </span>
          ) : result?.ok ? (
            <span className={`${ui.message} ${ui.messageOk}`}>
              <CheckIcon size={18} /> {result.message}
            </span>
          ) : null}
        </div>
        <button type="submit" className={`${ui.button} ${ui.primary}`} disabled={pending}>
          {pending ? "Saving…" : "Save limits"}
        </button>
      </div>
    </form>
  );
}

function LimitRow({
  id, name, useName, label, hint, unit, min, max, step, defaultValue, useDefault,
}: {
  id: string;
  name: string;
  useName: string;
  label: string;
  hint: string;
  unit?: string;
  min: number;
  max: number;
  step: number;
  defaultValue: string;
  useDefault: boolean;
}) {
  return (
    <div className={styles.switchRow}>
      <label className={styles.switchText} htmlFor={id}>
        <span className={styles.switchLabel}>{label}</span>
        <span className={styles.switchHint}>{hint}</span>
      </label>
      <span style={{ display: "flex", alignItems: "center", gap: 12, flex: "none" }}>
        <input
          id={id}
          name={name}
          type="number"
          min={min}
          max={max}
          step={step}
          required={!useDefault}
          className={ui.input}
          style={{ width: 120 }}
          defaultValue={defaultValue}
          disabled={useDefault}
        />
        {unit ? <span className={ui.muted}>{unit}</span> : null}
        <label className={styles.switchText} htmlFor={useName} style={{ flex: "none" }}>
          <span className={styles.switchHint}>Platform default</span>
        </label>
        <input
          id={useName}
          name={useName}
          type="checkbox"
          className={styles.switch}
          defaultChecked={useDefault}
          onChange={(e) => {
            const input = e.currentTarget.form?.elements.namedItem(name);
            if (input instanceof HTMLInputElement) {
              input.disabled = e.currentTarget.checked;
              input.required = !e.currentTarget.checked;
            }
          }}
        />
      </span>
    </div>
  );
}
