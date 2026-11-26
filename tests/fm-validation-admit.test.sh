#!/usr/bin/env bash
# Behavioral coverage for bin/fm-validation-admit.sh: the load verdict from
# faked host probes, unknown probes stepping aside, the bounded wait that
# re-judges after jittered sleeps and gives up deferred, the locked
# machine-wide start spacing, usage errors, and a real-host smoke.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-validation-admit)
ADMIT="$ROOT/bin/fm-validation-admit.sh"

# make_probes <dir> <load1|file> <mem-free-pct> <cores>: fake Darwin probes.
# An empty value makes that probe fail. A load1 naming an existing file reads
# one load per call from it (the last line repeats), so a wait can see load
# fall. The fake sleep records each requested duration and returns at once.
make_probes() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  printf '#!/usr/bin/env bash\necho Darwin\n' > "$fakebin/uname"
  cat > "$fakebin/sysctl" <<SH
#!/usr/bin/env bash
case "\$2" in
  vm.loadavg)
    if [ -f "$2" ]; then
      n=\$(cat "$fakebin/load-calls" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$fakebin/load-calls"
      v=\$(sed -n "\${n}p" "$2"); [ -n "\$v" ] || v=\$(tail -1 "$2")
      echo "{ \$v 1.00 1.00 }"
    elif [ -n "$2" ]; then echo "{ $2 1.00 1.00 }"; fi ;;
  kern.memorystatus_level) [ -n "$3" ] && echo "$3" ;;
  hw.logicalcpu) [ -n "$4" ] && echo "$4" ;;
esac
SH
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/getconf"
  # shellcheck disable=SC2016  # $1 belongs to the generated stub, not this shell
  printf '#!/usr/bin/env bash\necho "$1" >> "%s/slept"\n' "$fakebin" > "$fakebin/sleep"
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home"
  printf '%s\n' "$home"
}

run_admit() {  # <home> <fakebin> [args...]
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$BASE_PATH" FM_VALIDATION_START_FILE="${FM_VALIDATION_START_FILE:-$home/start-slot}" FM_HOME="$home" "$ADMIT" "$@" 2>&1
}

test_load_verdicts() {
  local home fakebin out rc
  home=$(make_home load)
  fakebin=$(make_probes "$TMP_ROOT/p-low" 3.50 4 8)
  out=$(run_admit "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "load under cores"
  assert_equals 'validation-admit: admit reason=ok load1=3.50 cores=8 max_load1=8.00 waited_s=0' "$out" \
    "load under cores must admit, and low free memory must not defer"
  fakebin=$(make_probes "$TMP_ROOT/p-high" 8.00 60 8)
  out=$(run_admit "$home" "$fakebin"); rc=$?
  expect_code 75 "$rc" "load at cores"
  assert_contains "$out" 'validation-admit: defer reason=load load1=8.00 cores=8 max_load1=8.00' \
    "load at the core count must defer"
  [ ! -e "$fakebin/slept" ] || fail "a single judgement must not sleep"
  pass "load at or over the core count defers; under it admits; memory is not judged"
}

test_unknown_probes_step_aside() {
  local home fakebin out rc
  home=$(make_home unknown)
  fakebin=$(make_probes "$TMP_ROOT/p-unknown" '' '' '')
  out=$(run_admit "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "no probes"
  assert_equals 'validation-admit: admit reason=ok load1=unknown cores=unknown max_load1=unknown waited_s=0' "$out" \
    "an unprobeable host must admit rather than strand a start"
  pass "unreadable probes are not judged, so an unprobeable host admits"
}

test_wait_rejudges_until_admitted() {
  local home fakebin out rc loads="$TMP_ROOT/loads-falling" calls
  home=$(make_home wait)
  printf '%s\n' 9.00 9.50 3.00 > "$loads"
  fakebin=$(make_probes "$TMP_ROOT/p-wait" "$loads" 50 8)
  out=$(run_admit "$home" "$fakebin" --wait 600 --interval 10); rc=$?
  expect_code 0 "$rc" "load falls during the wait"
  assert_contains "$out" 'validation-admit: admit reason=ok load1=3.00 cores=8' "the wait must admit once load falls"
  calls=$(cat "$fakebin/load-calls")
  assert_equals 3 "$calls" "the wait must judge until the first admitting sample and then stop"
  # Spec, interval 10: an initial 0..5 s jitter nap (skipped when it draws 0),
  # then one 10..15 s nap per deferral; two deferrals precede the admission.
  awk '$1 < 0 || $1 > 15 || ($1 > 5 && $1 < 10) {bad=1} $1 >= 10 {long++} END {exit bad || long != 2 || NR > 3}' "$fakebin/slept" ||
    fail "naps must be at most one 0..interval/2 jitter and exactly two interval plus 0..interval/2: $(tr '\n' ' ' < "$fakebin/slept")"
  pass "--wait re-judges after jittered naps and admits as soon as load falls"
}

test_wait_gives_up_deferred() {
  local home fakebin out rc total
  home=$(make_home wait-out)
  fakebin=$(make_probes "$TMP_ROOT/p-wait-out" 20.00 50 8)
  out=$(run_admit "$home" "$fakebin" --wait 25 --interval 0); rc=$?
  expect_code 75 "$rc" "load never falls"
  assert_contains "$out" 'validation-admit: defer reason=load load1=20.00' "a wait that runs out must report the deferral"
  assert_contains "$out" 'waited_s=25' "the summed wait must stop exactly at the bound"
  total=$(awk '{s += $1} END {print s}' "$fakebin/slept")
  assert_equals 25 "$total" "the naps must sum to the bound and never exceed it"
  pass "--wait gives up deferred once its summed naps reach the bound, even at interval 0"
}

# admit_spaced <start-file> <home> <fakebin> <wait>: one admission with a 40 s
# start window and no jitter; prints the whole-second spacing nap it recorded
# (0 for none). Sub-second sleeps are the lock helper's contention polls.
admit_spaced() {
  local out rc nap
  rm -f "$3/slept"
  out=$(FM_VALIDATION_START_FILE="$1" FM_VALIDATION_START_SPACING=40 run_admit "$2" "$3" --wait "$4" --interval 0); rc=$?
  expect_code 0 "$rc" "spaced admission"
  nap=$(grep -m1 -x '[0-9][0-9]*' "$3/slept" 2>/dev/null)
  nap=${nap:-0}
  assert_contains "$out" "waited_s=$nap" "the spacing wait must count in waited_s"
  printf '%s\n' "$nap"
}

# in_window <got> <want> <what>: the clock may tick up to 2 s between runs.
in_window() {
  [ "$1" -le "$2" ] && [ "$1" -ge $(($2 - 2)) ] || fail "$3 must wait about $2 s, slept $1"
}

test_start_spacing() {
  local home fakebin start="$TMP_ROOT/start-slot" nap
  home=$(make_home spacing)
  fakebin=$(make_probes "$TMP_ROOT/p-spacing" 1.00 50 8)
  nap=$(admit_spaced "$start" "$home" "$fakebin" 600)
  assert_equals 0 "$nap" "the first admission must not wait"
  nap=$(admit_spaced "$start" "$home" "$fakebin" 600); in_window "$nap" 40 "the second admission"
  nap=$(admit_spaced "$start" "$home" "$fakebin" 600); in_window "$nap" 80 "the third admission"
  nap=$(admit_spaced "$start" "$home" "$fakebin" 600); in_window "$nap" 120 "the fourth admission"
  nap=$(admit_spaced "$start" "$home" "$fakebin" 130)
  assert_equals 130 "$nap" "a reservation past the remaining wait must clamp to the wait, never reset"
  nap=$(admit_spaced "$start" "$home" "$fakebin" 10)
  assert_equals 0 "$nap" "a record past a shorter wait must not block that run"
  [ ! -e "$start.lock" ] || fail "the start lock must be released after each reservation"
  pass "--wait spaces back-to-back admissions one window apart, chained and bounded by --wait"
}

test_start_spacing_skips_a_held_lock() {
  local home fakebin start="$TMP_ROOT/start-locked" holder nap
  home=$(make_home spacing-locked)
  fakebin=$(make_probes "$TMP_ROOT/p-spacing-locked" 1.00 50 8)
  printf '%s\n' $(( $(date +%s) + 30 )) > "$start"
  sleep 600 & holder=$!
  mkdir "$start.lock"
  printf '%s\n' "$holder" > "$start.lock/pid"
  nap=$(admit_spaced "$start" "$home" "$fakebin" 600)
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  assert_equals 0 "$nap" "a start lock held past its wait must skip spacing, not read the record unlocked"
  pass "a start lock that cannot be taken skips spacing and admits"
}

test_start_spacing_never_blocks_on_an_unreadable_record() {
  local home fakebin out rc start="$TMP_ROOT/start-bad" future
  home=$(make_home spacing-bad)
  fakebin=$(make_probes "$TMP_ROOT/p-spacing-bad" 1.00 50 8)
  mkdir -p "$start"
  out=$(FM_VALIDATION_START_FILE="$start" FM_VALIDATION_START_SPACING=40 run_admit "$home" "$fakebin" --wait 600 --interval 0); rc=$?
  expect_code 0 "$rc" "start record is a directory"
  [ ! -e "$fakebin/slept" ] || fail "an unreadable start record must not wait"
  start="$TMP_ROOT/start-garbage"
  printf 'not a time\n' > "$start"
  out=$(FM_VALIDATION_START_FILE="$start" FM_VALIDATION_START_SPACING=40 run_admit "$home" "$fakebin" --wait 600 --interval 0); rc=$?
  expect_code 0 "$rc" "start record is garbage"
  [ ! -e "$fakebin/slept" ] || fail "a malformed start record must not wait"
  future=$(( $(date +%s) + 100000 ))
  printf '%s\n' "$future" > "$start"
  out=$(FM_VALIDATION_START_FILE="$start" FM_VALIDATION_START_SPACING=40 run_admit "$home" "$fakebin" --wait 600 --interval 0); rc=$?
  expect_code 0 "$rc" "start record is far in the future"
  [ ! -e "$fakebin/slept" ] || fail "a future-dated start record must not wait"
  assert_contains "$out" 'validation-admit: admit' "an unusable start record must admit"
  pass "a missing, unreadable, malformed, or future-dated start record never blocks a run"
}

test_usage_errors() {
  local fakebin arg rc
  fakebin=$(make_probes "$TMP_ROOT/p-usage" 1.00 50 8)
  for arg in '--wait' '--wait x' '--interval -1' '--bogus'; do
    # shellcheck disable=SC2086
    run_admit "$TMP_ROOT/usage-home" "$fakebin" $arg >/dev/null; rc=$?
    expect_code 2 "$rc" "usage: $arg"
  done
  run_admit "$TMP_ROOT/usage-home" "$fakebin" --help | grep -q 'validation-admit' || fail "--help must print the header"
  pass "bad flags are usage errors and --help prints the contract"
}

test_real_host_smoke() {
  local out rc
  out=$(FM_HOME="$TMP_ROOT/real-home" "$ADMIT"); rc=$?
  case "$rc" in 0|75) ;; *) fail "the real host must admit or defer, got exit $rc: $out" ;; esac
  printf '%s\n' "$out" | grep -Eq '^validation-admit: (admit|defer) reason=[a-z,]+ load1=([0-9.]+|unknown) ' ||
    fail "the real host report must be well formed: $out"
  pass "real host probes produce a well-formed verdict"
}

test_load_verdicts
test_unknown_probes_step_aside
test_wait_rejudges_until_admitted
test_wait_gives_up_deferred
test_start_spacing
test_start_spacing_skips_a_held_lock
test_start_spacing_never_blocks_on_an_unreadable_record
test_usage_errors
test_real_host_smoke

echo '# all fm-validation-admit tests passed'
