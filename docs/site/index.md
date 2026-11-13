---
description: A headless terminal multiplexer that humans and agents drive through the same verbs.
---

# venomx

venomx is a terminal multiplexer built so that a person at the keyboard and an
AI agent over MCP can work in the same sessions. A daemon owns every PTY,
session, window and pane and keeps the authoritative screen of each one.
Clients come and go: `venomx attach` draws the panes in your terminal, an agent
calls `venomx pane send` or the matching MCP tool, and both see the same state.

Status: alpha. Interfaces may still change.

## The model

| Thing | What it is |
|---|---|
| **daemon** | `venomx serve`. Owns the PTYs and processes and the terminal state of every pane. Listens on a Unix socket, `$XDG_RUNTIME_DIR/venom/venomx.sock`. |
| **session** | A named group of windows (`s0`, `s1`, ...). |
| **window** | A tree of tiled panes (`w0`, ...), plus a layer of floating panes. |
| **pane** | One process on one PTY (`p0`, ...), with its scrollback. An exited pane keeps its screen and exit status until it is removed. |
| **client** | Anything connected to the socket: `venomx attach`, a CLI call, an MCP server, another product. |

State lives in the daemon's memory. It survives every client disconnecting
and is lost when the daemon stops, unless you turn on
[checkpoints](daemon.md#checkpoints-and-restore).

Focus, scroll position, selection and zoom belong to each attached client, so
two people (or a person and an agent) can look at the same window without
moving each other. Split ratios and the pane tree are shared.

## One binary, one schema

`venomx` is the daemon, its CLI, its MCP server and the attach client. Every
action is a **verb** in one schema, and that schema generates the CLI flags,
the MCP tools, the [command reference](reference/commands.md), the shell
completions and the agent skill. A key binding that splits a pane sends the
same `pane.split` verb an agent would, with the same permission check.

This follows the ecosystem's [agent contract](https://venom.tools/spec/):
`--json` on every command, stable exit codes, `events --json` for a live
stream, `doctor`, `skill`, and the `config` verbs.

## Your scripts just work; agents can be kept apart

By default venomx trusts your own processes, as tmux does: a script can send
keys, split panes or post to the status line with nothing set. Turn on
**isolation** when agents work in venomx. Then a caller the daemon does not
know can only read, each pane writes only to what it created, and grants
only narrow as they are handed down. Approvals, host files and config stay
yours either way: you act as the owner through a private owner file next to
the socket. See [Isolation](isolation.md).

## Where to go next

- [Getting started](getting-started.md): build it, open a session, detach and
  come back.
- [Keys and the attach client](keys.md): the leader key, splits, scrolling,
  floats.
- [Configuration](configuration.md): the config file, key tables, theme.
- [Status line](status-line.md): segments, templates, rules.
- [Agents](agents.md): drive venomx from Claude Code, Codex or a script.
- [Isolation, owners and namespaces](isolation.md): who may do what, and
  when to keep agents apart.
- [Daemon lifetime and recovery](daemon.md): who starts the daemon, how panes
  end, checkpoints.
- [Performance](performance.md): measured against tmux, zellij and tuios.
- [Command reference](reference/commands.md): every verb and flag.
