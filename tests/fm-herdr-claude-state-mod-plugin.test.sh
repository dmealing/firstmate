#!/usr/bin/env bash
# The firstmate-herdr-state Claude Code mod (.claude/mods/firstmate-herdr-state)
# under the real installed Claude Code: `claude plugin validate --strict` reading
# the module the way the engine will, then the mod's own `claude plugin test`
# suite, which runs its hooks in the engine's host against a mocked clock,
# environment, settings, prompt box, and recording herdr. No model turn is
# submitted, so the guard runs by default wherever `claude` is installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_HERDR_CLAUDE_STATE_MOD_PLUGIN_TEST claude

MOD="$ROOT/.claude/mods/firstmate-herdr-state"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
TMP_ROOT=$(fm_test_tmproot fm-herdr-claude-state-mod-plugin)

test_validate_strict() {
  local report
  if ! report=$(claude plugin validate --strict "$MOD" 2>&1); then
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION refused the herdr state mod under strict validation"
  fi
  # The engine's own reading of the module: the environment it may read and the
  # capabilities it uses. Anything more is a drift.
  case "$report" in
    *"env reads: HERDR_BIN_PATH, HERDR_ENV, HERDR_PANE_ID, HERDR_SOCKET_PATH"*) ;;
    *) printf '%s\n' "$report" >&2; fail "Claude Code $CLAUDE_VERSION: the herdr state mod reads a different environment" ;;
  esac
  case "$report" in
    *"env writes: nothing"*) ;;
    *) printf '%s\n' "$report" >&2; fail "Claude Code $CLAUDE_VERSION: the herdr state mod writes the environment" ;;
  esac
  case "$report" in
    *"http.fetch"*|*"fs.write"*|*"prompt.submit (via"*|*"tool.register"*|*"command.register"*)
      printf '%s\n' "$report" >&2
      fail "Claude Code $CLAUDE_VERSION scanned a capability the herdr state mod must not use"
      ;;
  esac
  pass "Claude Code $CLAUDE_VERSION validates the herdr state mod strictly, reading only the herdr pane environment"
}

test_plugin_suites() {
  local report
  if ! report=$(cd "$TMP_ROOT" && claude plugin test "$MOD" 2>&1); then
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION failed the herdr state mod's plugin test suites"
  fi
  printf '%s\n' "$report" | grep -Eq '^ *[1-9][0-9]* pass$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION ran no herdr state mod plugin test"
  }
  printf '%s\n' "$report" | grep -Eq '^ *0 fail$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION reported herdr state mod plugin test failures"
  }
  pass "Claude Code $CLAUDE_VERSION runs the herdr state mod's plugin suites clean: activation, agent and composer states, freshness, lifecycle authority, and herdr failures"
}

test_validate_strict
test_plugin_suites
