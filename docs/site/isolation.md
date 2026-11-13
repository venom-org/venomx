---
title: Isolation, owners and namespaces
description: Why your scripts just work by default, and how to keep agents apart when you need to.
order: 6
---

By default venomx trusts your own processes, as tmux does. Any program you
run, in a pane or in a terminal outside venomx, can drive it with nothing
set:

```sh
venomx notify post --text "deploy done"
venomx status set --id user.build --text "build ok" --style ok --ttl-ms 60000
venomx pane send --pane p0 --text $'make test\r'
```

venomx can also keep its callers apart: every caller is an identity with its
own rights, panes only touch what they created, and each tool sets only its
own status segments and key tables. This is **isolation**, and it is off
until you turn it on. Turn it on when you let AI agents work in venomx panes
next to your own shells.

```sh
VENOMX_TOKEN=@owner venomx config set --key grants.isolation --value true
VENOMX_TOKEN=@owner venomx config reload
```

`venomx doctor` shows which mode the daemon is in.

## The pieces

**Principals.** The daemon gives every caller an identity, a *principal*.
`venomx whoami --json` prints yours.

| Principal | Who it is |
|---|---|
| `owner` | You. Your attach client authenticates through a private owner file next to the socket, and `VENOMX_TOKEN=@owner` uses it from a shell outside venomx. |
| `unknown` | A process venomx did not start and that has no token: a script in another terminal, cron, an editor. |
| a pane (`g1`, `g2`, ...) | The program in a pane. venomx hands it a `VENOMX_TOKEN` for its own principal. |
| a token | Rights you issued with `venomx grant issue`, handed to another process as `VENOMX_TOKEN`. |

**Rights.** A principal holds rights (`read`, `write`, `spawn`, `respond`,
`files`, `admin`) on scopes: everything (`*`), a kind (`pane:*`), one
resource and what is inside it (`session:s0`), or `self`, which is the panes
the principal created. [Agents](agents.md#grants-and-tokens) lists what each
right allows.

**Ownership.** Every pane remembers who created it. The `self` scope means
"panes I created, and the panes they created". It is how one agent is kept
from typing into another agent's pane or your shell.

**Namespaces.** Each principal also has a *namespace*, a short name that
prefixes the things it adds to the shared chrome: status segment ids
(`venom.agents`), key table names and float preset names. The namespaces
are:

- `venomx`, for venomx's own built-ins and the panes you create;
- `user`, for any principal without a namespace of its own;
- one per tool, such as `venom`, given when its token is issued with
  `venomx grant issue --namespace venom`.

**The `owner` tag.** Every pane carries a read-only `owner` tag: the
namespace of whoever created it (`venomx` for yours, `venom` for venom's
agents). It is a label, never a permission. Key tables and status segments
can match on it with `when`, for example to show a segment only while an
agent's pane is focused.

## Isolation off (the default)

- `unknown`, and every pane you create, may `read`, `write` and `spawn`
  everywhere: send keys to any pane, split and kill, post notifications, set
  status segments.
- `respond`, `files` and `admin` stay yours. Answering an agent's approval,
  installing skills to your files, `config set` and `audit` still need
  `VENOMX_TOKEN=@owner`.
- Namespaces are just names. Any program may set `user.*`, `venom.*` or any
  other prefix. Only `venomx.*` is reserved.
- Issued tokens are exactly as narrow as you issued them, and the panes a
  narrower principal creates are capped by it. Isolation off only widens the
  two defaults.
- A process that another tool manages, such as an agent venom starts by
  itself, stays read-only.

## Isolation on

- `unknown` can only read, as set by `grants.unknown` (default `read` on
  `*`). A program outside venomx needs a token you issued it to change
  anything.
- A pane you create gets `grants.interactive`: by default it reads
  everything, and writes and spawns only within `self`.
- Each principal sets ids only in its own namespace. The `owner` principal may
  use any namespace but `venomx`, and you set your own segments as `user.*`.
  Anything else fails with `denied.namespace`.

```zon
.grants = .{
    .isolation = true,
    .unknown = .{ .{ .right = .read, .scope = "*" } },
    .interactive = .{
        .{ .right = .read, .scope = "*" },
        .{ .right = .write, .scope = "self" },
        .{ .right = .spawn, .scope = "self" },
    },
},
```

`grants.unknown` and `grants.interactive` only apply while isolation is on.
`doctor` warns when you have changed them and isolation is off.

## When to turn it on

Leave isolation off when venomx is your terminal multiplexer and the
programs in it are yours. Turn it on when agents run in panes: a confused or
prompt-injected agent should not be able to type into your shell, kill
another agent's pane, or replace venom's status segments. venom warns in its
`doctor` when the venomx it drives has isolation off.

Grants are not a sandbox in either mode. A process running as your user can
read your files, and one outside venomx can read the owner file and act as
you.
Isolation protects venomx's own channel against mistakes and confused
agents, not against a program that sets out to attack you.
