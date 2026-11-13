---
title: Daemon lifetime and recovery
order: 7
---

The daemon holds everything: every process, every screen, every session. This
page covers when it starts and stops, how panes end, and how to keep a record
of your layout across a restart.

## Who starts the daemon

| Started by | Lifetime | Stops when |
|---|---|---|
| `venomx` or `venomx new` in a terminal, with no daemon running | on-demand | the last session is removed |
| `venomx serve`, by you or a supervisor such as venom-os | persistent | it is signalled |

Nothing else starts one. `attach`, MCP, agents and every other command fail
with exit 6 (`unavailable`) when no daemon is listening.

An on-demand daemon stays up while any session exists, including empty
sessions and exited panes. Detaching, or having no clients at all, does not
stop it.

```sh
venomx serve                                  # foreground, persistent
```

Set `daemon.interactive_start = false` if you want `venomx new` to fail
instead of starting a daemon, for example when a supervisor always runs one.
`venomx doctor` reports how the running daemon was started.

## The socket

The daemon listens on `$XDG_RUNTIME_DIR/venom/venomx.sock`, in a directory only
you can open, with the owner file next to it. `--socket <path>` on any command,
or `VENOMX_SOCKET`, picks another daemon. Processes in a pane get
`VENOMX_SOCKET` set to the daemon that started them.

## Stopping

On SIGINT or SIGTERM the daemon stops taking changes, sends SIGHUP to every
pane's process group, waits up to two seconds, then kills what is left and
reaps it. All live state is gone after that, unless checkpoints are on.

## How panes end

- **The process exits.** By default the pane stays, showing its last screen
  and its exit code or signal, until something removes it. Panes started from
  the keyboard, and with `--on-exit remove`, are removed at once. A window
  left empty that way is removed too, and so is a session created with
  `--on-empty remove`.
- **`pane kill`** sends a signal (SIGHUP by default) to the pane's process
  group, then SIGKILL after `--grace-ms` (2000), and answers once the process
  is reaped. `--remove=true` removes the pane in the same step.
- **Recursive removal**, `window remove` or `session remove` with
  `--recursive=true`, terminates every live pane under one shared deadline
  and removes the whole subtree at once.

venomx tracks each pane's leader process until its whole group is cleaned up,
so a recycled PID is never signalled. Processes that escape their process
group are not sandboxed.

## Checkpoints and restore

Checkpoints are off by default. When on, the daemon writes a private file of
your sessions, windows, splits and pane states at an interval, so after a
restart you can see what you had and start it again.

```sh
VENOMX_TOKEN=@owner venomx config set --key recovery.enabled --value true
VENOMX_TOKEN=@owner venomx config reload
VENOMX_TOKEN=@owner venomx recovery checkpoint      # write one now
VENOMX_TOKEN=@owner venomx recovery list
```

Every `recovery` verb needs `admin`, so run them from your own shell, outside
any pane.

Checkpoints are stored under `$XDG_STATE_HOME/venomx/recovery/`. The defaults
keep 3 of them, each up to 16 MiB, for a week. Screen text is **not** saved
unless you set `recovery.terminal_text = .plain`; that stores whatever was on
screen, which can include secrets.

Nothing is ever restored or re-run on its own. After a restart, on a daemon
with no sessions:

```sh
VENOMX_TOKEN=@owner venomx recovery inspect --checkpoint <id>
VENOMX_TOKEN=@owner venomx recovery restore --checkpoint <id>
```

Restore brings back the layout with **archive** panes: exited panes with
fresh IDs, showing the saved text if there is any. No process runs. To start
something in an archive's place, in the same spot in the layout:

```sh
venomx pane relaunch --pane p3 --argv '["/bin/zsh","-l"]' --ack-orphans=true
```

That is a new run, not a continuation: nothing about the old process
(command, directory, environment, rights) comes from the checkpoint.
`--ack-orphans=true` says you know processes from the old daemon may still be
running. `recovery forget --checkpoint <id>` deletes a checkpoint.

## Diagnostics

```sh
venomx doctor            # exits 1 if any check fails
venomx doctor --json     # each check has a fix command
venomx audit --limit 20  # recent audited actions (admin)
```

`doctor` checks the config, the socket and grants, the process tree, key
table conflicts, status exec sources, float presets, checkpoint retention and
the pane-stream budgets.
