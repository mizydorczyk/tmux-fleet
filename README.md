# tmux-agents

Start isolated Codex sessions from tmux. Each agent gets its own Git worktree, tmux session, and Podman container.

## Requirements

- tmux 3.x
- A POSIX-compatible shell
- Podman, with its machine running
- Git
- [Tmux Plugin Manager](https://github.com/tmux-plugins/tpm)

## Installation

From this repository, build the runtime image:

```sh
podman build -t runtime:latest -f runtime .
```

Add the plugin to your `.tmux.conf`:

```tmux
set -g @plugin 'mizydorczyk/tmux-agents'
```

Reload tmux, then install the plugin using TPM's prefix + <kbd>I</kbd> shortcut.

Log in to Codex on the host before launching an agent. The plugin mounts the host's `~/.codex` directory read/write so the container can refresh credentials and persist Codex session state.

## Configuration

Set these options before the plugin declaration in `.tmux.conf`:

```tmux
set -g @tmux-agents-key 'A'
set -g @tmux-agents-image 'runtime:latest'
set -g @tmux-agents-codex-home '/Users/me/.codex'
set -g @tmux-agents-worktree-root '/Users/me/.tmux-agents'
```

The defaults are `A`, `runtime:latest`, `~/.codex`, and `~/.tmux-agents`, respectively.
