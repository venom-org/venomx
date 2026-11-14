---
title: tmux shim
description: Run agents that only know tmux, such as Claude Code's agent teams, in venomx panes.
order: 8
---

Some agents drive panes with tmux commands and nothing else. Claude Code's
agent teams are one: the lead splits a pane for each teammate, starts it,
types into it and reads its screen, all through `tmux`. venomx answers the
subset of tmux those agents call, so they work inside venomx unchanged.

The shim is part of the `venomx` binary. Run it as `venomx tmux <command>`,
or run the binary under the name `tmux` by linking it into a directory that
comes first on the pane's `PATH`:

```sh
mkdir -p ~/.local/venomx-shim
ln -s "$(command -v venomx)" ~/.local/venomx-shim/tmux
```

```sh
# inside a venomx pane
export PATH=~/.local/venomx-shim:$PATH
tmux -V                                      # tmux 3.4 (venomx tmux shim)
tmux split-window -d -h -P -F '#{pane_id}'   # %3
```

Only put the link on `PATH` where you want it. A real tmux that comes first
on `PATH` wins, and the agent then starts its own tmux server instead of
using venomx.

## How it runs

Every tmux command becomes one or more ordinary venomx verbs, sent as the
calling pane's own principal (its `VENOMX_TOKEN` and `VENOMX_SOCKET`). The
shim never uses the owner file and never elevates, so it can do exactly what
the pane could do with `venomx` itself.

- With isolation off (the default), a pane may read, write and spawn
  everywhere, so the shim just works.
- With isolation on, the pane needs `read`, `write` and `spawn` for the
  commands that create and drive panes. Panes the shim creates belong to the
  calling pane, so `self` scopes cover them. See
  [Isolation, owners and namespaces](isolation.md).

The global `-L name` and `-S path` options are accepted and ignored:
`VENOMX_SOCKET` picks the daemon. Anything the shim does not support fails
with exit status 1 and a message that names the command, flag, key or format
variable, before any command with an effect runs. Nothing is silently
ignored, except `split-window -l`, which is applied after the split as a best
effort and prints a warning when it cannot be.

Outside a venomx pane the shim still works: it reaches the daemon on the
default socket (or `VENOMX_SOCKET`) with whatever rights that process has, as
`venomx` would. There is no calling pane then, so commands that default to it need `-t`.

## Supported commands

| tmux | What venomx does |
|---|---|
| `-V` | Prints a version line. |
| `has-session -t` | Looks the session up. |
| `new-session -d [-s -n -c -P -F] [-- cmd]` | Creates a session with one window; rolled back if the window fails. `-d` is required. |
| `new-window [-d -n -t -c -P -F] [-- cmd]` | Creates a window. |
| `split-window [-d -h -v -t -c -P -F] [-l N%] [-- cmd]` | Splits a pane: `-h` side by side, `-v` stacked. `-l N%` resizes after the split. |
| `list-panes -t -F`, `list-windows -t -F` | Lists panes or windows. `-F` is required. |
| `display-message -p [-t] fmt` | Prints the format for the target, or the calling pane. `-p` is required. |
| `kill-pane -t` | Kills and removes the pane, then removes its window and session if they are empty, as tmux does. |
| `send-keys [-l] -t keys...` | Types into the pane (one `pane send`). |
| `capture-pane -p [-N] [-S 0 / -N / -] -t` | Prints the screen, or history with `-S`. Trailing spaces are trimmed unless `-N`. |
| `select-pane -t -T title` | Sets the pane's title, kept as the pane tag `tmux.title`. Other uses of `select-pane` move focus, which belongs to the human, and fail. |
| `respawn-pane -k -t -- cmd` | Starts a command in a parked pane. See below. |

**Targets:** `%N` (pane `pN`), `@N` (window), `$N` or a session name,
`session:window` (window id, exact name or index) and `session:window.N`.

**Format variables**, as `#{name}` only: `pane_id`, `pane_index`,
`pane_title`, `pane_pid`, `pane_dead`, `pane_width`, `pane_height`,
`window_id`, `window_name`, `window_index`, `session_id`, `session_name`.

**Keys** for `send-keys`: `Enter Escape Space Tab BTab BSpace Up Down Left
Right Home End PageUp PageDown DC IC F1`-`F12`, `C-x` and `M-x`. An unknown
chord is an error; any other word is typed as text. With `-l`, every
argument is typed as text.

A new pane starts in the shim's working directory unless `-c` gives another.

## respawn-pane

venomx has no command that replaces a running pane's process, and tmux
agents rely on one: Claude Code starts each teammate pane on `cat`, then
replaces `cat` with the teammate. The shim handles that pattern only.

- A pane created with exactly the command `cat` starts as a *parked* pane
  (tag `tmux.state=parked`) that waits for one command line.
- `respawn-pane -k` on a parked pane sends it that line, and the pane runs it
  with `/bin/sh -c`.
- Respawning any other pane, or the same pane twice, fails. Commands of 4000
  bytes or more are refused.
- Concurrent respawns on one host are serialized by a lock file next to the
  socket, `<socket>.tmux.lock`, and fail after waiting 2 seconds.

## Not supported

`set-option`, `select-layout` and `resize-pane` fail. Chrome and layout in
venomx belong to the human and their attach client, and exited panes are
kept by default, so `remain-on-exit` is not needed. Claude Code ignores these
failures: its teammates still work, but they are not coloured, titled on a
pane border, or rebalanced.

## Example: Claude Code agent teams

Claude Code's agent teams run a *lead* session that starts *teammates*, each
a separate Claude Code session. In split-pane mode every teammate gets its
own terminal pane, driven with tmux. With the shim, those panes are venomx
panes: you can attach to them, read them with `pane capture`, tag them and
watch them in the status line like any other pane.

Agent teams are experimental in Claude Code. Turn them on and choose
split-pane mode in `~/.claude/settings.json`:

```json
{
  "env": { "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1" },
  "teammateMode": "tmux"
}
```

Use `"tmux"`, not the default `"auto"`. In `auto` mode Claude Code only uses
panes when `$TMUX` is set, and venomx panes don't set it, so teammates would
run in-process in the lead's terminal instead. You can also pass
`--teammate-mode tmux` on the command line for one session.

Claude Code then picks one of two layouts, depending on whether `$TMUX` is
set.

### Teammates in a session of their own

This is the default inside venomx, because `$TMUX` is not set. Start the lead
in a venomx pane with the shim on `PATH`:

```sh
venomx new --name lead
# in the new pane:
PATH=~/.local/venomx-shim:$PATH claude
```

Ask the lead for a team, for example *"Create an agent team: one teammate
reviews the parser, one writes tests for it."* Behind the scenes Claude Code
runs:

```sh
tmux -L claude-swarm-<pid> has-session -t claude-swarm     # fails: no such session yet
tmux -L claude-swarm-<pid> new-session -d -s claude-swarm -n swarm-view -P -F '#{pane_id}' -- cat   # prints %4
tmux -L claude-swarm-<pid> split-window -d -t %4 -v -P -F '#{pane_id}' -- cat   # prints %5
# then, for each teammate pane (%5 here):
tmux select-pane -t %5 -T reviewer
tmux respawn-pane -k -t %5 -- '<teammate command>'
tmux send-keys -t %5 -l '<a message>'
tmux send-keys -t %5 Enter
tmux capture-pane -t %5 -p
# and when the teammate is done:
tmux kill-pane -t %5
```

venomx creates a session named `claude-swarm` with a window `swarm-view`, one
parked pane per teammate, and starts each teammate in its pane. Watch them
from another terminal:

```sh
venomx session list                    # find the claude-swarm session's id
venomx attach --session <id>
```

When the lead shuts a teammate down, `kill-pane` removes its pane; when the
last one goes, the `swarm-view` window and the `claude-swarm` session go too.

`-L` is ignored, so every lead on one daemon shares the one `claude-swarm`
session. Their teammates sit side by side in it.

### Teammates beside the lead

To get the teammates as splits next to the lead, in the lead's own window,
set `TMUX` for the Claude Code process. Any non-empty value works; the shim
doesn't read it, and the calling pane comes from `VENOMX_PANE`:

```sh
PATH=~/.local/venomx-shim:$PATH TMUX=venomx claude
```

Claude Code now asks for its own pane (`display-message -p '#{pane_id}'`),
splits it with `split-window -h -l 70%` so the lead keeps about 30 percent of
the window, and stacks the remaining teammates with `split-window -v`. The
rest works as above. In this mode `teammateMode` can stay `"auto"`.

Set `TMUX` only on the `claude` command, not in your shell profile: programs
that see `$TMUX` assume they run inside tmux and may call tmux commands the
shim does not support.
