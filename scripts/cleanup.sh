#!/bin/sh

set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
worktree_root=${1:-}
client_tty=${2:-}

. "$script_dir/printing.sh"
. "$script_dir/state.sh"

if [ -z "$worktree_root" ]; then
  worktree_root=$(tmux show-option -gqv '@tmux-fleet-worktree-root' 2>/dev/null || true)
  [ -n "$worktree_root" ] || worktree_root=${HOME}/.tmux-fleet
fi

if [ -d "$worktree_root" ]; then
  worktree_root=$(CDPATH= cd -- "$worktree_root" && pwd -P) || exit 1
fi

state_dir="$worktree_root/.state"
[ -d "$state_dir" ] || {
  print 'No agent state to clean.'
  exit 0
}

found=0
cleanup_status=0
for manifest in "$state_dir"/*; do
  [ -f "$manifest" ] || continue
  found=1
  fleet_cleanup_manifest "$manifest" no || cleanup_status=1
done

[ "$found" -eq 1 ] || print 'No agent state to clean.'
exit "$cleanup_status"
