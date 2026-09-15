#!/bin/sh

if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ]; then
  print_prefix=$(printf '\033[90mtmux-agents >\033[0m')
else
  print_prefix='tmux-agents >'
fi

print() {
  printf '%s %s\n' "$print_prefix" "${2:-$1}" 2>/dev/null || :
}

notify() {
  if [ -n "${client_tty:-}" ] \
    && tmux display-message -d 8000 -c "$client_tty" "tmux-agents > $1" 2>/dev/null; then
    return 0
  fi
  [ -t 1 ] || print "$1" >&2
}
