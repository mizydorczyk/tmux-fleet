#!/bin/sh

set -eu

plugin_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
pane_dir=${1:-}
agent_name=${2:-}
client_tty=${3:-}
session_attempted=0
launch_complete=0

umask 077
. "$plugin_dir/scripts/printing.sh"

fail() {
  notify "${2:-$1}"
  # The error has already been reported. A nonzero run-shell exit would
  # replace it with tmux's generic "returned 1" message in a copy buffer.
  exit 0
}

tmux_option() {
  tmux show-option -gqv "$1" 2>/dev/null || true
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

rollback() {
  if [ "$session_attempted" -eq 1 ] \
    && tmux has-session -t "=$tmux_session" 2>/dev/null; then
    if ! tmux kill-session -t "=$tmux_session" 2>/dev/null; then
      notify "Could not stop incomplete session '$tmux_session'."
    fi
  fi
  return 0
}

cleanup_on_exit() {
  exit_status=$?
  trap - EXIT
  if [ "$launch_complete" -ne 1 ]; then
    rollback || :
  fi
  exit "$exit_status"
}

validate_request() {
  [ -n "$pane_dir" ] || fail 'could not determine the active pane directory'
  [ -n "$client_tty" ] || fail 'could not determine the invoking tmux client'
  case "$agent_name" in
    ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-]*)
      fail 'agent name must use only letters, numbers, underscores, and hyphens'
      ;;
  esac
}

resolve_repository() {
  repo=$(git -C "$pane_dir" rev-parse --show-toplevel 2>/dev/null) \
    || fail 'the active pane is not inside a Git repository'
  repo=$(CDPATH= cd -- "$repo" && pwd -P) \
    || fail 'could not resolve the repository path'
  repo_name=$(basename "$repo")

  git_common_dir=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) \
    || fail 'could not resolve the Git common directory'
  case "$git_common_dir" in
    /*) ;;
    *) git_common_dir="$repo/$git_common_dir" ;;
  esac
  git_common_dir=$(CDPATH= cd -- "$git_common_dir" && pwd -P) \
    || fail 'could not resolve the Git common directory path'
  repo_id=$(printf '%s' "$git_common_dir" | git -C "$repo" hash-object --stdin 2>/dev/null) \
    || fail 'could not generate the repository identifier'
  repo_id=$(printf '%s' "$repo_id" | cut -c 1-12)
  [ "${#repo_id}" -eq 12 ] \
    || fail 'Git returned an invalid repository identifier'

  safe_repo_name=$(printf '%s' "$repo_name" | LC_ALL=C tr -cs '[:alnum:]_-' '-')
  safe_repo_name=${safe_repo_name#-}
  safe_repo_name=${safe_repo_name%-}
  [ -n "$safe_repo_name" ] || safe_repo_name=repository
}

resolve_configuration() {
  image=$(tmux_option '@tmux-fleet-image')
  [ -n "$image" ] || image=runtime:latest
  codex_home=$(tmux_option '@tmux-fleet-codex-home')
  [ -n "$codex_home" ] || codex_home=${HOME}/.codex
  worktree_root=$(tmux_option '@tmux-fleet-worktree-root')
  [ -n "$worktree_root" ] || worktree_root=${HOME}/.tmux-fleet

  branch="agent/$agent_name"
  resource_name="$safe_repo_name-$agent_name-$repo_id"
  worktree="$worktree_root/$resource_name"
  tmux_session=$resource_name
  container="tmux-fleet-$resource_name"
}

validate_session() {
  tmux has-session -t "=$tmux_session" 2>/dev/null \
    && fail "Agent session '$tmux_session' already exists. Switch to it or choose another name."
  return 0
}

build_session_command() {
  session_command=$(shell_quote "$plugin_dir/scripts/session.sh")
  for argument in "$repo" "$worktree" "$branch" "$image" "$codex_home" "$container" "$client_tty"; do
    session_command="$session_command $(shell_quote "$argument")"
  done
}

create_session() {
  session_attempted=1
  tmux new-session -d -s "$tmux_session" -n "$agent_name" "$session_command" \
    || fail "could not create tmux session '$tmux_session'"
}

configure_session() {
  tmux set-window-option -t "=$tmux_session:" automatic-rename off \
    && tmux set-window-option -t "=$tmux_session:" allow-rename off \
    && tmux set-window-option -t "=$tmux_session:" remain-on-exit off \
    && tmux set-option -t "=$tmux_session" detach-on-destroy off \
    || fail "could not configure tmux session '$tmux_session'"
}

switch_to_session() {
  tmux switch-client -c "$client_tty" -t "=$tmux_session" \
    || fail "could not switch client '$client_tty' to session '$tmux_session'"
}

main() {
  validate_request
  resolve_repository
  resolve_configuration
  validate_session
  build_session_command
  create_session
  configure_session
  switch_to_session
  launch_complete=1
}

trap cleanup_on_exit EXIT
trap 'exit 129' HUP
trap 'exit 143' TERM
trap 'exit 130' INT

main
