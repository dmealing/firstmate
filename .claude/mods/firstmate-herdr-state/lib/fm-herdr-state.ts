// Firstmate herdr state reporting policy for the Claude Code mod, kept free of the engine.
//
// This module owns the decisions ../hooks/register.ts applies through `$`: whether the
// session runs inside a herdr pane, whether herdr's own Claude session-identity hook
// runs for this session, how the prompt box reads as a composer state, and the exact
// herdr command vectors the mod sends. docs/herdr-backend.md ("Claude Code state mod")
// owns the published contract that bin/backends/herdr.sh reads back. Everything here is
// pure so the plugin tests pin it without a herdr binary.

/** The stable herdr reporting source for both lifecycle reports and metadata tokens. */
export const HERDR_STATE_SOURCE = "custom:firstmate-claude";

/** The agent label every report names. */
export const HERDR_STATE_AGENT = "claude";

/** Metadata token names: the agent state, the composer state, and the report time. */
export const TOKEN_STATE = "fm_claude_state";
export const TOKEN_COMPOSER = "fm_claude_composer";
export const TOKEN_AT = "fm_claude_at";

/** How long herdr keeps the tokens without a refresh, and how often the mod refreshes. */
export const TOKEN_TTL_MS = 45_000;
export const HEARTBEAT_MS = 15_000;

/** How often the mod re-reads the prompt box to catch changes no event announces. */
export const COMPOSER_POLL_MS = 1_000;

/** The bound on every herdr command the mod runs. */
export const HERDR_TIMEOUT_MS = 3_000;

export type AgentState = "idle" | "working" | "blocked";

/**
 * `empty`: nothing typed; `suggestion`: only Claude Code's dim suggestion shows; `pending`:
 * real text; `dialog`: a dialog holds the keys, so typed text would not reach the box.
 */
export type ComposerState = "empty" | "suggestion" | "pending" | "dialog";

export type HerdrTarget = {
  /** The herdr binary herdr itself named for the pane. */
  readonly bin: string;
  /** The pane this session runs in. */
  readonly pane: string;
};

export type HerdrEnvironment = {
  readonly HERDR_ENV?: string | undefined;
  readonly HERDR_PANE_ID?: string | undefined;
  readonly HERDR_BIN_PATH?: string | undefined;
  readonly HERDR_SOCKET_PATH?: string | undefined;
};

/**
 * The pane to report to, or undefined outside herdr. herdr marks its panes with
 * `HERDR_ENV=1` and names the pane, its server socket, and its own binary; all four
 * must be present, the same gate herdr's own integration hooks apply. Whether the
 * binary resolves on disk is the caller's check.
 */
export function herdrTarget(env: HerdrEnvironment): HerdrTarget | undefined {
  if (env.HERDR_ENV !== "1") return undefined;
  const pane = env.HERDR_PANE_ID?.trim() ?? "";
  const bin = env.HERDR_BIN_PATH?.trim() ?? "";
  const socket = env.HERDR_SOCKET_PATH?.trim() ?? "";
  if (pane === "" || bin === "" || socket === "") return undefined;
  return { bin, pane };
}

/**
 * Whether the session's merged settings run a herdr hook. herdr's Claude integration
 * (`herdr integration install claude`) reports session identity from a settings hook,
 * and herdr 0.9.1 then refuses lifecycle reports from any other source for that pane;
 * a lifecycle report accepted before that identity lands would also freeze herdr's
 * state, so the mod sends lifecycle reports only when no herdr hook runs. Any hook
 * command naming herdr counts, so a renamed or wrapped hook errs toward metadata only.
 */
export function settingsRunHerdrHook(settings: unknown): boolean {
  if (settings === null || typeof settings !== "object") return false;
  const hooks = (settings as { hooks?: unknown }).hooks;
  if (hooks === undefined || hooks === null) return false;
  try {
    return /herdr/i.test(JSON.stringify(hooks));
  } catch {
    return true;
  }
}

/**
 * The composer state of a prompt box: any character, whitespace included, is real input
 * even under a dialog; an empty box under a dialog is not free to type into.
 */
export function composerState(text: string, suggestionShown: boolean, dialogOpen: boolean): ComposerState {
  if (text.length > 0) return "pending";
  if (dialogOpen) return "dialog";
  return suggestionShown ? "suggestion" : "empty";
}

/** Whether a submitted prompt is a slash command, which may start no model turn at all. */
export function isSlashCommand(text: string): boolean {
  return text.trimStart().startsWith("/");
}

/** Tools that put a question to the person and wait for the answer. */
export function toolAsksPerson(tool: string): boolean {
  return tool === "AskUserQuestion" || tool === "ExitPlanMode";
}

/** One line of at most 80 characters, control characters removed, for `--message`. */
export function shortMessage(text: string): string {
  const line = text.replace(/[\u0000-\u001f\u007f-\u009f​-‏‪-‮⁦-⁩]+/g, " ").trim();
  return line.length > 80 ? line.slice(0, 79) + "…" : line;
}

/** Strictly increasing report numbers: microseconds of wall time, never repeating. */
export function createSequence(): (nowMs: number) => number {
  let last = 0;
  return (nowMs: number) => {
    last = Math.max(Math.floor(nowMs) * 1000, last + 1);
    return last;
  };
}

export type Snapshot = {
  readonly state: AgentState;
  readonly composer: ComposerState;
};

/** The metadata report that publishes a snapshot, refreshed before its tokens expire. */
export function metadataArgv(target: HerdrTarget, seq: number, snapshot: Snapshot, nowMs: number): string[] {
  return [
    target.bin, "pane", "report-metadata", target.pane,
    "--source", HERDR_STATE_SOURCE,
    "--seq", String(seq),
    "--ttl-ms", String(TOKEN_TTL_MS),
    "--token", `${TOKEN_STATE}=${snapshot.state}`,
    "--token", `${TOKEN_COMPOSER}=${snapshot.composer}`,
    "--token", `${TOKEN_AT}=${Math.floor(nowMs)}`,
  ];
}

/** The metadata report that removes every token the mod published. */
export function clearMetadataArgv(target: HerdrTarget, seq: number): string[] {
  return [
    target.bin, "pane", "report-metadata", target.pane,
    "--source", HERDR_STATE_SOURCE,
    "--seq", String(seq),
    "--clear-token", TOKEN_STATE,
    "--clear-token", TOKEN_COMPOSER,
    "--clear-token", TOKEN_AT,
  ];
}

/** A lifecycle report. No session id: herdr's Claude integration owns session identity. */
export function reportAgentArgv(target: HerdrTarget, seq: number, state: AgentState, message?: string): string[] {
  const argv = [
    target.bin, "pane", "report-agent", target.pane,
    "--source", HERDR_STATE_SOURCE,
    "--agent", HERDR_STATE_AGENT,
    "--state", state,
    "--seq", String(seq),
  ];
  const text = message === undefined ? "" : shortMessage(message);
  if (text !== "") argv.push("--message", text);
  return argv;
}

/** The lifecycle release at session end, handing the pane back to herdr's screen detection. */
export function releaseAgentArgv(target: HerdrTarget, seq: number): string[] {
  return [
    target.bin, "pane", "release-agent", target.pane,
    "--source", HERDR_STATE_SOURCE,
    "--agent", HERDR_STATE_AGENT,
    "--seq", String(seq),
  ];
}
