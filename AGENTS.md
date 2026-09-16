@README.md

## Local Development

[`tmux-fleet.tmux`](tmux-fleet.tmux) is currently an executable POSIX shell script. Keep it executable and validate its syntax before handing off changes:

```sh
sh -n tmux-fleet.tmux
```

To run the plugin from a local checkout without installing it, use tmux's `run-shell` command from the repository root:

```sh
tmux run-shell "$PWD/tmux-fleet.tmux"
```
