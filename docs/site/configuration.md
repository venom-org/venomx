---
title: Configuration
order: 3
---

venomx reads [ZON](https://ziglang.org/documentation/master/#ZON), Zig's
data notation. There is no scripting: config is data, checked against a
schema before anything uses it.

## Files and layers

| Layer | Where |
|---|---|
| built-in | compiled in; `venomx config schema` lists every default |
| defaults | `$XDG_CONFIG_DIRS/venomx/defaults.zon`, for a distribution or venom-os |
| user | `$XDG_CONFIG_HOME/venomx/config.zon`, else `~/.config/venomx/config.zon` |

A later layer wins field by field. `venomx config get` prints the effective
config and says which layer each value came from.

## Changing config

Edit the file and reload, or let the verbs do it:

```sh
venomx config set --key theme --value .bone
venomx config set --key keys.leader --value '"ctrl+a"'
venomx config check            # validate every layer, change nothing
venomx config reload           # apply to the running daemon
```

`config set` validates the value and writes it to your file atomically, but
does not reload. `config reload` applies every setting that can change live
without touching your sessions. The `daemon.*` values only apply when the
daemon restarts; the reply says `restart_required` when that is the case.

`config set` and `config reload` need `admin`. At your own terminal, outside
any pane, set `VENOMX_TOKEN=@owner` for the call.

## A starting config

```zon
.{
    .theme = .trve,
    .keys = .{
        .leader = "ctrl+b",
        .unlock = "ctrl+alt+b",
        .popup_delay_ms = 200,
    },
    .attach = .{ .on_session_end = "next" },
    .attention = .{ .from_bell = true },
    .status = .{ .position = .top },
}
```

## Top-level sections

| Section | Controls |
|---|---|
| `theme` | `.trve` (dark, the default) or `.bone` (light) |
| `keys` | Leader, unlock key, popup delay, your key tables. See below. |
| `status` | The status line. See [Status line](status-line.md). |
| `floats` | The default float geometry and named presets. See below. |
| `attach` | `on_session_end`: `"exit"` (default) or `"next"`, to move to the most recent other session when yours ends |
| `attention` | `from_bell` (a bell marks the pane, default `true`) and `sticky` |
| `daemon` | `startup`, `interactive_start`, `startup_timeout_ms`. See [Daemon lifetime](daemon.md). |
| `recovery` | Checkpoints. Off by default. See [Daemon lifetime](daemon.md#checkpoints-and-restore). |
| `run` | Limits for `venomx run`: `max_active` (64), and how many finished runs are kept and for how long |
| `pane_stream` | Per-pane output ring, client backlog, scrollback (`max_history_rows`, 10000), the size policy for panes shown at several sizes (`.latest`, `.smallest`, `.fixed`), and `raw_clipboard` |
| `grants` | `isolation` (default `false`), what unknown callers and interactive panes may do while it is on, and the longest token lifetime. See [Isolation](isolation.md). |
| `log` | Log levels and formats |

`venomx config schema --json` has every field with its type, default and
whether it needs a restart.

## Keys

```zon
.keys = .{
    .leader = "ctrl+b",       // the one key the client intercepts
    .unlock = "ctrl+alt+b",   // leaves lock mode
    .popup_delay_ms = 200,    // 0 shows the leader popup at once
    .timeout_ms = 0,          // 0: wait for the next key forever
},
```

Keys are written as Kitty key names joined with `+` (`ctrl+a`,
`alt+shift+left`, `%`), and sequences are separated by spaces (`"s j"`).
`ctrl+b`, `ctrl+a` and `ctrl+space` work as a leader in any terminal.
`doctor` warns when you pick a leader your terminal can only send with the
Kitty keyboard protocol.

### Your own key tables

A key table lives under a one-key **sub-prefix** of the leader. `m` is
reserved for you:

```zon
.keys = .{
    .tables = .{
        .{
            .name = "mine",
            .prefix = "m",
            .label = "mine",
            .groups = .{ .{ .key = "s", .label = "scroll", .sticky = true } },
            .bind = .{
                .{ .key = "z", .label = "zoom it", .local = "zoom" },
                .{ .key = "c", .label = "clear attention", .verb = "pane.attention",
                   .args = "{\"pane\":\"{pane}\",\"clear\":true}" },
                .{ .key = "g", .label = "lazygit", .exec = .{ "lazygit-float", "{pane}" } },
                .{ .key = "s j", .local = "scroll-line-down" },
            },
        },
    },
},
```

With this, `ctrl+b m z` zooms. A binding has exactly one target:

- `.local`: a client command from the [key table](keys.md#default-keys).
- `.verb` with `.args`: a verb, sent with this client's own identity, so it
  gets exactly the permission a CLI call would. `.args` is a JSON object in a
  string.
- `.exec`: a program the client runs directly, with no shell, no input or
  output, and no venomx token in its environment. A failure shows in the
  status line.

`{pane}`, `{window}` and `{session}` stand for the focused pane's IDs. They
must fill a whole argv element or a whole JSON string value.

`.label` is what the leader popup shows. `.groups` name inner prefixes, and a
`sticky` group keeps the client in it after a binding runs, until `esc`.
`.when` limits a table to panes with certain [tags](agents.md#tags), for
example `.when = .{ .{ .key = "role", .value = "agent" } }`.

Products such as venom register their tables at run time under their own
sub-prefix (`v` for venom). To move one, without restating its bindings:

```zon
.keys = .{ .prefixes = .{ .{ .name = "venom", .prefix = "a" } } },
```

If two tables claim the same keys, the higher layer wins: your config, then
the defaults file, then product tables, then the built-in table.
`venomx keys list` shows every table, which layer it came from, and which
bindings are shadowed. `config check` fails on a clash within one layer.

## Floats

```zon
.floats = .{
    .default = .{ .width = "60%", .height = "60%", .anchor = .center, .border = .rounded },
    .presets = .{
        .@"user.monitor" = .{ .width = "50%", .height = "40%", .anchor = .bottom_right, .title = "monitor" },
    },
},
```

Sizes are cells (`"80"`) or a percent of the window area (`"60%"`). Anchors
are `center`, `top`, `bottom`, `left`, `right` and the four corners, with
`x` and `y` offsets. Below `min_cols` or `min_rows` a client shows the float
full-window. Borders are `none`, `single`, `rounded` or `heavy`.

Preset names are `<namespace>.<name>`. Products can ship presets with
`floats register`; a preset of the same name in your config wins field by
field.
