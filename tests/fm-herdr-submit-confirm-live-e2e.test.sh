#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. A stub cannot prove
# either signal. This guard launches real Claude Code in an isolated Herdr lab
# and requires fm_backend_herdr_send_text_submit to report empty for a landed
# idle steer. It then requires the same submit path to prove and submit a
# typed /exit slash command behind the command popup Claude renders below the
# composer (the fm-control exit breakage on 2.1.283) and verifies the agent
# actually exited. It fails naming the harness and version rather than
# degrading quietly.
#
# A second pane launches Claude the way fm-spawn names a worker
# (`--name 'worker · <id>'`, whose title Claude draws into the composer's top
# rule) without the state mod, so the screen-read composer path is what is
# proven: an idle composer reads empty, a typed draft reads pending, and
# fm-control.sh's exit sequence (composer proof, then `/exit` through the
# slash-command list) stops the agent.
#
# A third pane launches Claude the way fm-spawn launches a second mate
# (`--name '2nd mate · <id>'` with Remote Control at startup) and requires the
# submit path to prove and submit a steer that wraps onto a second composer row
# under that titled rule, then a typed /exit whose slash-command menu marks its
# selected entry with the agent glyph (Claude Code 2.1.296 and later).
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr submit confirmation" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-submit-confirm-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-submit-confirm-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive --no-focus) \
  || fail "could not create the isolated submit-confirm workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

wait_lab_idle() {  # <pane> <label> - poll up to 45s until the lab registers an idle agent
  local pane=$1 label=$2 st idle=0 i=0
  while [ "$i" -lt 45 ]; do
    st=$(lab agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$st" in idle|done|blocked) idle=1; break ;; esac
    i=$((i + 1))
    sleep 1
  done
  [ "$idle" = 1 ] || fail "$label ($VERSION) on $HERDR_VER never registered an idle agent in the lab pane"
}

lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
trusted=0
i=0
while [ "$i" -lt 60 ]; do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in
    *'bypass permissions on'*)
      # The composer footer means Claude is past any folder-trust prompt. Herdr
      # can report the agent idle while that prompt is still up, so the wait
      # keys off the rendered composer rather than the native status alone.
      st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
      case "$st" in idle|done) idle=1; break ;; esac
      ;;
    *'Yes, I trust this folder'*)
      # A fresh checkout path stops on Claude's folder-trust prompt, which the
      # pre-send proof would read as a non-empty composer. Accept it once and
      # keep waiting for a real idle composer; the accepted dialog stays in the
      # viewport. The prompt preselects "No, exit", so move to "Yes" before
      # confirming; a bare Enter quits Claude.
      if [ "$trusted" = 0 ]; then
        trusted=1
        lab pane send-keys "$PANE" down enter >/dev/null \
          || fail "could not accept Claude's folder-trust prompt"
      fi
      ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never rendered an idle composer in the lab pane"

TOKEN="FMHERDRPONG$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.4 0.4) \
  || fail "send_text_submit failed to run against Claude Code ($VERSION) on $HERDR_VER"
CHECKED=1
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed idle steer must confirm empty, got '$verdict'"

# Confirm the instruction reached Claude, not merely that the composer cleared.
# The token occurs once in the submitted prompt and once in Claude's reply.
landed=0
i=0
screen=''
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER reports empty and renders the requested reply in isolated session $SESSION"

# Away-mode digests start with U+2063, which Claude's composer read-back drops.
# The pre-Enter proof must still accept the rest of the payload.
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; esac
  i=$((i + 1))
  sleep 1
done
OP_TOKEN="FMHERDROPPONG$$_$RANDOM"
op_text=
fm_operational_input_encode away-supervisor "Reply with exactly $OP_TOKEN and nothing else." op_text \
  || fail "could not encode an away-supervisor payload"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$op_text" 3 0.4 0.4) \
  || fail "send_text_submit failed to run an operational payload against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed U+2063 operational payload must confirm empty, got '$verdict'"
landed=0
i=0
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$OP_TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: operational submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER submits a U+2063 away-supervisor payload whose read-back drops the mark"

# The fm-control exit regression: a typed slash command (/exit) makes Claude
# Code 2.1.283 render its command popup between the composer and the pane
# bottom, which pushed the composer above the old bounded proof read - the
# typed command was judged unsent, cleared, and never submitted. The viewport
# capture must prove the typed /exit and submit it; Claude must actually
# exit. This scenario runs last because it ends the lab's Claude process.
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; esac
  i=$((i + 1))
  sleep 1
done
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" '/exit' 3 0.4 1.2) \
  || fail "send_text_submit failed to run the /exit submission against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" != send-failed ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a typed /exit behind its command popup was judged unsent and cleared instead of submitted"
exited=0
i=0
while [ "$i" -lt 30 ]; do
  if ! lab agent get "$PANE" >/dev/null 2>&1; then exited=1; break; fi
  i=$((i + 1))
  sleep 1
done
[ "$exited" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the /exit submission reported '$verdict' but the agent never exited"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER proves and submits a typed /exit behind its command popup"

# The fleet launch shape, with the state mod deliberately absent: the screen
# read is the fallback whenever a mod report is stale or missing.
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-exitlive --no-focus) \
  || fail "could not create the isolated exit workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id for the exit pane"
TARGET="$SESSION:$PANE"
lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}' --name 'worker · fm-exitlive-$$'" >/dev/null \
  || fail "could not launch a named Claude Code ($VERSION) in the isolated Herdr pane"
wait_lab_idle "$PANE" "named Claude Code"

composer_reaches() {  # <want> - poll the screen-read verdict until it settles; leaves the last read in $state
  local want=$1 n=0
  state=''
  while [ "$n" -lt 20 ]; do
    state=$(fm_backend_herdr_composer_state "$TARGET")
    [ "$state" = "$want" ] && return 0
    n=$((n + 1))
    sleep 0.5
  done
  return 1
}
composer_reaches empty \
  || fail "named Claude Code ($VERSION) on $HERDR_VER: an idle composer under its titled rule must read empty, got '$state'"
lab pane send-text "$PANE" "an unsent draft" >/dev/null || fail "could not type the draft"
composer_reaches pending \
  || fail "named Claude Code ($VERSION) on $HERDR_VER: a typed draft under its titled rule must read pending, got '$state'"
lab pane send-keys "$PANE" ctrl+u >/dev/null || fail "could not clear the draft"
composer_reaches empty \
  || fail "named Claude Code ($VERSION) on $HERDR_VER: a cleared composer must read empty again, got '$state'"
pass "live Herdr composer: named Claude Code ($VERSION) on $HERDR_VER reads idle as empty and a draft as pending"

# fm-control.sh's exit sequence: submit /exit with its Enter retries, then the
# agent must stop. The verdict itself is not asserted, because Claude may exit
# before the composer can be re-read.
fm_backend_herdr_send_text_submit "$TARGET" "/exit" 3 0.5 1.2 >/dev/null \
  || fail "named Claude Code ($VERSION) on $HERDR_VER: send_text_submit could not deliver /exit"
st=''
i=0
while [ "$i" -lt 30 ]; do
  st=$(fm_backend_herdr_agent_state "$TARGET")
  [ "$st" = dead ] && break
  i=$((i + 1))
  sleep 1
done
[ "$st" = dead ] \
  || fail "named Claude Code ($VERSION) on $HERDR_VER: the agent did not stop within 30s of /exit (agent state '$st')"
pass "live Herdr exit: named Claude Code ($VERSION) on $HERDR_VER stops after fm-control's /exit sequence"

# The second-mate launch shape. Firstmate task variables are dropped so the lab
# agent can never be pointed at an operator's real steering inbox.
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-smlive --no-focus) \
  || fail "could not create the isolated second-mate workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id for the second-mate pane"
TARGET="$SESSION:$PANE"
lab pane run "$PANE" "env -u FM_TASK_ID -u FM_TASK_INBOX -u FM_HOME CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"remoteControlAtStartup\":true}' --name '2nd mate · fm-smlive-$$'" >/dev/null \
  || fail "could not launch a second-mate-shaped Claude Code ($VERSION) in the isolated Herdr pane"
wait_lab_idle "$PANE" "second-mate Claude Code"
composer_reaches empty \
  || fail "second-mate Claude Code ($VERSION) on $HERDR_VER: an idle composer under its titled rule must read empty, got '$state'"

# The steer must really wrap, or this check proves nothing about wrapping.
SM_TOKEN="FMHERDRSMPONG$$_$RANDOM"
SM_END="FMHERDRSMEND$$"
long="Reply with exactly $SM_TOKEN and nothing else. This request is padded on purpose so that it wraps onto a second composer row under the titled rule of a named second-mate session. $SM_END"
lab pane send-text "$PANE" "$long" >/dev/null || fail "could not type the wrapping steer"
sleep 1
screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
first_row=$(printf '%s\n' "$screen" | grep -n -F "$SM_TOKEN" | tail -1 | cut -d: -f1)
end_row=$(printf '%s\n' "$screen" | grep -n -F "$SM_END" | tail -1 | cut -d: -f1)
[ -n "$first_row" ] && [ -n "$end_row" ] && [ "$end_row" -gt "$first_row" ] \
  || fail "second-mate Claude Code ($VERSION) on $HERDR_VER: the padded steer did not wrap onto a second composer row (rows '$first_row' and '$end_row')"
# Claude deletes one wrapped row per Ctrl+U, so this is the adapter's verified
# multi-press clear, the same one a refused payload proof runs.
fm_backend_herdr_composer_clear "$TARGET" "$long" \
  || fail "second-mate Claude Code ($VERSION) on $HERDR_VER: the wrapped steer never cleared back to an empty composer (last read '$(fm_backend_herdr_composer_state "$TARGET")')"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$long" 3 0.4 0.4) \
  || fail "send_text_submit failed to run the wrapping steer against second-mate Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "second-mate Claude Code ($VERSION) on $HERDR_VER: a steer wrapped under the titled rule must confirm empty, got '$verdict'"
landed=0
i=0
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$SM_TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "second-mate Claude Code ($VERSION) on $HERDR_VER: the wrapped steer reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: second-mate Claude Code ($VERSION) on $HERDR_VER proves and submits a steer wrapped under its titled rule"

wait_lab_idle "$PANE" "second-mate Claude Code"
composer_reaches empty \
  || fail "second-mate Claude Code ($VERSION) on $HERDR_VER: the composer did not settle empty after the reply, got '$state'"
lab pane send-text "$PANE" "/exit" >/dev/null || fail "could not type /exit to inspect the slash-command menu"
sleep 1
screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
menu_pick=no
if printf '%s\n' "$screen" | grep -E -q '^[[:space:]]+❯ /exit[[:space:]]'; then
  menu_pick=yes
fi
lab pane send-keys "$PANE" ctrl+u >/dev/null || fail "could not clear the inspected /exit"
composer_reaches empty \
  || fail "second-mate Claude Code ($VERSION) on $HERDR_VER: a cleared /exit must read empty again, got '$state'"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" '/exit' 3 0.5 1.2) \
  || fail "send_text_submit failed to run /exit against second-mate Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" != send-failed ] \
  || fail "second-mate Claude Code ($VERSION) on $HERDR_VER: a typed /exit above its slash-command menu (menu pick rendered: $menu_pick) was judged unsent and cleared"
st=''
i=0
while [ "$i" -lt 30 ]; do
  st=$(fm_backend_herdr_agent_state "$TARGET")
  [ "$st" = dead ] && break
  i=$((i + 1))
  sleep 1
done
[ "$st" = dead ] \
  || fail "second-mate Claude Code ($VERSION) on $HERDR_VER: the agent did not stop within 30s of /exit (agent state '$st')"
pass "live Herdr exit: second-mate Claude Code ($VERSION) on $HERDR_VER stops after /exit (slash-menu pick rendered: $menu_pick)"

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"
