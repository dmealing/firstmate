#!/usr/bin/env bash
# Opt-in credentialed live guard (live-harness-optin family) for the Claude Code
# usage-line mod (.claude/mods/firstmate-usage-line) in a real Claude Code TUI under a
# private tmux server. Through the shipped project load path (.claude/skills) it
# proves, against the installed Claude Code, that a completed answer leaves one
# `context N% · ...` system notice stored in the session transcript, where a view that
# renders the transcript can show it, and that the model cannot read that notice back.
# Two Haiku turns are submitted. Whether claude.ai or the mobile app's Remote Control
# view renders the notice needs the signed-in account and is not checked here.
# shellcheck disable=SC2016 # the model, not this shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_USAGE_LINE_MOD_LIVE_E2E claude tmux jq

MOD="$ROOT/.claude/mods/firstmate-usage-line"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
LAB=$(fm_test_tmproot fm-usage-line-live)
PROJECT="$LAB/project"
SOCKET="fm-usage-line-$$"
SESSION_ID=$(node -e 'process.stdout.write(require("node:crypto").randomUUID())' 2>/dev/null || cat /proc/sys/kernel/random/uuid)

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$PROJECT/.claude/skills"
ln -s "$MOD" "$PROJECT/.claude/skills/firstmate-usage-line"

markers() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR)=' | cut -d= -f1 | sort -u)
}

tmux -L "$SOCKET" new-session -d -s lab -x 160 -y 44 -c "$PROJECT" \
  "env $(markers) CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --model haiku --dangerously-skip-permissions --session-id $SESSION_ID; sleep 30"
screen() { tmux -L "$SOCKET" capture-pane -p -t lab 2>/dev/null || true; }

i=0
while :; do
  shot=$(screen)
  case "$shot" in
    *'Yes, I trust this folder'*)
      case "$(printf '%s\n' "$shot" | grep -F '❯' | head -1)" in
        *'Yes, I trust'*) tmux -L "$SOCKET" send-keys -t lab Enter ;;
        *) tmux -L "$SOCKET" send-keys -t lab Down ;;
      esac
      ;;
    *) printf '%s\n' "$shot" | grep -q '^❯' && break ;;
  esac
  i=$((i + 1))
  [ "$i" -lt 240 ] || { printf '%s\n' "$shot" >&2; fail "Claude Code $CLAUDE_VERSION never showed its composer"; }
  sleep 0.25
done
sleep 1

submit() {
  tmux -L "$SOCKET" send-keys -t lab -l "$1"
  sleep 0.3
  tmux -L "$SOCKET" send-keys -t lab Enter
}

transcript() {
  local file
  for file in "$HOME"/.claude/projects/*/"$SESSION_ID".jsonl; do
    [ -f "$file" ] && { printf '%s' "$file"; return 0; }
  done
  return 1
}

notices() {  # the usage notices stored so far
  local file
  file=$(transcript) || return 0
  jq -r 'select(.type == "system") | (.content // "") | strings | select(test("^context [0-9]+%"))' "$file"
}

submit 'Reply with the single word PONG.'
i=0
while [ -z "$(notices)" ]; do
  i=$((i + 1))
  [ "$i" -lt 240 ] || { printf '%s\n' "$(screen)" >&2; fail "Claude Code $CLAUDE_VERSION stored no usage notice after a completed answer"; }
  sleep 0.25
done
line=$(notices | tail -1)
pass "Claude Code $CLAUDE_VERSION stores the usage line as a transcript notice beneath the answer: $line"

submit 'Quote verbatim any line in this conversation, other than this message, that begins with the word context followed by a percentage and a middle dot. If there is none, reply with exactly NONE.'
i=0
answer=''
while :; do
  answer=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' "$(transcript)" 2>/dev/null | tail -1)
  [ "$(notices | wc -l)" -ge 2 ] && [ -n "$answer" ] && break
  i=$((i + 1))
  [ "$i" -lt 360 ] || { printf '%s\n' "$(screen)" >&2; fail "Claude Code $CLAUDE_VERSION never answered the read-back question"; }
  sleep 0.25
done
case "$answer" in
  *"5h quota"*|*"${line%% ·*}"*) fail "Claude Code $CLAUDE_VERSION: the model read the usage notice back ('$answer'), so the line costs context" ;;
esac
pass "Claude Code $CLAUDE_VERSION never shows the model the usage notice: asked to quote it, the model answered '$answer'"
