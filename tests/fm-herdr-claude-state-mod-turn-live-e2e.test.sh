#!/usr/bin/env bash
# Live opt-in guard (live-harness-optin family) for the firstmate-herdr-state Claude
# Code mod: the half that submits prompts, so it spends a few Haiku turns and runs
# only with FM_HERDR_CLAUDE_STATE_MOD_TURN_LIVE=1 or FM_LIVE=1. Against the real
# installed Claude Code and Herdr in an isolated lab, it proves Firstmate's submit
# confirmation lands on the mod's working report, the turn reads working and then
# idle, a question put to the person reads blocked with its dialog leaving the
# composer to the screen reading, and an interrupted turn returns to idle.
# The token-free half is tests/fm-herdr-claude-state-mod-live-e2e.test.sh.
# shellcheck disable=SC2016 # the model, not this shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_HERDR_CLAUDE_STATE_MOD_TURN_LIVE herdr jq claude

# shellcheck source=tests/herdr-claude-state-mod-fixture.sh
. "$ROOT/tests/herdr-claude-state-mod-fixture.sh" herdr-claude-state-turn

launch_claude
wait_for_composer
wait_reported 'idle/empty' "an idle session at start"

verdict=$(fm_backend_herdr_send_text_submit "$TARGET" 'Run this exact bash command in the foreground: sleep 6   Then reply with the single word DONE.' 3 0.4 0.4) \
  || fail "the adapter could not submit to Claude Code ($CLAUDE_VER) on $HERDR_VER"
[ "$verdict" = empty ] || fail "Claude Code $CLAUDE_VER on $HERDR_VER: a landed submit confirmed '$verdict', not empty"
wait_reported 'working/*' "the submitted turn as working"
[ "$(fm_backend_herdr_agent_status_raw "$SESSION" "$PANE")" = working ] \
  || fail "Claude Code $CLAUDE_VER on $HERDR_VER: the adapter did not read the mod's working state mid-turn"
wait_reported 'idle/empty' "the finished turn as idle" 240
verdict=$(fm_backend_herdr_composer_state "$TARGET")
[ "$verdict" = empty ] || fail "Claude Code $CLAUDE_VER on $HERDR_VER: the composer after a turn read '$verdict', not empty"
pass "Claude Code $CLAUDE_VER on $HERDR_VER: a submitted turn confirms, reads working, then idle with an empty composer"

fm_backend_herdr_send_text_submit "$TARGET" 'Use the AskUserQuestion tool to ask me one question: red or blue. Do nothing else.' 3 0.4 0.4 >/dev/null \
  || fail "the adapter could not submit the question prompt"
wait_reported 'blocked/dialog' "a question waiting on the person as blocked, its dialog holding the keys" 240
verdict=$(fm_backend_herdr_composer_state "$TARGET")
[ "$verdict" != empty ] || fail "Claude Code $CLAUDE_VER on $HERDR_VER: the composer under a question dialog read empty"
lab pane send-keys "$PANE" esc >/dev/null || fail "could not dismiss the question"
wait_reported 'idle/empty' "the dismissed question as idle" 120
pass "Claude Code $CLAUDE_VER on $HERDR_VER: a question reads blocked, its dialog never reads as an empty composer, and dismissing it returns to idle"

fm_backend_herdr_send_text_submit "$TARGET" 'Run this exact bash command in the foreground, never in the background: sleep 40' 3 0.4 0.4 >/dev/null \
  || fail "the adapter could not submit the long turn"
wait_reported 'working/*' "the long turn as working" 120
sleep 3
lab pane send-keys "$PANE" esc >/dev/null || fail "could not interrupt the turn"
wait_reported 'idle/*' "the interrupted turn as idle" 60
pass "Claude Code $CLAUDE_VER on $HERDR_VER: an interrupted turn returns to idle"

lab pane send-keys "$PANE" ctrl+e ctrl+u >/dev/null || true
exit_claude_and_check_cleared
pass "Claude Code $CLAUDE_VER on $HERDR_VER: the mod clears its tokens when the session ends"
