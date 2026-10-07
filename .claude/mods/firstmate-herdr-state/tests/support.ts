// Shared fixtures for the firstmate-herdr-state plugin test suites under `claude plugin test`.
//
// Each test mocks the world beneath the plugin noun by noun: the herdr pane environment,
// the file system that says whether the herdr binary resolves, the session's merged
// settings, the prompt box, and a recording herdr: every `$.process.run` the mod makes
// is journaled with the token or lifecycle values it carried.
import type { On } from "claude-code";
import { mock, type MockClock } from "claude-code/testing";

export const HERDR_BIN = "/opt/herdr/bin/herdr";
export const PANE = "w1:p1";

/** The environment herdr gives a pane. */
export const HERDR_PANE_ENV = {
  HERDR_ENV: "1",
  HERDR_PANE_ID: PANE,
  HERDR_BIN_PATH: HERDR_BIN,
  HERDR_SOCKET_PATH: "/run/herdr/herdr.sock",
};

/** Settings as `herdr integration install claude` leaves them. */
export const HERDR_HOOK_SETTINGS = {
  hooks: {
    SessionStart: [{ hooks: [{ type: "command", command: "bash '~/.claude/hooks/herdr-agent-state.sh' session" }] }],
  },
};

export type Run = {
  argv: readonly string[];
  /** The herdr subcommand: report-metadata, report-agent, or release-agent. */
  command: string;
  seq: number;
  /** `--token NAME=VALUE` pairs. */
  tokens: Record<string, string>;
  /** `--clear-token` names. */
  cleared: string[];
  /** `--state` of a lifecycle report. */
  state?: string;
  message?: string;
  timeoutMs?: number;
};

export type World = {
  clock: MockClock;
  runs: Run[];
  /** Sets what `$.prompt.read()` answers from now on. */
  setBox: (text: string) => void;
  /** Opens or closes a dialog over the prompt box: fills are refused while it is open. */
  setDialog: (open: boolean) => void;
  /** Makes every herdr command fail (`deny`) or hang until its timeout. */
  failHerdr: (mode: "deny" | "hang" | undefined) => void;
};

export type WorldOptions = {
  env?: Record<string, string>;
  binaryExists?: boolean;
  settings?: unknown;
};

function parseRun(argv: readonly string[], timeoutMs: number | undefined): Run {
  const run: Run = { argv, command: argv[2] ?? "", seq: Number.NaN, tokens: {}, cleared: [], timeoutMs };
  for (let i = 3; i < argv.length; i += 1) {
    const flag = argv[i];
    const value = argv[i + 1] ?? "";
    if (flag === "--seq") run.seq = Number(value);
    else if (flag === "--token") {
      const cut = value.indexOf("=");
      run.tokens[value.slice(0, cut)] = value.slice(cut + 1);
    } else if (flag === "--clear-token") run.cleared.push(value);
    else if (flag === "--state") run.state = value;
    else if (flag === "--message") run.message = value;
  }
  return run;
}

export function world(on: On, options: WorldOptions = {}): World {
  mock.env(on, options.env ?? HERDR_PANE_ENV);
  const clock = mock.clock(on);
  const runs: Run[] = [];
  let box = "";
  let dialog = false;
  let failure: "deny" | "hang" | undefined;
  on("fs.exists", async (_$, e) => ({ value: (options.binaryExists ?? true) && e.path === HERDR_BIN }));
  on("settings.read", async () => ({ value: (options.settings ?? {}) as never }));
  on("prompt.read", async () => ({ value: { text: box, cursor: box.length } }));
  on("prompt.suggest", async () => ({ isShown: box === "" }));
  on("prompt.fill", async (_$, e) => {
    if (dialog) return { isFilled: false, refusal: "dialog" as const };
    box = e.mode === "replace" ? e.text : box + e.text;
    return { isFilled: true };
  });
  on("prompt.submit", async (_$, e) => ({ text: e.text }));
  on("turn.start", async (_$, e) => ({ turnId: e.turnId }));
  on("turn.complete", async (_$, e) => ({ text: e.answer }));
  on("session.start", async (_$, e) => ({ cwd: e.cwd }));
  on("session.end", async (_$, e) => ({ sessionId: e.sessionId }));
  on("classic.PermissionRequest", async () => ({}));
  on("process.run", async (_$, e) => {
    runs.push(parseRun(e.argv, e.init?.timeoutMs));
    if (failure === "deny") return { deny: "herdr: connection refused" };
    if (failure === "hang") return new Promise(() => undefined);
    return { value: { exitCode: 0, stdout: "", stderr: "", isStdoutTruncated: false, isStderrTruncated: false } };
  });
  return {
    clock,
    runs,
    setBox: (text) => {
      box = text;
    },
    setDialog: (open) => {
      dialog = open;
    },
    failHerdr: (mode) => {
      failure = mode;
    },
  };
}

export const sessionStart = { cwd: "/work", surface: "terminal" as const, isInteractive: true };

/** A prompt the person typed and sent with Enter. */
export function submitted(text: string) {
  return { text, wait: false, origin: { kind: "composer" as const } };
}

export function turnComplete(turnId: string, agentId?: string) {
  return {
    answer: "done",
    durationMs: 10,
    isAborted: false,
    turnId,
    reason: "answer" as const,
    ...(agentId === undefined ? {} : { agentId }),
  };
}

/** The metadata reports, in order. */
export function metadata(runs: readonly Run[]): Run[] {
  return runs.filter((run) => run.command === "report-metadata");
}

/** The last published `state/composer` pair. */
export function lastSnapshot(runs: readonly Run[]): string | undefined {
  const reports = metadata(runs).filter((run) => run.tokens.fm_claude_state !== undefined);
  const last = reports[reports.length - 1];
  return last === undefined ? undefined : `${last.tokens.fm_claude_state}/${last.tokens.fm_claude_composer}`;
}

/** The lifecycle states reported, in order. */
export function lifecycle(runs: readonly Run[]): string[] {
  return runs.filter((run) => run.command === "report-agent").map((run) => run.state ?? "");
}
