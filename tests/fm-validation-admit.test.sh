#!/usr/bin/env bash
# Behavioral coverage for bin/fm-validation-admit.sh: the load and opt-in
# memory verdicts from faked host probes, unknown probes stepping aside, the
# config/validation-admission thresholds and their refusals, the bounded wait
# that re-judges after jittered sleeps and gives up deferred, usage errors,
# and a real-host smoke.
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

make_home() {  # <name> [config line...]
  local home="$TMP_ROOT/$1"
  shift
  mkdir -p "$home/config"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" > "$home/config/validation-admission"
  printf '%s\n' "$home"
}

run_admit() {  # <home> <fakebin> [args...]
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$BASE_PATH" FM_HOME="$home" "$ADMIT" "$@" 2>&1
}

test_load_verdicts() {
  local home fakebin out rc
  home=$(make_home load)
  fakebin=$(make_probes "$TMP_ROOT/p-low" 3.50 4 8)
  out=$(run_admit "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "load under cores"
  assert_equals 'validation-admit: admit reason=ok load1=3.50 cores=8 max_load1=8.00 mem_free_pct=4 min_mem_free_pct=0 waited_s=0' "$out" \
    "load under cores must admit, and low free memory must not defer by default"
  fakebin=$(make_probes "$TMP_ROOT/p-high" 8.00 60 8)
  out=$(run_admit "$home" "$fakebin"); rc=$?
  expect_code 75 "$rc" "load at cores"
  assert_contains "$out" 'validation-admit: defer reason=load load1=8.00 cores=8 max_load1=8.00' \
    "load at the core count must defer"
  [ ! -e "$fakebin/slept" ] || fail "a single judgement must not sleep"
  pass "load at or over the core count defers; under it admits; memory is off by default"
}

test_config_thresholds() {
  local home fakebin out rc
  home=$(make_home cfg '# stricter host' 'max-load-per-core 0.5' 'min-mem-free-pct 20   # opt in')
  fakebin=$(make_probes "$TMP_ROOT/p-cfg" 4.00 10 8)
  out=$(run_admit "$home" "$fakebin"); rc=$?
  expect_code 75 "$rc" "configured thresholds"
  assert_contains "$out" 'defer reason=load,memory load1=4.00 cores=8 max_load1=4.00 mem_free_pct=10 min_mem_free_pct=20' \
    "both configured thresholds must be judged and named"
  home=$(make_home cfg-loose 'max-load-per-core 1.5')
  out=$(run_admit "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "looser load threshold"
  assert_contains "$out" 'admit reason=ok load1=4.00 cores=8 max_load1=12.00' "a looser ratio must raise the load ceiling"
  pass "config/validation-admission sets the load ratio and the opt-in memory floor"
}

test_config_refusals() {
  local fakebin line home out rc i=0
  fakebin=$(make_probes "$TMP_ROOT/p-bad" 1.00 50 8)
  for line in 'max-load-per-core 0' 'max-load-per-core abc' 'max-load-per-core 1.' 'min-mem-free-pct 101' \
    'min-mem-free-pct 5%' 'max-load-per-core' 'max-load-per-core 1 2' 'max-load 1' 'max-load-per-core *'; do
    i=$((i + 1))
    home=$(make_home "bad-$i" '' "$line")
    out=$(run_admit "$home" "$fakebin"); rc=$?
    expect_code 1 "$rc" "malformed line: $line"
    assert_contains "$out" 'config/validation-admission line 2:' "the refusal must name the malformed line for: $line"
    case "$out" in *"validation-admit: admit"*|*"validation-admit: defer"*) fail "a malformed config must not judge: $line" ;; esac
  done
  home=$(make_home dup 'max-load-per-core 1' 'max-load-per-core 2')
  out=$(run_admit "$home" "$fakebin"); rc=$?
  expect_code 1 "$rc" "repeated key"
  assert_contains "$out" "line 2: 'max-load-per-core' repeats" "a repeated key must be refused"
  pass "a malformed or repeated config line is refused by line number, never guessed"
}

test_unknown_probes_step_aside() {
  local home fakebin out rc
  home=$(make_home unknown 'min-mem-free-pct 50')
  fakebin=$(make_probes "$TMP_ROOT/p-unknown" '' '' '')
  out=$(run_admit "$home" "$fakebin"); rc=$?
  expect_code 0 "$rc" "no probes"
  assert_equals 'validation-admit: admit reason=ok load1=unknown cores=unknown max_load1=unknown mem_free_pct=unknown min_mem_free_pct=50 waited_s=0' "$out" \
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
  # An initial 0..5 s jitter nap, then two deferred naps of 10 plus 0..5 s.
  awk 'NR==1 && ($1 < 0 || $1 > 5) {bad=1} NR>1 && ($1 < 10 || $1 > 15) {bad=1} END {exit bad}' "$fakebin/slept" ||
    fail "naps must be an initial 0..interval/2 jitter, then interval plus 0..interval/2: $(tr '\n' ' ' < "$fakebin/slept")"
  [ "$(grep -c . "$fakebin/slept")" -le 3 ] || fail "the wait must not nap after admitting"
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
test_config_thresholds
test_config_refusals
test_unknown_probes_step_aside
test_wait_rejudges_until_admitted
test_wait_gives_up_deferred
test_usage_errors
test_real_host_smoke

echo '# all fm-validation-admit tests passed'
