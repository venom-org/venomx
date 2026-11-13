---
title: Keys and the attach client
order: 2
---

`venomx attach` (and the bare `venomx`) draws a session in your terminal. It
is one client among many: what it shows comes from the daemon, and what you
change locally (focus, scroll, zoom, selection) stays on this client.

```sh
venomx attach                       # most recently attached session
venomx attach --session s0          # a session, its lowest-ID window first
venomx attach --pane p0             # one pane, full screen
venomx attach --pane p0 --raw=true  # one pane, host terminal passthrough
```

`attach` never starts a daemon or creates anything. If the connection drops,
it reconnects for up to five seconds and resumes each pane where it left off.

## The leader

The client intercepts one key, the **leader**: `ctrl+b` by default, as in
tmux. It is a plain control byte, so it works over ssh and in any terminal.
Every other key, including `ctrl+a`, `shift+tab` and `esc`, goes to the
focused pane unchanged. There are no unprefixed bindings.

Press the leader twice to send it to the pane (Claude Code uses `ctrl+b` to
background a task).

After the leader the client waits for the next key, with no timeout by
default. If you pause for 200 ms, the **leader popup** lists the keys you can
press next, at the bottom of the pane area. It takes no focus, and if you type
faster than the delay you never see it.

- `esc` cancels from any level and clears this client's selection.
- `backspace` goes up one level.
- An unbound key cancels and is swallowed.
- `?` shows every binding of every active table in a list you can type to
  filter. `enter` runs the selected keys.

Change the leader, the delay and the timeout in
[configuration](configuration.md#keys).

## Default keys

All of these follow the leader.

| Key | Command | What it does |
|---|---|---|
| `h j k l`, arrows | `focus-left` ... `focus-right` | Move focus |
| `tab` / `shift+tab` | `focus-next` / `focus-prev` | Next / previous pane |
| `\` / `-` | `split-right` / `split-down` | Split the focused pane |
| `c` | `new-window` | New window |
| `n` / `p` / `1`-`9` | `window-next` / `window-prev` / `window-1`... | Switch window |
| `w` / `s` | `window-picker` / `session-picker` | Pick a window or session from a list |
| `r`, then `h j k l` | `resize-left` ... | Resize; stays in resize mode until `esc` |
| `[`, then `j k`, `pgup pgdn`, `{ }` | `scroll-*` | Scroll mode: lines, pages, previous / next command |
| `[`, then `v` | `copy-mode` | [Copy mode](#copy-mode): select and copy with vi keys |
| `pgup` / `pgdn` / `]` | `scroll-page-up` / `-down` / `scroll-bottom` | Scroll without entering scroll mode |
| `z` | `zoom` | Zoom the focused pane (this client only) |
| `!` | `focus-attention` | Jump to the next pane that needs attention |
| `X` | `close-pane` | Kill the focused pane and remove it |
| `f` / `F` / `x` | `toggle-floats` / `focus-float` / `dismiss-popup` | Floats and popups |
| `e` | `toggle-pane-float` | Float the focused pane, or tile it back |
| `:` | `command-prompt` | Type a command name |
| `?` | `all-keys` | Searchable list of every key |
| `L` | `lock` | Lock mode |
| `d` | `detach` | Detach |
| leader | `send-leader` | Send the leader to the pane |

Splits and new windows started from the keyboard run your login shell and are
removed when it exits. `X` sends SIGHUP to the pane's process group, escalates
to SIGKILL after two seconds, and removes the pane.

Command names also work at the `:` prompt. `:toggle-segment <id>` hides or
shows one [status line](status-line.md) segment on this client.

The sub-prefixes `v` (venom), `o` (venom-os) and `m` (yours) are reserved.
Products register their own tables there, and `m` is the place for
[your own bindings](configuration.md#your-own-key-tables).

## Copy mode

`ctrl+b [ v` starts copy mode on the focused pane: a block cursor you move
over the pane's screen and history with vi keys, to select text and copy it
with OSC 52. The status line shows `COPY`, and the view scrolls to keep the
cursor on screen. Copy mode is this client's own, like scrolling.

| Keys | What they do |
|---|---|
| `h j k l`, arrows | Move by a cell or a row |
| `w b e`, `W B E` | Next word, previous word, end of word (`W B E`: words split by blanks only) |
| `0` / `^` / `$` | Start of the row, first character, last character |
| `gg` / `G` | Oldest row of the history / the last row; `5G` goes to row 5 |
| `H` / `M` / `L` | Top, middle, bottom of the view |
| `ctrl+u` / `ctrl+d`, `ctrl+b` / `ctrl+f`, `pgup` / `pgdn` | Half a page, a page |
| `{` / `}` | Previous / next command (OSC 133 prompt marks) |
| `/` / `?`, then text and `enter` | Search forward / backward through the history, wrapping around |
| `n` / `N` | Repeat the search the same / the other way |
| `v` / `V` | Start or stop a character / line selection |
| `o` | Jump to the other end of the selection |
| `y`, `enter` | Copy the selection and leave; `y` with nothing selected copies the row |
| `esc` | Drop the selection; a second `esc` leaves |
| `q`, `ctrl+c` | Leave without copying |

The search line takes the status line while you type it (`backspace`,
`ctrl+u` to clear, `esc` to cancel). Search is plain text with smart case:
lowercase matches either case, and an uppercase letter makes it exact. The
cursor lands on the start of the match, so `v` and a motion select from there,
and the matches in view stay highlighted. `enter` on an empty line searches
for the last text again.

A number before a motion repeats it (`5j`, `3w`). The leader still works in
copy mode, and a mouse selection replaces the keyboard one. Leaving returns
the pane to its live screen.

## Lock mode

`ctrl+b L` sends every key to the pane, the leader included, until you press
the unlock key (`ctrl+alt+b`). The status line shows `LOCK`. Use it for a
nested multiplexer or a program that needs `ctrl+b`.

## Mouse

- The wheel scrolls the pane under the pointer.
- A left drag selects text and copies it with OSC 52, so it reaches your
  system clipboard if your terminal allows OSC 52.
- If the program in the pane asks for mouse events (vim, htop), they go to it,
  with coordinates relative to the pane. Hold `shift` at the start of a
  gesture to scroll or select locally anyway.
- `ctrl+shift+c` copies the selection again, as your terminal's own copy key
  would; it does not reach the pane. With no selection it does reach it.
- Typing returns a scrolled pane to its live screen and drops the selection.
  `ctrl` or `shift` pressed alone does neither.
- A left click on a status line segment runs that segment's click action, if
  it has one.
- Drag a float by its top border (the title line) to move it, or by its left,
  right or bottom border to resize it. After `ctrl+b`, a drag anywhere inside
  a float moves it. See [Floats and popups](#floats-and-popups).

## Paste

The client turns on bracketed paste in your terminal. A paste skips the key
bindings and goes to the pane where it started, wrapped in bracketed-paste
markers only if that pane asked for them.

## Floats and popups

Each window has a layer of **floating panes** above its tiles. A float is
drawn by every client showing the window, at a size and place resolved
against that client's own window area, and it never takes focus on its own.

| Key | Does |
|---|---|
| `ctrl+b f` | Show or hide floats on this client |
| `ctrl+b F` | Focus the next float |
| `ctrl+b x` | Close the focused popup |
| `ctrl+b e` | Float the focused pane, or put a float back in the tiles |

Floats are created with `venomx pane float`, usually from a named preset:

```sh
venomx pane float --window w0 --argv '["htop"]' --preset user.monitor
venomx pane float --window w0 --argv '["htop"]' \
    --width 60% --height 40% --anchor bottom_right --border rounded
```

`ctrl+b e` floats the focused pane at the `floats.default` size and keeps
your focus on it, showing floats again if you had hidden them. On a float it
does the opposite: the pane splits the largest tile of the window, side by
side when that tile is wide and stacked when it is tall. Popups stay popups.

**Moving and resizing a float.** With a float focused, the resize keys
(`ctrl+b r`, then `h j k l` or the arrows) resize the float itself rather
than a divider: `l` and `j` grow it by one cell, `h` and `k` shrink it, and
its top-left corner stays put. With the mouse, drag the title line to move
it, or a side or bottom border (or a bottom corner) to resize it; after
`ctrl+b`, a drag from anywhere inside it moves it. A float stays inside the
window and never gets smaller than its `min_cols` and `min_rows`. When you let
go, the new size and place are saved for the window, in cells, so every
client shows it there. Popups do not move.

**Hidden floats in the status line.** The status line's pane blocks list the
window's floats after its tiles. While `ctrl+b f` hides floats on your client,
their blocks stay, drawn dimmed and marked `⊘`, so you can still see what
runs in them.

`pane place` moves a pane between the tiled and floating layers, and
`pane raise` puts a float on top. Presets live in
[configuration](configuration.md#floats).

A **popup** is a float that appears on one client only, takes its focus, and
closes when its process exits, when you dismiss it, or when the client
detaches. A key binding opens one by passing the client's `{popup_ticket}` to
`pane popup`.

## Raw attach

`--raw=true` with `--pane` hands one pane straight to your terminal: venomx
replays the pane's history and screen, then forwards output without drawing
anything itself, so your terminal's own scrollback and selection work. Leader
`d` detaches and leader leader sends the leader.

venomx strips terminal queries and clipboard reads from the stream. Clipboard
writes pass for panes you can write to, unless `pane_stream.raw_clipboard` is
`.off`. If your terminal's size differs from the pane's, raw mode switches to
the normal emulated view for the rest of the attachment.
