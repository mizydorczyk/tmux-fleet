#!/bin/sh

CURRENT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
KEY=$(tmux show-option -gqv '@tmux-fleet-key')

[ -n "$KEY" ] || KEY=A

tmux bind-key "$KEY" command-prompt -p 'agent name:' \
  "run-shell \"'${CURRENT_DIR}/scripts/launch.sh' #{q:pane_current_path} #{q:1} #{q:client_tty}\" \"%%%\""
