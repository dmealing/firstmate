#!/usr/bin/env bash
# Shared fixture for the live firstmate-herdr-state guards: an isolated Herdr lab
# session (bin/fm-herdr-lab.sh owns isolation and teardown), a `herdr` wrapper that
# routes the adapter's own calls through that lab, and the real installed Claude
# Code launched in a lab pane the way bin/fm-spawn.sh launches it, with the mod
# loaded through --plugin-dir. The mod's own reports run inside the lab pane and
# reach only that pane's server socket. The caller has sourced tests/lib.sh and
# opened its fm_live_gate; this file only provides the world.
set -u

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

STATE_MOD="$ROOT/.claude/mods/firstmate-herdr-state"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
[ -x "$LAB_HELPER" ] || fail "the Herdr lab helper is not executable at $LAB_HELPER"
ORIGINAL_PATH=$PATH
CLAUDE_VER=$(claude --version 2>/dev/null | head -1)
HERDR_VER=$(herdr --version 2>/dev/null | head -1)
[ -n "$CLAUDE_VER" ] || fail "claude is installed but reports no version"
SESSION=$("$LAB_HELPER" name "$1")
LAB=$(fm_test_tmproot "$1")
FAKEBIN="$LAB/fakebin"
PROJECT="$LAB/project"
mkdir -p "$FAKEBIN" "$PROJECT"
printf '# Isolated Claude Code state mod lab\n' > "$PROJECT/AGENTS.md"

state_mod_cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || rc=1
  fm_test_cleanup
  exit "$rc"
}
trap state_mod_cleanup EXIT

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

WS_JSON=$(lab workspace create --cwd "$PROJECT" --label fm-statemod --no-focus) \
  || fail "could not create the lab workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') || fail "workspace create returned no pane id"
TARGET="$SESSION:$PANE"

# Claude Code refuses to nest inside another Claude session, so inherited session
# markers stay out of the lab pane.
unset_claude_markers() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR)=' | cut -d= -f1 | sort -u)
}

# launch_claude [extra env assignments...]: Claude Code as fm-spawn launches it, mod included.
launch_claude() {
  lab pane run "$PANE" "env $(unset_claude_markers) $* CLAUDE_CODE_SEND_FEEDBACK=0 claude --model haiku --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}' --plugin-dir '$STATE_MOD'" >/dev/null \
    || fail "could not launch Claude Code ($CLAUDE_VER) in the lab pane"
}

screen() { lab pane read "$PANE" --source visible 2>/dev/null || true; }

# The folder-trust dialog opens on "No, exit": move onto the trusting option first.
wait_for_composer() {
  local i=0 shot
  while [ "$i" -lt 240 ]; do
    shot=$(screen)
    case "$shot" in
      *'Yes, I trust this folder'*)
        case "$(printf '%s\n' "$shot" | grep -F '❯' | head -1)" in
          *'Yes, I trust'*) lab pane send-keys "$PANE" enter >/dev/null ;;
          *) lab pane send-keys "$PANE" down >/dev/null ;;
        esac
        ;;
      *)
        printf '%s\n' "$shot" | grep -q '^❯' && return 0
        ;;
    esac
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VER on $HERDR_VER never showed its composer in the lab pane"
}

# The mod's tokens on the pane as "<state>/<composer>", or nothing.
reported() {
  lab agent list 2>/dev/null | jq -r --arg p "$PANE" '
    .result.agents[]? | select(.pane_id == $p) | .tokens // {}
    | select(.fm_claude_state != null) | "\(.fm_claude_state)/\(.fm_claude_composer)"'
}

# wait_reported <pattern> <what> [iterations]: until the tokens match a shell pattern.
wait_reported() {
  local pattern=$1 what=$2 limit=${3:-80} i=0 now
  while [ "$i" -lt "$limit" ]; do
    now=$(reported)
    # shellcheck disable=SC2254 # the pattern is the caller's glob
    case "$now" in $pattern) return 0 ;; esac
    sleep 0.25
    i=$((i + 1))
  done
  fail "Claude Code $CLAUDE_VER on $HERDR_VER: the mod never reported $what (last report: '${now:-none}')"
}

# What the adapter would decide from the screen alone: no report is ever fresh.
screen_only_composer() {
  FM_HERDR_MOD_REPORT_MAX_AGE=-1 bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_composer_state "$1"' "$ROOT" "$TARGET"
}

exit_claude_and_check_cleared() {
  local verdict i=0 tokens
  verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "/exit" 3 0.4 1.2) || true
  : "$verdict"
  while [ "$i" -lt 60 ]; do
    tokens=$(lab pane get "$PANE" 2>/dev/null | jq -r '.result.pane.tokens // {} | keys | map(select(startswith("fm_claude_"))) | join(",")')
    [ -z "$tokens" ] && return 0
    sleep 0.25
    i=$((i + 1))
  done
  fail "Claude Code $CLAUDE_VER on $HERDR_VER: the mod's tokens ($tokens) outlived the session it reported"
}
