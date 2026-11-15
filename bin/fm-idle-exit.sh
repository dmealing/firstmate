#!/usr/bin/env bash
# fm-idle-exit.sh - stop an idle agent session to free its memory, and relaunch
# it when it is needed again. Two kinds of session qualify: a ship or scout
# worker sitting in a long declared wait, and a local secondmate with no work
# under way.
#
# Usage:
#   fm-idle-exit.sh tick
#   fm-idle-exit.sh exit <task-id>
#   fm-idle-exit.sh wake <task-id> --trigger <text>
#   fm-idle-exit.sh list
#   fm-idle-exit.sh run <task-id> exit|wake [<args>...]   (internal)
#
# Every stop goes through bin/fm-control.sh <id> exit and every relaunch
# through bin/fm-control.sh <id> relaunch, so the endpoint, worktree, branch,
# uncommitted changes, brief, and task record all stay exactly as they were;
# nothing here tears down, discards, or forces anything. The previous agent's
# conversation transcript stays wherever its harness keeps it, but the
# replacement is the fresh agent fm-control's relaunch starts: a ship or scout
# gets its brief plus a progress note naming the wait and the trigger, and a
# secondmate re-reads its charter and reconciles its own home.
#
# Settings: the optional local, gitignored config/idle-exit file holds
# key=value lines; an absent file or key takes the default. It is the one
# place every threshold lives (docs/configuration.md "Idle session exit"):
#   workers=on|off             worker wait exit (default on)
#   secondmates=on|off         idle secondmate exit (default on)
#   worker_wait_secs=<n>       a wait with no known end must last this long (4500)
#   worker_until_secs=<n>      a dated pause exits only while its until time is
#                              more than this far away (4500)
#   secondmate_idle_secs=<n>   a secondmate must have had no work this long (4500)
# A malformed value turns its behavior off and is reported once per change of
# the file. Turning a behavior off stops new exits only: a session already
# stopped still relaunches on its triggers, so nothing is stranded.
#
# Worker waits (ship and scout). The classifier in bin/fm-classify-lib.sh is
# the only reader of what the worker declared:
#   - a captain-held line that is still the declared wait (no known end), or an
#     open needs-decision the worker wrote (status_worker_wait_verb), qualifies
#     once it has lasted worker_wait_secs, aged from the line's own [at=] stamp
#     (else the status file's last change) or from this lane's last relaunch,
#     whichever is later;
#   - a paused line with an `until` time (status_paused_until) qualifies at once
#     while that time is more than worker_until_secs away, and never otherwise;
#     a pause declared before this lane's last relaunch never qualifies, since
#     that relaunch answered it, so only a pause declared afterwards stops it.
# An undated pause, a blocked line, and every other state never qualify.
# Before a stop the lane must also be local (no remote_host), on a backend
# whose agent state, exit, and relaunch are verified (bin/fm-control-lib.sh),
# with its brief and worktree present, an empty steering inbox, an agent that
# reads alive and exactly idle, nothing running under it (below), and a current
# state from bin/fm-crew-state.sh other than working (so an executing
# no-mistakes run or a busy pane keeps it running).
#
# Idle means the agent and everything it started are doing nothing. The agent's
# process tree is read from the endpoint's own process view (the pane's shell
# pid on tmux and Herdr, the foreground chain on Rex), and the stop is skipped
# when any descendant of an agent process started more than a grace window
# (FM_IDLE_EXIT_HELPER_GRACE_SECS, default 180) after the oldest agent process
# of that tree: a background test run, shell, or server the agent started is
# such a descendant, while its own helpers launched with the session (MCP
# servers) started inside the window and do not count. A zombie never counts.
# A tree that cannot be read, holds no recognizable agent process, or belongs
# to a backend with no process view reads as busy. If a stop is still
# attempted and the harness answers with its background-work exit picker, that
# is busy too: the picker is dismissed with Escape (never Enter), the agent
# keeps running, and no record is written. bin/fm-control.sh's refusal to
# press Enter there stays.
#
# Secondmates (local only; a remote route is never stopped here). A mate has no
# work under way when its home's state holds no child *.meta, its own wake
# queue is empty, its steering inbox in this home holds no unhandled message,
# no unresolved pending reply in this home names it, and its agent reads alive
# and exactly idle with nothing running under it (the same process-tree check
# as a worker's, which covers the mate's own background shells). The first such observation is stamped in
# state/.idle-exit-since-<id>, removed by any observation with work; the mate
# stops once the latest of that stamp, its status file's last change, its
# newest handled inbox message, and its last relaunch is secondmate_idle_secs
# old. While its record exists, bin/fm-secondmate-liveness-lib.sh's probe
# leaves the stopped endpoint down (status idle-exited) instead of relaunching
# it, so the session-start sweep and the watcher tick both honor a deliberate
# stop. A mate that dies without a record is relaunched exactly as before.
#
# exit <id> takes the lane lock (state/.idle-exit-<id>.lock), re-checks every
# condition, then under the task's meta lock (the lock bin/fm-send.sh records a
# steer under) checks the inbox and idle state once more and writes the record
# marked pending=1, releases that lock, stops the agent, and rewrites the
# record without pending once the stop is confirmed. A secondmate's stop also
# holds its liveness lock. No status line is appended: the worker's declared
# wait stays its latest event. Exit status 3 means the
# lane no longer qualified and nothing changed; any other nonzero is a failure.
#
# wake <id> --trigger <text> waits (bounded) for the lane lock, then relaunches
# a recorded lane; with no record it does nothing and succeeds. A worker is
# relaunched with --note-file; success removes the record and stamps
# state/.idle-exit-woke-<id>, failure keeps the record with relaunch_error=,
# which bin/fm-crew-state.sh reports as blocked and the tick leaves for a manual
# wake. A secondmate is relaunched under its liveness lock; on failure its
# record is removed so the secondmate liveness guarantee takes over on its
# next tick, and the failure is reported.
#
# Triggers. bin/fm-send.sh calls wake synchronously after durably recording a
# steer for a task that has a record, before it rings the doorbell, so the
# relaunched agent finds the steer (its progress note points a fresh worker at
# the inbox, and the watcher's ordinary re-ring ladder covers the rest). The
# tick relaunches a recorded worker when its inbox holds an unhandled message,
# its dated pause reaches its until time, or its current declared wait is no
# longer the recorded line (resolved, answered, released, or any later event);
# and a recorded secondmate when its inbox holds an unhandled message, its own
# wake queue has a row, or its home has a child record.
#
# tick is what bin/fm-watch.sh runs on each check sweep. With both behaviors on
# by default it evaluates every local task record in this home; it holds
# state/.idle-exit-tick.lock (a held lock exits silently), settles pending
# records (a dead agent is confirmed stopped; one still alive after
# FM_IDLE_EXIT_ACTION_SECS drops the record), drops a record whose agent is
# alive again or whose task record is gone, and starts each exit or wake as a
# detached `run` action in its own process group so no watcher budget cuts it
# short. A failed action publishes one outcome line as
# state/.idle-exit-report-<id>-<epoch>-<pid>; the tick prints those lines and
# removes them, and prints a malformed-settings line once, for the watcher to
# ring as one check wake. Successful stops and relaunches print nothing.
#
# list prints each recorded lane: id, kind, when it stopped, and its wait.
#
# The record, state/<id>.idle-exit, is key=value lines (kind=worker|secondmate,
# exited_at, wait (the declared wait line), until (epoch, dated pause only),
# pending=1 until the stop is confirmed, relaunch_error after a failed worker
# relaunch), mode 0600, published by rename. Teardown removes it and the
# stamps above.
#
# Overrides for tests: FM_IDLE_EXIT_CONTROL_BIN, FM_IDLE_EXIT_CREW_STATE_BIN,
# FM_IDLE_EXIT_ACTION_SECS (default 900, the bound on each lifecycle call and on
# lock waits), FM_IDLE_EXIT_HELPER_GRACE_SECS (default 180, the grace window
# above), and FM_IDLE_EXIT_INLINE=1, which runs tick actions in the foreground.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
export FM_HOME FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-secondmate-liveness-lib.sh
. "$SCRIPT_DIR/fm-secondmate-liveness-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$SCRIPT_DIR/fm-agent-process-lib.sh"

CONTROL_BIN="${FM_IDLE_EXIT_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}"
CREW_STATE_BIN="${FM_IDLE_EXIT_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"
ACTION_SECS=${FM_IDLE_EXIT_ACTION_SECS:-900}
case "$ACTION_SECS" in ''|*[!0-9]*) printf 'fm-idle-exit: FM_IDLE_EXIT_ACTION_SECS must be whole seconds\n' >&2; exit 2 ;; esac
HELPER_GRACE_SECS=${FM_IDLE_EXIT_HELPER_GRACE_SECS:-180}
case "$HELPER_GRACE_SECS" in ''|*[!0-9]*) printf 'fm-idle-exit: FM_IDLE_EXIT_HELPER_GRACE_SECS must be whole seconds\n' >&2; exit 2 ;; esac

usage() { sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0" | sed '$d'; }
die() { printf 'fm-idle-exit: %s\n' "$1" >&2; exit "${2:-1}"; }

LOCKS_HELD=
release_locks() {
  local lock
  for lock in $LOCKS_HELD; do fm_lock_release "$lock" || true; done
  LOCKS_HELD=
}
NOTE_TMP=
cleanup() {
  release_locks
  [ -z "$NOTE_TMP" ] || rm -f -- "$NOTE_TMP"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

lock_try() {  # <lock-path>
  fm_lock_try_acquire "$1" || return 1
  LOCKS_HELD="$LOCKS_HELD $1"
}
lock_wait() {  # <lock-path> <max-seconds>
  fm_lock_acquire_wait_max "$1" "$2" || return 1
  LOCKS_HELD="$LOCKS_HELD $1"
}
lock_drop() {  # <lock-path>
  local lock kept=
  fm_lock_release "$1" || true
  for lock in $LOCKS_HELD; do [ "$lock" = "$1" ] || kept="$kept $lock"; done
  LOCKS_HELD=$kept
}

task_id_ok() { case "${1-}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
lane_lock() { printf '%s/.idle-exit-%s.lock' "$STATE" "$1"; }
lane_busy() {  # <id>
  local lock
  lock=$(lane_lock "$1")
  fm_lock_try_acquire "$lock" || return 0
  fm_lock_release "$lock" || true
  return 1
}

record_path() { printf '%s/%s.idle-exit' "$STATE" "$1"; }
record_get() { fm_meta_get "$(record_path "$1")" "$2"; }
record_exists() { [ -e "$(record_path "$1")" ] || [ -L "$(record_path "$1")" ]; }
record_write() {  # <id> <key=value>...
  local id=$1 tmp
  shift
  tmp=$(mktemp "$STATE/.idle-exit.XXXXXX") || return 1
  if ! { printf '%s\n' "$@" > "$tmp" && chmod 0600 "$tmp" && mv -f -- "$tmp" "$(record_path "$id")"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}
# The record's lines with <key> dropped, as arguments for record_write.
record_lines_without() {  # <id> <key>
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*|'') ;; *) printf '%s\n' "$line" ;; esac
  done < "$(record_path "$1")"
}
record_rewrite_without() {  # <id> <key> [<extra key=value>...]
  local id=$1 key=$2 line
  local -a lines=()
  shift 2
  while IFS= read -r line; do lines+=("$line"); done < <(record_lines_without "$id" "$key")
  record_write "$id" "${lines[@]}" "$@"
}

woke_path() { printf '%s/.idle-exit-woke-%s' "$STATE" "$1"; }
since_path() { printf '%s/.idle-exit-since-%s' "$STATE" "$1"; }
read_epoch() {  # <file> -> epoch or nothing
  local v
  v=$(cat "$1" 2>/dev/null || true)
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$v"
}
file_mtime() {  # <path> -> epoch or nothing
  _fm_status_file_mtime "$1" 2>/dev/null || true
}

report_write() {  # <id> <line>
  local tmp
  tmp=$(mktemp "$STATE/.idle-exit.XXXXXX") || return 1
  if ! { printf '%s\n' "$2" > "$tmp" && mv -f -- "$tmp" "$STATE/.idle-exit-report-$1-$(date +%s)-$$"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

# --- settings ----------------------------------------------------------------

WORKERS_ON=1 SECONDMATES_ON=1
WORKER_WAIT_SECS=4500 WORKER_UNTIL_SECS=4500 SECONDMATE_IDLE_SECS=4500
SETTINGS_ERROR=
settings_load() {
  local f="$CONFIG/idle-exit" line key value
  WORKERS_ON=1 SECONDMATES_ON=1
  WORKER_WAIT_SECS=4500 WORKER_UNTIL_SECS=4500 SECONDMATE_IDLE_SECS=4500
  SETTINGS_ERROR=
  [ -e "$f" ] || return 0
  if [ ! -f "$f" ] || [ ! -r "$f" ]; then
    WORKERS_ON=0 SECONDMATES_ON=0
    SETTINGS_ERROR="$f is not a readable file; idle exit is off until it is fixed"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || { settings_bad "line '$line' is not key=value" all; continue; }
    case "$key" in
      workers|secondmates)
        case "$value" in
          on) ;;
          off) if [ "$key" = workers ]; then WORKERS_ON=0; else SECONDMATES_ON=0; fi ;;
          *) settings_bad "$key=$value is not on or off" "$key" ;;
        esac
        ;;
      worker_wait_secs|worker_until_secs|secondmate_idle_secs)
        case "$value" in
          ''|*[!0-9]*|0) settings_bad "$key=$value is not a positive whole number of seconds" "$key"; continue ;;
        esac
        [ "${#value}" -le 9 ] || { settings_bad "$key=$value is too large" "$key"; continue; }
        case "$key" in
          worker_wait_secs) WORKER_WAIT_SECS=$value ;;
          worker_until_secs) WORKER_UNTIL_SECS=$value ;;
          secondmate_idle_secs) SECONDMATE_IDLE_SECS=$value ;;
        esac
        ;;
      *) settings_bad "unknown key '$key'" all ;;
    esac
  done < "$f"
}
settings_bad() {  # <message> <workers|secondmates|worker_*|secondmate_*|all>
  case "$2" in
    workers|worker_*) WORKERS_ON=0 ;;
    secondmates|secondmate_*) SECONDMATES_ON=0 ;;
    *) WORKERS_ON=0 SECONDMATES_ON=0 ;;
  esac
  SETTINGS_ERROR="${SETTINGS_ERROR:+$SETTINGS_ERROR; }config/idle-exit: $1"
}

# --- shared reads ------------------------------------------------------------

meta_of() { printf '%s/%s.meta' "$STATE" "$1"; }

backend_ok() {  # <meta>
  local backend
  backend=$(fm_backend_of_meta "$1")
  fm_control_backend_state_verified "$backend" \
    && fm_control_backend_exit_supported "$backend" \
    && fm_control_backend_relaunch_supported "$backend"
}

agent_state_of() {  # <id>
  local meta backend target
  meta=$(meta_of "$1")
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  [ -n "$target" ] || { printf 'unreadable\n'; return 0; }
  fm_backend_agent_state "$backend" "$target" 2>/dev/null || printf 'unreadable\n'
}

agent_idle() {  # <id>
  local verdict
  verdict=$(fm_busy_classify_meta "$(meta_of "$1")" "$1" "$STATE" 2>/dev/null || true)
  case "$verdict" in idle\ *|idle) return 0 ;; esac
  return 1
}

# The pids an endpoint's process view names as its terminal's root: the pane
# shell on tmux and Herdr, the foreground chain on Rex. Any other backend, or
# an unreadable view, prints nothing.
tree_roots() {  # <id>
  local meta backend target
  meta=$(meta_of "$1")
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  [ -n "$target" ] || return 1
  fm_backend_source "$backend" >/dev/null 2>&1 || return 1
  case "$backend" in
    tmux) tmux display-message -p -t "$target" '#{pane_pid}' 2>/dev/null ;;
    herdr)
      fm_backend_herdr_parse_target "$target" || return 1
      fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" pane process-info --pane "$FM_BACKEND_HERDR_PANE" 2>/dev/null \
        | jq -r --arg pane "$FM_BACKEND_HERDR_PANE" '
            .result | select(.type == "pane_process_info" and .process_info.pane_id == $pane)
            | .process_info.shell_pid | select(type == "number" and . > 1) | floor' 2>/dev/null
      ;;
    rex) fm_backend_rex_live_pids "$target" 2>/dev/null | jq -r '.[]' 2>/dev/null ;;
    *) return 1 ;;
  esac | grep -E '^[0-9]+$'
}

# Succeeds only when nothing is running under the agent that it did not start
# with its session (header "Idle means"); prints the reason and returns 1
# otherwise, including whenever the tree cannot be read or classified.
agent_tree_quiet() {  # <id>
  local id=$1 roots members pid ppid age stat comm args argv0 amax=-1 agents='' busy
  roots=$(tree_roots "$id" 2>/dev/null | tr '\n' ' ') || roots=
  case "$roots" in *[0-9]*) ;; *) echo "its process tree could not be read"; return 1 ;; esac
  members=$(LC_ALL=C ps -axo pid=,ppid=,etime=,stat=,comm= 2>/dev/null | awk -v roots="$roots" '
    function secs(e,  d, p, n, i, s) {
      d = 0
      if (index(e, "-")) { split(e, p, "-"); d = p[1]; e = p[2] }
      n = split(e, p, ":"); s = 0
      for (i = 1; i <= n; i++) s = s * 60 + p[i]
      return d * 86400 + s
    }
    BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) want[r[i]] = 1 }
    {
      pid[NR] = $1; ppid[NR] = $2; age[NR] = secs($3); stat[NR] = $4
      c = $0
      sub(/^[ \t]*[0-9]+[ \t]+[0-9]+[ \t]+[^ \t]+[ \t]+[^ \t]+[ \t]+/, "", c)
      comm[NR] = c
    }
    END {
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= NR; i++) if ((ppid[i] in want) && !(pid[i] in want)) { want[pid[i]] = 1; changed = 1 }
      }
      for (i = 1; i <= NR; i++) if (pid[i] in want) printf "%s\t%s\t%s\t%s\t%s\n", pid[i], ppid[i], age[i], stat[i], comm[i]
    }' || true)
  [ -n "$members" ] || { echo "its process tree could not be read"; return 1; }
  while IFS=$'\t' read -r pid ppid age stat comm; do
    [ -n "$pid" ] || continue
    args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || continue
    args=${args#"${args%%[![:space:]]*}"}
    argv0=${args%%[[:space:]]*}
    [ "$(fm_agent_process_classify "${comm##*/}" "$argv0" "$args" "$pid")" = agent ] || continue
    agents="$agents $pid"
    [ "$age" -le "$amax" ] || amax=$age
  done <<EOF
$members
EOF
  [ -n "$agents" ] || { echo "no agent process was found in its terminal"; return 1; }
  busy=$(printf '%s\n' "$members" | awk -F'\t' -v agents="$agents" -v amax="$amax" -v grace="$HELPER_GRACE_SECS" '
    BEGIN { n = split(agents, a, " "); for (i = 1; i <= n; i++) root[a[i]] = 1 }
    { pid[NR] = $1; ppid[NR] = $2; age[NR] = $3; stat[NR] = $4; comm[NR] = $5 }
    END {
      changed = 1
      for (i = 1; i <= NR; i++) if (ppid[i] in root) under[pid[i]] = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= NR; i++) if ((ppid[i] in under) && !(pid[i] in under)) { under[pid[i]] = 1; changed = 1 }
      }
      for (i = 1; i <= NR; i++)
        if ((pid[i] in under) && stat[i] !~ /^Z/ && age[i] + grace < amax) { printf "%s %s\n", pid[i], comm[i]; exit }
    }')
  [ -z "$busy" ] || { echo "something it started is still running under its agent ($busy)"; return 1; }
}

# The harness answered the stop with its background-work exit picker: close it
# with Escape, never Enter, so the agent keeps running its job.
dismiss_exit_picker() {  # <id>
  local meta backend target screen
  meta=$(meta_of "$1")
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  fm_backend_source "$backend" >/dev/null 2>&1 || return 0
  screen=$(fm_backend_visible_capture "$backend" "$target" "fm-$1" 2>/dev/null) || return 0
  fm_composer_blocking_dialog "$screen" >/dev/null || return 0
  fm_backend_send_key "$backend" "$target" Escape "fm-$1" >/dev/null 2>&1 || true
}

inbox_pending() {  # <id>
  find "$STATE/$1.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | grep -q .
}

# An agent that is alive, exactly idle, has nothing waiting in its inbox, and
# has nothing running under it; prints the refusal and returns 1 otherwise.
agent_quiet() {  # <id>
  local state
  inbox_pending "$1" && { echo "an instruction is waiting in its inbox"; return 1; }
  state=$(agent_state_of "$1")
  [ "$state" = alive ] || { echo "its agent reads $state, not alive"; return 1; }
  agent_idle "$1" || { echo "its agent is not idle"; return 1; }
  agent_tree_quiet "$1" || return 1
}

newest_handled_mtime() {  # <id>
  local rec m newest=0
  for rec in "$STATE/$1.inbox/handled"/*.msg; do
    [ -e "$rec" ] || continue
    m=$(file_mtime "$rec")
    case "$m" in ''|*[!0-9]*) continue ;; esac
    [ "$m" -le "$newest" ] || newest=$m
  done
  printf '%s\n' "$newest"
}

# --- worker waits --------------------------------------------------------------

# Sets WAIT_KIND (held|decision|paused), WAIT_LINE, WAIT_AGE, WAIT_UNTIL
# (epoch, paused only), and WAIT_WOKE (1 when the lane was relaunched after the
# wait was declared, so WAIT_AGE counts from that relaunch) for a worker in a
# declared wait of a qualifying kind; returns 1 when it is in none. The age is
# not checked here.
worker_wait() {  # <id>
  local id=$1 f line verb now file_age mtime woke at
  f="$STATE/$id.status"
  WAIT_KIND='' WAIT_LINE='' WAIT_AGE=0 WAIT_UNTIL='' WAIT_WOKE=0
  [ -f "$f" ] || return 1
  line=$(status_declared_wait_line "$f")
  if [ -n "$line" ] && status_is_captain_held "$line"; then
    WAIT_KIND=held
  elif [ -n "$line" ] && WAIT_UNTIL=$(status_paused_until "$line"); then
    WAIT_KIND=paused
  elif verb=$(status_worker_wait_verb "$f") && [ "$verb" = needs-decision ]; then
    WAIT_KIND=decision
    line=$(last_status_line "$f")
  else
    WAIT_UNTIL=''
    return 1
  fi
  WAIT_LINE=$line
  now=$(date +%s)
  mtime=$(file_mtime "$f")
  case "$mtime" in ''|*[!0-9]*) mtime=$now ;; esac
  file_age=$(( now - mtime ))
  WAIT_AGE=$file_age
  if at=$(status_line_at_epoch "$line") && [ "$at" -le "$now" ]; then
    WAIT_AGE=$(( now - at ))
  fi
  if woke=$(read_epoch "$(woke_path "$id")") && [ "$woke" -le "$now" ] \
    && [ $(( now - woke )) -le "$WAIT_AGE" ]; then
    WAIT_AGE=$(( now - woke ))
    WAIT_WOKE=1
  fi
  return 0
}

# Succeeds when the worker's current wait is long enough to stop it (header
# "Worker waits").
worker_wait_long() {
  local now
  case "$WAIT_KIND" in
    held|decision) [ "$WAIT_AGE" -ge "$WORKER_WAIT_SECS" ] ;;
    paused)
      [ "$WAIT_WOKE" = 0 ] || return 1
      now=$(date +%s)
      [ $(( WAIT_UNTIL - now )) -gt "$WORKER_UNTIL_SECS" ]
      ;;
    *) return 1 ;;
  esac
}

# Every condition for stopping a worker; prints the first refusal.
worker_preflight() {  # <id>
  local id=$1 meta kind wt crew
  meta=$(meta_of "$id")
  [ -f "$meta" ] || { echo "no task record"; return 1; }
  kind=$(fm_meta_get "$meta" kind)
  case "${kind:-ship}" in ship|scout) ;; *) echo "kind $kind is not a worker"; return 1 ;; esac
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || { echo "it runs on another host"; return 1; }
  backend_ok "$meta" || { echo "its backend cannot prove a stop and relaunch"; return 1; }
  [ -f "$DATA/$id/brief.md" ] || { echo "it has no instructions on disk to relaunch from"; return 1; }
  wt=$(fm_meta_get "$meta" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || { echo "its local copy is missing"; return 1; }
  record_exists "$id" && { echo "it is already stopped"; return 1; }
  worker_wait "$id" || { echo "it is not in a qualifying declared wait"; return 1; }
  worker_wait_long || { echo "its $WAIT_KIND wait is not long enough"; return 1; }
  agent_quiet "$id" || return 1
  crew=$(FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE fm_run_timed 60 "$CREW_STATE_BIN" "$id" 2>/dev/null | head -1 || true)
  case "$crew" in
    'state: paused '*|'state: parked '*|'state: blocked '*) ;;
    *) echo "its current state is not a wait (${crew:-unreadable})"; return 1 ;;
  esac
}

# --- secondmates -----------------------------------------------------------------

sm_home() {  # <id>
  local meta home
  meta=$(meta_of "$1")
  home=$(fm_meta_get "$meta" home)
  [ -n "$home" ] || home=$(fm_meta_get "$meta" worktree)
  printf '%s\n' "$home"
}

sm_has_child() {  # <home>
  local m
  for m in "$1/state"/*.meta; do
    [ -e "$m" ] || [ -L "$m" ] || continue
    return 0
  done
  return 1
}

sm_reply_open() {  # <id>
  local rec phase
  for rec in "$STATE/pending-replies"/*; do
    [ -f "$rec" ] || continue
    [ "$(fm_meta_get "$rec" task_id)" = "$1" ] || continue
    phase=$(fm_meta_get "$rec" phase)
    [ "$phase" = resolved ] || return 0
  done
  return 1
}

# Every condition for a secondmate to have no work right now; prints the first
# reason it has some (or cannot be stopped).
sm_preflight() {  # <id>
  local id=$1 meta home
  meta=$(meta_of "$id")
  [ -f "$meta" ] || { echo "no task record"; return 1; }
  [ "$(fm_meta_get "$meta" kind)" = secondmate ] || { echo "not a secondmate"; return 1; }
  [ -z "$(fm_meta_get "$meta" remote_host)" ] || { echo "it runs on another host"; return 1; }
  backend_ok "$meta" || { echo "its backend cannot prove a stop and relaunch"; return 1; }
  record_exists "$id" && { echo "it is already stopped"; return 1; }
  home=$(sm_home "$id")
  [ -n "$home" ] && [ -d "$home/state" ] || { echo "its home state is unreadable"; return 1; }
  [ "$(cat "$home/.fm-secondmate-home" 2>/dev/null || true)" = "$id" ] || { echo "its home is not marked as its own"; return 1; }
  sm_has_child "$home" && { echo "it has work under way"; return 1; }
  [ ! -s "$home/state/.wake-queue" ] || { echo "its home has a queued notification"; return 1; }
  sm_reply_open "$id" && { echo "it owes a reply"; return 1; }
  agent_quiet "$id" || return 1
}

# Seconds the mate has had no work, from the latest of its first idle
# observation, its status file's last change, its newest handled message, and
# its last relaunch.
sm_idle_age() {  # <id>
  local id=$1 now latest v
  now=$(date +%s)
  latest=$(read_epoch "$(since_path "$id")") || latest=$now
  v=$(file_mtime "$STATE/$id.status")
  case "$v" in ''|*[!0-9]*) ;; *) [ "$v" -le "$latest" ] || latest=$v ;; esac
  v=$(newest_handled_mtime "$id")
  [ "$v" -le "$latest" ] || latest=$v
  if v=$(read_epoch "$(woke_path "$id")"); then [ "$v" -le "$latest" ] || latest=$v; fi
  [ "$latest" -le "$now" ] || latest=$now
  printf '%s\n' $(( now - latest ))
}

# --- exit --------------------------------------------------------------------------

cmd_exit() {
  local id=${1-} kind meta why meta_lock live_lock='' out rc=0 now
  task_id_ok "$id" || die "usage: fm-idle-exit.sh exit <task-id>" 2
  settings_load
  meta=$(meta_of "$id")
  [ -f "$meta" ] || die "no task record for $id" 3
  kind=$(fm_meta_get "$meta" kind)
  lock_try "$(lane_lock "$id")" || die "another idle-exit action holds $id" 3
  if [ "$kind" = secondmate ]; then
    why=$(sm_preflight "$id") || die "not stopping $id: $why" 3
    [ "$(sm_idle_age "$id")" -ge "$SECONDMATE_IDLE_SECS" ] || die "not stopping $id: it has not been idle long enough" 3
    live_lock="$STATE/.secondmate-liveness-$id.lock"
    lock_try "$live_lock" || die "not stopping $id: a liveness check holds it" 3
  else
    why=$(worker_preflight "$id") || die "not stopping $id: $why" 3
  fi
  # bin/fm-send.sh writes a steer under the task's meta lock and looks for the
  # record only after releasing it, so the last quiet check and the pending
  # record are made under that lock: a steer recorded first refuses the stop,
  # and one recorded afterwards finds the record and relaunches the agent. The
  # lock is released before the stop because bin/fm-control.sh takes it too.
  meta_lock=$(fm_meta_lock_path "$(meta_of "$id")") || die "not stopping $id: its task metadata lock could not be resolved" 3
  fm_task_inbox_lock_acquire "$meta_lock" || die "not stopping $id: its task metadata could not be locked" 3
  if ! why=$(agent_quiet "$id"); then
    fm_lock_release "$meta_lock" || true
    die "not stopping $id: $why" 3
  fi
  now=$(date +%s)
  local -a fields=("exited_at=$now")
  if [ "$kind" = secondmate ]; then
    fields=("kind=secondmate" "${fields[@]}")
  elif worker_wait "$id"; then
    fields=("kind=worker" "${fields[@]}" "wait=$WAIT_LINE")
    [ -z "$WAIT_UNTIL" ] || fields+=("until=$WAIT_UNTIL")
  else
    fm_lock_release "$meta_lock" || true
    die "not stopping $id: its declared wait cleared" 3
  fi
  if ! record_write "$id" "${fields[@]}" "pending=1"; then
    fm_lock_release "$meta_lock" || true
    die "could not write the idle-exit record for $id"
  fi
  fm_lock_release "$meta_lock" || true
  out=$(FM_HOME=$FM_HOME fm_run_timed "$ACTION_SECS" "$CONTROL_BIN" "$id" exit 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    if printf '%s\n' "$out" | grep -q 'Claude background-task exit picker'; then
      dismiss_exit_picker "$id"
      rm -f -- "$(record_path "$id")"
      die "not stopping $id: its harness reports background work still running" 3
    fi
    if [ "$(agent_state_of "$id")" = alive ]; then
      rm -f -- "$(record_path "$id")"
    fi
    die "could not stop $id: $(printf '%s\n' "$out" | tail -1)"
  fi
  record_write "$id" "${fields[@]}" || die "$id was stopped but its record could not be marked stopped; the next tick settles it"
  rm -f -- "$(since_path "$id")"
  printf 'stopped %s (%s) while idle\n' "$id" "${fields[0]#kind=}"
}

# --- wake --------------------------------------------------------------------------

worker_note() {  # <id> <trigger> <file>
  local wait
  wait=$(record_get "$1" wait)
  {
    printf 'Firstmate stopped the previous agent of this task to free memory while it waited on this declared wait:\n'
    printf '  %s\n' "${wait:-unknown}"
    printf 'You are a fresh agent relaunched in the same local copy on the same branch because %s.\n' "$2"
    printf 'Read your status file and inbox, then continue the task from that wait exactly as your instructions define.\n'
  } > "$3"
}

cmd_wake() {
  local id=${1-} trigger kind out rc=0 live_lock
  task_id_ok "$id" || die "usage: fm-idle-exit.sh wake <task-id> --trigger <text>" 2
  shift
  [ "${1-}" = --trigger ] && [ -n "${2-}" ] || die "usage: fm-idle-exit.sh wake <task-id> --trigger <text>" 2
  trigger=$2
  record_exists "$id" || return 0
  lock_wait "$(lane_lock "$id")" "$ACTION_SECS" || die "another idle-exit action still holds $id"
  record_exists "$id" || return 0
  if [ -n "$(record_get "$id" pending)" ]; then
    if [ "$(agent_state_of "$id")" = alive ]; then
      rm -f -- "$(record_path "$id")"
      return 0
    fi
    record_rewrite_without "$id" pending || die "could not settle the idle-exit record for $id"
  fi
  kind=$(record_get "$id" kind)
  if [ "$kind" = secondmate ]; then
    live_lock="$STATE/.secondmate-liveness-$id.lock"
    lock_wait "$live_lock" "$ACTION_SECS" || die "a liveness check still holds $id"
    out=$(FM_HOME=$FM_HOME fm_run_timed "$ACTION_SECS" "$CONTROL_BIN" "$id" relaunch 2>&1) || rc=$?
    # Either way the deliberate stop is over: on failure the liveness guarantee
    # relaunches the mate on its next tick.
    rm -f -- "$(record_path "$id")"
    lock_drop "$live_lock"
    if [ "$rc" -ne 0 ]; then
      die "relaunch of secondmate $id ($trigger) failed: $(printf '%s\n' "$out" | tail -1); the liveness check takes it over"
    fi
  else
    NOTE_TMP=$(mktemp "$STATE/.idle-exit-note.XXXXXX") || die "could not write the relaunch note for $id"
    worker_note "$id" "$trigger" "$NOTE_TMP"
    out=$(FM_HOME=$FM_HOME fm_run_timed "$ACTION_SECS" "$CONTROL_BIN" "$id" relaunch --note-file "$NOTE_TMP" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
      record_rewrite_without "$id" relaunch_error "relaunch_error=$(date +%s)" || true
      die "relaunch of $id ($trigger) failed: $(printf '%s\n' "$out" | tail -1); run fm-idle-exit.sh wake $id --trigger <why> once it is fixed"
    fi
    rm -f -- "$(record_path "$id")"
  fi
  date +%s > "$(woke_path "$id")" || true
  printf 'relaunched %s: %s\n' "$id" "$trigger"
}

# --- tick --------------------------------------------------------------------------

action_start() {  # <id> <verb> <args...>
  if [ "${FM_IDLE_EXIT_INLINE:-0}" = 1 ]; then
    "$SCRIPT_DIR/fm-idle-exit.sh" run "$@" </dev/null >/dev/null 2>&1 || true
    return 0
  fi
  ( set -m 2>/dev/null || true
    nohup "$SCRIPT_DIR/fm-idle-exit.sh" run "$@" </dev/null >/dev/null 2>&1 & )
}

# Prints the trigger that should relaunch a recorded lane, or nothing.
recorded_trigger() {  # <id>
  local id=$1 home now until
  inbox_pending "$id" && { echo "an instruction arrived in its inbox"; return 0; }
  if [ "$(record_get "$id" kind)" = secondmate ]; then
    home=$(sm_home "$id")
    [ ! -s "$home/state/.wake-queue" ] || { echo "its home has a queued notification"; return 0; }
    ! sm_has_child "$home" || { echo "its home has work under way"; return 0; }
    return 0
  fi
  until=$(record_get "$id" until)
  now=$(date +%s)
  case "$until" in
    ''|*[!0-9]*) ;;
    *) [ "$now" -lt "$until" ] || { echo "its declared wait time arrived"; return 0; } ;;
  esac
  if ! worker_wait "$id" || [ "$WAIT_LINE" != "$(record_get "$id" wait)" ]; then
    echo "its declared wait changed or cleared"
  fi
}

tick_recorded() {  # <id>
  local id=$1 state exited trigger
  lane_busy "$id" && return 0
  [ -f "$(meta_of "$id")" ] || { rm -f -- "$(record_path "$id")"; return 0; }
  state=$(agent_state_of "$id")
  if [ -n "$(record_get "$id" pending)" ]; then
    case "$state" in
      dead) record_rewrite_without "$id" pending || true ;;
      alive)
        exited=$(record_get "$id" exited_at)
        case "$exited" in ''|*[!0-9]*) exited=0 ;; esac
        [ $(( $(date +%s) - exited )) -le "$ACTION_SECS" ] || rm -f -- "$(record_path "$id")"
        ;;
    esac
    return 0
  fi
  # Relaunched some other way: the deliberate stop is over.
  [ "$state" != alive ] || { rm -f -- "$(record_path "$id")"; return 0; }
  [ -z "$(record_get "$id" relaunch_error)" ] || return 0
  trigger=$(recorded_trigger "$id")
  [ -z "$trigger" ] || action_start "$id" wake --trigger "$trigger"
}

settings_report_once() {
  local sig marker="$STATE/.idle-exit-settings-reported"
  if [ -z "$SETTINGS_ERROR" ]; then
    rm -f -- "$marker"
    return 0
  fi
  sig=$(cksum < "$CONFIG/idle-exit" 2>/dev/null || echo unreadable)
  [ "$(cat "$marker" 2>/dev/null || true)" != "$sig" ] || return 0
  printf '%s\n' "$sig" > "$marker" 2>/dev/null || true
  printf '%s\n' "$SETTINGS_ERROR"
}

cmd_tick() {
  local meta id kind report why
  settings_load
  lock_try "$STATE/.idle-exit-tick.lock" || return 0
  settings_report_once
  for report in "$STATE"/.idle-exit-report-*; do
    [ -f "$report" ] || continue
    cat "$report"
    rm -f -- "$report"
  done
  for report in "$STATE"/*.idle-exit; do
    [ -e "$report" ] || continue
    id=${report##*/}
    id=${id%.idle-exit}
    task_id_ok "$id" || continue
    tick_recorded "$id"
  done
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    task_id_ok "$id" || continue
    record_exists "$id" && continue
    lane_busy "$id" && continue
    kind=$(fm_meta_get "$meta" kind)
    case "${kind:-ship}" in
      ship|scout)
        [ "$WORKERS_ON" = 1 ] || continue
        # The cheap declared-wait read first; the full preflight runs only for
        # a lane that is already in a long qualifying wait.
        worker_wait "$id" || continue
        worker_wait_long || continue
        worker_preflight "$id" >/dev/null || continue
        action_start "$id" exit
        ;;
      secondmate)
        [ "$SECONDMATES_ON" = 1 ] || continue
        if ! why=$(sm_preflight "$id"); then
          rm -f -- "$(since_path "$id")"
          continue
        fi
        : "$why"
        [ -e "$(since_path "$id")" ] || date +%s > "$(since_path "$id")" || continue
        [ "$(sm_idle_age "$id")" -ge "$SECONDMATE_IDLE_SECS" ] || continue
        action_start "$id" exit
        ;;
    esac
  done
}

# --- list and detached run --------------------------------------------------------

cmd_list() {
  local rec id
  for rec in "$STATE"/*.idle-exit; do
    [ -f "$rec" ] || continue
    id=${rec##*/}
    id=${id%.idle-exit}
    printf '%s\t%s\t%s\t%s\n' "$id" "$(fm_meta_get "$rec" kind)" "$(fm_meta_get "$rec" exited_at)" "$(fm_meta_get "$rec" wait)"
  done
}

cmd_run() {
  local id=${1-} verb=${2-} out rc=0
  task_id_ok "$id" || die "usage: fm-idle-exit.sh run <task-id> exit|wake [<args>...]" 2
  case "$verb" in exit|wake) ;; *) die "usage: fm-idle-exit.sh run <task-id> exit|wake [<args>...]" 2 ;; esac
  shift 2
  # A command substitution does not inherit the EXIT trap, so the action
  # releases its own locks.
  out=$( LOCKS_HELD=; trap release_locks EXIT; "cmd_$verb" "$id" "$@" 2>&1 ) || rc=$?
  # 3 is a lane that no longer qualified: nothing changed and nothing to say.
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then
    report_write "$id" "idle-exit $verb $id failed: $(printf '%s\n' "$out" | tail -1 | sed 's/^fm-idle-exit: //')" || true
  fi
  return 0
}

case "${1-}" in
  tick) shift; cmd_tick "$@" ;;
  exit) shift; cmd_exit "$@" ;;
  wake) shift; cmd_wake "$@" ;;
  list) shift; cmd_list "$@" ;;
  run) shift; cmd_run "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
