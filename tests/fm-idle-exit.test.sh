#!/usr/bin/env bash
# Tests for bin/fm-idle-exit.sh: which declared waits stop a worker and at what
# threshold, the stop/relaunch cycle on each kind of clearing, a steer through
# bin/fm-send.sh relaunching a stopped worker, idle secondmate stops, the
# secondmate liveness probe leaving a deliberate stop down while a crash stays
# relaunchable, and the per-home settings.
#
# The lifecycle owners (bin/fm-control.sh and bin/fm-crew-state.sh) are faked
# through the script's documented FM_IDLE_EXIT_*_BIN overrides, and the agent
# endpoint through a tmux stub whose foreground command is a file the fake
# control flips between claude (alive) and zsh (stopped), so every case drives
# the real decision procedure and asserts the lifecycle calls it made.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

IDLE="$ROOT/bin/fm-idle-exit.sh"
TMP_ROOT=$(fm_test_tmproot fm-idle-exit-tests)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# A home with one ship lane in tmux window fm:fm-lane, an idle Claude busy
# record, instructions on disk, and stubs for tmux and the lifecycle owners.
make_world() {
  local name=$1 world fakebin wt
  world="$TMP_ROOT/$name"
  fakebin="$world/fakebin"
  mkdir -p "$world/state" "$world/config" "$world/data/lane" "$fakebin"
  git init -q -b main "$world/project"
  git -C "$world/project" commit -q --allow-empty -m base
  wt="$world/wt"
  git -C "$world/project" worktree add -q -b fm/lane "$wt" main
  fm_write_meta "$world/state/lane.meta" \
    "window=fm:fm-lane" "endpoint_task_id=lane" "worktree=$wt" \
    "project=$world/project" "kind=ship" "mode=local-only" "harness=claude" \
    "branch=fm/lane"
  printf '# brief\n' > "$world/data/lane/brief.md"
  set_idle "$world" lane
  printf 'claude\n' > "$world/pane.lane"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
case "\$1" in
  list-windows) printf '%s\n' fm-lane fm-sm1 ;;
  capture-pane) cat "$world/screen.lane" 2>/dev/null; exit 0 ;;
  send-keys) printf '%s\\n' "\$*" >> "$world/keys.log"; exit 0 ;;
  display-message)
    for a in "\$@"; do case "\$a" in *pane_pid*)
      for t in "\$@"; do case "\$t" in *fm-sm1*) cat "$world/panepid.sm1" 2>/dev/null; exit 0 ;; esac; done
      cat "$world/panepid.lane" 2>/dev/null; exit 0 ;; esac; done
    for a in "\$@"; do case "\$a" in *pane_current_command*)
      for t in "\$@"; do case "\$t" in *fm-sm1*) cat "$world/pane.sm1"; exit 0 ;; esac; done
      cat "$world/pane.lane"; exit 0 ;; esac; done
    exit 0 ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/fm-control.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$world/control.log"
[ ! -e "$world/control.fail" ] || { echo "error: control refused"; exit 1; }
[ ! -e "$world/control.picker" ] || { echo "error: task lane is blocked on a prompt: Claude background-task exit picker. Refusing to type Enter into it."; exit 1; }
pane="$world/pane.\$1"
case "\$2" in
  exit) printf 'zsh\n' > "\$pane" ;;
  relaunch)
    [ "\${3:-}" != --note-file ] || cat "\$4" >> "$world/control.log"
    printf 'claude\n' > "\$pane"
    ;;
esac
SH
  cat > "$fakebin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
cat "$world/crew-state" 2>/dev/null || echo 'state: paused · source: status-log · waiting'
SH
  chmod +x "$fakebin"/*
  start_agent "$world" lane 'read -r x'
  printf '%s\n' "$world"
}

# A fake agent process: a copy of bash named claude, so the process classifier
# reads it as a harness, running <script> with a stdin that never closes. Its
# pid becomes the pane's root pid for <name> (lane or sm1), replacing any
# earlier fake agent for that pane.
start_agent() {  # <world> <name> <script>
  local w=$1 name=$2 script=$3 pid
  mkdir -p "$w/agentbin"
  [ -x "$w/agentbin/claude" ] || cp "$(command -v bash)" "$w/agentbin/claude"
  [ -p "$w/agentin.$name" ] || mkfifo "$w/agentin.$name"
  if [ -s "$w/panepid.$name" ]; then pkill -P "$(cat "$w/panepid.$name")" 2>/dev/null || true; kill "$(cat "$w/panepid.$name")" 2>/dev/null || true; fi
  "$w/agentbin/claude" -c "$script" <>"$w/agentin.$name" >/dev/null 2>&1 &
  pid=$!
  printf '%s\n' "$pid" > "$w/panepid.$name"
  printf '%s\n' "$pid" >> "$TMP_ROOT/agent.pids"
}

reap_agents() {
  local pid
  while read -r pid; do
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
  done < "$TMP_ROOT/agent.pids" 2>/dev/null
}
trap 'reap_agents; fm_test_cleanup' EXIT

set_idle() {  # <world> <id>
  printf 'gen1\n' > "$1/state/$2.busy-gen"
  printf 'v1 gen=gen1 seq=3 state=idle source=claude-hook event=Stop ts=%s\n' "$(date +%s)" \
    > "$1/state/$2.busy-state"
}

run_idle() {  # <world> <args...>
  local world=$1
  shift
  PATH="$world/fakebin:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$world" \
    FM_IDLE_EXIT_HELPER_GRACE_SECS=1 \
    FM_STATE_OVERRIDE="$world/state" FM_CONFIG_OVERRIDE="$world/config" \
    FM_IDLE_EXIT_CONTROL_BIN="$world/fakebin/fm-control.sh" \
    FM_IDLE_EXIT_CREW_STATE_BIN="$world/fakebin/fm-crew-state.sh" \
    FM_IDLE_EXIT_INLINE=1 "$IDLE" "$@"
}

iso_at() {  # <epoch> -> YYYY-MM-DDTHH:MMZ
  TZ=UTC0 date -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || TZ=UTC0 date -r "$1" +%Y-%m-%dT%H:%MZ
}

control_log() { cat "$1/control.log" 2>/dev/null || true; }

# --- worker waits and their thresholds -----------------------------------------

test_decision_wait_threshold_both_sides() {
  local w now
  w=$(make_world decision-threshold)
  now=$(date +%s)
  printf 'needs-decision [at=%s]: pick A or B\n' $(( now - 4440 )) > "$w/state/lane.status"
  run_idle "$w" tick
  assert_not_contains "$(control_log "$w")" "lane exit" "a 74-minute decision wait must not stop its worker"
  assert_absent "$w/state/lane.idle-exit" "no record before the threshold"

  printf 'needs-decision [at=%s]: pick A or B\n' $(( now - 4560 )) > "$w/state/lane.status"
  run_idle "$w" tick
  assert_contains "$(control_log "$w")" "lane exit" "a 76-minute decision wait must stop its worker"
  assert_grep 'kind=worker' "$w/state/lane.idle-exit" "the stop must leave a worker record"
  assert_no_grep 'pending=' "$w/state/lane.idle-exit" "a confirmed stop must not stay pending"
  assert_grep 'wait=needs-decision' "$w/state/lane.idle-exit" "the record must name the wait"
  pass "worker: a decision wait stops its worker only past 75 minutes"
}

test_held_wait_threshold() {
  local w now
  w=$(make_world held-threshold)
  now=$(date +%s)
  printf 'captain-held [at=%s]: held for the captain\n' $(( now - 4440 )) > "$w/state/lane.status"
  run_idle "$w" tick
  assert_absent "$w/state/lane.idle-exit" "a 74-minute hold must not stop its worker"
  printf 'captain-held [at=%s]: held for the captain\n' $(( now - 4560 )) > "$w/state/lane.status"
  run_idle "$w" tick
  assert_present "$w/state/lane.idle-exit" "a 76-minute hold must stop its worker"
  pass "worker: a captain hold stops its worker only past 75 minutes"
}

test_dated_pause_threshold_both_sides() {
  local w now
  w=$(make_world pause-threshold)
  now=$(date +%s)
  printf 'paused [at=%s]: waiting on the vendor until %s\n' "$now" "$(iso_at $(( now + 4380 )))" > "$w/state/lane.status"
  run_idle "$w" tick
  assert_absent "$w/state/lane.idle-exit" "a pause ending within 75 minutes must not stop its worker"

  printf 'paused [at=%s]: waiting on the vendor until %s\n' "$now" "$(iso_at $(( now + 4680 )))" > "$w/state/lane.status"
  run_idle "$w" tick
  assert_present "$w/state/lane.idle-exit" "a pause ending more than 75 minutes away must stop its worker at once"
  assert_grep 'until=' "$w/state/lane.idle-exit" "a dated pause records its until time"
  pass "worker: a dated pause stops at once only when it ends more than 75 minutes away"
}

test_non_qualifying_and_guarded_waits_keep_running() {
  local w now
  w=$(make_world guarded)
  now=$(date +%s)
  printf 'paused [at=%s]: waiting on my test run\n' $(( now - 90000 )) > "$w/state/lane.status"
  run_idle "$w" tick
  assert_absent "$w/state/lane.idle-exit" "an undated pause must never stop its worker"

  printf 'blocked [at=%s]: stuck\n' $(( now - 90000 )) > "$w/state/lane.status"
  run_idle "$w" tick
  assert_absent "$w/state/lane.idle-exit" "a blocked worker is waiting on firstmate, not stopped"

  printf 'needs-decision [at=%s]: pick\n' $(( now - 90000 )) > "$w/state/lane.status"
  printf 'state: working · source: run-step · validating\n' > "$w/crew-state"
  run_idle "$w" tick
  assert_absent "$w/state/lane.idle-exit" "a lane whose current state is working must not be stopped"
  rm -f "$w/crew-state"

  printf 'v1 gen=gen1 seq=4 state=busy source=claude-hook event=UserPromptSubmit ts=%s\n' "$(date +%s)" > "$w/state/lane.busy-state"
  run_idle "$w" tick
  assert_absent "$w/state/lane.idle-exit" "a busy agent must not be stopped"
  set_idle "$w" lane

  mkdir -p "$w/state/lane.inbox"
  printf 'x\n' > "$w/state/lane.inbox/001.msg"
  run_idle "$w" tick
  assert_absent "$w/state/lane.idle-exit" "an agent with an unread instruction must not be stopped"
  rm -f "$w/state/lane.inbox/001.msg"

  printf 'workers=off\n' > "$w/config/idle-exit"
  run_idle "$w" tick
  assert_absent "$w/state/lane.idle-exit" "workers=off must stop no worker"
  rm -f "$w/config/idle-exit"

  printf 'worker_wait_secs=100000\n' > "$w/config/idle-exit"
  run_idle "$w" tick
  assert_absent "$w/state/lane.idle-exit" "a configured longer threshold must be honored"
  printf 'worker_wait_secs=60\n' > "$w/config/idle-exit"
  run_idle "$w" tick
  assert_present "$w/state/lane.idle-exit" "a configured shorter threshold must be honored"
  pass "worker: undated, blocked, working, busy, and unread lanes keep running; settings apply"
}

test_malformed_settings_reported_once_and_off() {
  local w now out
  w=$(make_world malformed)
  now=$(date +%s)
  printf 'needs-decision [at=%s]: pick\n' $(( now - 90000 )) > "$w/state/lane.status"
  printf 'worker_wait_secs=soon\n' > "$w/config/idle-exit"
  out=$(run_idle "$w" tick)
  assert_contains "$out" "worker_wait_secs=soon" "a malformed setting must be reported"
  assert_absent "$w/state/lane.idle-exit" "a malformed worker setting must turn worker exits off"
  out=$(run_idle "$w" tick)
  assert_equals "" "$out" "a malformed setting must be reported only once"
  pass "settings: a malformed value turns its behavior off and reports once"
}

# --- the stop/relaunch cycle -------------------------------------------------------

stop_worker_on_decision() {  # <world>
  local now
  now=$(date +%s)
  printf 'needs-decision [at=%s]: pick A or B\n' $(( now - 90000 )) > "$1/state/lane.status"
  run_idle "$1" tick
  assert_present "$1/state/lane.idle-exit" "setup: the worker should have stopped"
  : > "$1/control.log"
}

test_cycle_quiet_tick_keeps_worker_stopped() {
  local w out
  w=$(make_world cycle-quiet)
  stop_worker_on_decision "$w"
  out=$(run_idle "$w" tick)
  assert_equals "" "$out" "a quiet tick prints nothing"
  assert_not_contains "$(control_log "$w")" relaunch "an unchanged wait must not relaunch"
  assert_present "$w/state/lane.idle-exit" "an unchanged wait keeps the record"
  pass "cycle: an unchanged wait keeps the worker stopped"
}

test_cycle_answer_relaunches_with_note() {
  local w
  w=$(make_world cycle-answer)
  stop_worker_on_decision "$w"
  printf 'resolved [at=%s]: answered: A\n' "$(date +%s)" >> "$w/state/lane.status"
  run_idle "$w" tick
  assert_contains "$(control_log "$w")" "lane relaunch --note-file" "an answered decision must relaunch the worker"
  assert_contains "$(control_log "$w")" "declared wait changed or cleared" "the note must name the trigger"
  assert_contains "$(control_log "$w")" "pick A or B" "the note must name the wait"
  assert_absent "$w/state/lane.idle-exit" "a relaunch removes the record"
  assert_present "$w/state/.idle-exit-woke-lane" "a relaunch stamps the lane"
  : > "$w/control.log"
  printf 'needs-decision [at=%s]: next question\n' $(( $(date +%s) - 90000 )) >> "$w/state/lane.status"
  run_idle "$w" tick
  assert_not_contains "$(control_log "$w")" "lane exit" "a just-relaunched worker gets a fresh wait window before it stops again"
  pass "cycle: an answered decision relaunches the worker once, with a note"
}

test_cycle_until_time_relaunches() {
  local w now
  w=$(make_world cycle-until)
  now=$(date +%s)
  printf 'paused [at=%s]: vendor until %s\n' "$now" "$(iso_at $(( now + 9000 )))" > "$w/state/lane.status"
  run_idle "$w" tick
  assert_present "$w/state/lane.idle-exit" "setup: the dated pause should have stopped the worker"
  : > "$w/control.log"
  sed -i.bak "s/^until=.*/until=$(( now - 1 ))/" "$w/state/lane.idle-exit"
  run_idle "$w" tick
  assert_contains "$(control_log "$w")" "declared wait time arrived" "a reached until time must relaunch the worker"
  assert_absent "$w/state/lane.idle-exit" "the relaunch removes the record"
  : > "$w/control.log"
  run_idle "$w" tick
  assert_not_contains "$(control_log "$w")" "lane exit" "a pause declared before the relaunch must not stop the worker again"
  printf '%s\n' $(( now - 100 )) > "$w/state/.idle-exit-woke-lane"
  printf 'paused [at=%s]: vendor again until %s\n' "$now" "$(iso_at $(( now + 9000 )))" >> "$w/state/lane.status"
  run_idle "$w" tick
  assert_contains "$(control_log "$w")" "lane exit" "a pause declared after the relaunch stops the worker again"
  pass "cycle: a dated pause relaunches its worker when its time arrives, and only a new pause stops it again"
}

test_cycle_failed_relaunch_reports_and_holds() {
  local w out
  w=$(make_world cycle-fail)
  stop_worker_on_decision "$w"
  : > "$w/control.fail"
  printf 'resolved [at=%s]: answered\n' "$(date +%s)" >> "$w/state/lane.status"
  run_idle "$w" tick
  assert_grep 'relaunch_error=' "$w/state/lane.idle-exit" "a failed relaunch is recorded"
  out=$(run_idle "$w" tick)
  assert_contains "$out" "idle-exit wake lane failed" "a failed relaunch is reported on the next tick"
  : > "$w/control.log"
  out=$(run_idle "$w" tick)
  assert_not_contains "$(control_log "$w")" relaunch "a failed relaunch is not retried automatically"
  rm -f "$w/control.fail"
  run_idle "$w" wake lane --trigger "fixed by hand" >/dev/null
  assert_absent "$w/state/lane.idle-exit" "a manual wake relaunches and clears the record"
  pass "cycle: a failed relaunch is reported once, held, and recoverable by hand"
}

test_crew_state_reports_the_stop() {
  local w out
  w=$(make_world crew-state)
  stop_worker_on_decision "$w"
  out=$(PATH="$w/fakebin:$BASE_PATH" FM_HOME="$w" FM_STATE_OVERRIDE="$w/state" FM_CREW_STATE_NO_FORGE=1 \
    "$ROOT/bin/fm-crew-state.sh" lane 2>/dev/null | head -1)
  assert_contains "$out" "state: paused" "a stopped worker reads paused"
  assert_contains "$out" "source: idle-exit" "a stopped worker names the idle-exit record"
  pass "crew state: a stopped worker reads as a deliberate pause, not a dead pane"
}

test_steer_relaunches_stopped_worker() {
  local w out
  w=$(make_world steer)
  stop_worker_on_decision "$w"
  out=$(PATH="$w/fakebin:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$w" \
    FM_STATE_OVERRIDE="$w/state" FM_CONFIG_OVERRIDE="$w/config" \
    FM_IDLE_EXIT_CONTROL_BIN="$w/fakebin/fm-control.sh" \
    FM_IDLE_EXIT_CREW_STATE_BIN="$w/fakebin/fm-crew-state.sh" \
    "$ROOT/bin/fm-send.sh" lane "use option A" 2>&1) || fail "fm-send to a stopped worker must succeed: $out"
  assert_contains "$out" "relaunched it" "fm-send must say it relaunched the stopped worker"
  assert_contains "$(control_log "$w")" "lane relaunch --note-file" "the steer must relaunch the worker"
  assert_contains "$(control_log "$w")" "an instruction arrived in its inbox" "the note must name the steer"
  assert_absent "$w/state/lane.idle-exit" "the relaunch removes the record"
  find "$w/state/lane.inbox" -maxdepth 1 -name '*.msg' | grep -q . \
    || fail "the steer must stay durably recorded for the relaunched worker"
  pass "steer: a steer to a stopped worker relaunches it and keeps the message"
}

# --- secondmates --------------------------------------------------------------------

add_secondmate() {  # <world>
  local w=$1 home="$1/sm1home"
  mkdir -p "$home/state"
  printf 'sm1\n' > "$home/.fm-secondmate-home"
  fm_write_meta "$w/state/sm1.meta" \
    "window=fm:fm-sm1" "endpoint_task_id=sm1" "worktree=$home" "home=$home" \
    "kind=secondmate" "harness=claude"
  set_idle "$w" sm1
  printf 'claude\n' > "$w/pane.sm1"
  start_agent "$w" sm1 'read -r x'
  printf 'done [at=1]: ready\n' > "$w/state/sm1.status"
  fm_touch_epoch 1700000000 "$w/state/sm1.status"
}

test_secondmate_idle_threshold_both_sides() {
  local w now
  w=$(make_world sm-threshold)
  add_secondmate "$w"
  now=$(date +%s)
  run_idle "$w" tick
  assert_present "$w/state/.idle-exit-since-sm1" "the first idle observation is stamped"
  assert_absent "$w/state/sm1.idle-exit" "a just-idle mate must not stop"
  printf '%s\n' $(( now - 4440 )) > "$w/state/.idle-exit-since-sm1"
  run_idle "$w" tick
  assert_absent "$w/state/sm1.idle-exit" "a mate idle 74 minutes must not stop"
  printf '%s\n' $(( now - 4560 )) > "$w/state/.idle-exit-since-sm1"
  run_idle "$w" tick
  assert_contains "$(control_log "$w")" "sm1 exit" "a mate idle 76 minutes must stop"
  assert_grep 'kind=secondmate' "$w/state/sm1.idle-exit" "the stop leaves a secondmate record"
  pass "secondmate: an idle mate stops only past 75 minutes"
}

test_secondmate_with_work_keeps_running() {
  local w now
  w=$(make_world sm-work)
  add_secondmate "$w"
  now=$(date +%s)
  printf '%s\n' $(( now - 90000 )) > "$w/state/.idle-exit-since-sm1"
  printf 'kind=ship\n' > "$w/sm1home/state/child.meta"
  run_idle "$w" tick
  assert_absent "$w/state/sm1.idle-exit" "a mate with a child task must not stop"
  assert_absent "$w/state/.idle-exit-since-sm1" "work clears the idle stamp"
  rm -f "$w/sm1home/state/child.meta"
  printf '%s\n' $(( now - 90000 )) > "$w/state/.idle-exit-since-sm1"
  fm_touch_epoch "$now" "$w/state/sm1.status"
  run_idle "$w" tick
  assert_absent "$w/state/sm1.idle-exit" "a mate that reported recently must not stop"
  printf 'secondmates=off\n' > "$w/config/idle-exit"
  fm_touch_epoch 1700000000 "$w/state/sm1.status"
  run_idle "$w" tick
  assert_absent "$w/state/sm1.idle-exit" "secondmates=off must stop no secondmate"
  pass "secondmate: child work, a recent report, and the off switch keep a mate running"
}

stop_secondmate() {  # <world>
  printf '%s\n' $(( $(date +%s) - 90000 )) > "$1/state/.idle-exit-since-sm1"
  run_idle "$1" tick
  assert_present "$1/state/sm1.idle-exit" "setup: the mate should have stopped"
  : > "$1/control.log"
}

probe_sm1() {  # <world> -> FM_SM_LIVE_STATUS
  PATH="$1/fakebin:$BASE_PATH" TMUX='' FM_HOME="$1" STATE="$1/state" FM_ROOT="$ROOT" bash -c '
    . "$0/bin/fm-secondmate-liveness-lib.sh"
    fm_secondmate_liveness_probe "$STATE/sm1.meta" sm1 poll
    printf "%s\n" "$FM_SM_LIVE_STATUS"' "$ROOT"
}

test_liveness_leaves_deliberate_stop_down_and_relaunches_crash() {
  local w
  w=$(make_world sm-liveness)
  add_secondmate "$w"
  stop_secondmate "$w"
  assert_equals idle-exited "$(probe_sm1 "$w")" "the liveness probe must leave a deliberately stopped mate down"
  rm -f "$w/state/sm1.idle-exit"
  assert_equals relaunchable "$(probe_sm1 "$w")" "a dead mate with no record (a crash) must stay relaunchable"
  pass "liveness: a deliberate idle stop survives the probe while a crash still relaunches"
}

test_secondmate_routed_message_relaunches() {
  local w
  w=$(make_world sm-wake)
  add_secondmate "$w"
  stop_secondmate "$w"
  run_idle "$w" tick
  assert_not_contains "$(control_log "$w")" relaunch "a quiet tick keeps the mate stopped"
  mkdir -p "$w/state/sm1.inbox"
  printf 'x\n' > "$w/state/sm1.inbox/001.msg"
  run_idle "$w" tick
  assert_contains "$(control_log "$w")" "sm1 relaunch" "a routed message must relaunch the mate"
  assert_not_contains "$(control_log "$w")" "--note" "a secondmate relaunch keeps its charter untouched"
  assert_absent "$w/state/sm1.idle-exit" "the relaunch removes the record"
  pass "secondmate: a routed message relaunches a stopped mate"
}

test_secondmate_failed_relaunch_hands_back_to_liveness() {
  local w out
  w=$(make_world sm-wake-fail)
  add_secondmate "$w"
  stop_secondmate "$w"
  : > "$w/control.fail"
  printf 'row\n' > "$w/sm1home/state/.wake-queue"
  run_idle "$w" tick
  assert_absent "$w/state/sm1.idle-exit" "a failed mate relaunch drops the record"
  assert_equals relaunchable "$(probe_sm1 "$w")" "the liveness guarantee then relaunches the mate"
  out=$(run_idle "$w" tick)
  assert_contains "$out" "idle-exit wake sm1 failed" "the failure is reported"
  pass "secondmate: a failed relaunch hands the mate back to the liveness guarantee"
}

# --- what is running under the agent -------------------------------------------

long_wait() {  # <world>
  printf 'captain-held [at=%s]: held for the captain\n' $(( $(date +%s) - 4560 )) > "$1/state/lane.status"
}

test_worker_with_background_child_is_not_stopped() {
  local w
  w=$(make_world busy-child)
  long_wait "$w"
  # A test run the agent started after its session began: a sleep under its shell.
  start_agent "$w" lane 'sleep 2; sleep 600 & read -r x'
  sleep 3
  run_idle "$w" tick
  assert_not_contains "$(control_log "$w")" "lane exit" "a worker with a background child must not be stopped"
  assert_absent "$w/state/lane.idle-exit" "no record while the agent has a job running"
  run_idle "$w" exit lane && fail "a direct stop must refuse a worker with a background child"
  assert_not_contains "$(control_log "$w")" "lane exit" "a refused direct stop must not reach the lifecycle owner"
  pass "worker: a background child under the agent keeps a long wait from stopping it"
}

test_worker_without_child_is_stopped() {
  local w
  w=$(make_world no-child)
  long_wait "$w"
  run_idle "$w" tick
  assert_contains "$(control_log "$w")" "lane exit" "the same worker with no child is stopped"
  assert_present "$w/state/lane.idle-exit" "the stop leaves its record"
  pass "worker: a long wait with nothing under the agent still stops it"
}

test_session_helper_under_the_agent_does_not_count() {
  local w
  w=$(make_world helper-child)
  long_wait "$w"
  # Started with the session, like an MCP server: inside the grace window.
  start_agent "$w" lane 'sleep 600 & read -r x'
  sleep 3
  run_idle "$w" tick
  assert_contains "$(control_log "$w")" "lane exit" "a helper started with the session must not keep the worker running"
  pass "worker: a long-lived helper started with the session does not count as work"
}

test_unreadable_or_unclassified_tree_is_not_stopped() {
  local w stranger
  w=$(make_world unreadable-tree)
  long_wait "$w"
  rm -f "$w/panepid.lane"
  run_idle "$w" tick
  assert_not_contains "$(control_log "$w")" "lane exit" "an unreadable process tree must not stop the worker"
  assert_absent "$w/state/lane.idle-exit" "no record for an unreadable tree"
  sleep 600 &
  stranger=$!
  printf '%s\n' "$stranger" > "$w/panepid.lane"
  run_idle "$w" tick
  kill "$stranger" 2>/dev/null || true
  assert_not_contains "$(control_log "$w")" "lane exit" "a tree with no recognizable agent must not stop the worker"
  assert_absent "$w/state/lane.idle-exit" "no record for an unclassifiable tree"
  pass "worker: a process tree that cannot be read or classified reads as busy"
}

test_exit_picker_is_dismissed_and_leaves_no_record() {
  local w rc=0
  w=$(make_world picker)
  long_wait "$w"
  : > "$w/control.picker"
  printf 'Background work is running\n  ❯ 1. Exit and stop tasks\n    2. Cancel\nEnter to confirm · Esc to cancel\n' > "$w/screen.lane"
  run_idle "$w" exit lane >/dev/null 2>&1 || rc=$?
  assert_equals 3 "$rc" "a picker answer is a lane that no longer qualified"
  assert_absent "$w/state/lane.idle-exit" "no idle-exit record after the picker"
  assert_contains "$(cat "$w/keys.log" 2>/dev/null)" "Escape" "the picker is dismissed with Escape"
  assert_not_contains "$(cat "$w/keys.log" 2>/dev/null)" "Enter" "Enter is never pressed into the picker"
  run_idle "$w" tick
  assert_absent "$w/state/lane.idle-exit" "the worker keeps running"
  assert_not_contains "$(ls "$w/state")" ".idle-exit-report" "a busy picker is not a failure to report"
  pass "worker: the background-work exit picker is dismissed without choosing exit"
}

test_secondmate_with_background_child_is_not_stopped() {
  local w now
  w=$(make_world sm-busy-child)
  add_secondmate "$w"
  now=$(date +%s)
  start_agent "$w" sm1 'sleep 2; sleep 600 & read -r x'
  sleep 3
  printf '%s\n' $(( now - 4560 )) > "$w/state/.idle-exit-since-sm1"
  run_idle "$w" tick
  assert_absent "$w/state/sm1.idle-exit" "a mate with a background job under its agent must not stop"
  start_agent "$w" sm1 'read -r x'
  printf '%s\n' $(( now - 4560 )) > "$w/state/.idle-exit-since-sm1"
  run_idle "$w" tick
  assert_present "$w/state/sm1.idle-exit" "the same mate with nothing under it stops"
  pass "secondmate: its own background job under the agent keeps it running"
}

test_decision_wait_threshold_both_sides
test_held_wait_threshold
test_dated_pause_threshold_both_sides
test_non_qualifying_and_guarded_waits_keep_running
test_malformed_settings_reported_once_and_off
test_cycle_quiet_tick_keeps_worker_stopped
test_cycle_answer_relaunches_with_note
test_cycle_until_time_relaunches
test_cycle_failed_relaunch_reports_and_holds
test_crew_state_reports_the_stop
test_steer_relaunches_stopped_worker
test_secondmate_idle_threshold_both_sides
test_secondmate_with_work_keeps_running
test_liveness_leaves_deliberate_stop_down_and_relaunches_crash
test_secondmate_routed_message_relaunches
test_secondmate_failed_relaunch_hands_back_to_liveness
test_worker_with_background_child_is_not_stopped
test_worker_without_child_is_stopped
test_session_helper_under_the_agent_does_not_count
test_unreadable_or_unclassified_tree_is_not_stopped
test_exit_picker_is_dismissed_and_leaves_no_record
test_secondmate_with_background_child_is_not_stopped
