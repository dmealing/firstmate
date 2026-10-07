// firstmate-herdr-state under `claude plugin test`: activation, the agent and composer
// states it publishes to herdr, the lifecycle reports it sends only where herdr's Claude
// integration does not run, and that herdr failing never holds up a turn.
import { describe, expect, test } from "claude-code/testing";
import {
  HERDR_BIN,
  HERDR_HOOK_SETTINGS,
  HERDR_PANE_ENV,
  PANE,
  lastSnapshot,
  lifecycle,
  metadata,
  sessionStart,
  submitted,
  turnComplete,
  world,
} from "./support.ts";

const QUESTION = { tool: "AskUserQuestion", tool_use_id: "toolu_q", questions: [] } as never;

describe("activation", () => {
  test("is a complete no-op outside a herdr pane", async ($, on) => {
    const { clock, runs } = world(on, { env: {} });
    await $.session.start(sessionStart);
    await $.prompt.submit(submitted("hello"));
    await $.turn.start({ text: "hello", turnId: "t1" });
    await $.turn.complete(turnComplete("t1"));
    await clock.advance(60_000);
    expect(runs).toHaveLength(0);
  });

  test("is a complete no-op when HERDR_ENV is not exactly 1", async ($, on) => {
    const { clock, runs } = world(on, { env: { ...HERDR_PANE_ENV, HERDR_ENV: "true" } });
    await $.session.start(sessionStart);
    await clock.advance(60_000);
    expect(runs).toHaveLength(0);
  });

  test("is a complete no-op when the herdr binary does not resolve", async ($, on) => {
    const { clock, runs } = world(on, { binaryExists: false });
    await $.session.start(sessionStart);
    await $.prompt.submit(submitted("hello"));
    await clock.advance(60_000);
    expect(runs).toHaveLength(0);
  });

  test("is a complete no-op without the pane's server socket", async ($, on) => {
    const { HERDR_SOCKET_PATH: _dropped, ...env } = HERDR_PANE_ENV;
    const { clock, runs } = world(on, { env });
    await $.session.start(sessionStart);
    await clock.advance(60_000);
    expect(runs).toHaveLength(0);
  });

  test("publishes idle with an empty composer at session start, to the pane through herdr's own binary", async ($, on) => {
    const { clock, runs } = world(on, { settings: HERDR_HOOK_SETTINGS });
    const startedAt = clock.now();
    await $.session.start(sessionStart);
    await clock.advance(1);
    const first = metadata(runs)[0];
    expect(first?.argv.slice(0, 4)).toEqual([HERDR_BIN, "pane", "report-metadata", PANE]);
    expect(first?.argv).toContain("custom:firstmate-claude");
    expect(first?.argv).toContain("45000");
    expect(first?.tokens.fm_claude_state).toBe("idle");
    expect(first?.tokens.fm_claude_composer).toBe("empty");
    expect(Number(first?.tokens.fm_claude_at)).toBe(startedAt);
    expect(first?.timeoutMs).toBe(3000);
  });
});

describe("agent state", () => {
  test("reports working from prompt submission through the turn, then idle when it completes", async ($, on) => {
    const { clock, runs } = world(on, { settings: HERDR_HOOK_SETTINGS });
    await $.session.start(sessionStart);
    await $.prompt.submit(submitted("fix the bug"));
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("idle/empty");
    await $.turn.start({ text: "fix the bug", turnId: "t1" });
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("working/empty");
    await $.turn.complete(turnComplete("t1"));
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("idle/empty");
    const seqs = metadata(runs).map((run) => run.seq);
    expect(seqs).toEqual([...seqs].sort((a, b) => a - b));
    expect(new Set(seqs).size).toBe(seqs.length);
  });

  test("a slash command that starts no turn never reads as working", async ($, on) => {
    const { clock, runs } = world(on, { settings: HERDR_HOOK_SETTINGS });
    await $.session.start(sessionStart);
    await $.prompt.submit(submitted("/help"));
    await clock.advance(1);
    expect(metadata(runs).map((run) => run.tokens.fm_claude_state)).not.toContain("working");
  });

  test("a subagent's completed turn leaves the main turn working", async ($, on) => {
    const { clock, runs } = world(on, { settings: HERDR_HOOK_SETTINGS });
    await $.session.start(sessionStart);
    await $.turn.start({ text: "go", turnId: "t1" });
    await $.turn.complete(turnComplete("t2", "agent-7"));
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("working/empty");
  });

  test("reports blocked while a question waits on the person, and working once it is answered", async ($, on) => {
    const { clock, runs } = world(on, { settings: HERDR_HOOK_SETTINGS });
    let answer: () => void = () => undefined;
    on("tool.call", async () => {
      await new Promise<void>((resolve) => {
        answer = resolve;
      });
      return { result: { answers: {} } as never };
    });
    await $.session.start(sessionStart);
    await $.turn.start({ text: "go", turnId: "t1" });
    const call = $.tool.call(QUESTION);
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("blocked/empty");
    answer();
    await call;
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("working/empty");
  });

  test("reports blocked on a permission prompt until that tool's call resolves", async ($, on) => {
    const { clock, runs } = world(on, { settings: HERDR_HOOK_SETTINGS });
    on("tool.call", async () => ({ result: { stdout: "", stderr: "" } as never }));
    await $.session.start(sessionStart);
    await $.turn.start({ text: "go", turnId: "t1" });
    await $.classic.PermissionRequest({ tool_name: "Bash", tool_input: { command: "ls" } });
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("blocked/empty");
    await $.tool.call({ tool: "Read", tool_use_id: "toolu_r", file_path: "/x" } as never);
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("blocked/empty");
    await $.tool.call({ tool: "Bash", tool_use_id: "toolu_b", command: "ls" } as never);
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("working/empty");
  });

  test("an interrupted turn that ends while blocked reads idle", async ($, on) => {
    const { clock, runs } = world(on, { settings: HERDR_HOOK_SETTINGS });
    await $.session.start(sessionStart);
    await $.turn.start({ text: "go", turnId: "t1" });
    await $.classic.PermissionRequest({ tool_name: "Bash", tool_input: { command: "ls" } });
    await $.turn.complete({ ...turnComplete("t1"), isAborted: true, reason: "aborted" as const });
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("idle/empty");
  });
});

describe("composer state", () => {
  test("a dim suggestion reads as suggestion, not pending", async ($, on) => {
    const { clock, runs } = world(on, { settings: HERDR_HOOK_SETTINGS });
    await $.session.start(sessionStart);
    await $.prompt.suggest({ text: "run the tests", origin: { kind: "suggestion" } });
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("idle/suggestion");
  });

  test("filled text reads pending, and a submitted prompt empties it", async ($, on) => {
    const { clock, runs } = world(on, { settings: HERDR_HOOK_SETTINGS });
    await $.session.start(sessionStart);
    await $.prompt.fill({ text: "draft", mode: "replace", origin: { kind: "plugin", name: "drafts" } });
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("idle/pending");
    await $.prompt.submit(submitted("draft"));
    await clock.advance(1);
    expect(lastSnapshot(runs)?.endsWith("/empty")).toBe(true);
  });

  test("text that reaches the box without an event is caught within a second", async ($, on) => {
    const { clock, runs, setBox } = world(on, { settings: HERDR_HOOK_SETTINGS });
    await $.session.start(sessionStart);
    setBox("  ");
    await clock.advance(1000);
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("idle/pending");
    setBox("");
    await clock.advance(1000);
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("idle/empty");
  });

  test("an empty box under a dialog reads dialog, and empty again once it closes", async ($, on) => {
    const { clock, runs, setDialog } = world(on, { settings: HERDR_HOOK_SETTINGS });
    await $.session.start(sessionStart);
    setDialog(true);
    await clock.advance(1000);
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("idle/dialog");
    setDialog(false);
    await clock.advance(1000);
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("idle/empty");
  });

  test("text under a dialog still reads pending", async ($, on) => {
    const { clock, runs, setBox, setDialog } = world(on, { settings: HERDR_HOOK_SETTINGS });
    await $.session.start(sessionStart);
    setBox("half-typed");
    setDialog(true);
    await clock.advance(1000);
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("idle/pending");
  });

  test("text already in the box at session start reads pending", async ($, on) => {
    const { clock, runs, setBox } = world(on, { settings: HERDR_HOOK_SETTINGS });
    setBox("restored");
    await $.session.start(sessionStart);
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("idle/pending");
  });
});

describe("freshness", () => {
  test("refreshes the tokens before herdr's TTL expires, with an unchanged snapshot", async ($, on) => {
    const { clock, runs } = world(on, { settings: HERDR_HOOK_SETTINGS });
    await $.session.start(sessionStart);
    await clock.advance(1);
    const before = metadata(runs).length;
    await clock.advance(15_000);
    await clock.advance(1);
    const after = metadata(runs);
    expect(after.length).toBe(before + 1);
    expect(Number(after[after.length - 1]?.tokens.fm_claude_at)).toBeGreaterThan(Number(after[0]?.tokens.fm_claude_at));
  });

  test("a session end clears the tokens and stops every timer", async ($, on) => {
    const { clock, runs } = world(on, { settings: HERDR_HOOK_SETTINGS });
    await $.session.start(sessionStart);
    await $.session.end({ reason: "prompt_input_exit", sessionId: "s1", resume: { id: "s1" } } as never);
    const cleared = metadata(runs).filter((run) => run.cleared.length > 0);
    expect(cleared).toHaveLength(1);
    expect(cleared[0]?.cleared.sort()).toEqual(["fm_claude_at", "fm_claude_composer", "fm_claude_state"]);
    expect(lifecycle(runs)).toEqual([]);
    expect(runs.some((run) => run.command === "release-agent")).toBe(false);
    const count = runs.length;
    await clock.advance(60_000);
    expect(runs.length).toBe(count);
  });

  test("/clear keeps the session reporting, idle", async ($, on) => {
    const { clock, runs } = world(on, { settings: HERDR_HOOK_SETTINGS });
    await $.session.start(sessionStart);
    await $.turn.start({ text: "go", turnId: "t1" });
    await $.session.end({ reason: "clear", sessionId: "s1", resume: { id: "s1" } } as never);
    await clock.advance(1);
    expect(lastSnapshot(runs)).toBe("idle/empty");
    const count = metadata(runs).length;
    await clock.advance(15_000);
    expect(metadata(runs).length).toBeGreaterThan(count);
  });
});

describe("herdr lifecycle authority", () => {
  test("sends no lifecycle report while herdr's Claude integration runs in this session", async ($, on) => {
    const { clock, runs } = world(on, { settings: HERDR_HOOK_SETTINGS });
    await $.session.start(sessionStart);
    await $.turn.start({ text: "go", turnId: "t1" });
    await $.turn.complete(turnComplete("t1"));
    await clock.advance(1);
    expect(lifecycle(runs)).toEqual([]);
  });

  test("reports lifecycle state without a session id where no herdr hook runs, and releases it at the end", async ($, on) => {
    const { clock, runs } = world(on, { settings: {} });
    await $.session.start(sessionStart);
    await $.turn.start({ text: "go", turnId: "t1" });
    await clock.advance(1);
    await $.classic.PermissionRequest({ tool_name: "Bash", tool_input: { command: "rm -rf build" } });
    await clock.advance(1);
    await $.turn.complete(turnComplete("t1"));
    await clock.advance(1);
    expect(lifecycle(runs)).toEqual(["idle", "working", "blocked", "idle"]);
    const reports = runs.filter((run) => run.command === "report-agent");
    expect(reports.every((run) => !run.argv.includes("--agent-session-id"))).toBe(true);
    expect(reports.every((run) => run.argv.includes("--agent") && run.argv.includes("claude"))).toBe(true);
    expect(reports[2]?.message).toBe("permission: Bash");
    await $.session.end({ reason: "prompt_input_exit", sessionId: "s1", resume: { id: "s1" } } as never);
    expect(runs.filter((run) => run.command === "release-agent")).toHaveLength(1);
  });
});

describe("herdr never holds up Claude", () => {
  test("a failing herdr leaves every event to complete", async ($, on) => {
    const { clock, failHerdr } = world(on, { settings: {} });
    failHerdr("deny");
    await $.session.start(sessionStart);
    expect((await $.prompt.submit(submitted("hello"))).text).toBe("hello");
    await $.turn.start({ text: "hello", turnId: "t1" });
    await $.turn.complete(turnComplete("t1"));
    await clock.advance(60_000);
  });

  test("a hanging herdr leaves every event to complete", async ($, on) => {
    const { clock, failHerdr } = world(on, { settings: {} });
    failHerdr("hang");
    await $.session.start(sessionStart);
    expect((await $.prompt.submit(submitted("hello"))).text).toBe("hello");
    await $.turn.start({ text: "hello", turnId: "t1" });
    await $.turn.complete(turnComplete("t1"));
    await clock.advance(60_000);
  });
});
