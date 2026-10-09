#!/usr/bin/env bash
# shellcheck shell=bash
# Quota circuit breaker for Stop-hook supervision wakes.
#
# WHY THIS EXISTS: on 2026-10-09 a firstmate fleet kept translating watcher
# wakes into Claude turns while the plan behind those turns was already
# exhausted, feeding a fresh Pro five-hour window to ~20 sessions at ~8M
# tokens/minute until every limit fired (docs: the wake stayed "actionable"
# straight through `[Usage limit reached]` injections). The breaker is the
# missing backpressure: while the configured quota provider's effective
# availability sits at or below the floor, the wake translation steps aside.
# Durable wakes are NOT consumed - fm-wake-lib.sh keeps them pending, so the
# next Stop after the quota window resets re-arms and re-surfaces them intact.
#
# FAILS CLOSED. Every error path - quota-axi missing, jq missing, unreadable
# output, unknown provider, parse failure - reports the breaker CLOSED (wake
# allowed), because supervision continuity outranks the breaker; the breaker
# only ever suppresses a wake it can positively prove is unpayable.
#
# Usage (library only; sourced by bin/fm-claude-stop-autoarm.sh and
# bin/fm-turnend-guard.sh):
#   fm_quota_breaker_open            exit 0 = OPEN (suppress the wake
#                                   translation), exit 1 = CLOSED (allow it)
#   fm_quota_breaker_detail          one-line decision detail, set by the call
#   fm_quota_breaker_mark <state>    touch the state/.quota-breaker marker
#   fm_quota_breaker_unmark <state>  remove the marker
#
# Configuration, per home (env, or config/quota-breaker.env sourced by the
# caller's CONFIG convention):
#   FM_QUOTA_BREAKER=off             disable the breaker entirely (default on)
#   FM_QUOTA_BREAKER_PROVIDER=<id>   quota-axi provider id (default claude)
#   FM_QUOTA_BREAKER_FLOOR=<pct>     effective percent-remaining floor
#                                   (default 2)
#   FM_QUOTA_BREAKER_MAX_AGE=<dur>   quota-axi --max-age cache bound
#                                   (default 5m), so a fleet of homes shares
#                                   one vendor read per bound instead of one
#                                   read per Stop
# A per-home config/quota-breaker.env is read only when CONFIG names a real
# directory at call time, mirroring the config/x-mode.env convention.

# shellcheck source=bin/fm-quota-axi-lib.sh
# fm-quota-axi-lib.sh is NOT sourced here: this lib needs no version floor and
# must stay loadable in fixtures where quota-axi itself is stubbed out.

FM_QUOTA_BREAKER_MARKER='.quota-breaker'

fm_quota_breaker_config() {
  [ -n "${CONFIG:-}" ] && [ -f "$CONFIG/quota-breaker.env" ] && . "$CONFIG/quota-breaker.env" || true
}

fm_quota_breaker_open() {
  FM_QUOTA_BREAKER_DETAIL=
  fm_quota_breaker_config
  [ "${FM_QUOTA_BREAKER:-on}" = off ] && return 1
  command -v quota-axi >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local provider floor max_age out verdict
  provider=${FM_QUOTA_BREAKER_PROVIDER:-claude}
  floor=${FM_QUOTA_BREAKER_FLOOR:-2}
  max_age=${FM_QUOTA_BREAKER_MAX_AGE:-5m}
  case "$floor" in
    ''|*[!0-9]*|*.*)
      # A non-integer floor is a configuration error: fail closed, not loud.
      return 1
      ;;
  esac

  if [ "$(type -t fm_run_timed)" = function ]; then
    out=$(fm_run_timed 30 quota-axi --provider "$provider" --json \
      --max-age "$max_age" --no-credential-refresh </dev/null 2>/dev/null) || return 1
  else
    out=$(quota-axi --provider "$provider" --json \
      --max-age "$max_age" --no-credential-refresh </dev/null 2>/dev/null) || return 1
  fi

  # OPEN only when the provider is present AND the tightest of its published
  # remaining percentages - the per-window rows and the effective
  # availability rows quota-axi joins across them - is at or below the floor.
  # An absent provider, an empty join, or any jq failure stays CLOSED.
  verdict=$(printf '%s' "$out" | jq -r --arg p "$provider" --argjson floor "$floor" '
    [ .providers[]? | select(.provider == $p) ] as $rows
    | if ($rows | length) == 0 then
        "closed"
      else
        ( [ $rows[].windows[]?.percentRemaining ]
          + [ $rows[].quotaSemantics.effectiveAvailability[]?.effectivePercentRemaining ]
          | if length == 0 then
              "closed"
            else
              (min | numbers // 100) as $m
              | if $m <= $floor then "open" else "closed" end
            end
        )
      end' 2>/dev/null) || return 1

  case "$verdict" in
    open)
      FM_QUOTA_BREAKER_DETAIL="quota breaker open: $provider effective availability at or below ${floor}%"
      return 0
      ;;
    closed|*)
      # shellcheck disable=SC2034  # consumed by the sourcing guard/hook, not this lib
      FM_QUOTA_BREAKER_DETAIL="quota breaker closed: $provider availability above ${floor}% (or unmeasurable)"
      return 1
      ;;
  esac
}

fm_quota_breaker_mark() {  # <state-dir>
  [ -d "${1:-}" ] || return 0
  printf 'suppressed at=%s\n' "$(date +%s)" >>"$1/$FM_QUOTA_BREAKER_MARKER" 2>/dev/null || true
  # Keep the marker bounded: it is observability, not a log.
  tail -n 20 "$1/$FM_QUOTA_BREAKER_MARKER" >"$1/.quota-breaker.tmp" 2>/dev/null \
    && mv -f "$1/.quota-breaker.tmp" "$1/$FM_QUOTA_BREAKER_MARKER" 2>/dev/null || true
}

fm_quota_breaker_unmark() {  # <state-dir>
  [ -n "${1:-}" ] || return 0
  rm -f -- "$1/$FM_QUOTA_BREAKER_MARKER" "$1/.quota-breaker.tmp" 2>/dev/null || true
}
