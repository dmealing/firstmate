#!/usr/bin/env bash
# Live capacity probe: real tmux on a private fm-lab socket, real bin/fm-spawn.sh.
# Usage: drive.sh <scenario>   (scenario: parked | live | locked | unreachable)
set -u
REPO={run-worktree}
SCEN=$1
L=$(mktemp -d "${DEV_SCRATCH:-/tmp}/fm-cap-live.XXXXXX")
export TMUX_TMPDIR="$L/tmux"
mkdir -p "$L/tmux" "$L/home/state" "$L/home/config" "$L/home/data"
PROJ="$L/project"
git init -q "$PROJ" && git -C "$PROJ" remote add origin https://example.invalid/fm-cap-live.git && git -C "$PROJ" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
echo "project 1" > "$L/home/config/project-capacity"; mkdir -p "$L/home/data/newtask"; printf "# Task\n\n## Captain's intent\nx\n\n## Firstmate spec\ny\n" > "$L/home/data/newtask/brief.md"

tmux -L fm-lab new-session -d -s firstmate -n fm-park0 bash
for i in 1 2 3 4 5 6; do
  tmux -L fm-lab new-window -t firstmate -n "fm-park$i" bash
done
SOCK=$(tmux -L fm-lab display -p '#{socket_path}')
PID=$(tmux -L fm-lab display -p '#{pid}')
export TMUX="$SOCK,$PID,0"

rec() {  # <id> <window>
  mkdir -p "$L/home/data/$1"; printf "# Task\n\n## Captain's intent\nx\n\n## Firstmate spec\ny\n" > "$L/home/data/$1/brief.md"
  git -C "$PROJ" worktree add -q -b "wt-$1" "$L/wt-$1" >/dev/null 2>&1
  printf '%s\n' "window=firstmate:$2" "endpoint_task_id=$1" "project=$PROJ" "kind=ship" \
    "worktree=$L/wt-$1" "branch=wt-$1" "mode=no-mistakes" "yolo=off" "harness=codex" "spawn_gen=s-$1" \
    > "$L/home/state/$1.meta"
}
for i in 0 1 2 3 4 5 6; do :; done
case "$SCEN" in
  relaunch-free)
    for i in 0 1 2 3 4 5; do rec "park$i" "fm-park$i"; done
    ;;
  relaunch-full)
    tmux -L fm-lab new-window -t firstmate -n fm-live sleep 3000
    rec live-a fm-live
    for i in 0 1 2 3 4 5; do rec "park$i" "fm-park$i"; done
    ;;
  parked)
    for i in 0 1 2 3 4 5; do rec "park$i" "fm-park$i"; done
    ;;
  live)
    tmux -L fm-lab new-window -t firstmate -n fm-live sleep 3000
    rec live-a fm-live
    for i in 0 1 2 3 4 5; do rec "park$i" "fm-park$i"; done
    ;;
  locked)
    for i in 0 1 2 3 4 5; do rec "park$i" "fm-park$i"; done
    mkdir -p "$L/home/state/.meta-park0.lock"; echo "$$" > "$L/home/state/.meta-park0.lock/pid"
    ;;
  unreachable)
    # Records point at a window on a server that is not running at this socket.
    for i in 0 1; do rec "down$i" "fm-park$i"; done
    tmux -L fm-lab kill-server
    ;;
esac
echo "scenario=$SCEN lab=$L"
if [ "$SCEN" = unreachable ]; then
  export TMUX="$L/tmux/none,1,0"
fi
if [ "${SCEN#relaunch-}" = "$SCEN" ]; then
cd "$PROJ" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_ROOT_OVERRIDE='' FM_HOME="$L/home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
  FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
  timeout 120 "$REPO/bin/fm-spawn.sh" newtask "$PROJ" --mode no-mistakes --yolo off > "$L/spawn.out" 2>&1
fi
if [ "${SCEN#relaunch-}" != "$SCEN" ]; then
  cd "$PROJ" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_ROOT_OVERRIDE='' FM_HOME="$L/home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    timeout 120 "$REPO/bin/fm-spawn.sh" park0 --relaunch > "$L/spawn.out" 2>&1
fi
echo "exit=$?"
echo "--- spawn output (head) ---"
head -c 1200 "$L/spawn.out"; echo
tmux -L fm-lab kill-server 2>/dev/null
echo "$L"
