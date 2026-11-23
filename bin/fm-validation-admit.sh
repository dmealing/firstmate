#!/usr/bin/env bash
# fm-validation-admit.sh - say whether this host has the headroom to start a
# new no-mistakes validation run now, optionally waiting until it does.
#
# Usage:
#   fm-validation-admit.sh [--wait <seconds>] [--interval <seconds>]
#
# A worker runs it immediately before the `no-mistakes axi run` that starts a
# NEW run (never before reattaching to a run that already exists), as its
# generated instructions say. It is not a queue and keeps no shared record:
# every worker judges the host on its own, so concurrent starts stagger only
# because each one waits for headroom it can see. A deferral is advice with a
# bounded wait, never a stop: the worker starts its run once this returns,
# whatever the verdict, so a host that stays busy delays a start but never
# strands it.
#
# Headroom is this host's own probes (bin/fm-host-probe-lib.sh):
#   load    the 1-minute load average is at or over cores * max-load-per-core
#   memory  available memory is under min-mem-free-pct percent of total
#           (off by default)
# A probe that cannot be read is not judged, so an unprobeable host admits.
#
# Optional, gitignored config/validation-admission (docs/configuration.md
# "Validation admission" owns the format) sets the two thresholds as
# `max-load-per-core <decimal>` (default 1.0) and `min-mem-free-pct <0-100>`
# (default 0, which never defers: a host that runs with little free memory by
# design would otherwise never admit), one key and value per line, each key at
# most once; blank lines and # comments are ignored. A malformed file names
# its line on stderr and exits 1 without judging.
#
# Without --wait it judges once. With --wait it first sleeps a random 0 to
# interval/2 seconds, so workers that finished together do not all sample the
# same moment, then judges; while deferred it sleeps interval plus a random 0
# to interval/2 seconds (at least 1) and judges again, until it admits or the
# summed sleep reaches the wait. --interval defaults to 60 and may be 0.
#
# Output: one line on stdout, in this fixed order:
#   validation-admit: <admit|defer> reason=<ok|load|memory|load,memory>
#     load1=<X|unknown> cores=<N|unknown> max_load1=<X|unknown>
#     mem_free_pct=<N|unknown> min_mem_free_pct=<N> waited_s=<N>
# (one physical line).
#
# Environment: FM_HOME and FM_CONFIG_OVERRIDE resolve the config directory as
# the other bin/ scripts do.
#
# Exit status: 0 admit, 75 defer (still deferred when --wait ran out), 1 an
# invalid config/validation-admission, 2 a usage error.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-host-probe-lib.sh
. "$SCRIPT_DIR/fm-host-probe-lib.sh"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ADMISSION_CONFIG="$CONFIG/validation-admission"

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

max_per_core=1.0
min_mem_pct=0
if [ -e "$ADMISSION_CONFIG" ]; then
  n=0 seen=' '
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line=${line%%#*}
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    [ "$#" -gt 0 ] || continue
    key=$1 val=${2:-}
    if [ "$#" -ne 2 ]; then
      echo "fm-validation-admit: config/validation-admission line $n: expected one key and one value" >&2; exit 1
    fi
    case "$seen" in *" $key "*) echo "fm-validation-admit: config/validation-admission line $n: '$key' repeats" >&2; exit 1 ;; esac
    seen="$seen$key "
    case "$key" in
      max-load-per-core)
        case "$val" in
          ''|*[!0-9.]*|*.*.*|.*|*.) echo "fm-validation-admit: config/validation-admission line $n: max-load-per-core must be a positive decimal" >&2; exit 1 ;;
        esac
        awk -v v="$val" 'BEGIN{exit !(v > 0)}' || { echo "fm-validation-admit: config/validation-admission line $n: max-load-per-core must be a positive decimal" >&2; exit 1; }
        max_per_core=$val ;;
      min-mem-free-pct)
        if ! fm_host_probe_uint "$val" || [ "$val" -gt 100 ]; then
          echo "fm-validation-admit: config/validation-admission line $n: min-mem-free-pct must be a whole number from 0 to 100" >&2; exit 1
        fi
        min_mem_pct=$val ;;
      *) echo "fm-validation-admit: config/validation-admission line $n: unknown key '$key'" >&2; exit 1 ;;
    esac
  done < "$ADMISSION_CONFIG"
fi

# judge: sets verdict, reason, max_load1 from a fresh probe.
judge() {
  local reasons=
  load1='' cores='' mem_free_pct=''
  fm_host_probe
  max_load1=unknown
  if [ "$cores" != unknown ]; then
    max_load1=$(awk -v c="$cores" -v r="$max_per_core" 'BEGIN{printf "%.2f", c * r}')
    if [ "$load1" != unknown ] && awk -v a="$load1" -v b="$max_load1" 'BEGIN{exit !(a >= b)}'; then
      reasons=load
    fi
  fi
  if [ "$mem_free_pct" != unknown ] && [ "$mem_free_pct" -lt "$min_mem_pct" ]; then
    reasons=${reasons:+$reasons,}memory
  fi
  if [ -n "$reasons" ]; then verdict=defer reason=$reasons; else verdict=admit reason=ok; fi
}

# nap <base>: sleep base plus a random 0..interval/2 seconds, adding it to waited.
nap() {
  local s=$(( $1 + (interval > 1 ? RANDOM % (interval / 2 + 1) : 0) ))
  [ -n "$wait_s" ] && [ $((waited + s)) -gt "$wait_s" ] && s=$((wait_s - waited))
  [ "$s" -gt 0 ] && sleep "$s"
  waited=$((waited + s))
}

waited=0
[ -z "$wait_s" ] || nap 0
judge
while [ "$verdict" = defer ] && [ -n "$wait_s" ] && [ "$waited" -lt "$wait_s" ]; do
  nap "$(( interval > 0 ? interval : 1 ))"
  judge
done

printf 'validation-admit: %s reason=%s load1=%s cores=%s max_load1=%s mem_free_pct=%s min_mem_free_pct=%s waited_s=%s\n' \
  "$verdict" "$reason" "$load1" "$cores" "$max_load1" "$mem_free_pct" "$min_mem_pct" "$waited"
[ "$verdict" = admit ] || exit 75
exit 0
