"use client";

import { useEffect, useId, useMemo, useRef, useState, type KeyboardEvent, type PointerEvent } from "react";
import { formatCompact, formatNumber, formatShortDate } from "@/lib/format";
import type { UsageDay } from "@/lib/types";
import styles from "./usage-chart.module.css";

// Assistant usage per day as two small multiples on a shared day axis:
// requests (one series) and tokens (input + output, stacked). Two charts
// instead of one with two y-scales, since the magnitudes differ ~5000×.

const MARGIN = { left: 52, right: 10, top: 24, gap: 34, bottom: 28 };
const MAX_BAR = 24;
const RADIUS = 4;
const SEGMENT_GAP = 2;

type Props = { days: UsageDay[]; height?: number; label?: string };

export function UsageChart({ days, height = 150, label = "Assistant usage" }: Props) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(0);
  const [active, setActive] = useState<number | null>(null);
  const [showTable, setShowTable] = useState(false);
  const tableId = useId();

  useEffect(() => {
    const el = wrapRef.current;
    if (!el) return;
    const observer = new ResizeObserver(([entry]) => setWidth(Math.floor(entry.contentRect.width)));
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  const totals = useMemo(
    () =>
      days.reduce(
        (t, d) => ({
          requests: t.requests + d.requests,
          input: t.input + d.input_tokens,
          output: t.output + d.output_tokens,
        }),
        { requests: 0, input: 0, output: 0 },
      ),
    [days],
  );

  const n = days.length;
  const plotW = Math.max(width - MARGIN.left - MARGIN.right, 0);
  const band = n ? plotW / n : 0;
  const barW = Math.max(Math.min(MAX_BAR, band * 0.66, band - SEGMENT_GAP), 1);
  const reqTop = MARGIN.top;
  const tokTop = MARGIN.top + height + MARGIN.gap;
  const svgH = tokTop + height + MARGIN.bottom;

  const reqAxis = niceAxis(Math.max(...days.map((d) => d.requests), 0));
  const tokAxis = niceAxis(Math.max(...days.map((d) => d.input_tokens + d.output_tokens), 0));
  const yReq = (v: number) => reqTop + height - (v / reqAxis.max) * height;
  const yTok = (v: number) => tokTop + height - (v / tokAxis.max) * height;
  const xMid = (i: number) => MARGIN.left + band * (i + 0.5);

  const peak = days.reduce((best, d, i) => (d.requests > (days[best]?.requests ?? -1) ? i : best), 0);
  const labelEvery = Math.max(1, Math.ceil(64 / Math.max(band, 1)));
  const empty = totals.requests === 0;

  function pick(e: PointerEvent<SVGSVGElement>) {
    const rect = e.currentTarget.getBoundingClientRect();
    const x = e.clientX - rect.left - MARGIN.left;
    setActive(x < 0 || x > plotW ? null : Math.min(n - 1, Math.max(0, Math.floor(x / band))));
  }

  function onKey(e: KeyboardEvent<HTMLDivElement>) {
    const last = n - 1;
    const moves: Record<string, number> = {
      ArrowLeft: Math.max((active ?? n) - 1, 0),
      ArrowRight: Math.min((active ?? -1) + 1, last),
      Home: 0,
      End: last,
    };
    if (e.key in moves) {
      e.preventDefault();
      setActive(moves[e.key]);
    } else if (e.key === "Escape") {
      setActive(null);
    }
  }

  const a = active === null ? null : days[active];
  const tipLeft = active === null ? 0 : Math.min(Math.max(xMid(active), 90), Math.max(width - 90, 90));

  return (
    <div className={styles.chart}>
      <div className={styles.summary}>
        <div>
          <span className={styles.summaryValue}>{formatNumber(totals.requests)}</span>
          <span className={styles.summaryLabel}>requests</span>
        </div>
        <div>
          <span className={styles.summaryValue}>{formatCompact(totals.input + totals.output)}</span>
          <span className={styles.summaryLabel}>tokens</span>
        </div>
        <div className={styles.legend} aria-hidden="true">
          <span>
            <i className={styles.keyInput} /> Input tokens
          </span>
          <span>
            <i className={styles.keyOutput} /> Output tokens
          </span>
        </div>
      </div>

      <div
        ref={wrapRef}
        className={styles.plot}
        style={{ height: svgH }}
        tabIndex={0}
        role="group"
        aria-label={`${label}: ${n} days. Use the arrow keys to read each day.`}
        aria-describedby={showTable ? tableId : undefined}
        onKeyDown={onKey}
        onBlur={() => setActive(null)}
      >
        {width > 0 && n > 0 ? (
          <svg
            width={width}
            height={svgH}
            role="img"
            aria-label={`${label}. ${formatNumber(totals.requests)} requests and ${formatCompact(totals.input + totals.output)} tokens over ${n} days.`}
            onPointerMove={pick}
            onPointerLeave={() => setActive(null)}
          >
            {/* Highlight band for the active day, across both panels. */}
            {active !== null ? (
              <rect
                className={styles.activeBand}
                x={MARGIN.left + band * active}
                y={reqTop - 8}
                width={band}
                height={tokTop + height - reqTop + 8}
                rx={6}
              />
            ) : null}

            <Panel title="Requests per day" top={reqTop} width={width} axis={reqAxis} y={yReq} />
            <Panel title="Tokens per day" top={tokTop} width={width} axis={tokAxis} y={yTok} />

            {days.map((d, i) => {
              const x = xMid(i) - barW / 2;
              const dim = active !== null && active !== i;
              const total = d.input_tokens + d.output_tokens;
              const yIn = yTok(d.input_tokens);
              const yAll = yTok(total);
              const outH = yIn - yAll;
              const gap = d.input_tokens > 0 && outH > SEGMENT_GAP + 1 ? SEGMENT_GAP : 0;
              return (
                <g key={d.day} className={dim ? styles.dim : undefined}>
                  {d.requests > 0 ? (
                    <path className={styles.series1} d={column(x, yReq(d.requests), barW, reqTop + height, true)} />
                  ) : null}
                  {d.input_tokens > 0 ? (
                    <path
                      className={styles.series1}
                      d={column(x, yIn, barW, tokTop + height, outH <= SEGMENT_GAP + 1)}
                    />
                  ) : null}
                  {d.output_tokens > 0 && outH > SEGMENT_GAP + 1 ? (
                    <path className={styles.series2} d={column(x, yAll, barW, yIn - gap, true)} />
                  ) : null}
                </g>
              );
            })}

            {/* Selective direct label: the busiest day. */}
            {!empty ? (
              <text className={styles.valueLabel} x={xMid(peak)} y={yReq(days[peak].requests) - 6} textAnchor="middle">
                {formatNumber(days[peak].requests)}
              </text>
            ) : (
              <text className={styles.emptyLabel} x={MARGIN.left + plotW / 2} y={reqTop + height / 2} textAnchor="middle">
                No assistant requests in this period
              </text>
            )}

            {days.map((d, i) =>
              (n - 1 - i) % labelEvery === 0 ? (
                <text
                  key={d.day}
                  className={styles.tick}
                  x={Math.min(Math.max(xMid(i), MARGIN.left + 18), width - 22)}
                  y={tokTop + height + 18}
                  textAnchor="middle"
                >
                  {formatShortDate(d.day)}
                </text>
              ) : null,
            )}
          </svg>
        ) : null}

        {a ? (
          <div className={styles.tooltip} style={{ left: tipLeft }} role="status">
            <div className={styles.tipDate}>{formatShortDate(a.day)}</div>
            <TipRow value={formatNumber(a.requests)} label="requests" keyClass={styles.keyLine1} />
            <TipRow value={formatNumber(a.input_tokens)} label="input tokens" keyClass={styles.keyLine1} />
            <TipRow value={formatNumber(a.output_tokens)} label="output tokens" keyClass={styles.keyLine2} />
            {a.families !== undefined ? <TipRow value={formatNumber(a.families)} label="families" /> : null}
          </div>
        ) : null}
      </div>

      <button type="button" className={styles.tableToggle} onClick={() => setShowTable((s) => !s)} aria-expanded={showTable}>
        {showTable ? "Hide table" : "Show as table"}
      </button>
      {showTable ? (
        <div className={styles.tableWrap}>
          <table id={tableId} className={styles.table}>
            <caption className="visually-hidden">{label} by day</caption>
            <thead>
              <tr>
                <th scope="col">Day (UTC)</th>
                <th scope="col">Requests</th>
                <th scope="col">Input tokens</th>
                <th scope="col">Output tokens</th>
                {days[0]?.families !== undefined ? <th scope="col">Families</th> : null}
              </tr>
            </thead>
            <tbody>
              {[...days].reverse().map((d) => (
                <tr key={d.day}>
                  <th scope="row">{formatShortDate(d.day)}</th>
                  <td>{formatNumber(d.requests)}</td>
                  <td>{formatNumber(d.input_tokens)}</td>
                  <td>{formatNumber(d.output_tokens)}</td>
                  {d.families !== undefined ? <td>{formatNumber(d.families)}</td> : null}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : null}
    </div>
  );
}

function TipRow({ value, label, keyClass }: { value: string; label: string; keyClass?: string }) {
  return (
    <div className={styles.tipRow}>
      <i className={keyClass ?? styles.keyNone} />
      <strong>{value}</strong>
      <span>{label}</span>
    </div>
  );
}

function Panel({
  title,
  top,
  width,
  axis,
  y,
}: {
  title: string;
  top: number;
  width: number;
  axis: { max: number; ticks: number[] };
  y: (v: number) => number;
}) {
  return (
    <g>
      <text className={styles.panelTitle} x={MARGIN.left} y={top - 10}>
        {title}
      </text>
      {axis.ticks.map((t) => (
        <g key={t}>
          <line
            className={t === 0 ? styles.baseline : styles.grid}
            x1={MARGIN.left}
            x2={width - MARGIN.right}
            y1={Math.round(y(t)) + 0.5}
            y2={Math.round(y(t)) + 0.5}
          />
          <text className={styles.tick} x={MARGIN.left - 10} y={y(t) + 4} textAnchor="end">
            {formatCompact(t)}
          </text>
        </g>
      ))}
    </g>
  );
}

// A column from `bottom` up to `top`; the data end gets 4px rounded corners,
// the baseline end stays square.
function column(x: number, top: number, w: number, bottom: number, roundTop: boolean): string {
  const h = Math.max(bottom - top, 0);
  const r = roundTop ? Math.min(RADIUS, w / 2, h) : 0;
  return [
    `M${x},${bottom}`,
    `V${top + r}`,
    r ? `Q${x},${top} ${x + r},${top}` : "",
    `H${x + w - r}`,
    r ? `Q${x + w},${top} ${x + w},${top + r}` : "",
    `V${bottom}`,
    "Z",
  ].join("");
}

// Round tick steps (1, 2, 2.5, 5 × 10^k) with at most four gridlines.
function niceAxis(max: number): { max: number; ticks: number[] } {
  if (max <= 0) return { max: 1, ticks: [0] };
  const raw = max / 3;
  const pow = 10 ** Math.floor(Math.log10(raw));
  const step = [1, 2, 2.5, 5, 10].map((m) => m * pow).find((s) => s >= raw) ?? 10 * pow;
  const top = Math.ceil(max / step) * step;
  const ticks: number[] = [];
  for (let t = 0; t <= top + step / 2; t += step) ticks.push(Math.round(t * 1000) / 1000);
  return { max: top, ticks };
}
