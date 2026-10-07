// Firstmate herdr state for Claude Code: the hooks module of the `firstmate-herdr-state` mod.
//
// herdr's own Claude integration reports only session identity, and herdr infers
// working, idle, and blocked from the screen. This mod reports what Claude Code itself
// knows, from its events, to the herdr pane the session runs in:
//   - prompt submitted or turn started -> working; the main turn completed -> idle;
//   - a question tool waiting on the person, or a permission prompt -> blocked, until
//     that tool call resolves;
//   - the prompt box: real input (typed, pasted, or filled) -> pending; nothing, or only
//     Claude Code's dim suggestion -> empty or suggestion; an empty box while a dialog
//     holds the keys -> dialog.
// Every snapshot is published as herdr pane metadata tokens with a TTL, refreshed on a
// heartbeat, which Firstmate reads back per pane (docs/herdr-backend.md "Claude Code
// state mod" owns that contract). Where no herdr hook runs in this session, the agent
// state also goes to `herdr pane report-agent`, released at session end; where herdr's
// Claude integration runs, it owns the pane's identity and herdr 0.9.1 refuses other
// lifecycle sources, so the mod stays out of its way.
//
// Outside a herdr pane (no HERDR_ENV=1, pane, socket, or resolvable herdr binary) every
// hook passes straight through and no timer starts. Every report runs after the hook
// that caused it has returned, bounded by a timeout, its failure dropped, so herdr being
// slow or gone never blocks, slows, or fails a turn. ../lib/fm-herdr-state.ts owns the
// pure policy; this file is the only place the engine interface `$` is touched.
import { atom, read, update } from "claude-code";
import type { EngineInterface, Register } from "claude-code";
import type { FirstmateHerdrTurn } from "../types";
import {
  COMPOSER_POLL_MS,
  HEARTBEAT_MS,
  HERDR_TIMEOUT_MS,
  clearMetadataArgv,
  composerState,
  createSequence,
  herdrTarget,
  isSlashCommand,
  metadataArgv,
  releaseAgentArgv,
  reportAgentArgv,
  settingsRunHerdrHook,
  toolAsksPerson,
  type AgentState,
  type HerdrTarget,
} from "../lib/fm-herdr-state.ts";

// The turn lives in the session's state so a hot reload mid-turn keeps reporting it.
const turn = atom({ plugin: "firstmate-herdr-state", key: "turn" } as const, {
  running: false,
  blocked: null,
} as FirstmateHerdrTurn);

// One module environment serves one session; a reload starts these over and
// `session.start` fires again.
let target: HerdrTarget | undefined;
let lifecycle = false;
let composerText = "";
let suggestionShown = false;
let dialogOpen = false;
let submitPending = false;
let publishedSnapshot: string | undefined;
let publishedLifecycle: string | undefined;
let timers: { cancel(): void }[] = [];
let chain: Promise<void> = Promise.resolve();
const nextSeq = createSequence();

function agentState(t: FirstmateHerdrTurn): AgentState {
  if (t.blocked !== null) return "blocked";
  return t.running || submitPending ? "working" : "idle";
}

function blockMessage(t: FirstmateHerdrTurn): string | undefined {
  if (t.blocked === null) return undefined;
  return t.blocked.kind === "question" ? `question: ${t.blocked.tool}` : `permission: ${t.blocked.tool}`;
}

/** Run one herdr command in the background: bounded, its outcome ignored. */
function launch($: EngineInterface, argv: string[]): void {
  void $.process.run(argv, { timeoutMs: HERDR_TIMEOUT_MS }).catch(() => undefined);
}

/**
 * Publish the current snapshot when it changed (or always, on a heartbeat). Calls are
 * serialized so report numbers rise in the order snapshots were taken; the commands
 * themselves run unawaited, and herdr drops any that arrives behind a newer one.
 */
function publish($: EngineInterface, force = false): Promise<void> {
  chain = chain.then(async () => {
    const where = target;
    if (where === undefined) return;
    const t = await read($, turn);
    const snapshot = { state: agentState(t), composer: composerState(composerText, suggestionShown, dialogOpen) };
    const now = await $.clock.now();
    const key = `${snapshot.state}/${snapshot.composer}`;
    if (force || key !== publishedSnapshot) {
      publishedSnapshot = key;
      launch($, metadataArgv(where, nextSeq(now), snapshot, now));
    }
    if (lifecycle) {
      const message = blockMessage(t);
      const lifecycleKey = `${snapshot.state}/${message ?? ""}`;
      if (lifecycleKey !== publishedLifecycle) {
        publishedLifecycle = lifecycleKey;
        launch($, reportAgentArgv(where, nextSeq(now), snapshot.state, message));
      }
    }
  }).catch(() => undefined);
  return chain;
}

/** Publish after the calling hook has returned, so no hook waits on herdr. */
function schedule($: EngineInterface): void {
  if (target === undefined) return;
  $.clock.after(0, () => {
    void publish($);
  });
}

function setComposer($: EngineInterface, text: string, suggestion: boolean, dialog = dialogOpen): void {
  const before = composerState(composerText, suggestionShown, dialogOpen);
  composerText = text;
  suggestionShown = suggestion;
  dialogOpen = dialog;
  if (composerState(composerText, suggestionShown, dialogOpen) !== before) schedule($);
}

async function readBox($: EngineInterface): Promise<string | undefined> {
  try {
    return (await $.prompt.read()).text;
  } catch {
    return undefined;
  }
}

/**
 * Whether the box is free to type into. An empty insert at the cursor changes nothing
 * the person typed, and the engine refuses it while a dialog holds the keys (or no box
 * is drawn); any refusal counts as not free.
 */
async function boxHeldByDialog($: EngineInterface): Promise<boolean> {
  try {
    return !(await $.prompt.fill({ text: "", mode: "insert" })).isFilled;
  } catch {
    return true;
  }
}

/** Re-read the prompt box: catches changes no event announces (history, a restored prompt, a dialog). */
async function resyncComposer($: EngineInterface): Promise<void> {
  const text = await readBox($);
  if (text === undefined) return;
  // Text in the box is pending whatever covers it, so only an empty box needs the probe.
  const dialog = text === "" ? await boxHeldByDialog($) : false;
  setComposer($, text, text === "" ? suggestionShown : false, dialog);
}

function stopTimers(): void {
  for (const timer of timers) timer.cancel();
  timers = [];
}

async function binaryResolves($: EngineInterface, path: string): Promise<boolean> {
  try {
    return await $.fs.exists(path);
  } catch {
    return false;
  }
}

async function runsHerdrHook($: EngineInterface): Promise<boolean> {
  try {
    return settingsRunHerdrHook(await $.settings.read());
  } catch {
    // Unreadable settings: assume the integration may run, and send metadata only.
    return true;
  }
}

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    stopTimers();
    const found = herdrTarget({
      HERDR_ENV: await $.env.get("HERDR_ENV"),
      HERDR_PANE_ID: await $.env.get("HERDR_PANE_ID"),
      HERDR_BIN_PATH: await $.env.get("HERDR_BIN_PATH"),
      HERDR_SOCKET_PATH: await $.env.get("HERDR_SOCKET_PATH"),
    });
    target = found !== undefined && (await binaryResolves($, found.bin)) ? found : undefined;
    if (target === undefined) return next(e);
    lifecycle = !(await runsHerdrHook($));
    publishedSnapshot = undefined;
    publishedLifecycle = undefined;
    composerText = (await readBox($)) ?? "";
    suggestionShown = false;
    dialogOpen = composerText === "" ? await boxHeldByDialog($) : false;
    await publish($, true);
    timers = [
      $.clock.every(COMPOSER_POLL_MS, () => {
        void resyncComposer($);
      }),
      $.clock.every(HEARTBEAT_MS, () => {
        void publish($, true);
      }),
    ];
    return next(e);
  });

  // Every hook below lets its event through whatever herdr does.
  on("prompt.submit", async ($, e, next) => {
    if (target === undefined) return next(e);
    if (e.origin?.kind === "composer") setComposer($, "", false, false);
    // A slash command may start no turn; `turn.start` reports one that does.
    if (!isSlashCommand(e.text)) {
      submitPending = true;
      schedule($);
    }
    try {
      return await next(e);
    } finally {
      // The prompt entered and its turn started or queued, or it never entered:
      // `turn.start` now owns working either way.
      if (submitPending) {
        submitPending = false;
        schedule($);
      }
    }
  }).catch(($, e, next) => next(e));

  on("turn.start", async ($, e, next) => {
    if (target !== undefined) {
      await update($, turn, () => ({ running: true, blocked: null }));
      schedule($);
    }
    return next(e);
  });

  on("turn.complete", async ($, e, next) => {
    // A subagent's turn is not the session's.
    if (target !== undefined && e.agentId === undefined) {
      await update($, turn, () => ({ running: false, blocked: null }));
      schedule($);
      // An interrupted turn can put its prompt back in the box.
      void resyncComposer($);
    }
    return next(e);
  });

  on("tool.call", async ($, e, next) => {
    if (target === undefined) return next(e);
    const tool = String(e.tool);
    if (e.agentId === undefined && toolAsksPerson(tool)) {
      await update($, turn, (t) => ({ ...t, blocked: { kind: "question" as const, tool } }));
      schedule($);
    }
    try {
      return await next(e);
    } finally {
      // Answered, or approved and run, or refused: the wait on this tool is over.
      const t = await read($, turn);
      if (t.blocked !== null && t.blocked.tool === tool) {
        await update($, turn, (now) => ({ ...now, blocked: null }));
        schedule($);
      }
    }
  }).catch(($, e, next) => next(e));

  on("classic.PermissionRequest", async ($, e, next) => {
    if (target !== undefined) {
      const tool = String(e.tool_name);
      await update($, turn, (t) => ({ ...t, blocked: { kind: "permission" as const, tool } }));
      schedule($);
    }
    return next(e);
  }).catch(($, e, next) => next(e));

  on("prompt.edit", async ($, e, next) => {
    const box = await next(e);
    if (target !== undefined) setComposer($, box.text, false, false);
    return box;
  }).catch(($, e, next) => next(e));

  on("prompt.fill", async ($, e, next) => {
    const filled = await next(e);
    if (target !== undefined && filled.isFilled) void resyncComposer($);
    return filled;
  }).catch(($, e, next) => next(e));

  on("prompt.suggest", async ($, e, next) => {
    const shown = await next(e);
    if (target !== undefined && shown.isShown && composerText === "") setComposer($, "", true, false);
    return shown;
  }).catch(($, e, next) => next(e));

  on("session.end", async ($, e, next) => {
    const where = target;
    if (where === undefined) return next(e);
    if (e.reason === "clear") {
      // /clear keeps the session and its pane: start the next conversation idle.
      await update($, turn, () => ({ running: false, blocked: null }));
      setComposer($, "", false);
      schedule($);
      return next(e);
    }
    stopTimers();
    target = undefined;
    try {
      const now = await $.clock.now();
      const timeoutMs = Math.max(100, Math.min(HERDR_TIMEOUT_MS, next.budget.remainingMs - 250));
      const runs = [$.process.run(clearMetadataArgv(where, nextSeq(now)), { timeoutMs })];
      if (lifecycle) runs.push($.process.run(releaseAgentArgv(where, nextSeq(now)), { timeoutMs }));
      await Promise.allSettled(runs);
    } catch {
      // The tokens expire on their own; herdr releases lifecycle authority when the process exits.
    }
    return next(e);
  });
};
