#!/usr/bin/env bash
# fm-validation-admit.sh - say whether this host has the headroom to start a
# new no-mistakes validation run now, optionally waiting until it does.
#
# Usage:
#   fm-validation-admit.sh [--wait <seconds>] [--interval <seconds>]
#
# A worker runs it immediately before the `no-mistakes axi run` that starts a
# NEW run (never before reattaching to a run that already exists), as its
# generated instructions say. It is not a run queue: it keeps no order, no
# waiting list, and no per-project or per-home state. A deferral is advice
# with a bounded wait, never a stop: the worker starts its run once this
# returns, whatever the verdict, so a host that stays busy delays a start but
# never strands it.
#
# Start spacing (with --wait only): the 1-minute load average lags a freshly
# started run by about a minute, so load alone cannot see a start that just
# happened. One machine-wide file holds the time of the latest reserved start
# slot, kept in ${FM_VALIDATION_START_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/validation-start}
# and read and updated only under the portable lock of bin/fm-wake-lib.sh. A
# run reserves the slot FM_VALIDATION_START_SPACING seconds (default 90) after
# the recorded one, clamped to the end of its own remaining wait, waits until
# it, then judges load. A missing, unreadable, or malformed file, or one dated
# past the end of the remaining wait, never blocks a run: it admits as if no
# run had started. When the lock cannot be taken within 5 seconds the run
# skips spacing and judges load at once.
#
# Headroom is this host's own 1-minute load average (bin/fm-host-probe-lib.sh):
# the run defers while it is at or over the logical core count. A probe that
# cannot be read is not judged, so an unprobeable host admits.
#
# Without --wait it judges once. With --wait it first sleeps a random 0 to
# interval/2 seconds, then waits out the start spacing, then judges; while
# deferred it sleeps interval plus a random 0 to interval/2 seconds (at least
# 1) and judges again, until it admits or the summed sleep reaches the wait.
# --interval defaults to 60 and may be 0.
#
# Output: one line on stdout:
#   validation-admit: <admit|defer> reason=<ok|load> load1=<X|unknown>
#     cores=<N|unknown> max_load1=<X|unknown> waited_s=<N>
# (one physical line).
#
# Environment: FM_VALIDATION_START_FILE and FM_VALIDATION_START_SPACING set the
# start-spacing file and window.
#
# Exit status: 0 admit, 75 defer (still deferred when --wait ran out), 2 a
# usage error.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-host-probe-lib.sh
. "$SCRIPT_DIR/fm-host-probe-lib.sh"

usage() { echo "usage: fm-validation-admit.sh [--wait <seconds>] [--interval <seconds>]" >&2; exit 2; }

wait_s=
interval=60
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    --wait) [ "$#" -ge 2 ] || usage; wait_s=$2; shift 2 ;;
    --interval) [ "$#" -ge 2 ] || usage; interval=$2; shift 2 ;;
    *) usage ;;
  esac
done
if [ -n "$wait_s" ]; then fm_host_probe_uint "$wait_s" || usage; fi
fm_host_probe_uint "$interval" || usage

# judge: sets verdict, reason, max_load1 from a fresh probe.
judge() {
  load1='' cores=''
  fm_host_probe
  max_load1=unknown verdict=admit reason=ok
  if [ "$cores" != unknown ]; then
    max_load1=$(awk -v c="$cores" 'BEGIN{printf "%.2f", c}')
    if [ "$load1" != unknown ] && awk -v a="$load1" -v b="$max_load1" 'BEGIN{exit !(a >= b)}'; then
      verdict=defer reason=load
    fi
  fi
}

# nap <base>: sleep base plus a random 0..interval/2 seconds, adding it to waited.
nap() {
  local s=$(( $1 + (interval > 1 ? RANDOM % (interval / 2 + 1) : 0) ))
  [ -n "$wait_s" ] && [ $((waited + s)) -gt "$wait_s" ] && s=$((wait_s - waited))
  [ "$s" -gt 0 ] && sleep "$s"
  waited=$((waited + s))
}

# space_start: under the start lock, reserve the next machine-wide start slot
# within the remaining wait, then sleep until it.
space_start() {
  local lock="$START_FILE.lock" now limit last='' slot
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh" >/dev/null 2>&1 || return 0
  fm_lock_acquire_wait_max "$lock" 5 2>/dev/null || return 0
  now=$(date +%s)
  limit=$((now + wait_s - waited))
  [ ! -f "$START_FILE" ] || { IFS= read -r last < "$START_FILE"; } 2>/dev/null || last=
  fm_host_probe_uint "$last" && [ "$last" -le "$limit" ] || last=0
  slot=$((last + spacing))
  [ "$slot" -gt "$now" ] || slot=$now
  [ "$slot" -le "$limit" ] || slot=$limit
  printf '%s\n' "$slot" 2>/dev/null > "$START_FILE"
  fm_lock_release "$lock" 2>/dev/null
  [ "$slot" -gt "$now" ] || return 0
  sleep $((slot - now))
  waited=$((waited + slot - now))
}

START_FILE="${FM_VALIDATION_START_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/validation-start}"
spacing=${FM_VALIDATION_START_SPACING:-90}
fm_host_probe_uint "$spacing" || spacing=90

waited=0
if [ -n "$wait_s" ]; then
  nap 0
  mkdir -p "$(dirname "$START_FILE")" 2>/dev/null && space_start
fi
judge
while [ "$verdict" = defer ] && [ -n "$wait_s" ] && [ "$waited" -lt "$wait_s" ]; do
  nap "$(( interval > 0 ? interval : 1 ))"
  judge
done

printf 'validation-admit: %s reason=%s load1=%s cores=%s max_load1=%s waited_s=%s\n' \
  "$verdict" "$reason" "$load1" "$cores" "$max_load1" "$waited"
[ "$verdict" = admit ] || exit 75
exit 0
