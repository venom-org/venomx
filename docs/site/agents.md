---
title: Agents
description: Drive venomx from Claude Code, Codex, opencode or a script, over the CLI or MCP.
order: 5
---

Everything you can do from the keyboard, an agent can do with a verb. The CLI
and MCP share one schema, one set of handlers and one permission check, so
pick whichever the agent speaks.

## Connecting an agent

### Over MCP

`venomx mcp` serves every verb as an MCP tool on stdin and stdout. For Claude
Code:

```sh
claude mcp add venomx -- venomx mcp
```

For any other client, the command is `venomx mcp` with no arguments. Tool
names are the wire names with the dots encoded (`pane.send` is `pane_dsend`);
the [command reference](reference/commands.md) lists each one.

MCP calls never start a daemon. Streams such as `events` are buffered to 1024
items through MCP; use the CLI for a long-running stream.

### Over the CLI

Every command takes `--json`: stdout then holds only the result, or
`{"error":{"code":...}}`, and the exit status tells the error class. Match
`error.code` and the exit status, never the English message.

| Exit | Meaning | Exit | Meaning |
|---|---|---|---|
| 0 | success | 6 | `unavailable` |
| 1 | `failed` | 7 | `timeout` |
| 2 | `invalid_params` | 8 | `cancelled` |
| 3 | `not_found` | 9 | `protocol` |
| 4 | `denied` | 10 | `unsupported` |
| 5 | `conflict` | 11 | `internal` |

Every parameter is a named flag (`--pane p0`). Booleans need `=true` or
`=false`; arrays and objects take one JSON value; a value that starts with
`-` needs `=`.

### The skill

`venomx skill` prints a SKILL.md generated from the schema: how to call
venomx, the rules about grants, and every verb. Install it where your agent
looks for skills:

```sh
venomx skill install --target claude-code     # or codex, opencode
```

## A session for an agent

```console
$ venomx session create --name agents --json
{"session":"s0","name":"agents"}
$ venomx window create --session s0 --name build --cwd "$PWD" --argv '["/bin/sh"]' --json
{"pane":"p0","window":"w0","session":"s0","principal":"g1","pid":41200}
$ venomx pane split --pane p0 --axis cols --argv '["/bin/sh"]' --json
{"pane":"p1","window":"w0","session":"s0","principal":"g2","pid":41202}
```

`window create` and `pane split` run their argv directly: there is no
implicit shell. `--axis cols` puts the new pane on the right, `rows` below.
A new process starts in the daemon's working directory with the daemon's
environment, minus anything that looks like a token; set `--cwd` (absolute),
`--env '[{"name":"N","value":"V"}]'` and `--env-unset '["NAME"]'` to change
that. venomx then sets `VENOMX_TOKEN`, `VENOMX_PRINCIPAL`, `VENOMX_PANE` and
`VENOMX_SOCKET` in the child.

By default an exited pane stays, with its screen and exit status, so you can
read what happened. `--on-exit remove` removes it instead, and
`session create --on-empty remove` removes a session once its last window
goes.

## Type and read

```console
$ venomx pane send --pane p0 --text $'make test\n' --json
{"bytes":10}
$ venomx pane capture --pane p0 --json
{"text":"$ make test\n..."}
$ venomx pane capture-rows --pane p0 --tail 50 --json
```

`pane send` writes exactly the bytes you give it; add the newline yourself.
`pane capture` returns the visible screen. `pane capture-rows` reads
scrollback as plain lines, paged: `--tail N` for the newest rows, or
`--epoch`, `--start` and `--end` to walk the whole history. A resize or clear
starts a new epoch, and a page from an old one fails `conflict.epoch`.

## Run a command and wait for it

For a command whose result matters, use `run` instead of typing into a shell.
The exit status comes from the daemon's wait on the process, not from parsing
a screen:

```console
$ venomx run --key build-1 --session s0 --shell 'zig build test' --json
{"run":"r0","pane":"p2","window":"w1","session":"s0","reused":false,...}
$ venomx run wait --run r0 --timeout-ms 60000 --json
{"run":"r0","state":"completed","outcome":"failed","exit_code":3,"output":{"lines":[...]},...}
```

- `--key` makes retries safe: the same key with the same parameters returns
  the same run (`"reused": true`) instead of starting it twice.
- `--argv` runs a program directly; `--shell` runs `/bin/sh -c` explicitly.
- `--session` runs it in a new window; `--pane` with `--axis` splits it next
  to a live pane.
- `run wait` exits with the command's own status. Keep `--timeout-ms` at or
  below 60000 and loop on `timeout.wait`: a wait that times out never stops
  the command.
- `--deadline-ms` kills the command after that long. `run cancel` stops it
  now.
- The result keeps the last 100 rows of output (`--output-rows`); read more
  with `pane capture-rows`.

## Grants and tokens

Each pane gets its own principal, and its process receives a `VENOMX_TOKEN`
for it. What a caller may do depends on
[isolation](isolation.md):

- **Off (the default):** your processes, in a pane or outside venomx, may
  read, write and spawn everywhere, as in tmux. `respond`, `files` and
  `admin` stay the owner's.
- **On:** a caller venomx does not know can only read, and a pane may read
  everything but write and spawn only within what it created itself.

Turn isolation on before you let agents work next to your own shells.

| Right | Allows |
|---|---|
| `read` | Queries, events, pane contents |
| `write` | Changing resources, sending input, killing panes |
| `respond` | Answering other principals' approvals |
| `files` | Host files outside venomx, such as `skill install` |
| `spawn` | Starting processes, issuing tokens |
| `admin` | Everything, including `config set` and `audit` |

A grant is a right on a scope: `*`, a kind (`pane:*`), one resource and
everything inside it (`session:s0`), `self`, or `path:<dir>` for `files`.
Grants only narrow: a pane can give the panes it creates, and the tokens it
issues, at most what it holds.

```console
$ venomx grant issue --grants '[{"right":"read","scope":"session:s0"}]' --ttl 600 --label watcher --json
{"principal":"g4","token":"vnt1.venomx.g4.…","expires":"2026-11-12T16:36:02Z"}
$ venomx whoami --json
$ venomx grant list --json
$ venomx grant revoke --principal g4
```

The token is shown once. Hand it to another process as `VENOMX_TOKEN`.
Revoking a principal revokes everything it issued.

You are the **owner**. Your attach client authenticates through a private
owner file next to the socket. For a CLI call from your own shell, outside
any pane, `VENOMX_TOKEN=@owner` uses it. Agents must never use `@owner`: they
work with the token of the pane they run in, or one you issued them.

## Events

```sh
venomx events --json                                  # snapshot, then follow
venomx events --types '["window.*"]' --json           # new windows anywhere
venomx events --resources '["pane:p0"]' --follow=false --json
```

The stream starts with a snapshot of current state, then a checkpoint, then
live changes, as NDJSON. Each item has a cursor; pass it back with `--after`
to resume. You only see events for resources you can read.

Session, window and pane lifecycle events (`session.created`,
`window.layout_changed`, `pane.exited`, `pane.removed`, ...) come from the
daemon. With [shell integration](getting-started.md#shell-integration) or a
program that speaks OSC 133, panes also report `command.started` and
`command.finished` with the exit code. Programs can report their own status
with OSC 7501.

## Tags

Tags describe a pane for key tables and status segments:

```sh
venomx pane tag --pane p1 --set '[{"key":"role","value":"agent"}]'
```

A pane holds up to 16. The `owner` tag (the namespace of whoever created the
pane) is set by the daemon and is read-only.

## Ask for the human

```sh
venomx pane attention --pane p1 --level warn --reason "needs review"
venomx pane attention --pane p1 --clear=true
venomx notify post --text "tests are green" --level info
```

Attention marks the pane on every attached client and never moves anyone's
focus; the person jumps there with `ctrl+b !`. Levels are `info`, `warn` and
`urgent`.

## Termination

```sh
venomx pane kill --pane p1 --signal SIGTERM --grace-ms 2000 --remove=true
venomx window remove --window w1 --recursive=true
venomx session remove --session s0 --recursive=true
```

`pane kill` signals the pane's whole process group, sends SIGKILL at the
deadline, and answers only once the process is reaped. Recursive removal
checks `write` on everything first, then terminates every live pane under one
deadline and removes the lot in one step. Plain `remove` never signals: it
needs an exited pane or an empty container.

## tmux compatibility

Some agents only know tmux. Claude Code's agent teams, for example, drive
panes with tmux commands. venomx answers the subset they use when you run it
as `venomx tmux <command>`, or link it under the name `tmux` on the pane's
`PATH`:

```sh
mkdir -p ~/.local/venomx-shim && ln -s "$(command -v venomx)" ~/.local/venomx-shim/tmux
```

The shim covers `new-session -d`, `new-window`, `split-window`,
`list-panes`, `list-windows`, `display-message -p`, `kill-pane`,
`send-keys`, `capture-pane -p`, `select-pane -T`, `has-session` and
`respawn-pane -k`, with tmux's target and `#{format}` syntax. It runs every
command as the calling pane's own principal and never elevates. Anything else
fails with exit 1 and names what it does not support.
