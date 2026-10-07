// Firstmate usage line policy for the Claude Code mod, kept free of the engine.
//
// This module owns how the figures `$.session.usage()` reports read as one short line,
// such as `context 42% · 5h quota 63% · week 81% (resets Oct 9, 6pm)`.
// docs/usage-line.md owns the captain-facing contract.

/** The figures the line is built from, in `$.session.usage()`'s shape. */
export type UsageFigures = {
  readonly context: { readonly percent?: number };
  readonly rateLimits: readonly { readonly kind: string; readonly percentUsed: number; readonly resetsAt?: string }[];
};

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/** A reset time as the local `Oct 9, 6pm` (or `6:30pm` off the hour); undefined when unreadable. */
export function resetLabel(iso: string | undefined): string | undefined {
  if (iso === undefined) return undefined;
  const at = new Date(iso);
  if (Number.isNaN(at.getTime())) return undefined;
  const hour = at.getHours();
  const minutes = at.getMinutes();
  const hour12 = hour % 12 === 0 ? 12 : hour % 12;
  const minuteText = minutes === 0 ? "" : `:${String(minutes).padStart(2, "0")}`;
  const meridiem = hour < 12 ? "am" : "pm";
  return `${MONTHS[at.getMonth()]} ${at.getDate()}, ${hour12}${minuteText}${meridiem}`;
}

function percent(value: number): string {
  return `${Math.round(value)}%`;
}

/** The line, or undefined when there is no figure to show yet. */
export function usageLine(usage: UsageFigures): string | undefined {
  const parts: string[] = [];
  if (typeof usage.context.percent === "number") parts.push(`context ${percent(usage.context.percent)}`);
  for (const limit of usage.rateLimits) {
    if (limit.kind === "five_hour") parts.push(`5h quota ${percent(limit.percentUsed)}`);
    else if (limit.kind === "seven_day") {
      const resets = resetLabel(limit.resetsAt);
      parts.push(`week ${percent(limit.percentUsed)}${resets === undefined ? "" : ` (resets ${resets})`}`);
    } else parts.push(`${limit.kind.replace(/_/g, " ")} ${percent(limit.percentUsed)}`);
  }
  return parts.length === 0 ? undefined : parts.join(" · ");
}

/** The transcript notice that carries the line: shown and stored, never read by the model. */
export function usageNotice(line: string) {
  return { type: "system" as const, content: [{ type: "text" as const, text: line }] };
}
