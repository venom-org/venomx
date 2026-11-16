# venomx

A headless terminal multiplexer that agents can drive. One `venomx` binary serves schema-generated CLI and MCP verbs and negotiated pane streams on a secure Unix socket. The daemon owns PTYs, sessions, windows, topology and authoritative terminal state. State survives client disconnects; it is lost on daemon restart unless checkpoints are on. `venomx attach` is the emulating presentation client, and `venomx tmux` is a shim for the tmux subset agents call.

Part of [Venom](https://venom.tools). Status: **alpha**; interfaces may still change. Documentation: [venom.tools](https://venom.tools) (source in [docs/site/](docs/site/index.md)).

Download a static Linux x86_64 binary or a macOS Apple silicon binary from the [latest release](https://github.com/venom-org/venomx/releases/latest) (see [Download](#download)), or build from source with the Zig version in `.zigversion` (see [Build](#build)).

Licensed under the [MIT License](LICENSE). To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Download

Each release has a static Linux x86_64 binary, a macOS Apple silicon (arm64)
binary and a `sha256sums.txt`. On Linux:

```sh
curl -fsSLO https://github.com/venom-org/venomx/releases/latest/download/venomx-x86_64-linux.tar.gz
tar -xzf venomx-x86_64-linux.tar.gz
install -m 755 venomx-x86_64-linux/venomx ~/.local/bin/venomx
```

On macOS (M1 and later, macOS 13 or later):

```sh
curl -fsSLO https://github.com/venom-org/venomx/releases/latest/download/venomx-aarch64-macos.tar.gz
tar -xzf venomx-aarch64-macos.tar.gz
mkdir -p ~/.local/bin
install -m 755 venomx-aarch64-macos/venomx ~/.local/bin/venomx
```

The macOS binary is not notarized: if a browser downloaded it, clear the
quarantine flag with `xattr -d com.apple.quarantine ~/.local/bin/venomx`.

Releases are cut by pushing a version tag on `main` (`v0.0.1-alpha.1`, then
`v0.0.1`); the release workflow tests the tagged commit, builds the Linux and macOS
binaries, smoke-tests each on its own platform and publishes them. Tags with a `-` become pre-releases once a stable release exists. There is no CI on pull
requests: run `zig fmt --check .` and `zig build test` locally before opening one.

## Build

Zig 0.17 (see `.zigversion`). `zig build` fetches `venom-std` and `venom-term` at the commits pinned in `build.zig.zon`; to build against local checkouts instead, add `--fork=../venom-std --fork=../venom-term` to any `zig build` command:

```sh
zig build
zig build test
zig build test-conformance
zig fmt --check .
```

## Quick start

```sh
venomx
```

In a terminal, the bare command starts an on-demand daemon if
none is running, creates a session named after the working directory with
your login shell, and attaches. `Ctrl-B d` detaches; `venomx attach`
reattaches to the most recently attached session (else the most recently
created one); `exit` in the last shell removes the pane, window and session
and stops a daemon that `venomx` started:

```console
$ venomx new --name work        # the same, with a name
[venomx: detached from s0 (work)]
$ venomx attach                 # most recent session
$ venomx new -A --name work     # attach to "work" if it exists, else create it
$ venomx new -d -- htop         # create detached, running htop instead of the shell
```

`new` takes `--name`, `--cwd`, `-A` (`--attach-existing=true`), `-d`
(`--detached=true`) and a trailing `-- program args...`. The shell is
`$SHELL` if it is an absolute executable path, else the password database's
login shell, else `/bin/sh`, started with `-l`. `new` authorizes as the
owner through the owner file; it refuses to run inside a venomx pane
(`denied.startup_context`, exit 4) unless `--nested` is given with the
pane's own `VENOMX_TOKEN` against a running daemon, and needs a terminal
(`unsupported.terminal`, exit 10). With no daemon running, it and the on-demand
`session create` also refuse below a manager's marker (`denied.startup_context`),
and name the marker. Panes it creates use `on_exit = "remove"`
and its session `on_empty = "remove"`; so do the built-in split and
new-window bindings. The last-used session is kept in
`$XDG_STATE_HOME/venomx/last-session` with the daemon's epoch.

### Shell integration

The status line names what runs in the focused pane. A program that sets no
title (`ping`, `codex`) shows by its process name, which the daemon samples.
To show the whole command line (`ping google.com`), load the snippet for
your shell from its rc file:

```sh
eval "$(venomx shell init --shell=zsh)"     # ~/.zshrc
eval "$(venomx shell init --shell=bash)"    # ~/.bashrc (bash 4.4+)
venomx shell init --shell=fish | source     # ~/.config/fish/config.fish
```

Inside a venomx pane it sends OSC 133 marks: a prompt
mark, the percent-encoded command line before each command, and its exit
status. Outside a pane, and on a second load, it does nothing. It adds hooks
and leaves your prompt and existing hooks alone. `--json` prints
`{shell,script}` instead.

Who starts the daemon decides its lifetime: `venomx`/`new` start
`serve --lifetime on-demand --origin interactive`; a supervisor runs
`venomx serve` (persistent), and then exiting the last shell removes the
session but the daemon keeps running. Agents, MCP, `attach` and every other
command never start one. Config: `daemon.interactive_start` (default
`true`; `false` makes `new` fail `unavailable.not_running` when no daemon
runs) and `attach.on_session_end` (`"exit"` default, or `"next"` to move to
the most recent other session when the attached one ends). `doctor` reports
the latched lifetime, the origin, the startup keys and a stale
last-session file.

## Running the foundation

Start a foreground daemon, then create resources from another shell:

```sh
zig-out/bin/venomx serve
VENOMX_TOKEN=@owner zig-out/bin/venomx session create --name work --json
VENOMX_TOKEN=@owner zig-out/bin/venomx window create --session s0 --argv '["/bin/sh"]' --json
VENOMX_TOKEN=@owner zig-out/bin/venomx pane split --pane p0 --axis cols --argv '["/bin/sh"]' --json
zig-out/bin/venomx session get --session s0 --json
zig-out/bin/venomx window get --window w0 --json
zig-out/bin/venomx pane capture --pane p0 --json
```

Commands never auto-start a missing daemon. `serve` remains alive with no
sessions, children or clients. SIGINT/SIGTERM stops mutations, sends HUP to
pane process groups, waits up to two seconds while draining sockets, then
kills surviving groups and reaps children. Linux child subreaping and bound
principals constrain authorization; they do not sandbox escaped descendants.

`window create` and `pane split` execute a nonempty argv directly; there is
no implicit shell. By default the child runs in the daemon's working directory
with the daemon's environment, minus inherited `*_TOKEN`, `*_PRINCIPAL`,
`VENOMX_*` and token-shaped values. Three optional parameters change that:
`--cwd` (absolute only; use `--cwd "$PWD"`, resolved physically, sets `PWD`),
`--env-unset '["NAME"]'` and `--env '[{"name":"N","value":"V"}]'`, applied in
that order, after which venomx sets `VENOMX_TOKEN`, `VENOMX_PRINCIPAL`,
`VENOMX_PANE` and `VENOMX_SOCKET` (the socket this daemon listens on). `VENOMX_*`
names are reserved; venomx and owner tokens are rejected; another tool's token
is accepted only alone under its own `<TOOL>_TOKEN` name. The executable is
found on the child's final `PATH`, skipping empty and relative entries, with no
shell fallback; `unavailable.spawn` carries `data.reason` (`not_found`,
`permission`, `exec_format`, `too_large`, `resource`, `other`). New errors:
`invalid_params.cwd`, `invalid_params.env` (`data.param` and `data.reason`,
never a value), `not_found.cwd`, `unavailable.cwd`. Neither cwd nor environment
appears in results, events, errors, doctor or logs, and the daemon zeroes its
heap on free. Failed spawn/exec or allocation cannot publish a partial window,
pane or layout. IDs increase independently as s0, w0 and p0 and may be consumed
by failed creation.

The product verbs are `session create|list|get|remove`, `window create|get|remove`
and `pane list|split|send|capture|remove|kill`. Every selector and value uses named
flags. `pane send --text` queues exact UTF-8 bytes without adding a newline;
`pane capture` returns the visible active screen, including spaces and physical
row separators. Exited panes retain the terminal, history and authoritative
exit code or symbolic signal. Removal requires an exited pane or an empty
container. Empty windows and sessions remain until explicitly removed.

`window create` and `pane split` take `--on-exit keep|remove`
(default `keep`, as above) and `session create` takes `--on-empty
keep|remove` (default `keep`). With `remove`, the daemon publishes
`pane.exited`, then removes the pane in a following commit (`pane.removed`
with `reason: "on_exit"`), an emptied window (`window.removed`, reason
`empty`) and an `on_empty = "remove"` session left without windows
(`session.removed`, reason `empty`). Removing the last session this way
stops an on-demand daemon. `run` panes ignore `on_exit`, restored archives
keep their recorded policy (checkpoints store it), and a pane covered by a
`pane kill` or recursive removal is left to that request. The pane snapshot
entity shows `on_exit`.

Termination is explicit and destructive. `pane kill --pane p0
[--signal SIGHUP|SIGTERM|SIGINT] [--grace-ms 2000] [--remove=true]` sends the
signal and SIGCONT to the pane's process group, SIGKILL at the monotonic
deadline, and answers only after the leader is reaped:
`{pane,outcome,removed,escalated}` plus `exit_code` or `signal`. `window remove`
and `session remove` with `--recursive=true` authorize write on every
descendant before any effect, seal the subtree against new children, terminate
every live pane with one shared deadline and remove the subtree in one commit.
Plain removal never signals. A leader still alive 1000 ms after SIGKILL fails
the request `timeout.terminate` (exit 7) and nothing is removed; cancelling or
disconnecting ends the request (`cancelled`) but not the termination. While a
pane terminates, `pane send`, `pane split` and INPUT frames are refused or
discarded. Leaders are pinned (observed with `waitid(WNOWAIT)`) until their
group has been swept, so a reaped or recycled PID is never signalled; see
venom-std `supervisor.Leaders`.

`window get` returns a validated flat preorder tree: `nodes=[]` for empty,
`{kind:"pane",pane}` leaves, or `{kind:"split",axis,first,second}` branches.
`cols` splits left/right and `rows` splits top/bottom with equal shares (the
first gets any extra cell). A split replaces its source leaf with existing
pane first, new pane second. Removal collapses the parent. Revisions start
at 1 and advance with topology. Focus, scroll, selection and host rectangles
belong to each presentation client (see the attach client below).

Unknown callers are read-only. Scoped reads filter discovery and each pane;
container metadata never substitutes for a pane read grant. Mutations check
the target scope before lookup. Owner authority in the examples is an explicit
human opt-in. CLI and MCP use the same schema, handlers and grant resolver.
`mcp`, `docs`, `completions`, `skill`, `doctor`, `events`, grant verbs and
`config get|set|check|reload|schema` use the shared venom-std bundles.

Configuration is ZON at `$XDG_CONFIG_HOME/venomx/config.zon`, otherwise
`$HOME/.config/venomx/config.zon`. Defaults and types are exposed by
`config schema`: `grants` contains unknown/interactive profiles and token TTL;
`pane_stream` contains ring/client budgets, sizing policy and history bounds;
`log` contains level/format settings. Reload applies validated policy and
pane-stream settings without destroying sessions or changing source identity.
Doctor reports config, transport/grants, source, retention, resource counts,
tree invariants, process supervision and pane-stream budgets.

## Attach client

```sh
zig-out/bin/venomx attach --session s0     # lowest-ID window first
zig-out/bin/venomx attach --pane p0        # one pane, full screen
zig-out/bin/venomx attach --pane p0 --raw=true  # host terminal passthrough
```

`attach` is the emulating presentation client in the same binary,
declared as an interactive local command in the generated CLI,
help, docs and completions. MCP and the agent skill omit it. It needs a
terminal on stdin and stdout (`unsupported.terminal`, exit 10 otherwise), exits 6 when no
daemon is listening and never starts one. Like other human clients it reads
the owner file by default; `VENOMX_TOKEN` overrides that, and
inside a managed pane the pane's own rights apply.

`--raw=true` requires `--pane`. It negotiates VT replay, resets the host,
replays retained history and the screen, then forwards live output without
a client VT or status line. The host owns scrolling, selection and subsequent
scrollback. Input retains the host's key/mouse/paste encodings; leader `d`
detaches and leader leader sends a literal leader (Ctrl-B is the 0x02
byte in raw input). Boolean flags take explicit
values, so bare `--raw` is rejected by the shared parser.

The raw tokenizer removes terminal queries and clipboard reads, including
sequences split across frames or reconnects. Clipboard writes pass only for
writers when `pane_stream.raw_clipboard = .external` (default); `.off` removes
them. Write-grant or clipboard-policy changes trigger a new snapshot before more output,
refreshing the client's input/clipboard permissions. Overlong control strings
(above 64 KiB) are discarded through their terminator with bounded storage.

A host/pane size mismatch immediately stops passthrough and requests an
emulating VT snapshot on the same stream. After READY, that pane is drawn
cropped or letterboxed on an alternate screen. The fallback keeps VT format,
so a different daemon Ghostty pin is supported. It stays in emulation for the
rest of that attachment. Reconnect preserves partial tokenizer state when
resuming an offset and resets it when a fresh snapshot is required.

Raw attach measurements and reproduction commands are in
[docs/raw-attach.md](docs/raw-attach.md). The 10% throughput budget is not
met yet.

One binary connection carries CONTROL (`session.get`, the `window.*` event
subscription staged through its checkpoint, bound verbs) and one odd-ID
stream per displayed pane. Each stream has its own venom-term `Vt` (no query
replies, no OSC side effects), offset check, snapshot decoder and backfill:
the pane paints at `READY`, history rows still in flight show as a loading
band, a PTY gap or misplaced `RESIZE` sends `RESYNC` for that stream only,
and the old screen stays up until the new `READY`. A lost connection
reconnects for up to 5 s and resumes each stream at its applied offset.

Window choice, focus, scroll position and selection are local to the
client and never sent. Splits get equal shares with a one-cell separator;
a pane larger than its rectangle is cropped around the cursor and a smaller
one letterboxed. Empty sessions/windows and unreadable panes show a state
instead of disappearing.

### Keys

The client intercepts only the **leader**, `Ctrl-B` by default (`keys.leader`),
as in tmux. It is a plain control byte, so it works over ssh with no keyboard
protocol. Claude Code uses it to background a task, which then takes a double
press: leader leader sends the leader to the pane. `ctrl+a` and `ctrl+space`
work too where the terminal delivers them. Every other key, including the
shell's `Ctrl-A`, Claude Code's `Shift-Tab` and `Esc`, reaches the focused pane
unchanged. There are no unprefixed bindings.

After the leader the client waits for the next key (`keys.timeout_ms`, default 0:
no timeout). If none comes within `keys.popup_delay_ms` (200; 0 shows it at once)
the **leader popup** lists the next keys of the active tables, at the bottom of
the pane area. It takes no focus and changes no pane, and a faster key never sees
it. `esc` cancels from any level and clears this client's selection; `backspace`
goes up one level; an unbound key cancels and is swallowed. In a sticky group the
popup goes away after the first binding and the client stays there until `esc`:
`venomx.mode` shows the group, and `?` brings the popup back.

`L` enters **lock mode**: every key, the leader too, goes to the pane until
`keys.unlock` (`Ctrl-Alt-B`); `venomx.mode` shows `LOCK`. Keys are Kitty names
joined with `+` (`ctrl+a`, `alt+shift+left`, `%`), and sequences are separated by
spaces.

The built-in `venomx` table (names also work at the `:` prompt):

| Key | Command | Kind |
|---|---|---|
| `h j k l`, `← ↓ ↑ →` | `focus-left`, `focus-down`, `focus-up`, `focus-right` | local |
| `Tab` / `Shift-Tab` | `focus-next` / `focus-prev` | local |
| `\\` / `-` | `split-right` / `split-down` → `pane.split` (`on_exit = remove`) | verb |
| `c` | `new-window` → `window.create` (`on_exit = remove`) | verb |
| `n` / `p` / `1`–`9` | `window-next` / `window-prev` / `window-1`–`window-9` | local |
| `w` / `s` | `window-picker` / `session-picker`: a list over the pane area; `j k` or `↑ ↓` move, `Enter` switches this client only, `Esc` closes | local |
| `r`, then `h j k l` or `← ↓ ↑ →` | `resize-left`, `resize-down`, `resize-up`, `resize-right` → `pane.resize`, sticky | verb |
| `[`, then `j k`, `↑ ↓`, `PgUp`, `PgDn`, `{ }` | `scroll-line-down`, `scroll-line-up`, `scroll-page-up`, `scroll-page-down`, `scroll-prev-command`, `scroll-next-command`, sticky | local |
| `PgUp` / `PgDn` / `]` | `scroll-page-up` / `scroll-page-down` / `scroll-bottom` | local |
| `z` / `!` / `d` | `zoom` / `focus-attention` / `detach` | local |
| `X` | `close-pane` → `pane.kill` (`remove = true`) | verb |
| `f` / `F` / `x` | `toggle-floats` / `focus-float` / `dismiss-popup` | local |
| `e` | `toggle-pane-float` → `pane.place`: float the focused tiled pane (`floats.default`), or tile the focused float into the largest tile | verb |
| `:` | `command-prompt` | local |
| `?` | `all-keys`: every active binding, all levels and tables, in a list over the pane area; typing fuzzy-filters it (`Backspace` deletes, `Ctrl-U` clears), `↑ ↓` or `Ctrl-P`/`Ctrl-N` move, `Enter` types the selected keys, `Esc` closes | local |
| `L` | `lock` | local |
| `Esc` | `clear-selection` | local |
| leader | `send-leader` | local |

The sub-prefixes `v` (venom), `o` (venom-os) and `m` (your own tables) are
reserved, so a built-in never takes them. Window and session pickers have keys
reserved and are not bound yet.

On a focused float the resize keys don't send `pane.resize`: the client resizes
the float itself by a cell (right/down grow, left/up shrink, top-left fixed) and
sends `pane.place` with the geometry in cells (`anchor = top_left`, `x`/`y` from
the window area's corner). Mouse drags on a float's border, or anywhere in it
after the leader, move or resize it the same way, previewed locally and placed on
release.

`pane.resize {pane, direction, cells}` moves the divider of the pane's nearest
split on that axis, in that direction. Split ratios are shared, so every client
follows, and each draws the same share of its own viewport. It needs `write` on
the pane's window. It stops at a child's minimum, one cell per pane and separator
it holds, and never moves against the direction; `moved` says how far it went
(0 with no event when nothing can move). `cells` counts on the panes' PTY sizes, so
on a narrower client a press can draw no change. A split that would leave a child
below its minimum moves that ratio just far enough, taking the cells from the
other side only, which keeps its own minimum; the ratio goes back to equal only
when the viewport can't hold both. Ratios appear as
`ratio` on a split node in `window.get` and `window.layout_changed`, in 1/10000 of
the split for its first child, and only when not equal. Format-3 checkpoints
keep the ratios, so a restored split draws the same shares;
format-1 and format-2 checkpoints restore as equal splits.

More tables come from config (`keys.tables`) and from products, which
register theirs at run time under a one-key **sub-prefix** (never a built-in
key). A product's table is registered by the owner, from a process outside
every managed tree, because a pane does not hold `write` on `server:root`:

```console
$ VENOMX_TOKEN=@owner venomx keys register --name venom --prefix v --label venom \
    --when '[{"key":"product","value":"venom"}]' \
    --groups '[{"key":"a","label":"agents"}]' \
    --bindings '[{"key":"a s","label":"stop","exec":["venom","agent","stop","--pane","{pane}"]}]' \
    --bind daemon --json
{"name":"venom","prefix":"v","layer":"product","shadowed":[]}
```

`when` uses a tag the product sets itself. The `owner` tag would not do: it is
the namespace of whoever created the pane, which is `venomx` for a pane made
with the owner's credentials.

Who may use which name (`keys register`, `keys unregister`, and the
`<namespace>.` of `floats register`):

| Caller | Names | Grant |
|---|---|---|
| The `owner` principal | Any except `venomx` (`venomx.*` for presets) | Holds everything |
| Any other principal | Its own namespace only, else `denied.namespace` | `write` on `server:root` |

This tests the principal, not the namespace, so a pane the owner created gains
nothing from the first row.

```zon
.keys = .{
    .leader = "ctrl+b",
    .tables = .{
        .{ .name = "mine", .prefix = "m", .label = "mine", .when = .{ .{ .key = "role", .value = "agent" } }, .groups = .{
            .{ .key = "s", .label = "size", .sticky = true },
        }, .bind = .{
            .{ .key = "z", .label = "zoom it", .local = "zoom" },
            .{ .key = "c", .verb = "pane.attention", .args = "{\"pane\":\"{pane}\",\"clear\":true}" },
            .{ .key = "s j", .local = "scroll-line-down" },
        } },
    },
    .prefixes = .{
        .{ .name = "venom", .prefix = "a" },
    },
},
```

`.label` is what the popup shows, 1-40 bytes; without one it shows the local
action, verb or `argv[0]`. On a table it names the sub-prefix. `.groups` names
inner prefixes, and a sticky one keeps the client there after a binding runs.
`keys.prefixes` moves a table to another sub-prefix without restating its
bindings, per table name across the defaults and user files, and the move
survives the product registering again. `keys.list` and `keys.register` report
the effective prefix.

A binding has exactly one target: `.local` (a client command above), `.verb`
with `.args` (a schema verb sent with the client's own identity; params are a
JSON object string, since format 1 has no open map type), or `.exec` (an argv
the client runs with no shell, stdin and output on the null device, and no
venomx token in its environment; a failure shows in the status line).
`{pane}`, `{window}` and `{session}` of the focused pane replace whole argv
elements or whole JSON string values; spliced placeholders are rejected.
`when` (a tag list) activates a table only while the focused pane has those
tags. Layers, highest first: user config, the defaults file
(`$XDG_CONFIG_DIRS/venomx/defaults.zon`), registered product tables,
built-in; a higher layer wins for the same table name, the same sub-prefix
or an overlapping key sequence. Within one layer such an overlap is an
error: `config check` fails on `keys.tables` with the offending file, and
`keys.register` fails `conflict.key_prefix`. `keys list --json` shows every
table with its layer, the `shadowed` bindings and any conflicts; `doctor`
reports conflicts, shadowing, and a leader a terminal without the Kitty
keyboard protocol cannot send. Registered tables follow `bind`
(`connection` by default) and emit `keys.changed`; clients reload on it.
An owner-registered `--bind daemon` table has no expiry: it lasts until
`keys unregister` or until the daemon stops, and is not checkpointed. A table
from any other principal also goes when that principal is revoked or expires.
Registering a name already in use replaces the whole table for every client,
and `source`, `bind` and the lifetime become the new registrar's. To keep
bindings no registrar can change, put them in `keys.tables` in your config.
Presets from `floats register` follow the same rules.

Verb commands are checked against the manifest at compile time and sent
with the client's own identity, so they get the same authorization as
CLI/MCP calls. Keys are encoded using the focused pane's emulator modes
(legacy, DECCKM, keypad, modifyOtherKeys and kitty keyboard). Host terminals
that support kitty keyboard reporting supply modifiers, repeats and releases;
legacy hosts supply the information available in their ordinary key bytes.
A lone host Escape waits 25 ms for the rest of a possible escape sequence.

Mouse reports go to the pane under the pointer when it enables tracking,
with coordinates relative to that pane. A button gesture stays with its
starting pane. Otherwise the wheel scrolls locally and a left drag selects
and copies with OSC 52. Hold **Shift** at the start to force local scrolling
or selection. Typing and program mouse input return the pane to its live
screen. Pixel mouse mode uses host cell dimensions when available; without
them, the client reports that mouse encoding is unavailable.

The client enables bracketed paste on the host. Paste content bypasses
keybindings and stays bound to the pane where the paste began; it is wrapped
only if that pane enables bracketed paste. A paste fits in one INPUT frame
when possible, with larger pastes split at the negotiated frame limit.
Pastes in the local command prompt are discarded. Watchers send no input.
The raw attach path continues to forward the host's original encodings.

`zig build test` runs the client against the real stream server in memory
(backfill, pending rows, gap and resize resync, resume, removal, topology,
local scroll/selection) and `test/attach.py`, which drives two real attach
processes on PTYs and reads their screens through a test-only Vt helper.

## Status line

Every part of the status line is a segment you can move, hide or
re-template in `.status`. The lists set the drawing order on each side.
When the line is short, `priority` decides what goes first, across all three
sides:

```zon
.status = .{
    .position = .top,
    .left = .{ "venomx.session", "venomx.windows", "venomx.panes", "venomx.pane" },
    .center = .{ "venomx.clock" },
    .right = .{ "venomx.message", "venomx.notify", "venomx.tray", "venomx.attention" },
    .unlisted = .show, // .hide draws only listed segments
    .segments = .{
        // Only the focused pane, process then ID.
        .{ .id = "venomx.panes", .panes = .focused, .format = "{pane.process} <{pane.id}>" },
        .{ .id = "venomx.clock", .format = "{clock:%a %d %H:%M}" },
        .{ .id = "venomx.pane", .format = "{pane.tag.branch|}" },
        .{ .id = "user.host", .text = "devbox", .side = .left, .priority = 20 },
        // A slot override for another product's segment, with a click.
        .{ .id = "venom.agents", .priority = 70, .click = .{ .local = "zoom" } },
    },
},
```

- **Templates** take `{name[:spec][|fallback]}` and `[...]` groups. A group is
  dropped when a variable inside it is empty. The variables are
  `session.*`, `window.*`, `pane.*` (including `pane.tag.<key>`),
  `attention.count`, `host`, `user` and `clock`.
- **The tray** (`venomx.tray`) draws every segment with `.group = "tray"`,
  showing its icon, or its text when it has none. It isn't drawn while it
  has no members.
- **Clicks:** a left click runs the segment's `click`, a key-binding target
  run as this client. A click on a segment without one does nothing.
- `:toggle-segment <id>` (command prompt) hides or shows a segment on this
  client until it detaches.
- `status.hide` and `status.priority` are gone. `config check` rejects them
  with `invalid_params.config_key`. Use a `.segments` entry with
  `.show = false` or `.priority` instead.
## Status rules and exec sources

Besides `status set`, two daemon-side sources fill the status line.

**Rules** turn events into a segment, so a program doesn't need to keep a
connection open and push on every change. A rule only sees events its
principal can read, and it needs `--ttl-ms`, `--clear-on` or both:

```console
$ venomx status rule set --id venom.failed --on '["command.finished"]' \
    --match '[{"key":"exit_code","op":"ne","value":"0"}]' --clear-on '["command.started"]' \
    --format '✕ {event.command} {event.exit_code}' --style error --ttl-ms 5000 --json
{"id":"venom.failed","revision":1}
```

`status rule list` and `status rule clear` manage them. `--scope event` puts
the segment in the session of the event's pane. Config rules are
`.status.segments` entries with a `.rule` and a `.format`, under `user.*`.

**Exec sources** run a command from the config files and show its stdout:
the last line of each run with `.every_ms`, or every line while it keeps
running (stream mode, restarted with backoff from 1 s to 60 s). A line that
starts with `{` is JSON `{"text","style","icon"}`. The child runs with no
shell, stdin from `/dev/null`, its cwd at `$HOME`, `VENOMX_SEGMENT=<id>`,
and **no** venomx token. Only the owner principal may change an exec entry
with `config set`. `doctor` reports the sources that fail.

```zon
.status = .{ .segments = .{
    .{ .id = "user.battery", .exec = .{ .argv = .{ "venom-os-battery", "--short" }, .every_ms = 30000 }, .group = "tray" },
} },
```

`status set` also takes `--group` (e.g. `tray`), `--icon` and `--click`
(a key-binding target that a click runs as the clicking client), and
`--side center`.

## Benchmark against tmux, zellij and tuios

```sh
zig build bench-compare -Doptimize=ReleaseFast                  # all installed, 5 trials
zig build bench-compare -Doptimize=ReleaseFast -- --data sgr --report sgr.json
python3 test/muxbench.py --compare old.json new.json            # deltas, >10% regressions marked !
```

`test/muxbench.py` drives each multiplexer the way a user would: its real
client runs on a PTY that the harness owns. The harness acts as the host
terminal: it drains the output and answers DA, CPR, OSC 10/11, size and
DECRQM queries, but draws nothing. Every pane runs the same program through
`$SHELL`, so each tool keeps its default config and layout. tmux runs with
`-f /dev/null`. zellij runs without tips or release notes. tuios uses
`new --detach` followed by `attach`, because an attached `new` opens with
no window.

Each trial starts from scratch, in its own HOME and XDG directories. The
first trial is a warmup and isn't counted. The harness reports these
metrics:

- startup time, until the pane's first text shows
- keystroke-to-echo latency (median and p90)
- `--mib` flood throughput, as plain ASCII or as SGR-heavy text (`--data`)
- CPU time (`schedstat`) and PSS, summed over each multiplexer's client and
  server processes

Multiplexers that aren't installed are skipped. `--mux`, `--tmux`,
`--zellij` and `--tuios` choose which ones run and which binaries they use.
The numbers measure the multiplexer, not a terminal emulator. They aren't
like for like on every count: for example, tmux keeps 2000 lines of history
by default, venomx 10000. This command is timing-based, so `zig build test`
doesn't run it.

## Events

`events --json` uses the shared Venom event envelope, source-qualified cursors,
authorized snapshots, replay, checkpoints and cancellation. Filters are exact
resources; a session filter does not subscribe to descendant panes/windows.
Use `--types '["window.*"]'` with no resource filter to discover new windows.
Stage snapshot chunks until the final chunk and checkpoint, then apply live
changes. Current empty containers appear even without retained create events.

The manifest extends the shared event data descriptor without changing any
existing field type. Product additions are:

| Type | Resource | Data | Snapshot entity |
|---|---|---|---|
| `session.created` | session | session, name | session: session, name |
| `session.removed` | session | session, reason (`empty` for an `on_empty` cascade) | disappears |
| `window.created` | window | window, session, name, revision, nodes | complete window |
| `window.layout_changed` | window | window, session, revision, nodes | complete window |
| `window.removed` | window | window, session, reason (`empty`) | disappears |
| `pane.terminating` | pane | pane, requested_signal | pane gains `terminating: true` |

`pane.created` also carries the pane's `tags` (additive) so
attached clients match `when` tables without a resync. Window creation
publishes window.created then pane.created; splitting
publishes pane.created then window.layout_changed. Pane removal publishes
observation cleanup, pane.removed, then window.layout_changed. Recursive
removal publishes, per window in ascending ID, each pane's cleanup and
pane.removed in ascending ID, then window.removed, and session.removed last.
Removed resource metadata stays available for authorization of retained
events and is freed once no retained event refers to it. Root-process
exit finishes the observed command and clears transient program status before
pane.exited, without changing topology. OSC 7501/133 observations come only
from the authoritative Vt, never from attached clients; they cannot grant
rights or establish trusted execution results. Program status retains at
most 64 records per pane with least-recently-updated eviction. Done/error/idle
records survive prompts and process exit; RIS clears all observations.

## Pane-stream component

The `pane-stream` build module implements the daemon side of the pane-stream protocol.
It imports venom-term's headless `vt` module; no renderer is loaded. The
installed daemon embeds it alongside the schema dispatcher.

- `Server.init(allocator, source)` borrows the daemon's lifetime
  `venomx/<uuid>` identity. `createPane(size)` allocates monotonically
  increasing IDs. `pane.spawn(argv)` owns the PTY and child process;
  `pane.vt` is the authoritative terminal for capture and agent queries.
- Install `server.handler()` on `proto.Server`, negotiate
  `venomx.pane_stream`, and set `server.control` to the product's
  `proto.Dispatcher.handler()` to share binary CONTROL and NDJSON traffic.
  Set `authorize` to the product's pane-scoped grant resolver. The default
  grants read only; no client-provided JSON can make a watcher a writer.
- Call `server.pump(monotonic_ms)` around `proto.Server.poll(...)` on one
  reactor thread. Include PTY readability, pending PTY input writability,
  socket work and held resize deadlines in the owner's wait set. A short
  bounded socket poll also works; no threads or hidden timers are created.
  Never block that thread writing a client. Each pump services every PTY,
  then queues at most one frame per empty connection, rotating pane streams.
  Destroy the transport before the component so disconnect callbacks run
  while its borrowed connections and streams are alive.
- `removePane` queues CLOSE after any in-flight frame drains, refuses new
  attaches and releases the pane after its final attachment closes. Process
  exit retains the pane for snapshots until explicit removal.
- `pane.observers` forwards validated OSC 7501 and OSC 133 observations from
  the authoritative parser. Strings are borrowed during the callback;
  observers must not reenter the same Vt. The product owns event publication.

Each pane retains a bounded ring of raw output with ordered resize markers.
Clients have independent cursors into it. Snapshot prefixes and history are
owned per stream and emitted lazily; live bytes take priority over history.
History records too large for the negotiated frame limit, or beyond the
requested row budget, end backfill early with LAST. Epoch changes end it
with LAST|ABORTED. Repeated overflow encodes at most one snapshot per second.
A `vt` snapshot uses a ground-state offset and waits if its unfinished
sequence is older than the retained ring.

`stream.Config` has the protocol defaults and validation. `pane.reconfigure`
changes the policy at the next activity and ring storage at the next PTY
feed. The embedding product exposes these fields through its ZON config
verbs. No-client panes continue to read, emulate and retain output.
Input and terminal query replies enter one bounded, nonblocking queue;
input frames cannot interleave. Host colors come from the active writer,
then the latest writer that reported colors, and never from a watcher.

Tests cover two clients, overflow isolation and resync, offset resume with
resize replay, stale resume fallback, ghostty prefix/history restoration,
epoch aborts, VT continuations, input grants and ordering, size policies,
host colors, config validation/reload, and two real Unix socket clients
sharing a shell PTY through exit. All use `std.testing.allocator`.

`zig build test` also runs the installed binary through headless socket
acceptance (including two clients, detach/reattach, split/removal, scoped
grants, spawn rollback, OSC ordering and shutdown) and the packaged
venom-std agent-contract suite using its event-only stream profile. Resource
creation and layout tests inject allocation failures with the testing
allocator and check for leaked state, PTYs, children and principals.

## Benchmark results

Measured with `test/muxbench.py` (see *Benchmark against tmux, zellij and
tuios* above): 200×50 pane, 16 MiB flood, 5 trials, medians, ReleaseFast
venomx. AMD Ryzen 7 9800X3D, Linux 7.3; tmux 3.8, zellij 0.45.1,
tuios 0.12.1. Each tool runs with its default config. Echo latency is ranked
by p50.

**SGR-heavy flood** (256-colour foreground plus bold/dim on every word)

| metric | better | venomx | venomx rank | tmux | zellij | tuios |
|---|---|---|---|---|---|---|
| flood throughput (MiB/s) | higher | **92.4** | best | 25.1 | 59.6 | 73.7 |
| flood CPU (s) | lower | **0.28** | best | 0.47 | 0.32 | 0.53 |
| startup (ms) | lower | **14.8** | best | 23.8 | 77.4 | 69.3 |
| echo latency p50 / p90 (ms) | lower | 0.37 / 0.57 | 2nd | **0.14 / 0.19** | 11.37 / 11.45 | 2.14 / 2.60 |
| idle memory, PSS (MiB) | lower | 11.5 | 2nd | **4.3** | 94.7 | 80.0 |
| memory after flood (MiB) | lower | 19.7 | 2nd | **6.4** | 162.1 | 121.2 |

**Plain ASCII flood**

| metric | better | venomx | venomx rank | tmux | zellij | tuios |
|---|---|---|---|---|---|---|
| flood throughput (MiB/s) | higher | **177.9** | best | 77.1 | 37.2 | 80.5 |
| flood CPU (s) | lower | **0.15** | best | 0.21 | 0.49 | 0.46 |
| startup (ms) | lower | **15.7** | best | 21.8 | 77.4 | 68.8 |
| echo latency p50 / p90 (ms) | lower | 0.39 / 0.58 | 2nd | **0.14 / 0.19** | 11.36 / 11.48 | 2.14 / 2.57 |
| idle memory, PSS (MiB) | lower | 11.5 | 2nd | **4.3** | 94.9 | 79.9 |
| memory after flood (MiB) | lower | 19.2 | 2nd | **5.6** | 136.2 | 104.6 |
