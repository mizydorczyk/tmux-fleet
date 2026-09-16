#!/bin/sh

set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=${1:?missing repository path}
worktree=${2:?missing worktree path}
branch=${3:?missing branch name}
image=${4:?missing image name}
codex_home=${5:?missing Codex home path}
container=${6:?missing container name}
client_tty=${7:-}
worktree_attempted=0
container_attempted=0

short_path() {
  case "$1" in
    "$HOME") printf '~' ;;
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}
display_repo=$(short_path "$repo")
display_worktree=$(short_path "$worktree")
cleanup_reason=normal
. "$script_dir/printing.sh"

fail() {
  print "$1"
  exit 1
}

worktree_registered() {
  git -C "$repo" worktree list --porcelain \
    | grep -Fqx "worktree $worktree"
}

remove_git_resources() {
  worktree_removed=0
  branch_removed=0

  if worktree_registered; then
    print "Removing worktree '$worktree'..." "Removing worktree '$display_worktree'..."
    if ! git -C "$repo" worktree remove --force "$worktree"; then
      print "Could not remove worktree: $worktree. The branch was retained." "Could not remove worktree: $display_worktree. The branch was retained."
      notify "Could not remove worktree '$display_worktree'. The branch was retained."
      return 1
    fi
    worktree_removed=1
  elif [ -e "$worktree" ] || [ -L "$worktree" ]; then
    print "Removing incomplete worktree '$worktree'..." "Removing incomplete worktree '$display_worktree'..."
    if ! rm -rf -- "$worktree"; then
      print "Could not remove incomplete worktree: $worktree." "Could not remove incomplete worktree: $display_worktree."
      notify "Could not remove incomplete worktree '$display_worktree'."
      return 1
    fi
    worktree_removed=1
  fi

  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    print "Deleting branch '$branch'..."
    if ! git -C "$repo" branch -D --quiet -- "$branch"; then
      print "Could not delete branch '$branch'."
      notify "Could not delete branch '$branch'."
      return 1
    fi
    branch_removed=1
  fi

  if [ "$worktree_removed" -eq 1 ] && [ "$branch_removed" -eq 1 ]; then
    print "Removed worktree and branch '$branch'."
  elif [ "$worktree_removed" -eq 1 ]; then
    print "Removed worktree '$worktree'." "Removed worktree '$display_worktree'."
  elif [ "$branch_removed" -eq 1 ]; then
    print "Removed branch '$branch'."
  fi
  return 0
}

validate_environment() {
  command -v podman >/dev/null 2>&1 \
    || fail 'Podman is not installed or not on PATH.'
  if ! podman image exists "$image" >/dev/null 2>&1; then
    podman info >/dev/null 2>&1 \
      || fail 'Podman is not running. Start its machine and try again.'
    fail "Container image '$image' does not exist. Build it before launching."
  fi
  [ -d "$codex_home" ] \
    || fail "Codex config directory '$codex_home' does not exist."
  { [ ! -e "$worktree" ] && [ ! -L "$worktree" ]; } \
    || fail "Worktree '$display_worktree' already exists. Choose another name."
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    fail "Branch '$branch' already exists. Choose another name."
  fi
  return 0
}

create_worktree() {
  worktree_root=$(dirname "$worktree")
  mkdir -p "$worktree_root" \
    || fail "Could not create worktree root '$worktree_root'."
  worktree_attempted=1
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree" \
    || fail "Could not create worktree '$display_worktree'."
}

run_container() {
  # Preserve the pane's terminal capabilities instead of Podman's TERM=xterm.
  set -- --env "TERM=${TERM:-xterm-256color}"
  if [ -n "${COLORTERM:-}" ]; then
    set -- "$@" --env "COLORTERM=$COLORTERM"
  fi

  container_attempted=1
  podman run --rm --interactive --tty \
    "$@" \
    --name "$container" \
    --userns=keep-id:uid=1000,gid=1000 \
    --volume "$worktree:/workspace:rw" \
    --volume "$codex_home:/home/agent/.codex:rw" \
    --workdir /workspace \
    "$image" /bin/bash -c '
      if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
        print_prefix=$(printf "\033[90mtmux-fleet >\033[0m")
      else
        print_prefix="tmux-fleet >"
      fi
      codex
      codex_status=$?
      printf "\n%s Codex exited with status %s.\n" "$print_prefix" "$codex_status"
      printf "%s %s\n" "$print_prefix" \
        "Run codex to start another session on this worktree and branch."
      printf "%s %s\n" "$print_prefix" \
        "Type exit to leave the container and remove the worktree and branch."
      exec /bin/bash -i
    ' <&0 &
  # Waiting on a background child lets POSIX sh handle HUP/TERM immediately.
  container_pid=$!
  wait "$container_pid"
}

pause_for_key() {
  # A killed pane may no longer have a usable terminal. Do not block cleanup
  # in that case, and keep the test/non-interactive path unattended.
  [ -t 0 ] && [ -t 1 ] || return 0

  tty_state=$(stty -g < /dev/tty 2>/dev/null) || return 0
  printf '%s %s' "$print_prefix" "Press any key to acknowledge and close this pane."
  if stty -icanon min 1 -echo < /dev/tty 2>/dev/null; then
    dd if=/dev/tty bs=1 count=1 >/dev/null 2>&1 || :
    stty "$tty_state" < /dev/tty 2>/dev/null || :
    printf '\n'
  fi
}

cleanup() {
  cleanup_status=$?
  remove_git=1
  trap - EXIT
  trap '' HUP INT TERM
  if [ "$container_attempted" -eq 1 ]; then
    # A killed pane can leave Podman's container running. Stop it before removing files it can still write.
    print "Stopping/removing container '$container'..."
    if ! podman rm --force --ignore "$container"; then
      print "Container removal failed. The worktree and branch were retained."
      notify "Container removal failed. The worktree and branch were retained."
      cleanup_status=1
      remove_git=0
    fi
  fi
  if [ "$remove_git" -eq 1 ] \
    && [ "$worktree_attempted" -eq 1 ] \
    && ! remove_git_resources; then
    cleanup_status=1
  fi
  print "Agent session finished."
  [ "$cleanup_reason" = normal ] && pause_for_key
  exit "$cleanup_status"
}

main() {
  print "Repository: $display_repo."
  print "Checking container runtime..."
  validate_environment
  print "Preparing worktree '$display_worktree'..."
  create_worktree
  print "Created branch: $branch."
  print "Created worktree: $display_worktree."
  print "Starting container '$container' from '$image'..."
  print "Starting Codex in /workspace..."

  run_container
  container_status=$?
  print "Container exited with status $container_status."
  return "$container_status"
}

trap cleanup EXIT
trap 'cleanup_reason=signal; exit 129' HUP
trap 'cleanup_reason=signal; exit 143' TERM
trap 'cleanup_reason=signal; exit 130' INT

main
exit $?
