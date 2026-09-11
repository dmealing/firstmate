#!/usr/bin/env bash
# Behavior tests for fm-overlap-check.sh: detecting active local work in another clone
# of the same repo, which firstmate's own in-flight bookkeeping cannot see.
# Every test builds throwaway git repos under a temp root; nothing touches the fleet.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/bin/fm-overlap-check.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-overlap.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# A self-contained repo with one commit and an explicit origin URL.
make_repo() {
  local path=$1 remote=$2
  mkdir -p "$path"
  git -C "$path" init -q
  git -C "$path" config user.email fm@example.invalid
  git -C "$path" config user.name firstmate-test
  git -C "$path" config commit.gpgsign false
  echo seed > "$path/file.txt"
  git -C "$path" add file.txt
  git -C "$path" commit -qm seed
  [ -n "$remote" ] && git -C "$path" remote add origin "$remote"
  return 0
}

# ACTIVE_WINDOW=0 switches the recency signal off, so each test isolates the one signal
# it is about instead of always tripping on "seed commit was made moments ago".
run_check() {
  local target=$1 root=$2
  shift 2
  env "$@" FM_CLONE_ROOTS="$root" FM_OVERLAP_ACTIVE_WINDOW=0 FM_PROJECTS_OVERRIDE="$TMP_ROOT/fleet-projects" \
    "$CHECK" "$target" 2>&1
}

test_clean_sibling_is_silent() {
  local d="$TMP_ROOT/clean"
  make_repo "$d/fleet/app" git@example.invalid:acme/app.git
  make_repo "$d/own/app" git@example.invalid:acme/app.git
  local out
  out=$(run_check "$d/fleet/app" "$d/own")
  [ -z "$out" ] || fail "clean sibling clone should produce no output, got: $out"
  pass "a clean, idle sibling clone is not reported as overlap"
}

test_dirty_sibling_is_reported() {
  local d="$TMP_ROOT/dirty"
  make_repo "$d/fleet/app" git@example.invalid:acme/app.git
  make_repo "$d/own/app" git@example.invalid:acme/app.git
  echo wip > "$d/own/app/scratch.txt"
  local out
  out=$(run_check "$d/fleet/app" "$d/own")
  printf '%s\n' "$out" | grep -F 'overlap risk' >/dev/null \
    || fail "uncommitted work in a sibling clone was not reported: $out"
  printf '%s\n' "$out" | grep -F "$d/own/app" >/dev/null \
    || fail "warning did not name the overlapping clone path: $out"
  printf '%s\n' "$out" | grep -F 'uncommitted file(s)' >/dev/null \
    || fail "warning did not describe the uncommitted change: $out"
  pass "uncommitted work in a sibling clone is reported"
}

test_different_repo_is_ignored() {
  local d="$TMP_ROOT/other"
  make_repo "$d/fleet/app" git@example.invalid:acme/app.git
  make_repo "$d/own/unrelated" git@example.invalid:acme/unrelated.git
  echo wip > "$d/own/unrelated/scratch.txt"
  local out
  out=$(run_check "$d/fleet/app" "$d/own")
  [ -z "$out" ] || fail "a dirty clone of a DIFFERENT repo must not be reported, got: $out"
  pass "clones of other repos are ignored"
}

test_remote_url_forms_match() {
  local d="$TMP_ROOT/urlforms"
  make_repo "$d/fleet/app" git@example.invalid:acme/app.git
  make_repo "$d/own/app" https://example.invalid/acme/app
  echo wip > "$d/own/app/scratch.txt"
  local out
  out=$(run_check "$d/fleet/app" "$d/own")
  printf '%s\n' "$out" | grep -F 'overlap risk' >/dev/null \
    || fail "ssh and https forms of the same origin were not matched: $out"
  pass "ssh, https and .git-suffixed remote forms resolve to the same repo"
}

test_fleet_clones_are_skipped() {
  local d="$TMP_ROOT/fleetskip"
  mkdir -p "$TMP_ROOT/fleet-projects"
  make_repo "$d/fleet/app" git@example.invalid:acme/app.git
  make_repo "$TMP_ROOT/fleet-projects/app-two" git@example.invalid:acme/app.git
  echo wip > "$TMP_ROOT/fleet-projects/app-two/scratch.txt"
  local out
  out=$(run_check "$d/fleet/app" "$TMP_ROOT/fleet-projects")
  [ -z "$out" ] || fail "clones under projects/ are firstmate's own and must be skipped, got: $out"
  pass "clones inside the fleet projects dir are skipped"
}

test_unpushed_commits_are_reported() {
  local d="$TMP_ROOT/unpushed"
  make_repo "$d/fleet/app" git@example.invalid:acme/app.git
  make_repo "$d/origin/app" ''
  git -C "$d/origin/app" config receive.denyCurrentBranch ignore
  git -C "$d/own" init -q 2>/dev/null || true
  rm -rf "$d/own"
  mkdir -p "$d/own"
  git -C "$d/own" clone -q "$d/origin/app" app
  git -C "$d/own/app" config user.email fm@example.invalid
  git -C "$d/own/app" config user.name firstmate-test
  git -C "$d/own/app" config commit.gpgsign false
  git -C "$d/own/app" remote set-url origin git@example.invalid:acme/app.git
  echo more > "$d/own/app/next.txt"
  git -C "$d/own/app" add next.txt
  git -C "$d/own/app" commit -qm next
  local out
  out=$(run_check "$d/fleet/app" "$d/own")
  printf '%s\n' "$out" | grep -F 'unpushed commit(s)' >/dev/null \
    || fail "commits not yet on the remote were not reported: $out"
  pass "unpushed commits in a sibling clone are reported"
}

test_recent_commit_counts_as_active() {
  local d="$TMP_ROOT/recent"
  make_repo "$d/fleet/app" git@example.invalid:acme/app.git
  make_repo "$d/own/app" git@example.invalid:acme/app.git
  local out
  # Default window (24h): the seed commit was made moments ago, so it is active work.
  out=$(env FM_CLONE_ROOTS="$d/own" FM_PROJECTS_OVERRIDE="$TMP_ROOT/fleet-projects" \
    "$CHECK" "$d/fleet/app" 2>&1)
  printf '%s\n' "$out" | grep -F 'last commit' >/dev/null \
    || fail "a commit inside the activity window was not treated as active: $out"
  pass "a commit inside the activity window counts as active work"
}

test_block_mode_exits_nonzero() {
  local d="$TMP_ROOT/block"
  make_repo "$d/fleet/app" git@example.invalid:acme/app.git
  make_repo "$d/own/app" git@example.invalid:acme/app.git
  echo wip > "$d/own/app/scratch.txt"
  local status
  run_check "$d/fleet/app" "$d/own" FM_OVERLAP_BLOCK=1 >/dev/null 2>&1
  status=$?
  [ "$status" -eq 1 ] || fail "FM_OVERLAP_BLOCK=1 should exit 1 on overlap, got $status"
  run_check "$d/fleet/app" "$d/own" >/dev/null 2>&1
  status=$?
  [ "$status" -eq 0 ] || fail "advisory mode should always exit 0, got $status"
  pass "FM_OVERLAP_BLOCK=1 exits non-zero; advisory mode exits 0"
}

test_disabled_check_is_silent() {
  local d="$TMP_ROOT/disabled"
  make_repo "$d/fleet/app" git@example.invalid:acme/app.git
  make_repo "$d/own/app" git@example.invalid:acme/app.git
  echo wip > "$d/own/app/scratch.txt"
  local out
  out=$(run_check "$d/fleet/app" "$d/own" FM_OVERLAP_CHECK=0)
  [ -z "$out" ] || fail "FM_OVERLAP_CHECK=0 should silence the check, got: $out"
  pass "FM_OVERLAP_CHECK=0 disables the check"
}

test_no_origin_is_silent() {
  local d="$TMP_ROOT/noorigin"
  make_repo "$d/fleet/app" ''
  make_repo "$d/own/app" git@example.invalid:acme/app.git
  echo wip > "$d/own/app/scratch.txt"
  local out
  out=$(run_check "$d/fleet/app" "$d/own")
  [ -z "$out" ] || fail "a local-only project has no sibling to collide with, got: $out"
  pass "a project with no origin is silently skipped"
}

test_clean_sibling_is_silent
test_dirty_sibling_is_reported
test_different_repo_is_ignored
test_remote_url_forms_match
test_fleet_clones_are_skipped
test_unpushed_commits_are_reported
test_recent_commit_counts_as_active
test_block_mode_exits_nonzero
test_disabled_check_is_silent
test_no_origin_is_silent
