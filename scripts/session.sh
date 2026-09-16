#!/bin/sh

set -u

umask 077

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo=${1:?missing repository path}
worktree=${2:?missing worktree path}
branch=${3:?missing branch name}
image=${4:?missing image name}
codex_auth_home=${5:?missing Codex authentication home path}
codex_home=${6:?missing Codex home path}
container=${7:?missing container name}
client_tty=${8:-}
manifest_written=0

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
. "$script_dir/state.sh"

fail() {
  print "$1"
  exit 1
}

validate_environment() {
  command -v podman >/dev/null 2>&1 || fail 'Podman is not installed or not on PATH.'
  if ! podman image exists "$image" >/dev/null 2>&1; then
    podman info >/dev/null 2>&1 || fail 'Podman is not running. Start its machine and try again.'
    fail "Container image '$image' does not exist. Build it before launching."
  fi
  [ -d "$codex_auth_home" ] || fail "Codex authentication directory '$codex_auth_home' does not exist."
  [ -f "$codex_auth_home/auth.json" ] && [ -r "$codex_auth_home/auth.json" ] || fail "Codex authentication file '$codex_auth_home/auth.json' is unavailable."
  { [ ! -e "$codex_home" ] && [ ! -L "$codex_home" ]; } || fail "Codex home '$codex_home' already exists. Choose another name."
  { [ ! -e "$worktree" ] && [ ! -L "$worktree" ]; } || fail "Worktree '$display_worktree' already exists. Choose another name."
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    fail "Branch '$branch' already exists. Choose another name."
  fi
  return 0
}

create_codex_home() {
  mkdir -p "$codex_home" || fail "Could not create Codex home '$codex_home'."
  chmod 700 "$codex_home" || fail "Could not protect Codex home '$codex_home'."
  cp "$codex_auth_home/auth.json" "$codex_home/auth.json" || fail "Could not copy Codex authentication file '$codex_auth_home/auth.json'."
  chmod 600 "$codex_home/auth.json" || fail "Could not protect Codex authentication file '$codex_home/auth.json'."
}

create_worktree() {
  worktree_root=$(dirname "$worktree")
  mkdir -p "$worktree_root" || fail "Could not create worktree root '$worktree_root'."
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree" || fail "Could not create worktree '$display_worktree'."
}

create_manifest() {
  resource=${worktree##*/}
  agent=${branch#agent/}
  [ "$branch" = "agent/$agent" ] && [ -n "$agent" ] \
    || fail "Branch '$branch' is not a valid agent branch."
  [ "$container" = "tmux-fleet-$resource" ] \
    || fail "Container '$container' does not match resource '$resource'."

  fleet_resolve_repository_identity "$repo" || fail 'Could not resolve the repository identity.'
  git_common_dir=$fleet_resolved_common_dir
  repo_id=$fleet_resolved_repo_id
  manifest="$(dirname "$worktree")/.state/$resource"

  fleet_write_manifest "$manifest" "$agent" "$resource" "$repo" \
    "$git_common_dir" "$repo_id" "$resource" "$container" "$worktree" "$branch" \
    "$codex_home" || fail "Could not write agent manifest '$manifest'."
  manifest_written=1
}

run_container() {
  # Preserve the pane's terminal capabilities instead of Podman's TERM=xterm.
  set -- --env "TERM=${TERM:-xterm-256color}"
  if [ -n "${COLORTERM:-}" ]; then
    set -- "$@" --env "COLORTERM=$COLORTERM"
  fi

  podman run --rm --interactive --tty \
    "$@" \
    --name "$container" \
    --label io.tmux-fleet.managed=true \
    --label "io.tmux-fleet.resource=$resource" \
    --label "io.tmux-fleet.repo-id=$repo_id" \
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
  trap - EXIT
  trap '' HUP INT TERM
  if [ "$manifest_written" -eq 1 ] && ! fleet_cleanup_manifest "$manifest" yes; then
    cleanup_status=1
    notify "Cleanup failed for '$resource'. Run scripts/cleanup.sh to retry."
  fi
  print "Agent session finished."
  [ "$cleanup_reason" = normal ] && pause_for_key
  exit "$cleanup_status"
}

main() {
  print "Repository: $display_repo."
  print "Checking container runtime..."
  validate_environment
  create_manifest
  print "Preparing isolated Codex home..."
  create_codex_home
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
