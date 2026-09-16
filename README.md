# tmux-fleet

Start isolated Codex sessions from tmux.

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
set -g @plugin 'mizydorczyk/tmux-fleet'
```

Reload tmux, then install the plugin using TPM's prefix + <kbd>I</kbd> shortcut.

Log in to Codex on the host before launching an agent. The plugin mounts the host's `~/.codex` directory read/write so the container can refresh credentials and persist Codex session state.

## Manage a fleet

Use one tmux session as the control plane for local agents. Each agent runs in its own tmux session, Git worktree, and Podman container.

```text
tmux: fleet
├── agent 0
├── agent 1
└── agent 2
```

An agent is temporary, it's resources -- container, worktree, and branch -- are normally removed when their tmux session ends. To retry cleanup after a crash or host restart, run:

```sh
scripts/cleanup.sh
```

The command only removes resources recorded in `$worktree_root/.state/`

## Configuration

Set these options before the plugin declaration in `.tmux.conf`:

```tmux
set -g @tmux-fleet-key 'A'
set -g @tmux-fleet-image 'runtime:latest'
set -g @tmux-fleet-codex-home '/Users/me/.codex'
set -g @tmux-fleet-worktree-root '/Users/me/.tmux-fleet'
```

The defaults are `A`, `runtime:latest`, `~/.codex`, and `~/.tmux-fleet`, respectively.
