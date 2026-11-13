# tmux shim

`venomx tmux <command> ...`, or the `venomx` binary run under the name `tmux`
(`ln -s "$(command -v venomx)" ~/bin/tmux`, with that directory first on
`PATH` inside the pane). It implements the tmux subset that Claude Code's
agent teams use (recorded from Claude Code 2.1.319, `TmuxBackend`; the
recorded calls are `test/tmux_calls.json`, replayed by `test/tmux.py`,
`zig build test-tmux`) and sends ordinary verbs as the calling pane's own
principal (`VENOMX_TOKEN`, `VENOMX_SOCKET`). It never uses the owner file
and never elevates, so the pane needs `read`, `write` and `spawn` rights for
the commands that create and drive panes.

Anything not listed fails with exit status 1 and a message that names the
command, flag, key or format variable, before any verb with an effect runs.

| tmux | venomx |
|---|---|
| `-V` | prints a version line |
| `-L name`, `-S path` (global) | accepted and ignored: `VENOMX_SOCKET` picks the daemon |
| `has-session -t` | `session.list` |
| `new-session -d [-s -n -c -P -F] [-- cmd]` | `session.create` + `window.create` (rolled back on failure); `-d` is required |
| `new-window [-d -n -t -c -P -F] [-- cmd]` | `window.create` |
| `split-window [-d -h -v -t -c -P -F] [-l N%] [-- cmd]` | `pane.split` (`-h` is `cols`, `-v` is `rows`); `-l N%` is a best-effort `pane.resize` after the split (stderr warning if not applied) |
| `list-panes -t -F`, `list-windows -t -F` | `window.get`, `session.get`, `pane.list`; `-F` is required |
| `display-message -p [-t] fmt` | same reads; `-p` is required |
| `kill-pane -t` | `pane.kill --remove`, then removes an emptied window and an emptied session, as tmux does |
| `send-keys [-l] -t keys...` | one `pane.send`; key names `Enter Escape Space Tab BTab BSpace Up Down Left Right Home End PageUp PageDown DC IC F1-F12`, `C-x`, `M-x`; an unknown chord is an error, other words are typed |
| `capture-pane -p [-N] [-S 0 / -N / -] -t` | `pane.capture` / `pane.capture_rows`; trailing spaces trimmed unless `-N` |
| `select-pane -t -T title` | pane tag `tmux.title` (`#{pane_title}` reads it); other `select-pane` uses move focus, which no verb can |
| `respawn-pane -k -t -- cmd` | see below |

Targets: `%N` (pane `pN`), `@N` (window), `$N` or a session name, `%N`,
`session:window` (window id, exact name or index), `session:window.N`.
Format variables: `pane_id pane_index pane_title pane_pid pane_dead
pane_width pane_height window_id window_name window_index session_id
session_name`, as `#{name}` only. A new pane starts in the shim's working
directory unless `-c` is given.

## respawn-pane

venomx has no verb that replaces a live pane's process. Claude Code parks a
teammate pane on `cat` and then respawns it, so a pane created with exactly
the command `cat` is started as a parked launcher (tag `tmux.state=parked`)
that reads one command line and execs `/bin/sh -c` on it; `respawn-pane`
sends that line once. Respawning any other pane, or a pane twice, fails. Concurrent respawns are serialized by an flock on `<socket>.tmux.lock` (fails closed after 2 s); the lock only serializes shim processes on this host, not other clients that tag or send to the pane. Commands of 4000 bytes or more are refused (a terminal line is truncated at 4096). If the send itself fails with no reply, the pane stays marked respawned because delivery is unknown.
A `pane.respawn` daemon verb would remove this special case.

## Not supported (Claude Code 2.1.319 calls these and ignores the failure)

`set-option` (pane border and window styles, `remain-on-exit`),
`select-layout`, `resize-pane`: venomx chrome and layout belong to the human
(its presentation clients), and exited panes are kept by default. Teammates still work;
they are not coloured, titled on a border, or rebalanced.
