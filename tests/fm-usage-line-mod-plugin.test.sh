#!/usr/bin/env bash
# The firstmate-usage-line Claude Code mod (.claude/mods/firstmate-usage-line) under the
# real installed Claude Code: `claude plugin validate --strict` reading the module the
# way the engine will, then the mod's own `claude plugin test` suite. No model turn is
# submitted, so the guard runs by default wherever `claude` is installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_USAGE_LINE_MOD_PLUGIN_TEST claude

MOD="$ROOT/.claude/mods/firstmate-usage-line"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
TMP_ROOT=$(fm_test_tmproot fm-usage-line-mod-plugin)

test_validate_strict() {
  local report
  if ! report=$(claude plugin validate --strict "$MOD" 2>&1); then
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION refused the usage-line mod under strict validation"
  fi
  # The engine's own reading of the module: it hooks only the turn's completion and
  # calls only the free usage read and the notice append, so no model call, network,
  # environment, or new turn.
  case "$report" in
    *"hooks: turn.complete"*"calls: \$.session.append, \$.session.usage"*) ;;
    *) printf '%s\n' "$report" >&2; fail "Claude Code $CLAUDE_VERSION: the usage-line mod hooks or calls more than the turn's completion, the usage read, and the append" ;;
  esac
  pass "Claude Code $CLAUDE_VERSION validates the usage-line mod strictly: it hooks only the turn completion and calls only the usage read and the notice append"
}

test_plugin_suites() {
  local report
  if ! report=$(cd "$TMP_ROOT" && claude plugin test "$MOD" 2>&1); then
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION failed the usage-line mod's plugin test suites"
  fi
  printf '%s\n' "$report" | grep -Eq '^ *[1-9][0-9]* pass$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION ran no usage-line mod plugin test"
  }
  printf '%s\n' "$report" | grep -Eq '^ *0 fail$' || {
    printf '%s\n' "$report" >&2
    fail "Claude Code $CLAUDE_VERSION reported usage-line mod plugin test failures"
  }
  pass "Claude Code $CLAUDE_VERSION runs the usage-line mod's plugin suites clean: the usage read, subagent turns, failures, and the line text"
}

test_validate_strict
test_plugin_suites
