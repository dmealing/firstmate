// Firstmate usage line for Claude Code: the hooks module of the `firstmate-usage-line` mod.
//
// After each completed main-loop answer, the mod appends one transcript notice built
// from `$.session.usage()`: the context window's fill and each plan-limit window's use.
// A notice (`type: "system"`) is drawn and stored in the conversation, so a view that
// renders the transcript can show it, and the model never reads it, so it costs no
// context. The plain usage call is free: no model call, no network, no new turn.
// docs/usage-line.md owns the contract; ../lib/fm-usage-line.ts owns the line's text.
import type { Register } from "claude-code";
import { usageLine, usageNotice } from "../lib/fm-usage-line.ts";

export const register: Register = (on) => {
  on("turn.complete", async ($, e, next) => {
    const answered = await next(e);
    // A subagent's turn is not the session's answer.
    if (e.agentId !== undefined) return answered;
    try {
      const line = usageLine(await $.session.usage());
      if (line !== undefined) {
        await $.session.append({ message: usageNotice(line) });
      }
    } catch {
      // No figures this time; the answer stands as it is.
    }
    return answered;
  });
};
