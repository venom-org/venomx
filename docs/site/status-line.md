---
title: Status line
order: 4
---

The status line is a row of **segments** on three sides: left, center and
right. venomx draws its own (`venomx.session`, `venomx.windows`, ...), and
anything with the right grant can add more: venom shows its agents there, a
script can show a build result, and your config can run a command for the
battery level.

## Layout

```zon
.status = .{
    .position = .top,      // or .bottom
    .left = .{ "venomx.session", "venomx.nested", "venomx.mode", "venomx.windows", "venomx.panes", "venomx.pane" },
    .center = .{},
    .right = .{ "venomx.message", "venomx.notify", "venomx.tray", "venomx.attention", "venomx.clock" },
    .unlisted = .show,     // .hide draws only the segments listed above
},
```

These are the defaults. The lists set the drawing order on each side. A
segment someone else publishes and you did not list goes on the side it asks
for, unless `.unlisted = .hide`.

| Segment | Shows |
|---|---|
| `venomx.session` | The session name |
| `venomx.nested` | A mark when this client runs inside another venomx pane |
| `venomx.mode` | The active key group, or `LOCK` |
| `venomx.windows` | The window list, the current one marked |
| `venomx.panes` | The panes of the window as `cwd › process`, tiles then floats; a float hidden on this client is dimmed and marked `⊘` |
| `venomx.pane` | Notes on the focused pane: zoomed, floating, watching only, an archive, its attention reason |
| `venomx.message` | Messages from this client, such as a binding that failed |
| `venomx.notify` | The latest notification |
| `venomx.tray` | Small icons from segments in the `tray` group |
| `venomx.attention` | How many panes need attention |
| `venomx.clock` | The time |

When the line is too short, segments with a lower `priority` (0 to 100) go
first, across all three sides.

## Segments in config

`.segments` changes any segment, yours or another product's, by id:

```zon
.status = .{
    .segments = .{
        // Only the focused pane: process, then ID.
        .{ .id = "venomx.panes", .panes = .focused, .format = "{pane.process} <{pane.id}>" },
        .{ .id = "venomx.clock", .format = "{clock:%a %d %H:%M}" },
        // The git branch, if something tagged the pane with it.
        .{ .id = "venomx.pane", .format = "{pane.tag.branch|}" },
        // A fixed segment of your own.
        .{ .id = "user.host", .text = "devbox", .side = .left, .priority = 20 },
        // Hide one.
        .{ .id = "venomx.attention", .show = false },
        // Give another product's segment a click.
        .{ .id = "venom.agents", .priority = 70, .click = .{ .local = "zoom" } },
    },
},
```

Your own segment ids start with `user.`. A click runs a
[key binding target](configuration.md#your-own-key-tables) as the clicking
client. `:toggle-segment <id>` at the command prompt hides or shows a segment
on one client until it detaches.

### Templates

`.format` takes `{name}`, `{name:spec}` and `{name|fallback}`. Text in
`[...]` is dropped when any variable inside it is empty, so
`"[{pane.tag.branch}] "` draws nothing on a pane with no branch tag.

Variables: `session.*`, `window.*`, `pane.*` (including `pane.tag.<key>`),
`attention.count`, `host`, `user` and `clock`.

### The tray

`venomx.tray` draws every segment with `.group = "tray"` as its icon, or its
text when it has none, and disappears while it has no members.

## Publishing from a program

A program with `write` on the server publishes a segment with `status set`.
With isolation off (the default, see [Isolation](isolation.md)) that is any
program you run. With `--ttl-ms` the segment lasts until it expires or is
cleared. Without it, it lasts until the program's connection closes
(`--bind daemon` keeps it until cleared):

```sh
venomx status set --id user.build --text "build ok" --style ok --ttl-ms 60000
venomx status clear --id user.build
venomx status list
```

`status set` also takes `--side`, `--priority`, `--group`, `--icon` and
`--click`. Any namespace but `venomx` is yours to use. With isolation on, a
program can only touch ids in its own namespace.

## Rules: segments from events

A **rule** turns [events](agents.md#events) into a segment inside the
daemon, so nothing has to stay connected and push updates. A rule only sees
events its owner can read, and needs `--ttl-ms`, `--clear-on`, or both:

```sh
venomx status rule set --id user.failed --on '["command.finished"]' \
    --match '[{"key":"exit_code","op":"ne","value":"0"}]' \
    --clear-on '["command.started"]' \
    --format 'failed ({event.exit_code})' --style error --ttl-ms 5000 --bind daemon
```

This shows the last failure for five seconds, or until the next command
starts. A rule goes when the connection that set it closes, so from a shell
pass `--bind daemon` to keep it until `status rule clear`. `command.*` events need [shell integration](getting-started.md#shell-integration).
`command.finished` carries the exit code and a command ID (`p0/c3`), not the
command line: only `command.started` has `cmdline`, so a rule can't pick out
one command by name when it ends (see [Test results](#test-results) for that).
`--scope event` puts the segment only in the session of the pane the event
came from. `status rule list` and `status rule clear` manage rules.

Rules can live in config too, as a `.segments` entry with a `.rule` and a
`.format`.

## Exec sources

An exec source runs a command from your config and shows what it prints:

```zon
.status = .{ .segments = .{
    .{ .id = "user.battery", .exec = .{ .argv = .{ "battery-status", "--short" }, .every_ms = 30000 }, .group = "tray" },
} },
```

With `.every_ms`, the command runs on that interval and the last line it
prints is the segment. Without it, the command keeps running and every line
replaces the segment (restarted with a backoff from 1 to 60 seconds if it
exits). A line starting with `{` is read as JSON `{"text","style","icon"}`.

The command runs with no shell, stdin from `/dev/null`, in `$HOME`, with
`VENOMX_SEGMENT` set to the segment id and no venomx token. Only the owner can
add or change an exec entry with `config set`. `doctor` lists the ones that
fail.

## Notifications

```sh
venomx notify post --text "deploy done"
venomx notify list
venomx notify dismiss --id n0
```

A notification shows in `venomx.notify` on every client. The daemon keeps the
newest 64. Dismissing hides it for your connection; `--all=true` hides it for
everyone.

## Attention

A pane can ask for you. `venomx pane attention --pane p1 --level warn
--reason "needs review"` marks it on every client and adds it to the count in
`venomx.attention`. Nothing moves anyone's focus: `ctrl+b !` jumps to the next
pane that needs attention. A bell in a pane marks it too, unless
`attention.from_bell` is `false`.

## Recipes

Each of these works on its own. To combine them, merge the `.segments`
entries into one `.status` block with one entry per id: two recipes that both
change `venomx.panes` become one entry. `venomx config check` rejects
anything else it can't use.

### Git branch

Let your shell tag the pane with its branch before each prompt, and show the
tag next to the pane:

```zsh
# ~/.zshrc, after the shell integration line
_venomx_branch() {
  [[ -n $VENOMX_PANE ]] || return
  local b
  b=$(git branch --show-current 2>/dev/null)
  if [[ -n $b ]]; then
    venomx pane tag --pane "$VENOMX_PANE" --set "[{\"key\":\"branch\",\"value\":\"$b\"}]" >/dev/null
  else
    venomx pane tag --pane "$VENOMX_PANE" --unset '["branch"]' >/dev/null
  fi
}
precmd_functions+=(_venomx_branch)
```

```zon
.{ .id = "venomx.pane", .format = "[ {pane.tag.branch}]" },
```

Outside a repository the tag goes away and the brackets drop the segment.

### What each agent is doing

An agent that reports its state with OSC 7501 (`working`, `blocked`, `done`,
...) sets `pane.program`. Put it in every pane block:

```zon
.{ .id = "venomx.panes", .format = "{pane.label}[ ·{pane.program}]" },
```

A pane with no state draws as before.

### ✓ or ✗ for the last command

Two rules on `command.finished`, one per outcome. Each clears when the next
command starts, and `.scope = "event"` keeps it to the session it came from:

```zon
.{ .id = "user.last_ok", .format = "✓", .style = .ok, .scope = "event", .ttl_ms = 30000,
   .rule = .{ .on = .{"command.finished"}, .clear_on = .{"command.started"},
              .match = .{.{ .key = "exit_code", .op = .eq, .value = "0" }} } },
.{ .id = "user.last_fail", .format = "✗ {event.exit_code}", .style = .@"error", .scope = "event", .ttl_ms = 30000,
   .rule = .{ .on = .{"command.finished"}, .clear_on = .{"command.started"},
              .match = .{.{ .key = "exit_code", .op = .ne, .value = "0" }} } },
```

### Test results

To name one command, wrap it and push the result with `status set`:

```zsh
t() {
  zig build test "$@"
  local rc=$?
  if (( rc == 0 )); then
    venomx status set --id user.tests --text "tests ok" --style ok --ttl-ms 600000 >/dev/null
  else
    venomx status set --id user.tests --text "tests failed" --style error --ttl-ms 600000 >/dev/null
  fi
  return rc
}
```

With `--ttl-ms` the result outlives the shell and stays for ten minutes.

### Battery in the tray

An exec source that prints JSON picks its own icon and style. This one turns
`warn` under 20%:

```sh
#!/bin/sh
# battery-status, somewhere on the daemon's PATH
cap=$(cat /sys/class/power_supply/BAT0/capacity)
if [ "$cap" -lt 20 ]; then style=warn; else style=normal; fi
printf '{"text":"%s%%","icon":"🔋","style":"%s"}\n' "$cap" "$style"
```

```zon
.{ .id = "user.battery", .exec = .{ .argv = .{"battery-status"}, .every_ms = 30000 }, .group = "tray" },
```

### A loud PROD marker

`.when` shows a segment only while the focused pane has those tags:

```zon
.{ .id = "user.prod", .text = " PROD ", .style = .@"error", .side = .center, .priority = 98,
   .when = .{.{ .key = "env", .value = "prod" }} },
```

Tag the pane from whatever opens the connection, for example an ssh wrapper:

```sh
venomx pane tag --pane "$VENOMX_PANE" --set '[{"key":"env","value":"prod"}]'
ssh prod-db "$@"
venomx pane tag --pane "$VENOMX_PANE" --unset '["env"]'
```

### A minimal line

Only what you list, at the bottom, with `user@host` in front:

```zon
.status = .{
    .position = .bottom,
    .left = .{ "venomx.mode", "user.where", "venomx.panes" },
    .center = .{"venomx.windows"},
    .right = .{ "venomx.attention", "venomx.clock" },
    .unlisted = .hide,
    .segments = .{
        .{ .id = "user.where", .format = "{user}@{host}", .style = .accent, .priority = 99 },
        .{ .id = "venomx.panes", .panes = .focused, .format = "{pane.cwd}" },
        .{ .id = "venomx.clock", .format = "{clock:%a %H:%M}" },
    },
},
```

With `.unlisted = .hide`, segments other programs publish don't show up
until you add their ids to a list.
