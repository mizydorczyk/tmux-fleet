@README.md

## Local Development

[`tmux-agents.tmux`](tmux-agents.tmux) is currently an executable POSIX shell script. Keep it executable and validate its syntax before handing off changes:

```sh
sh -n tmux-agents.tmux
```

To run the plugin from a local checkout without installing it, use tmux's `run-shell` command from the repository root:

```sh
tmux run-shell "$PWD/tmux-agents.tmux"
```
