#!/usr/bin/env bash
# Cross-clone overlap check, called by fm-spawn.sh before a ship/scout dispatch.
#
# Firstmate serializes work by comparing a new task against its OWN in-flight tasks
# (state/<id>.meta, data/backlog.md). That is blind by construction: the captain also
# works repos directly, in their own clone, outside firstmate entirely. Dispatching a
# crewmate into a repo the captain is mid-change on produces a confident "no overlap"
# that is simply wrong.
#
# This script closes that gap. Given a project directory, it finds other clones of the
# same origin on this machine and reports whichever of them hold active local work:
# uncommitted changes, unpushed commits, or a commit inside the activity window.
#
# Usage: fm-overlap-check.sh <project-dir>
# Prints WARNING lines to stderr when overlap is found, nothing when clean.
# Advisory by default (always exits 0), matching fm-guard.sh: the supervisor reads the
# warning in tool output and decides. Set FM_OVERLAP_BLOCK=1 to exit 1 instead, which
# makes fm-spawn.sh refuse the dispatch.
#
# Environment:
#   FM_OVERLAP_CHECK=0          disable entirely (exit 0, silent)
#   FM_OVERLAP_BLOCK=1          exit 1 on overlap instead of warning only
#   FM_CLONE_ROOTS              colon-separated roots to scan for sibling clones;
#                               default is the parent of the firstmate home, since
#                               firstmate is normally cloned alongside the captain's repos
#   FM_OVERLAP_DEPTH            find maxdepth under each root (default 3)
#   FM_OVERLAP_ACTIVE_WINDOW    seconds; a commit newer than this counts as active
#                               (default 86400; 0 turns the recency signal off and
#                               leaves only uncommitted/unpushed work)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
DEPTH=${FM_OVERLAP_DEPTH:-3}
WINDOW=${FM_OVERLAP_ACTIVE_WINDOW:-86400}

[ "${FM_OVERLAP_CHECK:-1}" = 0 ] && exit 0

TARGET=${1:-}
[ -n "$TARGET" ] || { echo "usage: fm-overlap-check.sh <project-dir>" >&2; exit 2; }
[ -d "$TARGET" ] || exit 0
TARGET_ABS=$(cd "$TARGET" 2>/dev/null && pwd) || exit 0
git -C "$TARGET_ABS" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# Compare remotes by identity, not by string: git@host:owner/repo.git,
# https://host/owner/repo.git and ssh://git@host/owner/repo all name one repo.
normalize_remote() {
  local u=$1
  u=${u%.git}
  u=${u%/}
  u=${u#ssh://}
  u=${u#https://}
  u=${u#http://}
  u=${u#git://}
  u=${u#*@}
  u=${u/:/\/}
  printf '%s' "$u" | tr '[:upper:]' '[:lower:]'
}

TARGET_REMOTE=$(git -C "$TARGET_ABS" remote get-url origin 2>/dev/null || true)
# A repo with no origin (a local-only project) has no sibling clone to collide with.
[ -n "$TARGET_REMOTE" ] || exit 0
TARGET_ID=$(normalize_remote "$TARGET_REMOTE")
NAME=$(basename "$TARGET_ABS")

roots=${FM_CLONE_ROOTS:-$(dirname "$FM_HOME")}

# Report only work that is genuinely live: uncommitted changes, commits not yet pushed,
# or a commit inside the activity window. A clean, pushed, idle clone is not overlap.
describe_activity() {
  local repo=$1 dirty ahead branch last age details=""
  dirty=$(git -C "$repo" status --porcelain 2>/dev/null | grep -c . || true)
  branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
  ahead=$(git -C "$repo" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
  last=$(git -C "$repo" log -1 --format=%ct 2>/dev/null || echo 0)
  age=$(( $(date +%s) - last ))

  [ "${dirty:-0}" -gt 0 ] && details="$details ${dirty} uncommitted file(s),"
  [ "${ahead:-0}" -gt 0 ] && details="$details ${ahead} unpushed commit(s),"
  if [ "${last:-0}" -gt 0 ] && [ "$age" -lt "$WINDOW" ]; then
    details="$details last commit $(( age / 3600 ))h ago,"
  fi
  [ -n "$details" ] || return 1
  printf '%s [%s]:%s' "$repo" "$branch" "${details%,}"
}

found=0
IFS=':' read -r -a root_list <<< "$roots"
for root in "${root_list[@]}"; do
  [ -n "$root" ] && [ -d "$root" ] || continue
  while IFS= read -r gitpath; do
    repo=$(dirname "$gitpath")
    # Skip the project itself and every clone firstmate already owns - those are
    # covered by the normal in-flight bookkeeping this check exists to supplement.
    [ "$repo" = "$TARGET_ABS" ] && continue
    case "$repo/" in "$PROJECTS"/*) continue ;; esac
    remote=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
    [ -n "$remote" ] || continue
    [ "$(normalize_remote "$remote")" = "$TARGET_ID" ] || continue
    if line=$(describe_activity "$repo"); then
      [ "$found" -eq 0 ] && echo "WARNING: overlap risk in '$NAME' - another clone of the same repo has active local work:" >&2
      echo "  $line" >&2
      found=$((found + 1))
    fi
  done <<EOF
$(find "$root" -maxdepth "$DEPTH" -name .git -prune -print 2>/dev/null)
EOF
done

[ "$found" -eq 0 ] && exit 0

echo "Firstmate's blocked-by logic does not see work outside its own tasks. Confirm with the captain before dispatching into '$NAME'." >&2
[ "${FM_OVERLAP_BLOCK:-0}" = 1 ] && exit 1
exit 0
