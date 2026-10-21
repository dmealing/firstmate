// firstmate-usage-line under `claude plugin test`: the line is read from
// `$.session.usage()` after each completed main-loop answer and never holds the turn.
// The world's `$.session.append` hook passes each row through to the test kit
// (Claude Code 2.1.306 skips a hook that answers without `next`); the stored row is
// proven live (tests/fm-usage-line-mod-live-e2e.test.sh) and its notice shape here.
import type { On } from "claude-code";
import { describe, expect, test } from "claude-code/testing";
import { resetLabel, usageLine, usageNotice } from "../lib/fm-usage-line.ts";

const USAGE = {
  startedAt: 0,
  context: { window: 200_000, tokens: 84_000, percent: 42 },
  rateLimits: [
    { kind: "five_hour", percentUsed: 63.4, resetsAt: "2026-10-07T03:00:00Z" },
    { kind: "seven_day", percentUsed: 81, resetsAt: "2026-10-09T18:00:00" },
  ],
};

function world(on: On, usage: "fail" | typeof USAGE = USAGE): { reads: number } {
  const journal = { reads: 0 };
  on("turn.complete", async (_$, e) => ({ text: e.answer }));
  on("session.usage", async () => {
    journal.reads += 1;
    return usage === "fail" ? { deny: "usage unavailable" } : { value: usage as never };
  });
  on("session.append", async (_$, e, next) => next(e));
  return journal;
}

function completed(agentId?: string) {
  return {
    answer: "done",
    durationMs: 10,
    isAborted: false,
    turnId: "t1",
    reason: "answer" as const,
    ...(agentId === undefined ? {} : { agentId }),
  };
}

describe("usage line", () => {
  test("reads the usage figures after a completed main-loop answer and leaves the answer as it was", async ($, on) => {
    const journal = world(on);
    expect((await $.turn.complete(completed())).text).toBe("done");
    expect(journal.reads).toBe(1);
  });

  test("a subagent's completed turn reads nothing", async ($, on) => {
    const journal = world(on);
    await $.turn.complete(completed("agent-3"));
    expect(journal.reads).toBe(0);
  });

  test("a failing usage read never fails the turn", async ($, on) => {
    world(on, "fail");
    expect((await $.turn.complete(completed())).text).toBe("done");
  });
});

describe("line text", () => {
  test("joins context and each plan-limit window, with the weekly reset", () => {
    expect(usageLine(USAGE)).toBe("context 42% · 5h quota 63% · week 81% (resets Oct 9, 6pm)");
    expect(usageNotice("x")).toEqual({ type: "system", content: [{ type: "text", text: "x" }] });
  });

  test("shows only the figures that exist, and names an unknown window by its kind", () => {
    expect(usageLine({ context: {}, rateLimits: [] })).toBeUndefined();
    expect(usageLine({ context: { percent: 7.6 }, rateLimits: [] })).toBe("context 8%");
    expect(usageLine({ context: {}, rateLimits: [{ kind: "spend_limit", percentUsed: 104 }] })).toBe("spend limit 104%");
    expect(usageLine({ context: {}, rateLimits: [{ kind: "seven_day", percentUsed: 5 }] })).toBe("week 5%");
  });

  test("labels a reset in local time, minutes only off the hour", () => {
    expect(resetLabel("2026-10-09T18:00:00")).toBe("Oct 9, 6pm");
    expect(resetLabel("2026-01-02T00:30:00")).toBe("Jan 2, 12:30am");
    expect(resetLabel("not a time")).toBeUndefined();
    expect(resetLabel(undefined)).toBeUndefined();
  });
});
