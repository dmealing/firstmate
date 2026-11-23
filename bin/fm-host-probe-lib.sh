#!/usr/bin/env bash
# fm-host-probe-lib.sh - this host's own load, core, and memory probes.
#
# The one owner of the host probes that bin/fm-capacity.sh (queued-work
# dispatch headroom) and bin/fm-validation-admit.sh (validation-start
# headroom) both judge. Source it, then call fm_host_probe, which sets:
#   load1           1-minute load average, or unknown
#   cores           logical cores online, or unknown
#   mem_free_pct    available memory as a whole percentage of total, or unknown
#   probe_avail_gb  available memory in GB (two decimals), or empty
#   probe_total_gb  total memory in GB (two decimals), or empty
#   host_os         uname -s, or unknown
# Darwin reads sysctl (vm.loadavg, kern.memorystatus_level, hw.memsize,
# hw.logicalcpu); other systems read /proc/loadavg and /proc/meminfo
# (MemAvailable/MemTotal). Cores come from getconf with a sysctl fallback.
# A probe that cannot be read degrades to unknown (or empty) and is never an
# error; callers decide what an unknown probe means for their verdict.

fm_host_probe_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# shellcheck disable=SC2034  # the probe results are this function's output for the sourcing script
fm_host_probe() {
  local v
  host_os=$(uname -s 2>/dev/null) || host_os=unknown
  [ -n "$host_os" ] || host_os=unknown

  load1=unknown
  if [ "$host_os" = Darwin ]; then
    v=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')
  else
    v=$(awk '{print $1}' /proc/loadavg 2>/dev/null)
  fi
  case "$v" in [0-9]*) load1=$v ;; esac

  cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || cores=
  fm_host_probe_uint "$cores" || cores=$(sysctl -n hw.logicalcpu 2>/dev/null) || cores=
  fm_host_probe_uint "$cores" && [ "$cores" -gt 0 ] || cores=unknown

  mem_free_pct=unknown
  probe_avail_gb=
  probe_total_gb=
  if [ "$host_os" = Darwin ]; then
    v=$(sysctl -n kern.memorystatus_level 2>/dev/null)
    fm_host_probe_uint "$v" && mem_free_pct=$v
    v=$(sysctl -n hw.memsize 2>/dev/null)
    if fm_host_probe_uint "$v" && [ "$mem_free_pct" != unknown ]; then
      probe_total_gb=$(awk -v b="$v" 'BEGIN{printf "%.2f", b / 1073741824}')
      probe_avail_gb=$(awk -v b="$v" -v p="$mem_free_pct" 'BEGIN{printf "%.2f", b * p / 100 / 1073741824}')
    fi
  else
    v=$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{if (t > 0 && a != "") printf "%d %.2f %.2f", a * 100 / t, a / 1048576, t / 1048576}' /proc/meminfo 2>/dev/null)
    if [ -n "$v" ]; then
      # shellcheck disable=SC2086
      set -- $v
      mem_free_pct=$1 probe_avail_gb=$2 probe_total_gb=$3
    fi
  fi
}
