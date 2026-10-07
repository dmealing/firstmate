# Usage line

The usage line is a one-row status of context fill and plan-limit use that Firstmate's Claude Code sessions leave under each completed answer, such as `context 42% · 5h quota 63% · week 81% (resets Oct 9, 6pm)`.
Its purpose is to make the context handoff point and an approaching weekly limit visible from the Remote Control view on claude.ai or the Claude mobile app, where the terminal's own status line does not reach.

## Where it runs

The `firstmate-usage-line` Claude Code mod (`.claude/mods/firstmate-usage-line`) loads through the project's `.claude/skills/firstmate-usage-line` entry, so it runs only in Claude Code sessions whose directory is this repository: the primary, its second mates, and workers on this repository.
Claude Code mods are on by default since Claude Code 2.1.287, and the mod has no switch of its own.

## What it does

After each completed main-loop answer, the mod reads `$.session.usage()` and appends one transcript notice built from it: the context window's percent, the five-hour window's percent, and the weekly window's percent with its local reset time.
A window Claude Code has no reading for is left out, and a session with no figures yet gets no line.
The plain usage read is free: the mod makes no model call, no network request, and no new turn, and a subagent's turn adds nothing.

## Form and its costs

The line is a `system` notice appended with `$.session.append`.
Claude Code stores it in the session transcript as an `informational` system row, and the model never reads it, so it costs no context.
Claude Code 2.1.292 does not draw such a notice in the terminal transcript, where the status line already shows the same figures.
The alternative of answering `turn.complete` with the line draws it beneath the answer in the terminal, but with an engine-chosen prefix naming every plugin hooked on that event, and stores the same kind of row, so it was not used.

Whether the Remote Control view on claude.ai or the mobile app renders a stored notice has not been verified, because that view needs the signed-in account.
[Verification](verification/runtime-backends.md#usage-line) records what was measured.

## Regression entry points

```sh
tests/fm-usage-line-mod.test.sh
tests/fm-usage-line-mod-plugin.test.sh
FM_USAGE_LINE_MOD_LIVE_E2E=1 tests/fm-usage-line-mod-live-e2e.test.sh
```
