# tmux-agents

A minimal tmux plugin scaffold for running coding agents locally inside `tmux`.

## Requirements

- tmux 3.x
- A POSIX-compatible shell
- [Tmux Plugin Manager](https://github.com/tmux-plugins/tpm)

## Installation

Add the plugin to your `.tmux.conf`:

```tmux
set -g @plugin 'mizydorczyk/tmux-agents'
```

Reload tmux, then install it with TPM's prefix + <kbd>I</kbd> shortcut.
