#!/usr/bin/env bash
# Live token-free guard (live-harness-optin family) for the firstmate-herdr-state
# Claude Code mod against the real installed Claude Code and Herdr, in an isolated
# Herdr lab. No prompt is submitted, so it runs by default wherever herdr, jq, and
# claude are installed. It proves the mod loads through --plugin-dir as fm-spawn
# launches it, publishes the idle session's empty composer, reports typed text as
# pending, and that Firstmate's herdr adapter reads that back: an idle Claude
# session's composer reads empty, never unknown, and real input stays pending.
# The prompt-submitting half is tests/fm-herdr-claude-state-mod-turn-live-e2e.test.sh.
# Refresh docs/verification/runtime-backends.md "Claude Code state mod" from it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_HERDR_CLAUDE_STATE_MOD_LIVE herdr jq claude

# shellcheck source=tests/herdr-claude-state-mod-fixture.sh
. "$ROOT/tests/herdr-claude-state-mod-fixture.sh" herdr-claude-state-mod

launch_claude CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false
wait_for_composer
wait_reported 'idle/empty' "an idle session with an empty composer"
verdict=$(fm_backend_herdr_composer_state "$TARGET")
[ "$verdict" = empty ] \
  || fail "Claude Code $CLAUDE_VER on $HERDR_VER: an idle session's empty composer read '$verdict', not empty"
[ "$(fm_backend_herdr_agent_status_raw "$SESSION" "$PANE")" = idle ] \
  || fail "Claude Code $CLAUDE_VER on $HERDR_VER: the adapter did not read the mod's idle state"
pass "Claude Code $CLAUDE_VER on $HERDR_VER: the mod loads through --plugin-dir and an idle session's composer reads empty (screen alone: $(screen_only_composer))"

lab pane send-text "$PANE" "typed by the person" >/dev/null || fail "could not type into the lab pane"
wait_reported 'idle/pending' "typed text as pending"
verdict=$(fm_backend_herdr_composer_state "$TARGET")
[ "$verdict" = pending ] \
  || fail "Claude Code $CLAUDE_VER on $HERDR_VER: typed text read '$verdict', not pending"
lab pane send-keys "$PANE" ctrl+e ctrl+u >/dev/null || fail "could not clear the lab composer"
wait_reported 'idle/empty' "the cleared composer as empty"
pass "Claude Code $CLAUDE_VER on $HERDR_VER: typed text reads pending and a cleared composer reads empty again"

exit_claude_and_check_cleared
pass "Claude Code $CLAUDE_VER on $HERDR_VER: the mod clears its tokens when the session ends"
