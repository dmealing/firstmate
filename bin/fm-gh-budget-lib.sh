#!/usr/bin/env bash
# Fleet-wide GitHub budget for background polls, shared by every firstmate home
# on this machine, plus the conditional-read cache those polls reuse.
#
# Every home on one machine normally runs gh as one GitHub account, so they
# share one rate limit. This library keeps that shared state in one directory,
# FM_GH_STATE_DIR (default ${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/github),
# created mode 0700. Set FM_GH_STATE_DIR to separate homes that use different
# accounts. Nothing here contacts GitHub.
#
# Admission (fm_gh_budget_admit <resource> [cost]) refuses a background read
# when any of these holds (the last only when a cost is given):
#   - a rate-limit response set a back-off for that resource (or for every
#     resource, after a secondary rate limit) that has not expired;
#   - the last response GitHub sent for that resource reported
#     X-RateLimit-Remaining below FM_GH_POLL_RESERVE (default 1000) and its
#     window has not reset, leaving that reserve to interactive work;
#   - core reads this machine's polls were charged in the last hour, plus cost,
#     would exceed FM_GH_POLL_HOURLY (default 1000).
# A refused read is budget refusal: the caller leaves its records untouched and
# tries again on a later poll. Resources are core and graphql.
# fm_gh_budget_charge [n] charges n core reads to the hourly ledger: one append
# per read to a per-minute bucket file, older buckets pruned, so no lock is
# needed. A 304 Not Modified response is never charged, because GitHub does not
# count it against the rate limit.
# fm_gh_response_note <resource> <stdout-file> <stderr-file> records what one
# finished gh call taught: the X-RateLimit headers of an --include response,
# and a rate-limit response (HTTP 429, a 403 that carries Retry-After or whose
# remaining count is 0, or gh's rate-limit error text on stderr; a response
# body never counts). A rate limit sets the back-off until Retry-After, else
# the reported reset, else FM_GH_BACKOFF seconds (default 300) from now, and
# returns 2 so the caller backs off instead of retrying. A secondary rate
# limit backs off every resource.
# fm_gh_cache_get <request> <etag-var> <body-file> and fm_gh_cache_put
# <request> <etag> <body-file> keep one entry per request string (an ETag line,
# then the body), published by rename so a reader sees one whole entry.
# Admission prunes entries not rewritten for more than seven days, at most once
# an hour; a pruned entry costs one ordinary read.
# fm_gh_response_split <raw> <headers-file> <body-file> splits gh api --include
# output; fm_gh_header <headers-file> <name> prints one header's value.
# When the state directory cannot be created, admission admits and charging,
# back-off and caching do nothing, so polls keep working without the budget.

fm_gh_state_dir() {
  local dir=${FM_GH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/firstmate/github}
  [ -d "$dir" ] || (umask 077 && mkdir -p -- "$dir/cache" "$dir/ledger") 2>/dev/null || return 1
  [ -d "$dir/cache" ] || mkdir -p -- "$dir/cache" 2>/dev/null || return 1
  [ -d "$dir/ledger" ] || mkdir -p -- "$dir/ledger" 2>/dev/null || return 1
  printf '%s\n' "$dir"
}

_fm_gh_num() { # value default: a non-negative integer or the default
  case "$1" in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

_fm_gh_publish() { # dir name content: write one small file by rename
  local tmp
  tmp=$(mktemp "$1/.$2.XXXXXX" 2>/dev/null) || return 0
  if ! { printf '%s\n' "$3" > "$tmp" && mv -f -- "$tmp" "$1/$2" 2>/dev/null; }; then rm -f -- "$tmp"; fi
}

fm_gh_backoff_until() { # resource epoch: back off that resource (or all) until epoch
  local dir current=0
  dir=$(fm_gh_state_dir) || return 0
  [ ! -f "$dir/backoff-$1" ] || IFS= read -r current < "$dir/backoff-$1" || true
  current=$(_fm_gh_num "$current" 0)
  [ "$2" -le "$current" ] || _fm_gh_publish "$dir" "backoff-$1" "$2"
}

fm_gh_budget_used() { # -> core reads charged in the last hour
  local dir now bucket file name total=0 count
  dir=$(fm_gh_state_dir) || { printf '0\n'; return 0; }
  now=$(date +%s); bucket=$((now / 60))
  for file in "$dir"/ledger/*; do
    [ -f "$file" ] || continue
    name=${file##*/}
    case "$name" in ''|*[!0-9]*) continue ;; esac
    if [ "$name" -le $((bucket - 60)) ]; then
      rm -f -- "$file"
      continue
    fi
    count=$(wc -l < "$file" 2>/dev/null) || count=0
    total=$((total + count))
  done
  printf '%s\n' "$total"
}

fm_gh_budget_charge() { # [n]
  local dir n=${1:-1} now
  dir=$(fm_gh_state_dir) || return 0
  now=$(date +%s)
  while [ "$n" -gt 0 ]; do
    printf '1\n' >> "$dir/ledger/$((now / 60))" 2>/dev/null || return 0
    n=$((n - 1))
  done
}

fm_gh_budget_admit() { # resource [cost]: 0 admits, 1 refuses; a cost checks the hourly cap
  local resource=$1 cost=${2:-} dir now until name remaining=0 limit reset=0 reserve cap used
  dir=$(fm_gh_state_dir) || return 0
  now=$(date +%s)
  fm_gh_cache_prune "$dir" "$now"
  for name in "backoff-$resource" backoff-all; do
    until=0
    [ ! -f "$dir/$name" ] || IFS= read -r until < "$dir/$name" || true
    until=$(_fm_gh_num "$until" 0)
    if [ "$until" -gt "$now" ]; then
      return 1
    fi
  done
  reserve=$(_fm_gh_num "${FM_GH_POLL_RESERVE:-}" 1000)
  if [ -f "$dir/rate-$resource" ] && read -r remaining limit reset < "$dir/rate-$resource"; then
    remaining=$(_fm_gh_num "$remaining" "$reserve"); reset=$(_fm_gh_num "$reset" 0)
    if [ "$reset" -gt "$now" ] && [ "$remaining" -lt "$reserve" ]; then
      return 1
    fi
  fi
  [ "$resource" = core ] && [ -n "$cost" ] || return 0
  cap=$(_fm_gh_num "${FM_GH_POLL_HOURLY:-}" 1000)
  used=$(fm_gh_budget_used)
  if [ $((used + cost)) -gt "$cap" ]; then
    return 1
  fi
}

fm_gh_response_split() { # raw headers-out body-out: split gh api --include output
  awk -v h="$2" -v b="$3" '
    BEGIN { printf "" > h; printf "" > b }
    !body { line = $0; sub(/\r$/, "", line); if (line == "") { body = 1; next } print line > h; next }
    { print > b }' "$1"
}

fm_gh_header() { # headers-file name: print the first value of one header
  awk -v want="$2" 'BEGIN { want = tolower(want) }
    { i = index($0, ":"); if (i && tolower(substr($0, 1, i - 1)) == want) { v = substr($0, i + 1); sub(/^[ \t]+/, "", v); print v; exit } }' "$1"
}

fm_gh_response_status() { # headers-file: the numeric HTTP status of an --include response
  sed -n '1s/^HTTP\/[0-9.]* \([0-9][0-9][0-9]\).*/\1/p' "$1"
}

fm_gh_response_note() { # resource stdout-file stderr-file: 0 ordinary, 2 rate limited
  local resource=$1 out=$2 err=$3 dir now hdr status remaining limit reset rlres retry until scope
  dir=$(fm_gh_state_dir) || dir=
  now=$(date +%s)
  hdr=$(mktemp "${TMPDIR:-/tmp}/fm-gh-hdr.XXXXXX") || return 0
  status=
  if head -c 5 "$out" 2>/dev/null | grep -q '^HTTP/'; then
    fm_gh_response_split "$out" "$hdr" /dev/null
    status=$(fm_gh_response_status "$hdr")
  fi
  remaining=$(fm_gh_header "$hdr" X-RateLimit-Remaining)
  limit=$(fm_gh_header "$hdr" X-RateLimit-Limit)
  reset=$(fm_gh_header "$hdr" X-RateLimit-Reset)
  rlres=$(fm_gh_header "$hdr" X-RateLimit-Resource)
  retry=$(fm_gh_header "$hdr" Retry-After)
  rm -f -- "$hdr"
  case "$rlres" in core|graphql) resource=$rlres ;; esac
  if [ -n "$dir" ] && [ -n "$remaining" ] && [ -n "$reset" ]; then
    _fm_gh_publish "$dir" "rate-$resource" "$(_fm_gh_num "$remaining" 0) $(_fm_gh_num "$limit" 0) $(_fm_gh_num "$reset" 0)"
  fi
  scope=
  retry=$(_fm_gh_num "$retry" '')
  if grep -Eqi 'secondary[- ]rate[- ]limit|abuse detection|wait a few minutes before you try again' "$err" 2>/dev/null \
    || { [ "$status" = 403 ] && [ -n "$retry" ]; }; then
    scope=all
  elif [ "$status" = 429 ] || { [ "$status" = 403 ] && [ "$remaining" = 0 ]; } \
    || grep -Eqi 'API rate limit (exceeded|already exceeded)|HTTP 429|rate limit exceeded' "$err" 2>/dev/null; then
    scope=$resource
  fi
  [ -n "$scope" ] || return 0
  if [ -n "$retry" ]; then
    until=$((now + retry))
  elif [ "$(_fm_gh_num "$reset" 0)" -gt "$now" ]; then
    until=$reset
  else
    until=$((now + $(_fm_gh_num "${FM_GH_BACKOFF:-}" 300)))
  fi
  fm_gh_backoff_until "$scope" "$until"
  return 2
}

_fm_gh_cache_file() { # request -> cache path
  local dir key
  dir=$(fm_gh_state_dir) || return 1
  key=$(printf '%s' "$1" | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{print $1}')
  [ -n "$key" ] || return 1
  printf '%s/cache/%s\n' "$dir" "$key"
}

fm_gh_cache_get() { # request etag-var body-file: 0 when an entry was copied out
  local file copy tag
  printf -v "$2" '%s' ''
  file=$(_fm_gh_cache_file "$1") || return 1
  [ -f "$file" ] || return 1
  copy=$(mktemp "${TMPDIR:-/tmp}/fm-gh-cache.XXXXXX") || return 1
  cp -- "$file" "$copy" 2>/dev/null || { rm -f -- "$copy"; return 1; }
  IFS= read -r tag < "$copy" || { rm -f -- "$copy"; return 1; }
  [ -n "$tag" ] || { rm -f -- "$copy"; return 1; }
  tail -n +2 "$copy" > "$3"
  rm -f -- "$copy"
  printf -v "$2" '%s' "$tag"
}

fm_gh_cache_put() { # request etag body-file
  local file tmp
  [ -n "$2" ] || return 0
  case "$2" in *$'\n'*) return 0 ;; esac
  file=$(_fm_gh_cache_file "$1") || return 0
  tmp=$(mktemp "${file%/*}/.entry.XXXXXX" 2>/dev/null) || return 0
  if ! { { printf '%s\n' "$2"; cat -- "$3"; } > "$tmp" && mv -f -- "$tmp" "$file" 2>/dev/null; }; then rm -f -- "$tmp"; fi
}

fm_gh_cache_prune() { # dir now: drop entries not rewritten for seven days, at most once an hour
  local last=0
  [ ! -f "$1/pruned" ] || IFS= read -r last < "$1/pruned" || true
  last=$(_fm_gh_num "$last" 0)
  [ "$last" -gt $(($2 - 3600)) ] && return 0
  _fm_gh_publish "$1" pruned "$2"
  find "$1/cache" -type f -mtime +7 -delete 2>/dev/null || true
}
