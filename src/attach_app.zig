//! `venomx attach` presentation state, free of I/O so it
//! can be tested headlessly. The daemon owns topology; this client owns the
//! active window, focus, per-pane scroll and selection, and never sends them.
//! Keybindings are `key → Command`: typed local actions, or schema verbs sent
//! to the daemon with the client's own identity and authorization.
const std = @import("std");
const term = @import("venom-term");
const Vt = @import("vt").Vt;
const layout = @import("layout.zig");
const geometry = @import("attach_layout.zig");
const edges = @import("attach_border.zig");
const text_width = term.widgets.text;
/// Stands for a space in a window name, so the name stays one word of the window list.
const nbsp = "\u{a0}";
const manifest = @import("manifest.zig");
const pane_stream = @import("pane_stream");
const PaneStream = pane_stream.PaneStream;
const ac = @import("attach_chrome.zig");
const keys = @import("keys.zig");
const floats = @import("floats.zig");
const Value = std.json.Value;
const Surface = term.Surface;
const Style = term.Style;
const Rect = geometry.Rect;
const popup_chrome = @import("term_chrome").leader_popup;
const popup_widget = term.widgets.leader_popup;
const chrome_theme = @import("chrome_theme.zig");
const restore_notice = @import("restore_notice.zig");
const denied_notice = @import("denied_notice.zig");
const fuzzy = @import("fuzzy.zig");
const fangs = @import("fangs.zig");
const pane_text = @import("pane_text.zig");

/// The active window's marker and the fang cut after the
/// session block; 2.3: the selected row's mark.
const active_mark = "▸";
const selected_mark = "▌";
/// A pane block in the status line: its process is cut to
/// `process_cells`, its cwd loses its start past `cwd_cells`.
const process_cells = 24;
const cwd_cells = 20;
const block_sep = " › ";
/// The pane blocks keep at least this many cells when other items crowd them.
const blocks_min: usize = 12;
/// The status line lists at most this many panes.
const max_listed = 64;

/// One pane's block in the status line (`panesText`, `drawPanes`).
const PaneBlock = struct {
    cwd: []const u8,
    process: []const u8,
    focus: bool,
    mark: ?edges.Mark = null,
    /// A float this client hides (`leader f`): drawn dimmed, after
    /// `hidden_glyph`.
    hidden: bool = false,
};
const hidden_glyph = "⊘";
/// The blocks as status text: ` [⊘ ]cwd › process [mark] `, one space between.
fn blocksText(a: std.mem.Allocator, blocks: []const PaneBlock) ![]const u8 {
    var line: std.ArrayList(u8) = .empty;
    for (blocks, 0..) |blk, i| {
        if (i > 0) try line.append(a, ' ');
        const sep = if (blk.cwd.len > 0 and blk.process.len > 0) block_sep else "";
        try line.print(a, " {s}{s}{s}{s}", .{ if (blk.hidden) hidden_glyph ++ " " else "", blk.cwd, sep, blk.process });
        if (blk.mark) |m| try line.print(a, " {s}", .{m.glyph});
        try line.append(a, ' ');
    }
    return line.items;
}
/// The cells `blocksText` gives `blocks`: ` cwd › process [mark] `, one
/// space between blocks.
fn blocksWidth(blocks: []const PaneBlock) usize {
    var w: usize = 0;
    for (blocks, 0..) |blk, i| {
        if (i > 0) w += 1;
        const sep: usize = if (blk.cwd.len > 0 and blk.process.len > 0) edges.cells(block_sep) else 0;
        w += 2 + edges.cells(blk.cwd) + sep + edges.cells(blk.process);
        if (blk.hidden) w += edges.cells(hidden_glyph) + 1;
        if (blk.mark) |m| w += 1 + edges.cells(m.glyph);
    }
    return w;
}
const session_name_cells = 24;
const window_name_cells = 16;

pub const Target = union(enum) { session: []const u8, pane: []const u8 };

/// Commands, key syntax and tables are shared with the daemon (keys.zig).
pub const Local = keys.Local;
pub const Verb = keys.Verb;
pub const Command = keys.Command;
pub const commandName = keys.commandName;
pub const parseCommand = keys.parseCommand;
const named = term.Input.NamedKey;
const copy_mode = @import("copy_mode.zig");
/// Key tables as `keys.list` reports them; the built-in table
/// and default leader until it answers (or when it is denied).
pub const KeyMap = struct {
    arena: ?std.heap.ArenaAllocator = null,
    tables: []const keys.Table = &.{keys.builtin_table},
    settings: keys.Settings = keys.default_settings,
    fn deinit(self: *KeyMap) void {
        if (self.arena) |*x| x.deinit();
        self.* = .{};
    }
};
/// An `exec` binding's argv with placeholders substituted, for the
/// transport to run (attach_exec.zig).
pub const Exec = struct {
    argv: [][]u8,
    pub fn deinit(self: Exec, a: std.mem.Allocator) void {
        for (self.argv) |x| a.free(x);
        a.free(self.argv);
    }
};

const Point = copy_mode.Point;
const Selection = struct { epoch: u64, anchor: Point, head: Point, dragging: bool = true };
pub const PaneView = struct {
    stream: PaneStream,
    /// Absolute top row while scrolled back; null follows the active area.
    scroll: ?u64 = null,
    scroll_epoch: u64 = 0,
    selection: ?Selection = null,
    /// The keyboard copy mode's cursor and selection, when on.
    copy: ?copy_mode.State = null,
    view: term.VtView = .{},
    rect: Rect = .{},
    started: bool = false,
    /// Counts the times this stream entered a snapshot or asked for a resync
    /// (`App.frame`), once per hold, so `HoldKey` can tell a re-entered
    /// snapshot from the same one.
    hold_gen: u32 = 0,
    /// The `hold_gen` this pane had when `App.tick` last ran with it focused,
    /// so a later `hold_gen` is a new snapshot even after a focus flip past
    /// the run's cap.
    timed_gen: u32 = 0,
    /// Pane output arrived since the last render.
    damaged: bool = false,
    /// When the pane's program turned synchronized output (mode 2026) on,
    /// while it is still on: it is partway through a frame.
    sync_since: ?i64 = null,
    /// Hash of the title its title line last showed; a different one needs a
    /// full redraw, since damage-only renders patch cells, not borders.
    drawn_title: u64 = 0,
    /// Set by a full render that drew this pane's title line; floats and
    /// lone panes have none.
    has_title_line: bool = false,
    /// The start row of the command block at `top`, so a
    /// scrolled frame does not search the history again. `oldest` is the
    /// oldest row when it was found: backfill below it can hold a start row
    /// a null search missed, while trimming history leaves it valid.
    block_cache: ?struct { epoch: u64, oldest: u64, top: u64, first: ?u64 } = null,
};
/// What a stream frame can change besides the pane's cells: when any of
/// it changes, the whole client redraws.
const Look = struct {
    vt: ?*anyopaque,
    epoch: u64,
    phase: pane_stream.Phase,
    writer: bool,
    backfill: @FieldType(PaneStream, "backfill"),
    exit: bool,
    closed: bool,
    fn of(p: *const PaneView) Look {
        const vt = p.stream.vt;
        return .{ .vt = if (vt) |v| v.impl else null, .epoch = if (vt) |v| v.rows().epoch else 0, .phase = p.stream.phase, .writer = p.stream.writer, .backfill = p.stream.backfill, .exit = p.stream.exit != null, .closed = p.stream.closed != null };
    }
};
/// `window-picker` / `session-picker`: a list this client
/// shows over the pane area. `⏎` switches this client only, `esc` closes.
/// `all-keys` is one too: every active binding, filtered by a
/// fuzzy query; `⏎` types the binding's keys.
const Picker = struct {
    /// For `keys`: `id` is the keys after the leader, `label` the group path
    /// and the binding's label, `seq` what `⏎` types.
    const Item = struct { id: []u8, label: []u8, seq: keys.Sequence = .{} };
    const max_query = 64;
    kind: enum { window, session, keys },
    items: std.ArrayList(Item) = .empty,
    /// Indexes into `items` that match `query`, best first (`filter`).
    shown: std.ArrayList(usize) = .empty,
    query: std.ArrayList(u8) = .empty,
    /// An index into `shown`.
    selected: usize = 0,
    fn deinit(self: *Picker, a: std.mem.Allocator) void {
        for (self.items.items) |i| {
            a.free(i.id);
            a.free(i.label);
        }
        self.items.deinit(a);
        self.shown.deinit(a);
        self.query.deinit(a);
    }
    fn add(self: *Picker, a: std.mem.Allocator, id: []const u8, comptime fmt: []const u8, args: anytype) !void {
        const owned = try a.dupe(u8, id);
        errdefer a.free(owned);
        const label = try std.fmt.allocPrint(a, fmt, args);
        errdefer a.free(label);
        try self.items.append(a, .{ .id = owned, .label = label });
    }
    fn move(self: *Picker, down: bool) void {
        const n = self.shown.items.len;
        if (n == 0) return;
        self.selected = if (down) (self.selected + 1) % n else (self.selected + n - 1) % n;
    }
    pub fn current(self: *const Picker) ?*const Item {
        if (self.selected >= self.shown.items.len) return null;
        return &self.items.items[self.shown.items[self.selected]];
    }
    /// `shown` for `query`: the matching items by score, then list order. An
    /// empty query keeps every item in order.
    fn filter(self: *Picker, a: std.mem.Allocator) !void {
        const Scored = struct { i: usize, s: i32 };
        var scored: std.ArrayList(Scored) = .empty;
        defer scored.deinit(a);
        for (self.items.items, 0..) |it, i| {
            if (fuzzy.scoreFields(&.{ it.id, it.label }, self.query.items)) |s| try scored.append(a, .{ .i = i, .s = s });
        }
        std.mem.sort(Scored, scored.items, {}, struct {
            fn lt(_: void, x: Scored, y: Scored) bool {
                return x.s > y.s or (x.s == y.s and x.i < y.i);
            }
        }.lt);
        self.shown.clearRetainingCapacity();
        try self.shown.ensureTotalCapacity(a, scored.items.len);
        for (scored.items) |x| self.shown.appendAssumeCapacity(x.i);
        if (self.selected >= self.shown.items.len) self.selected = 0;
    }
};
const Window = struct {
    id: []u8,
    /// The display name from `window.created` (empty: unnamed).
    name: []u8,
    session: []u8,
    revision: u64,
    nodes: []layout.Node,
    fn deinit(self: Window, a: std.mem.Allocator) void {
        for (self.nodes) |n| if (n.pane) |p| a.free(p);
        a.free(self.nodes);
        a.free(self.id);
        a.free(self.name);
        a.free(self.session);
    }
};
/// A sent `pane.resize` the window's tree does not show yet. `expect` is the
/// window revision its `layout_changed` will carry, one per moving press.
const Press = struct {
    id: i64,
    window: []u8,
    pane: []u8,
    axis: layout.Axis,
    delta: i64,
    expect: u64,
    fn deinit(self: Press, a: std.mem.Allocator) void {
        a.free(self.window);
        a.free(self.pane);
    }
};
pub const Request = struct { id: i64, verb: []const u8, params: []u8 };
/// Status of a restored archive pane, from the `recovery`
/// object of its pane snapshot entity. Shown only in the status line,
/// never inside terminal cells.
pub const Archive = struct {
    pane: []u8,
    process_state: enum { exited, interrupted },
    text_state: enum { omitted, expired, plain },
    cut_rows: u64 = 0,
};

const Paste = struct {
    pane: ?[]u8 = null,
    stream: u32 = 0,
    bracketed: bool = false,
    bytes: std.ArrayList(u8) = .empty,
    fn deinit(self: *Paste, a: std.mem.Allocator) void {
        if (self.pane) |id| a.free(id);
        self.bytes.deinit(a);
    }
};
const MouseCapture = struct { pane: []u8, local: bool };
/// A float being moved or resized with the mouse. `edges` names the
/// borders that follow the pointer; none moves the whole float.
const FloatDrag = struct {
    pane: []u8,
    edges: Edges = .{},
    from_x: i16,
    from_y: i16,
    start: Rect,
    const Edges = struct { left: bool = false, right: bool = false, bottom: bool = false };
    fn moving(self: FloatDrag) bool {
        return !self.edges.left and !self.edges.right and !self.edges.bottom;
    }
};
/// A floating pane of this session, or a popup opened for this
/// client. The daemon publishes the geometry spec; this client resolves it
/// against its own window area.
pub const Overlay = struct {
    pane: []u8,
    window: []u8,
    layer: floats.Layer,
    geometry: floats.Geometry,
    z: u64,
    /// Where this client drew it last (with border).
    outer: Rect = .{},
    full: bool = false,
    /// The outer rectangle a drag or resize key gave it here, drawn
    /// until the daemon's `pane.placed` for every sent `pane.place` lands.
    pinned: ?Rect = null,
    /// Sent `pane.place` calls not yet seen as `pane.placed`, and the last
    /// one's request ID (its error reply drops the pin).
    placing: u32 = 0,
    place_id: i64 = -1,
    /// Popups: the focus to return to when it closes.
    back: ?[]u8 = null,
    fn deinit(self: *Overlay, a: std.mem.Allocator) void {
        a.free(self.pane);
        a.free(self.window);
        a.free(self.geometry.title);
        if (self.back) |b| a.free(b);
    }
};
/// A binding waiting for its popup ticket: a verb's params, or an
/// exec argv, with `{popup_ticket}` still in place.
const Deferred = struct {
    id: i64,
    target: union(enum) { verb: struct { name: []const u8, params: []u8 }, exec: [][]u8 },
    fn deinit(self: Deferred, a: std.mem.Allocator) void {
        switch (self.target) {
            .verb => |v| a.free(v.params),
            .exec => |argv| {
                for (argv) |x| a.free(x);
                a.free(argv);
            },
        }
    }
};

/// How long input may stay held waiting for the server.
pub const hold_limit_ms: i64 = 5000;
/// How long a pane's open synchronized-output frame holds rendering before
/// the client draws anyway, so a program that dies mid-frame cannot freeze
/// the screen. Ghostty's limit too.
pub const sync_limit_ms: i64 = 1000;

pub const App = struct {
    a: std.mem.Allocator,
    target: Target,
    history: u64,
    shell: []const u8,
    raw: bool = false,
    cols: u16,
    rows: u16,
    windows: std.ArrayList(Window) = .empty,
    /// Snapshot entities stage here until the stream checkpoint.
    staged: ?std.ArrayList(Window) = null,
    /// Restored archive panes. An archive never becomes live: relaunch
    /// creates a new pane and removes this one (`pane.removed`).
    archives: std.ArrayList(Archive) = .empty,
    topology_ready: bool = false,
    /// The restore notice is shown once per attach.
    restore_noticed: bool = false,
    /// Pane of each principal seen in `principal.created`.
    principal_panes: denied_notice.Panes = .{},
    /// When `holdsInput` first held in this stretch (set by `tick`); after
    /// `hold_limit_ms` the hold is released, so a server that never answers
    /// cannot keep Ctrl-B d out of reach.
    held_since: ?i64 = null,
    /// What `held_since` was measured for. A different cause or focused pane
    /// is a new hold with a fresh `hold_limit_ms`.
    held_for: ?HoldKey = null,
    /// When the current unbroken run of holds began. Past twice
    /// `hold_limit_ms` a changed pane or a repeated cause no longer restarts
    /// the timer, so server-driven focus flips cannot hold input forever.
    held_first: ?i64 = null,
    /// The causes this run has already timed, whatever the pane. A cause not
    /// in the set always restarts the timer, however long the run has lasted.
    held_causes: std.EnumSet(HoldCause) = .empty,
    active: ?[]u8 = null,
    focus: ?[]u8 = null,
    /// The pane this client split off or the window it created, from
    /// the verb's reply. Focus moves there once the topology shows it.
    want_focus: ?WantFocus = null,
    panes: std.ArrayList(*PaneView) = .empty,
    next_stream: u32 = 1,
    next_request: i64 = 10,
    requests: std.ArrayList(Request) = .empty,
    pending: std.ArrayList(struct { id: i64, verb: []const u8, key: []const u8 = "" }) = .empty,
    /// Resize presses this client sent whose `window.layout_changed` has not
    /// arrived, so the tree still lacks them.
    presses: std.ArrayList(Press) = .empty,
    /// Bytes for the host terminal outside the Surface (OSC 52 copies).
    host: std.ArrayList(u8) = .empty,
    input: term.Input = .{},
    keymap: KeyMap = .{},
    /// Tables that arrived during leader mode, used once it ends. Replacing
    /// them mid-sequence would end it silently, and with `keys.timeout_ms = 0`
    /// the next key, however much later, would reach the pane.
    next_keymap: ?KeyMap = null,
    /// Leader and lock mode: keys typed after the leader,
    /// and the tables active when it was pressed.
    router: keys.Router,
    /// Focus moved in steps that `reconcile` finishes: it calls `refocusLeader`.
    refocus_due: bool = false,
    /// When the leader popup is up. `syncPopup` keeps it current.
    popup: popup_chrome.Timer = .{},
    /// Raw attach: the leader byte was seen.
    raw_leader: bool = false,
    /// Verb names of bound `.verb` targets, owned for queued requests.
    verb_names: std.ArrayList([]u8) = .empty,
    /// `exec` targets waiting for the transport.
    execs: std.ArrayList(Exec) = .empty,
    suppressed_keys: std.ArrayList(u21) = .empty,
    paste: ?Paste = null,
    input_frame_limit: usize = @import("proto").default_max_frame,
    mouse_geometry: Vt.MouseGeometry = .{},
    mouse_capture: ?MouseCapture = null,
    float_drag: ?FloatDrag = null,
    host_input_enabled: bool = false,
    prompt: ?std.ArrayList(u8) = null,
    /// The open window or session picker.
    picker: ?Picker = null,
    /// The session the user picked: the transport re-attaches to it.
    switch_to: ?[]u8 = null,
    message: std.ArrayList(u8) = .empty,
    quit: ?[]const u8 = null,
    exit_status: u8 = 0,
    /// The attached session was removed.
    session_ended: bool = false,
    /// Anything but pane cells changed: the next render redraws everything.
    dirty: bool = true,
    /// Only pane cells changed (PaneView.damaged): the next render
    /// rewrites just the rows those panes changed.
    pane_damage: bool = false,
    /// Shared content (segments, tags, attention, notifications).
    shared: ac.State,
    /// The locally zoomed pane (a viewing choice of this client).
    zoom: ?[]u8 = null,
    /// Started inside a venomx pane.
    nested: bool = false,
    /// What the host terminal can draw (heavy lines, the fang); see `edges.Support`.
    support: edges.Support = .{},
    /// Hash of the listed panes' processes and cwds as the status line's
    /// pane blocks last showed them (`statusKey`).
    status_key: u64 = 0,
    /// The pane blocks of the status line, as data for `drawPanes`: the
    /// item's text is not parsed to find them. Arena memory, valid only
    /// while `drawStatus` runs (or until the next `statusItems`).
    pane_blocks: []const PaneBlock = &.{},
    /// The attached session's name, from its `session` snapshot entity; the
    /// session block shows the ID until then, and when the name is empty.
    session_name: ?[]u8 = null,
    /// Tests pin the clock and the millisecond time.
    fixed_clock: ?[]const u8 = null,
    /// `$HOME` and the local hostname, for the `~` shortening of a pane's
    /// reported cwd. Borrowed; empty means none.
    home: []const u8 = "",
    local_host: []const u8 = "",
    fixed_now: ?i64 = null,
    /// Ids `toggle-segment` flipped on this client.
    toggled: std.ArrayList([]u8) = .empty,
    shown_minute: i64 = -1,
    /// Floats of this session and this client's popups.
    overlays: std.ArrayList(Overlay) = .empty,
    /// This connection's client ID, from its first popup ticket.
    client_id: ?[]u8 = null,
    /// `toggle-floats`: this client hides the float layer.
    floats_hidden: bool = false,
    /// Bindings waiting for a `popup.ticket` reply.
    deferred: std.ArrayList(Deferred) = .empty,
    /// Set while substituting: the binding needs a popup ticket.
    needs_ticket: bool = false,
    /// The chrome's Venom theme: the `theme` config key in venomx's
    /// edition, in the host's colour mode. Read once per attach, from
    /// `requestTheme`; it does not change while attached.
    chrome: term.theme.Chrome = chrome_theme.chrome(.trve, .ansi16),

    pub fn init(a: std.mem.Allocator, target: Target, size: struct { cols: u16, rows: u16 }, options: struct { history: u64 = 10000, shell: []const u8 = "/bin/sh" }) !App {
        var app: App = .{ .a = a, .target = target, .history = options.history, .shell = options.shell, .cols = @max(size.cols, 1), .rows = @max(size.rows, 1), .shared = .{ .a = a }, .router = .init(a) };
        if (target == .pane) {
            // A direct pane attach shows exactly one leaf, owned locally.
            try app.addPane(target.pane);
            app.focus = try a.dupe(u8, target.pane);
            app.topology_ready = true;
        }
        return app;
    }
    pub fn deinit(self: *App) void {
        if (self.session_name) |n| self.a.free(n);
        for (self.toggled.items) |t| self.a.free(t);
        self.toggled.deinit(self.a);
        self.principal_panes.deinit(self.a);
        for (self.windows.items) |w| w.deinit(self.a);
        self.windows.deinit(self.a);
        for (self.archives.items) |x| self.a.free(x.pane);
        self.archives.deinit(self.a);
        if (self.staged) |*s| {
            for (s.items) |w| w.deinit(self.a);
            s.deinit(self.a);
        }
        for (self.panes.items) |p| {
            p.stream.deinit();
            self.a.destroy(p);
        }
        self.panes.deinit(self.a);
        for (self.requests.items) |r| self.a.free(r.params);
        self.requests.deinit(self.a);
        self.pending.deinit(self.a);
        for (self.presses.items) |x| x.deinit(self.a);
        self.presses.deinit(self.a);
        self.host.deinit(self.a);
        self.suppressed_keys.deinit(self.a);
        if (self.paste) |*paste| paste.deinit(self.a);
        self.releaseMouse();
        self.endFloatDrag();
        if (self.prompt) |*p| p.deinit(self.a);
        if (self.picker) |*p| p.deinit(self.a);
        if (self.switch_to) |x| self.a.free(x);
        self.message.deinit(self.a);
        if (self.active) |x| self.a.free(x);
        if (self.focus) |x| self.a.free(x);
        if (self.want_focus) |x| x.deinit(self.a);
        if (self.zoom) |x| self.a.free(x);
        self.shared.deinit();
        self.router.deinit();
        self.keymap.deinit();
        if (self.next_keymap) |*m| m.deinit();
        for (self.verb_names.items) |x| self.a.free(x);
        self.verb_names.deinit(self.a);
        for (self.execs.items) |x| x.deinit(self.a);
        self.execs.deinit(self.a);
        for (self.overlays.items) |*o| o.deinit(self.a);
        self.overlays.deinit(self.a);
        if (self.client_id) |x| self.a.free(x);
        for (self.deferred.items) |d| d.deinit(self.a);
        self.deferred.deinit(self.a);
    }
    pub fn say(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.message.clearRetainingCapacity();
        self.message.print(self.a, fmt, args) catch {};
        self.dirty = true;
    }

    // ------------------------------------------------------------ topology

    fn window(self: *const App, id: []const u8) ?*Window {
        for (self.windows.items) |*w| if (std.mem.eql(u8, w.id, id)) return w;
        return null;
    }
    pub fn activeWindow(self: *const App) ?*Window {
        return self.window(self.active orelse return null);
    }
    pub fn pane(self: *const App, id: []const u8) ?*PaneView {
        for (self.panes.items) |p| if (std.mem.eql(u8, p.stream.pane, id)) return p;
        return null;
    }
    pub fn streamPane(self: *const App, stream: u32) ?*PaneView {
        for (self.panes.items) |p| if (p.stream.id == stream) return p;
        return null;
    }
    pub fn overlay(self: *const App, id: []const u8) ?*Overlay {
        for (self.overlays.items) |*o| if (std.mem.eql(u8, o.pane, id)) return o;
        return null;
    }
    /// Popups always; floats of the active window unless hidden.
    fn overlayVisible(self: *const App, o: *const Overlay) bool {
        return switch (o.layer) {
            .popup => true,
            .float => !self.floats_hidden and self.active != null and std.mem.eql(u8, self.active.?, o.window),
            .tile => false,
        };
    }
    /// Whether this client shows the pane: a leaf of the active window, or
    /// a visible float or popup.
    pub fn visibleNow(self: *const App, id: []const u8) bool {
        if (self.target == .pane) return std.mem.eql(u8, id, self.target.pane);
        if (self.activeWindow()) |w| if (contains(w.nodes, id)) return true;
        if (self.overlay(id)) |o| return self.overlayVisible(o);
        return false;
    }
    /// Visible overlays bottom to top: floats by z, then popups by z.
    pub fn overlayOrder(self: *const App, a: std.mem.Allocator) ![]*Overlay {
        var out: std.ArrayList(*Overlay) = .empty;
        for (self.overlays.items) |*o| if (self.overlayVisible(o)) try out.append(a, o);
        std.mem.sort(*Overlay, out.items, {}, struct {
            fn lt(_: void, x: *Overlay, y: *Overlay) bool {
                if (x.layer != y.layer) return x.layer == .float;
                return x.z < y.z;
            }
        }.lt);
        return out.items;
    }
    /// A pane entity or `pane.created` / `pane.placed` data. True when this
    /// client's overlays changed. `opening`: a new popup takes focus.
    fn noteOverlay(self: *App, v: Value, opening: bool) !bool {
        const id = string(v, "pane") orelse return error.BadEvent;
        const layer = std.meta.stringToEnum(floats.Layer, string(v, "layer") orelse "tile") orelse return error.BadEvent;
        if (layer == .tile) return self.dropOverlay(id);
        if (self.target != .session) return false;
        const window_id = string(v, "window") orelse return error.BadEvent;
        const parsed = floats.Geometry.fromWire(field(v, "float") orelse return error.BadEvent) orelse return error.BadEvent;
        if (self.overlay(id)) |o| {
            const title = try self.a.dupe(u8, parsed.geometry.title);
            errdefer self.a.free(title);
            const win = try self.a.dupe(u8, window_id);
            self.a.free(o.geometry.title);
            self.a.free(o.window);
            o.window = win;
            o.geometry = parsed.geometry;
            o.geometry.title = title;
            o.z = parsed.z;
            o.layer = layer;
            // The daemon's geometry replaces this client's pin once
            // every `pane.place` it sent has landed and no drag holds it.
            if (o.placing > 0) o.placing -= 1;
            if (o.placing == 0 and !self.dragging(id)) o.pinned = null;
            return true;
        }
        if (string(v, "session")) |sid| {
            if (!std.mem.eql(u8, sid, self.target.session)) return false;
        } else if (self.window(window_id) == null) return false;
        // A popup is seen only by the client it was opened for.
        if (layer == .popup) {
            const mine = self.client_id orelse return false;
            if (!std.mem.eql(u8, mine, string(v, "client") orelse return false)) return false;
        }
        try self.overlays.ensureUnusedCapacity(self.a, 1);
        const owned = try self.a.dupe(u8, id);
        errdefer self.a.free(owned);
        const win = try self.a.dupe(u8, window_id);
        errdefer self.a.free(win);
        var geo = parsed.geometry;
        geo.title = try self.a.dupe(u8, geo.title);
        self.overlays.appendAssumeCapacity(.{ .pane = owned, .window = win, .layer = layer, .geometry = geo, .z = parsed.z });
        // A popup takes focus on its client; a float never does.
        if (layer == .popup and opening) {
            const o = &self.overlays.items[self.overlays.items.len - 1];
            if (self.focus) |f| o.back = try self.a.dupe(u8, f);
            try self.setFocus(id);
        }
        return true;
    }
    fn dropOverlay(self: *App, id: []const u8) bool {
        for (self.overlays.items, 0..) |*o, i| if (std.mem.eql(u8, o.pane, id)) {
            var gone = self.overlays.orderedRemove(i);
            defer gone.deinit(self.a);
            if (self.focus) |f| if (std.mem.eql(u8, f, id)) {
                self.a.free(f);
                self.focus = null;
                // Back to where the human was, if that is still shown.
                if (gone.back) |b| if (self.visibleNow(b)) {
                    self.focus = b;
                    gone.back = null;
                };
                self.refocus_due = true;
            };
            return true;
        };
        return false;
    }
    fn clearOverlays(self: *App) void {
        for (self.overlays.items) |*o| o.deinit(self.a);
        self.overlays.clearRetainingCapacity();
    }
    fn addPane(self: *App, id: []const u8) !void {
        const view = try self.a.create(PaneView);
        errdefer self.a.destroy(view);
        view.* = .{ .stream = try PaneStream.init(self.a, id, self.next_stream, .{ .cols = 80, .rows = 24 }, self.history) };
        errdefer view.stream.deinit();
        view.stream.cell = hostCell(self.mouse_geometry);
        self.next_stream += 2;
        // ATTACH waits for place(): a claiming attach sets the shared size.
        try self.panes.append(self.a, view);
    }
    fn reconcile(self: *App) !void {
        try self.reconcileViews();
        // Last: a removed pane moves focus in steps, and only here has it landed.
        if (self.refocus_due) try self.refocusLeader();
    }
    /// Every displayed pane has one stream; hidden ones are detached. Leaves
    /// `refocus_due` to the caller, which may be about to move focus again.
    fn reconcileViews(self: *App) !void {
        if (self.target == .pane) return self.place();
        const w = self.activeWindow();
        var i: usize = 0;
        while (i < self.panes.items.len) {
            const p = self.panes.items[i];
            if (!self.visibleNow(p.stream.pane)) {
                try p.stream.detach();
                // Keep it until its CLOSE has been handed to the transport.
                if (p.stream.outbox.items.len == 0) {
                    p.stream.deinit();
                    self.a.destroy(self.panes.orderedRemove(i));
                    continue;
                }
            }
            i += 1;
        }
        if (w) |win| for (win.nodes) |n| if (n.kind == .pane and self.pane(n.pane.?) == null) try self.addPane(n.pane.?);
        for (self.overlays.items) |*o| if (self.overlayVisible(o) and self.pane(o.pane) == null) try self.addPane(o.pane);
        // A removed focused pane falls back to the lowest-ID surviving pane.
        if (self.zoom) |z| if (w == null or !contains(w.?.nodes, z)) self.unzoom();
        if (self.focus) |f| if (!self.visibleNow(f)) {
            self.a.free(f);
            self.focus = null;
            self.refocus_due = true;
        };
        if (self.focus == null) if (w) |win| if (lowest(win.nodes)) |id| {
            self.focus = try self.a.dupe(u8, id);
            self.refocus_due = true;
        };
        try self.place();
        self.dirty = true;
    }
    /// Focus moved, so leader mode goes on with the new pane's
    /// tables, or ends if the typed keys no longer lead anywhere.
    fn refocusLeader(self: *App) !void {
        self.refocus_due = false;
        if (!self.router.pending()) return;
        _ = try self.router.refocus(self.keymap.tables, .{ .ctx = self, .f = whenActive });
        // The popup's rows can change without its level changing.
        self.dirty = true;
        self.syncPopup();
    }
    /// Drop streams whose CLOSE has been sent and that are no longer shown.
    /// Hand the queued verb requests to `send` as NDJSON lines, oldest first.
    /// A request leaves the queue before its params are freed, so when `send`
    /// fails part-way the queue holds exactly the unsent requests and `deinit`
    /// frees each once (as `PaneStream.flush` does for frames).
    pub fn flushRequests(self: *App, ctx: anytype, comptime send: fn (@TypeOf(ctx), []const u8) anyerror!void) !void {
        var sent: usize = 0;
        defer {
            for (self.requests.items[0..sent]) |r| self.a.free(r.params);
            const left = self.requests.items.len - sent;
            std.mem.copyForwards(Request, self.requests.items[0..left], self.requests.items[sent..]);
            self.requests.items.len = left;
        }
        for (self.requests.items) |r| {
            const line = try std.fmt.allocPrint(self.a, "{{\"id\":{d},\"verb\":\"{s}\",\"params\":{s}}}", .{ r.id, r.verb, r.params });
            defer self.a.free(line);
            try send(ctx, line);
            sent += 1;
        }
    }
    pub fn collect(self: *App) void {
        var i: usize = 0;
        while (i < self.panes.items.len) {
            const p = self.panes.items[i];
            if (!self.visibleNow(p.stream.pane) and p.stream.phase == .closed and p.stream.outbox.items.len == 0) {
                p.stream.deinit();
                self.a.destroy(self.panes.orderedRemove(i));
            } else i += 1;
        }
    }
    fn chooseWindow(self: *App) !void {
        if (self.active) |id| if (self.window(id) != null) return;
        if (self.active) |id| self.a.free(id);
        self.active = null;
        var best: ?*Window = null;
        for (self.windows.items) |*w| if (best == null or idLess(w.id, best.?.id)) {
            best = w;
        };
        if (best) |w| self.active = try self.a.dupe(u8, w.id);
    }
    fn parseWindow(self: *App, v: Value) !?Window {
        const id = string(v, "window") orelse return error.BadEvent;
        const session = string(v, "session") orelse return error.BadEvent;
        if (!std.mem.eql(u8, session, self.target.session)) return null;
        const nodes_value = field(v, "nodes") orelse return error.BadEvent;
        if (nodes_value != .array) return error.BadEvent;
        const nodes = try self.a.alloc(layout.Node, nodes_value.array.items.len);
        var filled: usize = 0;
        errdefer {
            for (nodes[0..filled]) |n| if (n.pane) |p| self.a.free(p);
            self.a.free(nodes);
        }
        for (nodes_value.array.items, nodes) |item, *n| {
            const kind = string(item, "kind") orelse return error.BadEvent;
            n.* = .{ .kind = if (std.mem.eql(u8, kind, "pane")) .pane else if (std.mem.eql(u8, kind, "split")) .split else return error.BadEvent };
            if (string(item, "axis")) |axis| n.axis = std.meta.stringToEnum(layout.Axis, axis) orelse return error.BadEvent;
            if (field(item, "first")) |x| n.first = try index(x);
            if (field(item, "second")) |x| n.second = try index(x);
            if (field(item, "ratio")) |x| n.ratio = std.math.cast(u16, try index(x)) orelse return error.BadEvent;
            if (string(item, "pane")) |p| n.pane = try self.a.dupe(u8, p);
            filled += 1;
        }
        if (!layout.valid(nodes)) return error.BadEvent;
        const revision: u64 = if (field(v, "revision")) |r| @intCast(try index(r)) else 0;
        const owned_id = try self.a.dupe(u8, id);
        errdefer self.a.free(owned_id);
        const owned_name = try self.a.dupe(u8, string(v, "name") orelse "");
        errdefer self.a.free(owned_name);
        return .{ .id = owned_id, .name = owned_name, .session = try self.a.dupe(u8, session), .revision = revision, .nodes = nodes };
    }
    fn upsert(self: *App, list: *std.ArrayList(Window), w: Window) !void {
        for (list.items) |*old| if (std.mem.eql(u8, old.id, w.id)) {
            // Revisions only increase; a stale replay never rolls topology back.
            if (w.revision != 0 and old.revision > w.revision) return w.deinit(self.a);
            // `window.layout_changed` carries no name and a name never changes.
            var next = w;
            if (w.name.len == 0 and old.name.len > 0) {
                const kept = self.a.dupe(u8, old.name) catch |err| {
                    w.deinit(self.a);
                    return err;
                };
                self.a.free(next.name);
                next.name = kept;
            }
            old.deinit(self.a);
            old.* = next;
            return;
        };
        list.append(self.a, w) catch |err| {
            w.deinit(self.a);
            return err;
        };
    }
    fn removeWindow(list: *std.ArrayList(Window), a: std.mem.Allocator, id: []const u8) void {
        for (list.items, 0..) |w, i| if (std.mem.eql(u8, w.id, id)) {
            w.deinit(a);
            _ = list.orderedRemove(i);
            return;
        };
    }
    /// One `state.snapshot` entity; an error means the entity is bad.
    fn snapshotEntity(self: *App, e: Value) !void {
        const t = string(e, "entity_type") orelse return;
        if (std.mem.eql(u8, t, "pane")) {
            const content = string(e, "content") orelse return error.BadEvent;
            const parsed = try std.json.parseFromSlice(Value, self.a, content, .{});
            defer parsed.deinit();
            try self.noteArchive(parsed.value);
            try self.shared.paneEntity(parsed.value);
            _ = try self.noteOverlay(parsed.value, false);
        } else if (std.mem.eql(u8, t, "program_status")) {
            const content = string(e, "content") orelse return error.BadEvent;
            const parsed = try std.json.parseFromSlice(Value, self.a, content, .{});
            defer parsed.deinit();
            try self.shared.programChanged(parsed.value);
            self.dirty = true;
        } else if (std.mem.eql(u8, t, "command")) {
            const content = string(e, "content") orelse return error.BadEvent;
            const parsed = try std.json.parseFromSlice(Value, self.a, content, .{});
            defer parsed.deinit();
            try self.shared.commandEntity(parsed.value);
            self.dirty = true;
        } else if (std.mem.eql(u8, t, "status") or std.mem.eql(u8, t, "notification")) {
            const content = string(e, "content") orelse return error.BadEvent;
            const parsed = try std.json.parseFromSlice(Value, self.a, content, .{});
            defer parsed.deinit();
            if (t[0] == 's') try self.shared.upsertSegment(parsed.value) else try self.shared.posted(parsed.value, self.now());
            self.dirty = true;
        } else if (std.mem.eql(u8, t, "window") and self.target == .session) {
            const content = string(e, "content") orelse return error.BadEvent;
            const parsed = try std.json.parseFromSlice(Value, self.a, content, .{});
            defer parsed.deinit();
            if (try self.parseWindow(parsed.value)) |w| try self.upsert(&self.staged.?, w);
        } else if (std.mem.eql(u8, t, "session") and self.target == .session) {
            const content = string(e, "content") orelse return error.BadEvent;
            const parsed = try std.json.parseFromSlice(Value, self.a, content, .{});
            defer parsed.deinit();
            const sid = string(parsed.value, "session") orelse return error.BadEvent;
            if (!std.mem.eql(u8, sid, self.target.session)) return;
            const owned = try self.a.dupe(u8, string(parsed.value, "name") orelse "");
            if (self.session_name) |old| self.a.free(old);
            self.session_name = owned;
            self.dirty = true;
        }
    }
    /// One event item from the `events` subscription.
    pub fn event(self: *App, item: Value) !void {
        const kind = string(item, "type") orelse return error.BadEvent;
        const data = field(item, "data") orelse Value{ .object = .empty };
        if (std.mem.eql(u8, kind, "state.snapshot")) {
            if (self.staged == null) {
                self.staged = .empty;
                // A snapshot replaces every shared chrome item.
                self.shared.reset();
                self.clearOverlays();
            }
            const entities = field(data, "entities") orelse return error.BadEvent;
            if (entities != .array) return error.BadEvent;
            // One bad entity must not drop the rest of the snapshot: skip
            // it. Only running out of memory aborts.
            for (entities.array.items) |e| {
                self.snapshotEntity(e) catch |err| {
                    const any: anyerror = err;
                    if (any == error.OutOfMemory) return err;
                };
            }
            return;
        }
        if (std.mem.eql(u8, kind, "stream.checkpoint")) {
            if (self.staged) |*staged| {
                for (self.windows.items) |w| w.deinit(self.a);
                self.windows.deinit(self.a);
                self.windows = staged.*;
                self.staged = null;
            }
            self.topology_ready = true;
            try self.noticeRestore();
        } else if (std.mem.eql(u8, kind, "window.created") or std.mem.eql(u8, kind, "window.layout_changed")) {
            const w = try self.parseWindow(data) orelse return;
            try self.upsert(if (self.staged) |*s| s else &self.windows, w);
        } else if (std.mem.eql(u8, kind, "pane.created") or std.mem.eql(u8, kind, "pane.placed") or std.mem.eql(u8, kind, "pane.raised")) {
            self.dirty = true;
            if (kind[5] == 'c') try self.shared.paneCreated(data);
            if (kind[5] == 'r') {
                const o = self.overlay(string(data, "pane") orelse return error.BadEvent) orelse return;
                if (field(data, "z")) |z| o.z = @intCast(try index(z));
                return self.place();
            }
            if (!try self.noteOverlay(data, kind[5] == 'c')) return;
        } else if (std.mem.eql(u8, kind, "pane.removed")) {
            const id = string(data, "pane") orelse return error.BadEvent;
            if (self.want_focus) |x| if (std.mem.eql(u8, x.pane, id)) self.dropWantFocus();
            self.dropArchive(id);
            self.shared.removePane(id);
            self.dirty = true;
            if (!self.dropOverlay(id)) return;
        } else if (std.mem.startsWith(u8, kind, "principal.")) {
            try self.principalEvent(kind, string(item, "resource"), data);
            return;
        } else if (try self.chromeEvent(kind, data)) {
            self.dirty = true;
            return;
        } else if (std.mem.eql(u8, kind, "session.removed")) {
            const id = string(data, "session") orelse return error.BadEvent;
            if (self.target == .session and std.mem.eql(u8, id, self.target.session)) {
                for (self.panes.items) |x| try x.stream.detach();
                self.session_ended = true;
                self.quit = "session ended";
            }
            return;
        } else if (std.mem.eql(u8, kind, "window.removed")) {
            const id = string(data, "window") orelse return error.BadEvent;
            removeWindow(if (self.staged) |*s| s else &self.windows, self.a, id);
        } else return;
        if (self.staged == null) {
            self.prunePresses();
            try self.chooseWindow();
            try self.reconcile();
            try self.applyWantFocus();
        }
    }

    /// Denial notifications. `principal.created` teaches which pane a
    /// principal is; a `principal.denied` write on a pane of this session
    /// becomes a notification for its TTL. Nothing is drawn on the target
    /// pane. Other denials, and targets that are not panes of this session,
    /// show nothing. A principal not known to be a pane (made before this
    /// client attached) is named by its principal ID.
    fn principalEvent(self: *App, kind: []const u8, resource: ?[]const u8, data: Value) !void {
        const prefix = "principal:";
        const res = resource orelse return;
        if (!std.mem.startsWith(u8, res, prefix)) return;
        const who = res[prefix.len..];
        if (std.mem.eql(u8, kind, "principal.created")) {
            try self.principal_panes.learn(self.a, who, string(data, "pane"), string(data, "parent"));
        } else if (std.mem.eql(u8, kind, "principal.revoked")) {
            self.principal_panes.forget(self.a, who);
        } else if (std.mem.eql(u8, kind, "principal.denied")) {
            const right = string(data, "right") orelse return;
            if (!std.mem.eql(u8, right, "write")) return;
            const target = denied_notice.targetPane(string(data, "resource")) orelse return;
            switch (self.target) {
                .session => |sid| {
                    const info = self.shared.pane(target) orelse return;
                    if (!std.mem.eql(u8, info.session, sid)) return;
                },
                // A pane attach shows it for its own pane only; raw has none.
                .pane => |pid| if (self.raw or !std.mem.eql(u8, pid, target)) return,
            }
            const name = self.principal_panes.paneOf(who) orelse who;
            // Not "another pane": a pane denied on itself is not this notice.
            if (std.mem.eql(u8, name, target)) return;
            const text = try denied_notice.format(self.a, name, target, string(data, "verb") orelse "?");
            defer self.a.free(text);
            const id = try denied_notice.noteId(self.a, name, target);
            defer self.a.free(id);
            try self.shared.postLocal(id, text, .urgent, denied_notice.ttl_ms, self.now());
            self.dirty = true;
        }
    }

    /// The principals that existed before attach, from `grant.list`'s
    /// `principals` array (`principal`, `pane`, `parent`).
    pub fn seedPrincipals(self: *App, principals: Value) !void {
        if (principals != .array) return;
        for (principals.array.items) |p| {
            const id = string(p, "principal") orelse continue;
            try self.principal_panes.learn(self.a, id, string(p, "pane"), string(p, "parent"));
        }
    }

    /// Shared-state events. False when `kind` is not one.
    fn chromeEvent(self: *App, kind: []const u8, data: Value) !bool {
        const is = std.mem.eql;
        if (is(u8, kind, "status.changed")) {
            try self.shared.upsertSegment(field(data, "segment") orelse return error.BadEvent);
        } else if (is(u8, kind, "status.cleared")) {
            self.shared.dropSegment(string(data, "id") orelse return error.BadEvent);
        } else if (is(u8, kind, "pane.tags_changed")) {
            try self.shared.tagsChanged(data);
        } else if (is(u8, kind, "pane.attention_changed")) {
            try self.shared.attentionChanged(data);
            try self.clearSeenAttention(data);
        } else if (is(u8, kind, "program.status_changed")) {
            try self.shared.programChanged(data);
        } else if (is(u8, kind, "command.started")) {
            try self.shared.commandStarted(data);
        } else if (is(u8, kind, "command.finished")) {
            try self.shared.commandFinished(data);
        } else if (is(u8, kind, "pane.process_changed")) {
            try self.shared.processChanged(data);
        } else if (is(u8, kind, "pane.title_changed")) {
            try self.shared.titleChanged(data);
        } else if (is(u8, kind, "notify.posted")) {
            try self.shared.posted(data, self.now());
        } else if (is(u8, kind, "notify.dismissed")) {
            self.shared.dismiss(string(data, "id") orelse return error.BadEvent);
        } else if (is(u8, kind, "config.changed") or is(u8, kind, "config.reloaded")) {
            try self.requestConfig();
        } else if (is(u8, kind, "keys.changed")) {
            try self.requestKeys();
        } else return false;
        return true;
    }
    /// On the first view of a session that still holds
    /// restored (un-relaunched) archive panes, a notification for its TTL. The
    /// daemon publishes no restore summary, so this is the
    /// panes' own archives; "agents resumed" and "grants dropped" are left out
    /// until it does.
    fn noticeRestore(self: *App) !void {
        if (self.restore_noticed or self.target != .session) return;
        // Only this session's restored panes count: the snapshot lists the
        // whole daemon's panes.
        var panes: usize = 0;
        var attention: std.ArrayList([]const u8) = .empty;
        defer attention.deinit(self.a);
        for (self.archives.items) |x| {
            const info = self.shared.pane(x.pane) orelse continue;
            if (!std.mem.eql(u8, info.session, self.target.session)) continue;
            panes += 1;
            if (info.level != .none) try attention.append(self.a, x.pane);
        }
        if (panes == 0) return;
        const text = try restore_notice.format(self.a, .{ .panes = panes, .attention = attention.items });
        defer self.a.free(text);
        try self.shared.postLocal(restore_notice.id, text, if (attention.items.len > 0) .warn else .info, restore_notice.ttl_ms, self.now());
        // Set only once posted: a failed post is retried at the next checkpoint.
        self.restore_noticed = true;
        self.dirty = true;
    }
    /// Status-line and attention settings come from the daemon's config (`config.get`).
    pub fn requestConfig(self: *App) !void {
        try self.requestKeyed("config.get", "status", .{ .key = "status" });
        try self.requestKeyed("config.get", "attention", .{ .key = "attention" });
        try self.requestKeys();
    }
    /// The `theme` config key, once per attach. Not part of
    /// `requestConfig`, which a reload repeats: the chrome keeps the theme it
    /// attached with.
    pub fn requestTheme(self: *App) !void {
        try self.requestKeyed("config.get", "theme", .{ .key = "theme" });
    }
    /// A `config.get` result for `theme`. An unreadable value keeps the default.
    fn applyTheme(self: *App, content: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const source = arena.allocator().dupeSentinel(u8, content, 0) catch return;
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        const name = std.zon.parse.fromSlice(chrome_theme.Name, .{ .gpa = arena.allocator(), .arena = arena.allocator(), .source = source, .diagnostics = &diagnostics }) catch return;
        self.chrome = chrome_theme.chrome(name, self.chrome.mode);
    }
    /// Every layer's tables, resolved here against the focused pane.
    pub fn requestKeys(self: *App) !void {
        try self.requestKeyed("keys.list", "keys", struct {}{});
    }
    /// A `keys.list` result. Unreadable parts keep the previous key map.
    pub fn applyKeys(self: *App, ok: Value) !void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        errdefer arena.deinit();
        const x = arena.allocator();
        var map: KeyMap = .{};
        map.settings.leader = keys.parseChord(string(ok, "leader") orelse return arena.deinit()) orelse return arena.deinit();
        map.settings.unlock = keys.parseChord(string(ok, "unlock") orelse return arena.deinit()) orelse return arena.deinit();
        if (field(ok, "popup_delay_ms")) |v| if (v == .integer and v.integer >= 0) {
            map.settings.popup_delay_ms = @intCast(@min(v.integer, keys.Config.max_ms));
        };
        if (field(ok, "timeout_ms")) |v| if (v == .integer and v.integer >= 0) {
            map.settings.timeout_ms = @intCast(@min(v.integer, keys.Config.max_ms));
        };
        const items = if (field(ok, "tables")) |v| (if (v == .array) v.array.items else &.{}) else &.{};
        var tables: std.ArrayList(keys.Table) = .empty;
        var builtin = false;
        for (items) |item| if (try keys.tableFromJson(x, item)) |t| {
            builtin = builtin or t.layer == .builtin;
            try tables.append(x, t);
        };
        if (!builtin) try tables.insert(x, 0, keys.builtin_table);
        map.tables = tables.items;
        map.arena = arena;
        if (self.next_keymap) |*old| old.deinit();
        self.next_keymap = map;
        self.useNextKeymap();
    }
    /// Leader state points into the tables, so they change only outside it.
    fn useNextKeymap(self: *App) void {
        if (self.next_keymap == null or self.router.pending()) return;
        self.keymap.deinit();
        self.keymap = self.next_keymap.?;
        self.next_keymap = null;
        self.dirty = true;
    }
    pub fn now(self: *const App) i64 {
        return self.fixed_now orelse @import("server.zig").nowMs();
    }
    /// Once per transport turn: redraw when the clock's minute changes, a
    /// notification expires, or the leader popup comes up or goes away.
    pub fn tick(self: *App) void {
        if (self.holdCause()) |cause| {
            const key = self.holdKey(cause);
            // A new generation on the same pane is a new snapshot: a new run.
            if (self.newGeneration(key)) self.resetHold();
            if (self.holdRestarts(key)) {
                if (self.held_first == null) self.held_first = self.now();
                self.held_since = self.now();
                self.held_for = key;
                self.held_causes.insert(cause);
            }
        } else self.resetHold();
        if (self.focused()) |p| p.timed_gen = p.hold_gen;
        if (self.router.tick(self.now())) self.dirty = true;
        self.useNextKeymap();
        self.syncPopup();
        const minute = @divFloor(wallSeconds(), 60);
        if (minute != self.shown_minute) self.dirty = true;
        if (self.shared.notes.items.len > 0) {
            const before = self.shared.notes.items.len;
            _ = self.shared.newest(self.now());
            if (self.shared.notes.items.len != before) self.dirty = true;
        }
    }

    /// Once per transport turn, before queued frames go out: ask for history
    /// that a stream lost, each on its own settle time.
    pub fn recoverBackfill(self: *App) !void {
        for (self.panes.items) |p| try p.stream.recoverBackfill(self.now());
    }
    /// The popup's state after anything that can change the router. When the
    /// popup goes away or shrinks the next render redraws everything: its edge
    /// can have blanked half a wide glyph outside what it covered.
    fn syncPopup(self: *App) void {
        if (self.popup.sync(.of(&self.router), self.keymap.settings.popup_delay_ms, self.now())) self.dirty = true;
    }
    /// When `tick` must run next for the popup or `keys.timeout_ms`, or
    /// `recoverBackfill` for a stream; null when nothing is waiting, so an
    /// open popup costs no wakeups.
    pub fn nextWake(self: *const App) ?i64 {
        var wake = self.popup.nextWake();
        if (self.held_since) |since| if (self.holdInput()) {
            wake = if (wake) |w| @min(w, since + hold_limit_ms) else since + hold_limit_ms;
        };
        if (self.router.nextDeadline()) |deadline| wake = if (wake) |w| @min(w, deadline) else deadline;
        for (self.panes.items) |p| if (p.stream.recoveryDeadline()) |deadline| {
            wake = if (wake) |w| @min(w, deadline) else deadline;
        };
        for (self.panes.items) |p| if (p.damaged) if (p.sync_since) |since| {
            wake = if (wake) |w| @min(w, since + sync_limit_ms) else since + sync_limit_ms;
        };
        return wake;
    }
    /// This frame's popup. Allocates in `a` (an arena).
    pub fn popupModel(self: *const App, a: std.mem.Allocator) !popup_chrome.Model {
        return popup_chrome.model(a, "venomx", &self.router, .{ .key = self.keymap.settings.leader, .label = "send-leader" });
    }

    fn noteArchive(self: *App, v: Value) !void {
        const id = string(v, "pane") orelse return error.BadEvent;
        const meta = field(v, "recovery") orelse return;
        const process = std.meta.stringToEnum(@FieldType(Archive, "process_state"), string(meta, "process_state") orelse return error.BadEvent) orelse return error.BadEvent;
        const text = std.meta.stringToEnum(@FieldType(Archive, "text_state"), string(meta, "text_state") orelse return error.BadEvent) orelse return error.BadEvent;
        const cut_rows = if (field(meta, "cut_rows")) |count| try index(count) else 0;
        self.dropArchive(id);
        const owned = try self.a.dupe(u8, id);
        errdefer self.a.free(owned);
        try self.archives.append(self.a, .{ .pane = owned, .process_state = process, .text_state = text, .cut_rows = cut_rows });
        self.dirty = true;
    }
    fn dropArchive(self: *App, id: []const u8) void {
        for (self.archives.items, 0..) |x, i| if (std.mem.eql(u8, x.pane, id)) {
            self.a.free(x.pane);
            _ = self.archives.orderedRemove(i);
            return;
        };
    }
    pub fn archive(self: *const App, id: []const u8) ?Archive {
        for (self.archives.items) |x| if (std.mem.eql(u8, x.pane, id)) return x;
        return null;
    }

    // ------------------------------------------------------------ control

    pub fn control(self: *App, line: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Value, self.a, line, .{});
        defer parsed.deinit();
        const v = parsed.value;
        if (field(v, "item")) |item| return self.event(item);
        const id = field(v, "id") orelse return;
        if (id != .integer) return;
        for (self.pending.items, 0..) |p, i| if (p.id == id.integer) {
            _ = self.pending.orderedRemove(i);
            if (std.mem.eql(u8, p.verb, "pane.resize")) {
                // A refused or empty press leaves the tree alone: forget it.
                // A moving one waits for the revision its reply names.
                const ok = field(v, "ok");
                const moved = if (ok) |o| (if (field(o, "moved")) |m| m == .integer and m.integer > 0 else false) else false;
                const revision = if (ok) |o| (if (field(o, "revision")) |r| (if (r == .integer and r.integer >= 0) @as(?u64, @intCast(r.integer)) else null) else null) else null;
                if (moved and revision != null) {
                    for (self.presses.items) |*x| if (x.id == p.id) {
                        x.expect = revision.?;
                    };
                    self.prunePresses();
                } else self.dropPress(p.id);
            }
            if (std.mem.eql(u8, p.verb, "popup.ticket")) return self.ticketReply(p.id, v);
            if (std.mem.eql(u8, p.key, "focus")) if (field(v, "ok")) |ok| return self.wantFocus(ok);
            if (std.mem.eql(u8, p.verb, "keys.list")) {
                // An older daemon or a pane-scoped identity keeps the built-ins.
                if (field(v, "ok")) |ok| try self.applyKeys(ok);
                return;
            }
            if (std.mem.eql(u8, p.verb, "session.list")) {
                const ok = field(v, "ok") orelse {
                    if (field(v, "error")) |e| self.say("session-picker: {s}", .{string(e, "code") orelse "error"});
                    return;
                };
                return self.openSessionPicker(ok);
            }
            if (std.mem.eql(u8, p.verb, "config.get")) {
                // Unreadable config keeps the defaults silently.
                const ok = field(v, "ok") orelse return;
                if (std.mem.eql(u8, p.key, "theme")) {
                    self.applyTheme(string(ok, "content") orelse return);
                    self.dirty = true;
                    return;
                }
                self.shared.applyConfig(p.key, string(ok, "content") orelse return) catch |err| if (err == error.OutOfMemory) return err;
                try self.place();
                self.dirty = true;
                return;
            }
            if (field(v, "error")) |e| {
                // A refused move or resize puts the float back.
                if (std.mem.eql(u8, p.key, "float_fix")) for (self.overlays.items) |*o| if (o.place_id == p.id) {
                    o.placing = 0;
                    if (!self.dragging(o.pane)) o.pinned = null;
                    try self.place();
                    self.dirty = true;
                };
                self.say("{s}: {s}", .{ p.verb, string(e, "code") orelse "error" });
            }
            return;
        };
    }
    fn request(self: *App, verb: []const u8, params: anytype) !void {
        return self.requestKeyed(verb, "", params);
    }
    fn requestKeyed(self: *App, verb: []const u8, key: []const u8, params: anytype) !void {
        const bytes = try std.json.Stringify.valueAlloc(self.a, params, .{});
        errdefer self.a.free(bytes);
        try self.pending.ensureUnusedCapacity(self.a, 1);
        try self.requests.append(self.a, .{ .id = self.next_request, .verb = verb, .params = bytes });
        self.pending.appendAssumeCapacity(.{ .id = self.next_request, .verb = verb, .key = key });
        self.next_request += 1;
    }
    pub fn frame(self: *App, stream: u32, kind: u16, payload: []const u8) !void {
        const p = self.streamPane(stream) orelse return;
        const before = Look.of(p);
        const recovering = p.stream.recovering;
        const phase_before = p.stream.phase;
        const resyncs_before = p.stream.resyncs;
        p.stream.handle(kind, payload) catch |err| {
            if (err == error.OutOfMemory or err == error.WriteFailed) return err;
            // A broken stream fails alone; the others keep running.
            try p.stream.detach();
            self.say("{s}: stream error {s}", .{ p.stream.pane, @errorName(err) });
        };
        if ((phase_before != .snapshot and p.stream.phase == .snapshot) or p.stream.resyncs != resyncs_before) p.hold_gen +%= 1;
        // After a reflow, partial history numbered rows differently under the
        // same epoch number, so a scroll or selection would point elsewhere.
        if (recovering and !p.stream.recovering) {
            p.scroll = null;
            p.selection = null;
            p.copy = null;
        }
        p.sync_since = if (p.stream.vt) |vt| if (vt.syncOutput() catch false) p.sync_since orelse self.now() else null else null;
        if (std.meta.eql(before, Look.of(p))) {
            p.damaged = true;
            self.pane_damage = true;
        } else self.dirty = true;
        if (self.target == .pane and p.stream.phase == .closed and p.stream.closed != null and !std.mem.eql(u8, p.stream.closed.?, "detached")) {
            self.quit = "pane closed";
            self.exit_status = if (std.mem.eql(u8, p.stream.closed.?, "denied.read")) 4 else if (std.mem.eql(u8, p.stream.closed.?, "not_found.pane")) 3 else 0;
        }
    }

    // ------------------------------------------------------------ geometry

    /// The host terminal's cell size, for mouse pixel reports and each pane's
    /// pixel size. A change reaches live panes.
    pub fn setHostGeometry(self: *App, g: Vt.MouseGeometry) !void {
        self.mouse_geometry = g;
        for (self.panes.items) |p| try p.stream.setCell(hostCell(g));
    }

    pub fn resize(self: *App, cols: u16, rows: u16) !void {
        self.cols = @max(cols, 1);
        self.rows = @max(rows, 1);
        try self.place();
        self.dirty = true;
    }
    /// The status line's row, or null when it is off.
    pub fn statusRow(self: *const App) ?u16 {
        if (self.raw) return null;
        return switch (self.shared.status.position) {
            .off => null,
            .top => 0,
            .bottom => self.rows - 1,
        };
    }
    fn paneArea(self: *const App) Rect {
        const row = self.statusRow() orelse return .{ .width = self.cols, .height = self.rows };
        return .{ .y = if (row == 0) @min(1, self.rows -| 1) else 0, .width = self.cols, .height = self.rows -| 1 };
    }
    /// The tiled panes' area: the window area less the title row, which a window with two or more panes adds as its first row.
    /// The layout tree divides what is left.
    fn tiledArea(self: *const App) Rect {
        var a = self.paneArea();
        if (self.hasTitleRow() and a.height > 0) {
            a.y += 1;
            a.height -= 1;
        }
        return a;
    }
    /// A window with one pane draws no title line; zoom is
    /// not a lone pane, so a zoomed window keeps it.
    fn hasTitleRow(self: *const App) bool {
        if (self.target != .session) return false;
        const w = self.activeWindow() orelse return false;
        var n: usize = 0;
        for (w.nodes) |node| if (node.kind == .pane) {
            n += 1;
        };
        return n >= 2;
    }
    /// The one tiled pane of `w`, if it has exactly one.
    fn lonePane(self: *const App, w: anytype) ?*PaneView {
        var only: ?[]const u8 = null;
        for (w.nodes) |n| if (n.kind == .pane) {
            if (only != null) return null;
            only = n.pane.?;
        };
        return self.pane(only orelse return null);
    }
    /// The zoomed pane, while it is still shown in the active window.
    pub fn zoomed(self: *const App) ?*PaneView {
        const id = self.zoom orelse return null;
        if (self.target == .pane) return null;
        const w = self.activeWindow() orelse return null;
        if (!contains(w.nodes, id)) return null;
        return self.pane(id);
    }
    fn unzoom(self: *App) void {
        if (self.zoom) |z| self.a.free(z);
        self.zoom = null;
    }
    fn place(self: *App) !void {
        if (self.target == .pane) {
            const p = self.pane(self.target.pane) orelse return;
            return placeOne(p, self.paneArea());
        }
        const w = self.activeWindow() orelse return;
        var l = try geometry.compute(self.a, w.nodes, self.tiledArea());
        defer l.deinit(self.a);
        for (l.leaves.items) |leaf| if (self.pane(leaf.pane)) |p| try placeOne(p, leaf.rect);
        // Zoom only changes what this client draws: viewports (and so PTY
        // sizes) keep the tiled rectangles above.
        if (self.zoomed()) |z| for (l.leaves.items) |leaf| if (self.pane(leaf.pane)) |p| {
            p.rect = if (p == z) self.tiledArea() else .{};
        };
        // Each float's spec against this client's area; its
        // inner rectangle is this writer's viewport.
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        for (try self.overlayOrder(arena.allocator())) |o| {
            const r = floats.rect(self.shownGeometry(o), self.paneArea());
            o.outer = r.outer;
            o.full = r.full;
            if (self.pane(o.pane)) |p| try placeOne(p, r.inner);
        }
    }
    fn placeOne(p: *PaneView, rect: Rect) !void {
        p.rect = rect;
        // Clipped leaves keep their last positive size.
        const size: Vt.Size = .{ .cols = @max(rect.width, 1), .rows = @max(rect.height, 1) };
        if (!p.started) {
            p.stream.size = size;
            try p.stream.attach(null);
            p.started = true;
        } else if (rect.width > 0 and rect.height > 0) try p.stream.viewport(size);
    }

    // ------------------------------------------------------------ input

    fn focused(self: *const App) ?*PaneView {
        return self.pane(self.focus orelse return null);
    }
    /// Whether host input should stay queued in the terminal for now.
    /// Until the topology is known and the focused pane's stream can take
    /// input, keys would be dropped, so keystrokes typed while attaching
    /// (or reconnecting, or resyncing) were lost. The transport
    /// stops reading stdin while this holds; the kernel keeps the bytes.
    pub fn holdInput(self: *const App) bool {
        if (!self.holdsInput()) return false;
        // A cause or pane that `tick` has not seen yet is a new hold.
        if (self.holdRestarts(self.holdKey(self.holdCause().?))) return true;
        return self.now() - self.held_since.? < hold_limit_ms;
    }
    /// The conditions for a hold, before the time limit. A RESYNC or
    /// `stream.checkpoint` the server never sends would hold forever, and
    /// with the keys still in the tty not even detach could be typed, so
    /// `holdInput` gives up after `hold_limit_ms`. Keys typed
    /// meanwhile that need the missing state are dropped; leader commands work.
    fn holdsInput(self: *const App) bool {
        return self.holdCause() != null;
    }
    /// Forget the hold's start, so the next hold gets a full `hold_limit_ms`.
    /// A reconnect calls this: the stream is attaching again.
    pub fn resetHold(self: *App) void {
        self.held_since = null;
        self.held_for = null;
        self.held_first = null;
        self.held_causes = .{};
    }
    /// A new connection: every stream attaches again, so the hold starts over.
    pub fn reattachStreams(self: *App) !void {
        self.next_stream = 1;
        for (self.panes.items) |p| {
            try p.stream.reattach(self.next_stream);
            self.next_stream += 2;
        }
        self.resetHold();
    }
    /// `gen` is the focused pane's `hold_gen`, so a clear and restart within
    /// one `service()` batch is a new key.
    const HoldKey = struct { cause: HoldCause, pane: u64, gen: u32 };
    fn holdKey(self: *const App, cause: HoldCause) HoldKey {
        const p = self.focused();
        return .{
            .cause = cause,
            .pane = std.hash.Wyhash.hash(0, self.focus orelse ""),
            .gen = if (p) |v| v.hold_gen else 0,
        };
    }
    /// Whether the focused pane has a snapshot or resync that `tick` has not
    /// seen, which starts a new run of holds even past the cap. It
    /// compares against the pane's own `timed_gen`, not `held_for`, which a
    /// focus flip past the cap leaves naming the old pane.
    fn newGeneration(self: *const App, key: HoldKey) bool {
        if (self.held_for == null) return false;
        const p = self.focused() orelse return false;
        return p.hold_gen != p.timed_gen and p.hold_gen == key.gen;
    }
    /// Whether a hold with this key starts a fresh timer: nothing is timed
    /// yet, or a cause this run has not held before. A changed pane, a
    /// repeated cause restarts only while the run is under twice the limit.
    fn holdRestarts(self: *const App, key: HoldKey) bool {
        if (self.held_since == null or self.held_for == null) return true;
        if (self.newGeneration(key)) return true;
        if (std.meta.eql(self.held_for.?, key)) return false;
        if (!self.held_causes.contains(key.cause)) return true;
        return self.now() - (self.held_first orelse self.now()) < 2 * hold_limit_ms;
    }
    const HoldCause = enum { topology, attaching, snapshot, discarding, no_vt };
    fn holdCause(self: *const App) ?HoldCause {
        if (self.quit != null or self.prompt != null or self.picker != null) return null;
        if (!self.topology_ready) return .topology;
        const p = self.focused() orelse return null;
        // ATTACHED has not said yet whether this client may write.
        if (p.stream.phase == .attaching) return .attaching;
        if (!p.stream.writer) return null;
        if (p.stream.phase == .snapshot) return .snapshot;
        if (p.stream.discarding) return .discarding;
        if (p.stream.mode == .emulate and p.stream.vt == null) return .no_vt;
        return null;
    }
    /// Parse host-terminal bytes. Returns how many were consumed; keep the
    /// rest and retry with more input.
    pub fn feedInput(self: *App, bytes: []const u8) !usize {
        var used: usize = 0;
        while (used < bytes.len and self.quit == null) {
            const rest = bytes[used..];
            if (self.paste != null) {
                const end = "\x1b[201~";
                if (std.mem.indexOf(u8, rest, end)) |at| {
                    try self.pasteBytes(rest[0..at]);
                    if (self.paste.?.bracketed) try self.pasteBytes(end);
                    try self.flushPaste();
                    self.paste.?.deinit(self.a);
                    self.paste = null;
                    used += at + end.len;
                    continue;
                }
                // Retain only a possible partial delimiter in the caller's
                // input buffer; all other bytes are literal, including ESC.
                var suffix = @min(rest.len, end.len - 1);
                while (suffix > 0 and !std.mem.endsWith(u8, rest, end[0..suffix])) suffix -= 1;
                try self.pasteBytes(rest[0 .. rest.len - suffix]);
                used += rest.len - suffix;
                break;
            }
            // A lone ESC can begin a split host key or paste delimiter.
            // The transport calls flushEscape after its short ESC timeout.
            if (rest.len == 1 and rest[0] == 0x1b) break;
            const result = self.input.parse(rest) catch {
                used += 1;
                continue;
            };
            if (result.consumed == 0) break;
            try self.event_input(result.event);
            used += result.consumed;
        }
        return used;
    }
    pub fn flushEscape(self: *App) !void {
        if (self.paste != null) return;
        try self.event_input(.{ .key = .{ .codepoint = @backingInt(named.escape), .text = null, .shifted = null, .base_layout = null, .mods = .{}, .action = .press } });
    }
    fn event_input(self: *App, ev: ?term.Input.Event) !void {
        const e = ev orelse return;
        switch (e) {
            .mouse => |m| {
                if (self.picker != null) return;
                return self.mouse(m);
            },
            .paste_start => {
                // The paste goes to the pane; the next typed key must too.
                if (self.router.pending()) self.endLeader();
                return self.beginPaste();
            },
            .key => |k| {
                if (k.action == .release) {
                    for (self.suppressed_keys.items, 0..) |cp, i| if (cp == k.codepoint) {
                        _ = self.suppressed_keys.swapRemove(i);
                        return;
                    };
                } else {
                    // Holding a key repeats a sticky group's binding, and only that.
                    // A held motion key repeats in copy mode too.
                    if (k.action == .repeat and !self.stickyBinding(k) and !self.copying()) for (self.suppressed_keys.items) |cp| if (cp == k.codepoint) return;
                    // A host reporting all keys sends Shift (for `%`) as its
                    // own event; it must not consume a pending leader/prompt.
                    if ((self.prompt != null or self.picker != null or self.router.pending()) and isModifierKey(k.codepoint)) return self.suppress(k.codepoint);
                    if (self.picker != null) {
                        try self.suppress(k.codepoint);
                        return self.pickerKey(k);
                    }
                    if (self.prompt != null) {
                        try self.suppress(k.codepoint);
                        return self.promptKey(k);
                    }
                    // Only the leader (and, locked, the
                    // unlock key) is intercepted; anything else passes.
                    self.useNextKeymap();
                    const out = try self.router.feed(self.keymap.settings, self.keymap.tables, .{ .ctx = self, .f = whenActive }, self.routerChord(k), self.now());
                    if (out != .pass) {
                        try self.suppress(k.codepoint);
                        return self.keyOutcome(out);
                    }
                }
                const p = self.focused() orelse return;
                // `esc` dismisses a popup whose process has
                // exited (on_exit=keep). A running popup gets the key.
                if (k.action == .press and self.exitedPopup(p) and isBareEscape(k)) {
                    try self.suppress(k.codepoint);
                    return self.dismissPopup();
                }
                // Ctrl+Shift+C copies this client's selection, as a
                // host terminal's own copy key does; it never reaches the pane.
                // With no selection it passes, as on a host with none.
                if (k.action == .press and isCopyChord(k) and hasSelection(p)) {
                    try self.suppress(k.codepoint);
                    return self.copy(p);
                }
                if (p.copy != null and k.action != .release) {
                    try self.suppress(k.codepoint);
                    if (isModifierKey(k.codepoint)) return;
                    return self.copyKey(p, k);
                }
                // A Kitty host reporting all keys sends Ctrl or Shift
                // alone. It still reaches the pane but is not typing: the
                // selection and the scroll position stay, so Ctrl+Shift+C or
                // Shift+PageUp after it still finds them.
                if (k.action != .release and !isModifierKey(k.codepoint)) self.follow(p);
                try self.sendKey(p, k);
            },
            else => {},
        }
    }
    /// Ctrl+Shift+C, the Linux terminals' copy key.
    fn isCopyChord(k: term.Input.Key) bool {
        if (!k.mods.ctrl or !k.mods.shift or k.mods.alt or k.mods.super) return false;
        return k.codepoint == 'c' or k.codepoint == 'C' or (if (k.shifted) |sh| sh == 'C' else false);
    }
    /// A selection worth copying: dragged across cells, or made in copy mode.
    fn hasSelection(p: *const PaneView) bool {
        const sel = p.selection orelse return false;
        const vt = p.stream.vt orelse return false;
        if (sel.epoch != vt.rows().epoch) return false;
        return p.copy != null or !std.meta.eql(sel.anchor, sel.head);
    }
    fn copying(self: *const App) bool {
        const p = self.focused() orelse return false;
        return p.copy != null;
    }
    fn isBareEscape(k: term.Input.Key) bool {
        return k.codepoint == @backingInt(named.escape) and !k.mods.ctrl and !k.mods.alt and !k.mods.shift and !k.mods.super;
    }
    /// Whether `p` is a popup of this client whose process has exited.
    fn exitedPopup(self: *const App, p: *const PaneView) bool {
        const o = self.overlay(p.stream.pane) orelse return false;
        return o.layer == .popup and p.stream.exit != null;
    }
    /// Kitty keyboard protocol modifier and lock keys (CSI u codes 57358-57360
    /// and 57441-57454): reported alone by a host in report-all-keys mode.
    fn isModifierKey(cp: u21) bool {
        return (cp >= 57358 and cp <= 57360) or (cp >= 57441 and cp <= 57454);
    }
    /// The chord the router gets. The pane still gets the key as it came.
    fn routerChord(self: *const App, k: term.Input.Key) keys.Chord {
        return self.router.chordOf(self.keymap.settings, k.codepoint, .{ .ctrl = k.mods.ctrl, .alt = k.mods.alt, .shift = k.mods.shift, .super = k.mods.super }, k.shifted, k.text, k.base_layout);
    }
    /// A key that runs a binding of the sticky group the client is in.
    fn stickyBinding(self: *const App, k: term.Input.Key) bool {
        if (self.router.stickyGroup() == null) return false;
        var typed = self.router.seq;
        if (!typed.push(self.routerChord(k))) return false;
        return self.router.resolved.lookup(typed.slice()) == .exact;
    }
    /// The character a key produces, for the command prompt line.
    fn keyChar(k: term.Input.Key) u21 {
        if (k.mods.shift) if (k.shifted) |s| return s;
        if (k.text) |t| if (t.len > 0 and t[0] >= 0x20 and t[0] != 0x7f) {
            const n = std.unicode.utf8ByteSequenceLength(t[0]) catch return k.codepoint;
            if (n == t.len) return std.unicode.utf8Decode(t) catch k.codepoint;
        };
        return k.codepoint;
    }
    /// Tables apply while the focused pane has all of their `when` tags.
    fn whenActive(ctx: *const anyopaque, when: []const @import("chrome.zig").Tag) bool {
        const self: *const App = @ptrCast(@alignCast(ctx));
        if (when.len == 0) return true;
        const f = self.focus orelse return false;
        const info = self.shared.pane(f) orelse return false;
        return info.tags.matches(when);
    }
    pub fn endLeader(self: *App) void {
        self.router.end();
        self.syncPopup();
    }
    pub fn leaderPending(self: *const App) bool {
        return self.router.pending();
    }
    fn keyOutcome(self: *App, out: keys.Router.Outcome) !void {
        self.dirty = true;
        switch (out) {
            .pass, .leader, .partial, .unlocked => {},
            // Leader then leader sends the leader key to the pane.
            .send_leader => return self.runLocal(.send_leader),
            .overflow => return self.say("no binding", .{}),
            // The binding lives in the key map, not the router.
            .run => |binding| return self.runTarget(binding.target),
            // Cancelled; the key is swallowed and needs no message. `esc`
            // runs the root's `escape` binding only at the root, and it
            // clears the selection from any level.
            .unbound => |seq| if (seq.keys[seq.len - 1].eql(keys.esc_key)) {
                if (self.focused()) |p| p.selection = null;
            },
        }
    }
    /// `exec` placeholders of the focused pane; null when unknown.
    fn placeholderValue(self: *const App, which: usize) ?[]const u8 {
        const f = self.focus orelse return null;
        return switch (which) {
            0 => f,
            1 => switch (self.target) {
                .session => if (self.active) |w| (if (self.activeWindow()) |win| (if (contains(win.nodes, f)) w else null) else null) else null,
                .pane => null,
            },
            2 => switch (self.target) {
                .session => |s| s,
                .pane => if (self.shared.pane(f)) |info| (if (info.session.len > 0) info.session else null) else null,
            },
            // `{popup_ticket}` is minted per use (`requestTicket`).
            else => null,
        };
    }
    /// The session a popup ticket is minted for.
    fn ticketSession(self: *const App) ?[]const u8 {
        return switch (self.target) {
            .session => |sid| sid,
            .pane => if (self.focus) |f| (if (self.shared.pane(f)) |info| (if (info.session.len > 0) info.session else null) else null) else null,
        };
    }
    /// Mint a ticket for a binding; it runs when the ticket arrives.
    fn requestTicket(self: *App, target: @FieldType(Deferred, "target")) !void {
        // On error the caller still owns `target`; otherwise this does.
        const sid = self.ticketSession() orelse {
            (Deferred{ .id = 0, .target = target }).deinit(self.a);
            return self.missing(3);
        };
        const id = self.next_request;
        try self.deferred.ensureUnusedCapacity(self.a, 1);
        const w: ?[]const u8 = if (self.target == .session) self.active else null;
        try self.requestKeyed("popup.ticket", "", .{ .session = sid, .window = w });
        self.deferred.appendAssumeCapacity(.{ .id = id, .target = target });
    }
    /// A `popup.ticket` reply: run the waiting binding with the ticket.
    fn ticketReply(self: *App, id: i64, v: Value) !void {
        const at = for (self.deferred.items, 0..) |d, i| {
            if (d.id == id) break i;
        } else return;
        const d = self.deferred.orderedRemove(at);
        defer d.deinit(self.a);
        const ok = field(v, "ok") orelse {
            const code = if (field(v, "error")) |e| string(e, "code") orelse "error" else "error";
            return self.say("popup.ticket: {s}", .{code});
        };
        const ticket = string(ok, "ticket") orelse return;
        if (string(ok, "client")) |cid| if (self.client_id == null or !std.mem.eql(u8, self.client_id.?, cid)) {
            const owned = try self.a.dupe(u8, cid);
            if (self.client_id) |old| self.a.free(old);
            self.client_id = owned;
        };
        switch (d.target) {
            .exec => |argv| {
                const out = try self.a.alloc([]u8, argv.len);
                var filled: usize = 0;
                errdefer {
                    for (out[0..filled]) |x| self.a.free(x);
                    self.a.free(out);
                }
                for (argv, out) |arg, *dst| {
                    dst.* = try self.a.dupe(u8, if (std.mem.eql(u8, arg, keys.placeholders[3])) ticket else arg);
                    filled += 1;
                }
                try self.execs.append(self.a, .{ .argv = out });
            },
            .verb => |vb| {
                var arena = std.heap.ArenaAllocator.init(self.a);
                defer arena.deinit();
                const x = arena.allocator();
                var params = try std.json.parseFromSliceLeaky(Value, x, vb.params, .{});
                params = try replaceTicket(x, params, ticket);
                if (std.mem.eql(u8, vb.name, "pane.popup") and params == .object) try params.object.put(x, "ticket", .{ .string = ticket });
                const bytes = try std.json.Stringify.valueAlloc(self.a, params, .{});
                errdefer self.a.free(bytes);
                try self.pending.ensureUnusedCapacity(self.a, 1);
                try self.requests.append(self.a, .{ .id = self.next_request, .verb = vb.name, .params = bytes });
                self.pending.appendAssumeCapacity(.{ .id = self.next_request, .verb = vb.name });
                self.next_request += 1;
            },
        }
    }
    fn missing(self: *App, which: usize) void {
        self.say("binding needs {s}, which is unavailable", .{keys.placeholders[which]});
    }
    fn substitute(self: *App, a: std.mem.Allocator, v: Value) !?Value {
        switch (v) {
            .string => |s| if (keys.placeholder(s)) |i| {
                if (i == 3) {
                    self.needs_ticket = true;
                    return v;
                }
                const value = self.placeholderValue(i) orelse {
                    self.missing(i);
                    return null;
                };
                return .{ .string = value };
            },
            .array => |arr| {
                var out: std.json.Array = .init(a);
                for (arr.items) |x| try out.append((try self.substitute(a, x)) orelse return null);
                return .{ .array = out };
            },
            .object => |o| {
                var out: std.json.ObjectMap = .empty;
                var it = o.iterator();
                while (it.next()) |e| try out.put(a, e.key_ptr.*, (try self.substitute(a, e.value_ptr.*)) orelse return null);
                return .{ .object = out };
            },
            else => {},
        }
        return v;
    }
    pub fn runTarget(self: *App, target: keys.Target) !void {
        self.dirty = true;
        switch (target) {
            .local => |c| return self.run(c),
            .verb => |v| {
                var arena = std.heap.ArenaAllocator.init(self.a);
                defer arena.deinit();
                const parsed = try std.json.parseFromSliceLeaky(Value, arena.allocator(), v.args, .{});
                self.needs_ticket = false;
                const params = (try self.substitute(arena.allocator(), parsed)) orelse return;
                const bytes = try std.json.Stringify.valueAlloc(self.a, params, .{});
                errdefer self.a.free(bytes);
                const name = try self.internVerb(v.name);
                // A pane.popup binding mints and uses a ticket itself.
                if (self.needs_ticket or std.mem.eql(u8, v.name, "pane.popup")) return self.requestTicket(.{ .verb = .{ .name = name, .params = bytes } });
                try self.pending.ensureUnusedCapacity(self.a, 1);
                try self.requests.append(self.a, .{ .id = self.next_request, .verb = name, .params = bytes });
                self.pending.appendAssumeCapacity(.{ .id = self.next_request, .verb = name });
                self.next_request += 1;
            },
            .exec => |argv| {
                const out = try self.a.alloc([]u8, argv.len);
                var filled: usize = 0;
                errdefer {
                    for (out[0..filled]) |x| self.a.free(x);
                    self.a.free(out);
                }
                var ticket = false;
                for (argv, out) |arg, *dst| {
                    // Whole elements only; anything else stays literal.
                    if (keys.placeholder(arg) == 3) ticket = true;
                    const value = if (keys.placeholder(arg)) |i| (if (i == 3) arg else self.placeholderValue(i)) orelse {
                        self.missing(i);
                        for (out[0..filled]) |x| self.a.free(x);
                        self.a.free(out);
                        return;
                    } else arg;
                    dst.* = try self.a.dupe(u8, value);
                    filled += 1;
                }
                if (ticket) return self.requestTicket(.{ .exec = out });
                try self.execs.append(self.a, .{ .argv = out });
            },
        }
    }
    fn internVerb(self: *App, name: []const u8) ![]const u8 {
        for (self.verb_names.items) |x| if (std.mem.eql(u8, x, name)) return x;
        const owned = try self.a.dupe(u8, name);
        errdefer self.a.free(owned);
        try self.verb_names.append(self.a, owned);
        return owned;
    }
    fn suppress(self: *App, cp: u21) !void {
        for (self.suppressed_keys.items) |old| if (old == cp) return;
        try self.suppressed_keys.append(self.a, cp);
    }
    fn follow(self: *App, p: *PaneView) void {
        if (p.scroll != null or p.selection != null or p.copy != null) {
            p.scroll = null;
            p.selection = null;
            p.copy = null;
            self.dirty = true;
        }
    }
    fn canInput(p: *const PaneView) bool {
        return p.stream.writer and p.stream.phase == .live and !p.stream.discarding and p.stream.vt != null;
    }
    fn sendKey(self: *App, p: *PaneView, k: term.Input.Key) !void {
        if (!canInput(p)) return;
        const bytes = p.stream.vt.?.encodeKey(self.a, k) catch |err| switch (err) {
            error.Unavailable, error.InvalidValue => return self.say("key encoding unavailable", .{}),
            else => return err,
        };
        defer self.a.free(bytes);
        try p.stream.input(bytes);
    }
    fn beginPaste(self: *App) !void {
        self.paste = .{};
        errdefer {
            self.paste.?.deinit(self.a);
            self.paste = null;
        }
        // A paste in the local command prompt is consumed but never executed.
        if (self.prompt != null or self.picker != null) return;
        const p = self.focused() orelse return;
        if (!canInput(p)) return;
        const bracketed = (try p.stream.vt.?.inputModes()).bracketed_paste;
        self.paste.?.pane = try self.a.dupe(u8, p.stream.pane);
        self.paste.?.stream = p.stream.id;
        self.paste.?.bracketed = bracketed;
        self.follow(p);
        if (bracketed) try self.pasteBytes("\x1b[200~");
    }
    fn pasteBytes(self: *App, bytes: []const u8) !void {
        if (self.paste.?.pane == null) return;
        var rest = bytes;
        const limit = @max(self.input_frame_limit, 1);
        while (rest.len > 0) {
            const paste = &self.paste.?;
            if (paste.bytes.items.len >= limit) try self.flushPaste();
            const n = @min(rest.len, limit - paste.bytes.items.len);
            try paste.bytes.appendSlice(self.a, rest[0..n]);
            rest = rest[n..];
        }
    }
    fn flushPaste(self: *App) !void {
        const paste = &self.paste.?;
        if (paste.pane) |id| if (self.pane(id)) |p| if (p.stream.id == paste.stream and canInput(p)) try p.stream.input(paste.bytes.items);
        paste.bytes.clearRetainingCapacity();
    }
    /// Discard any unfinished paste on reconnect, while still consuming its
    /// host terminator. It must not continue on a replacement pane stream.
    pub fn cancelPaste(self: *App) void {
        if (self.paste) |*paste| {
            if (paste.pane) |id| self.a.free(id);
            paste.pane = null;
            paste.bytes.clearRetainingCapacity();
        }
    }
    fn promptKey(self: *App, k: term.Input.Key) !void {
        var line = &self.prompt.?;
        self.dirty = true;
        if (k.codepoint == @backingInt(named.escape)) {
            line.deinit(self.a);
            self.prompt = null;
        } else if (k.codepoint == @backingInt(named.enter)) {
            const trimmed = std.mem.trim(u8, line.items, " ");
            if (std.mem.startsWith(u8, trimmed, "toggle-segment ")) {
                const id = std.mem.trim(u8, trimmed["toggle-segment ".len..], " ");
                const owned = try self.a.dupe(u8, id);
                defer self.a.free(owned);
                line.deinit(self.a);
                self.prompt = null;
                return self.toggleSegment(owned);
            }
            const command = parseCommand(trimmed);
            const text = try self.a.dupe(u8, line.items);
            defer self.a.free(text);
            line.deinit(self.a);
            self.prompt = null;
            if (command) |c| try self.run(c) else self.say("unknown command: {s}", .{text});
        } else if (k.codepoint == @backingInt(named.backspace)) {
            if (line.items.len > 0) line.items.len -= 1;
        } else if (k.mods.ctrl or k.mods.alt) {
            // A chord is not text; the line takes nothing from it.
        } else if (k.text) |t| {
            if (line.items.len + t.len <= 128) try line.appendSlice(self.a, t);
        } else if (keyChar(k) < 0x80 and keyChar(k) >= 0x20 and line.items.len < 128) try line.append(self.a, @intCast(keyChar(k)));
    }
    pub fn run(self: *App, command: Command) !void {
        self.dirty = true;
        switch (command) {
            .local => |l| try self.runLocal(l),
            .verb => |v| try self.runVerb(v),
        }
    }
    fn runLocal(self: *App, l: Local) !void {
        const p = self.focused();
        switch (l) {
            .detach => {
                for (self.panes.items) |x| try x.stream.detach();
                self.quit = "detached";
            },
            .focus_left => try self.focusDirection(.left),
            .focus_down => try self.focusDirection(.down),
            .focus_up => try self.focusDirection(.up),
            .focus_right => try self.focusDirection(.right),
            .focus_next, .focus_prev => try self.cycleFocus(l == .focus_next),
            .window_next, .window_prev => try self.cycleWindow(l == .window_next),
            .window_1, .window_2, .window_3, .window_4, .window_5, .window_6, .window_7, .window_8, .window_9 => try self.selectWindow(@backingInt(l) - @backingInt(Local.window_1)),
            .scroll_line_up => if (p) |x| self.scrollBy(x, -1),
            .scroll_line_down => if (p) |x| self.scrollBy(x, 1),
            .scroll_page_up => if (p) |x| self.scrollBy(x, -@as(i64, @max(x.rect.height, 2) - 1)),
            .scroll_page_down => if (p) |x| self.scrollBy(x, @as(i64, @max(x.rect.height, 2) - 1)),
            .scroll_prev_command => if (p) |x| self.jumpCommand(x, .prev),
            .scroll_next_command => if (p) |x| self.jumpCommand(x, .next),
            .scroll_bottom => if (p) |x| {
                x.scroll = null;
            },
            .send_leader => if (p) |x| {
                const lk = self.keymap.settings.leader;
                var key: term.Input.Key = .{ .codepoint = lk.cp, .text = null, .shifted = null, .base_layout = null, .mods = .{ .ctrl = lk.mods.ctrl, .alt = lk.mods.alt, .shift = lk.mods.shift, .super = lk.mods.super }, .action = .press };
                self.follow(x);
                try self.sendKey(x, key);
                key.action = .release;
                try self.sendKey(x, key);
            },
            .lock => self.router.lock(),
            .command_prompt => self.prompt = .empty,
            .window_picker => try self.openWindowPicker(),
            .session_picker => {
                if (self.target != .session) return self.say("session-picker needs attach --session", .{});
                try self.requestKeyed("session.list", "", struct {}{});
            },
            .all_keys => try self.openKeysPicker(),
            .clear_selection => if (p) |x| {
                // Escape on a popup with nothing selected dismisses it.
                if (x.selection == null) if (self.overlay(x.stream.pane)) |o| if (o.layer == .popup) return self.dismissPopup();
                x.selection = null;
                x.copy = null;
            },
            .copy_mode => if (p) |x| {
                // Copy mode takes the keys the sticky scroll group would.
                self.endLeader();
                self.enterCopy(x);
            },
            .zoom => {
                if (self.zoomed() != null) {
                    self.unzoom();
                } else if (self.target == .session) if (self.focus) |f| {
                    self.unzoom();
                    self.zoom = try self.a.dupe(u8, f);
                };
                try self.place();
            },
            .focus_attention => try self.focusAttention(),
            .toggle_floats => {
                self.floats_hidden = !self.floats_hidden;
                self.say("floats {s}", .{if (self.floats_hidden) "hidden" else "shown"});
                try self.reconcile();
            },
            .focus_float => try self.focusFloat(),
            .dismiss_popup => try self.dismissPopup(),
        }
    }
    /// `leader F`: the next visible float or popup above the focused one.
    fn focusFloat(self: *App) !void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const order = try self.overlayOrder(arena.allocator());
        if (order.len == 0) return self.say("no floats shown", .{});
        var next: usize = 0;
        if (self.focus) |f| for (order, 0..) |o, i| if (std.mem.eql(u8, o.pane, f)) {
            next = (i + 1) % order.len;
        };
        try self.setFocus(order[next].pane);
    }
    /// Dismiss: the focused popup, else the topmost one, is killed
    /// and removed under this client's identity.
    fn dismissPopup(self: *App) !void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const order = try self.overlayOrder(arena.allocator());
        var target: ?*Overlay = null;
        if (self.focus) |f| if (self.overlay(f)) |o| if (o.layer == .popup) {
            target = o;
        };
        if (target == null) {
            var i = order.len;
            while (i > 0) {
                i -= 1;
                if (order[i].layer == .popup) {
                    target = order[i];
                    break;
                }
            }
        }
        const o = target orelse return self.say("no popup", .{});
        try self.request("pane.kill", .{ .pane = o.pane, .remove = true });
    }
    /// The next pane after the focused one (windows, then panes, in ID
    /// order) whose attention is not `none`. Local: nothing is sent except
    /// the attention clear of `setFocus`.
    fn focusAttention(self: *App) !void {
        if (self.target != .session) return;
        const Spot = struct { window: []const u8, pane: []const u8 };
        var spots: std.ArrayList(Spot) = .empty;
        defer spots.deinit(self.a);
        var ws: std.ArrayList(*Window) = .empty;
        defer ws.deinit(self.a);
        for (self.windows.items) |*w| try ws.append(self.a, w);
        std.mem.sort(*Window, ws.items, {}, struct {
            fn lt(_: void, x: *Window, y: *Window) bool {
                return idLess(x.id, y.id);
            }
        }.lt);
        for (ws.items) |w| {
            const start = spots.items.len;
            for (w.nodes) |n| if (n.kind == .pane) try spots.append(self.a, .{ .window = w.id, .pane = n.pane.? });
            std.mem.sort(Spot, spots.items[start..], {}, struct {
                fn lt(_: void, x: Spot, y: Spot) bool {
                    return idLess(x.pane, y.pane);
                }
            }.lt);
        }
        if (spots.items.len == 0) return;
        var at: usize = spots.items.len - 1;
        for (spots.items, 0..) |sp, i| if (self.focus != null and std.mem.eql(u8, sp.pane, self.focus.?) and self.active != null and std.mem.eql(u8, sp.window, self.active.?)) {
            at = i;
        };
        for (1..spots.items.len + 1) |step| {
            const sp = spots.items[(at + step) % spots.items.len];
            const info = self.shared.pane(sp.pane) orelse continue;
            if (info.level == .none) continue;
            if (self.active == null or !std.mem.eql(u8, self.active.?, sp.window)) {
                const owned = try self.a.dupe(u8, sp.window);
                if (self.active) |old| self.a.free(old);
                self.active = owned;
                self.unzoom();
                // Not `reconcile`: its fallback pane must not cancel the sequence.
                try self.reconcileViews();
            }
            return self.setFocus(sp.pane);
        }
        self.say("no pane needs attention", .{});
    }
    fn runVerb(self: *App, v: Verb) !void {
        const argv = [_][]const u8{self.shell};
        switch (v) {
            .split_right, .split_down => {
                const p = self.focus orelse return self.say("no pane to split", .{});
                // Panes a human creates by hand behave like tmux.
                // Like tmux, the new pane takes this client's focus.
                try self.requestKeyed(v.wire(), "focus", .{ .pane = p, .axis = if (v == .split_right) "cols" else "rows", .argv = &argv, .on_exit = "remove" });
            },
            .resize_left, .resize_down, .resize_up, .resize_right => {
                const p = self.focus orelse return self.say("no pane to resize", .{});
                if (self.target == .session) if (self.overlay(p)) |o| return self.resizeFloat(o, v);
                const direction: []const u8 = switch (v) {
                    .resize_left => "left",
                    .resize_down => "down",
                    .resize_up => "up",
                    else => "right",
                };
                const id = self.next_request;
                const cells = try self.pressCells(p, v, id);
                errdefer self.dropPress(id);
                try self.request(v.wire(), .{ .pane = p, .direction = direction, .cells = cells });
            },
            .close_pane => {
                const p = self.focus orelse return self.say("no pane to close", .{});
                try self.request(v.wire(), .{ .pane = p, .remove = true });
            },
            .toggle_pane_float => try self.togglePaneFloat(),
            .new_window => switch (self.target) {
                .session => |s| try self.requestKeyed(v.wire(), "focus", .{ .session = s, .argv = &argv, .on_exit = "remove" }),
                .pane => self.say("new-window needs attach --session", .{}),
            },
        }
    }
    /// `leader e`: float the focused tiled pane with `floats.default`,
    /// or tile the focused float back. A float splits the largest tiled pane
    /// of the window as this client lays it out (ties: lowest ID), along its
    /// longer side (cells are about twice as tall as wide); with no tile
    /// left it becomes the window's only one. Focus stays on the pane.
    fn togglePaneFloat(self: *App) !void {
        if (self.target != .session) return self.say("toggle-pane-float needs attach --session", .{});
        const f = self.focus orelse return self.say("no pane to float", .{});
        const w = self.activeWindow() orelse return;
        if (self.overlay(f)) |o| {
            if (o.layer == .popup) return self.say("popups cannot be placed", .{});
            var l = try geometry.compute(self.a, w.nodes, self.tiledArea());
            defer l.deinit(self.a);
            var best: ?geometry.Leaf = null;
            for (l.leaves.items) |leaf| {
                const area = @as(u32, leaf.rect.width) * leaf.rect.height;
                const better = if (best) |b| blk: {
                    const best_area = @as(u32, b.rect.width) * b.rect.height;
                    break :blk area > best_area or (area == best_area and idLess(leaf.pane, b.pane));
                } else true;
                if (better) best = leaf;
            }
            const t = best orelse return self.request(Verb.toggle_pane_float.wire(), .{ .pane = f, .tile = struct {}{} });
            const axis: []const u8 = if (@as(u32, t.rect.width) >= 2 * @as(u32, t.rect.height)) "cols" else "rows";
            return self.request(Verb.toggle_pane_float.wire(), .{ .pane = f, .tile = .{ .target = t.pane, .axis = axis } });
        }
        // A float this client hides would vanish from under the human.
        if (self.floats_hidden) {
            self.floats_hidden = false;
            try self.reconcile();
        }
        try self.request(Verb.toggle_pane_float.wire(), .{ .pane = f, .float = struct {}{} });
    }
    /// The geometry this client draws a float with: the daemon's, or the
    /// pinned rectangle of a drag or resize key as cells from the top left
    /// of the window area.
    fn shownGeometry(self: *const App, o: *const Overlay) floats.Geometry {
        var geo = o.geometry;
        const r = o.pinned orelse return geo;
        const area = self.paneArea();
        geo.width = .{ .cells = r.width };
        geo.height = .{ .cells = r.height };
        geo.anchor = .top_left;
        geo.x = @as(i32, r.x) - area.x;
        geo.y = @as(i32, r.y) - area.y;
        return geo;
    }
    /// The fewest cells a float keeps on one axis: its `min_cols` or
    /// `min_rows`, and room for a border with one cell inside.
    fn floatMin(n: u16, border: floats.Border) u16 {
        return @max(n, if (border != .none) @as(u16, 3) else 1);
    }
    /// A resize key on a focused float resizes the float, not a
    /// divider: right and down grow it by one cell, left and up shrink it,
    /// with its top-left corner fixed. It stays inside the window area
    /// (growing at an edge pushes it back in) and keeps its minimum size.
    fn resizeFloat(self: *App, o: *Overlay, v: Verb) !void {
        if (o.layer == .popup) return self.say("popups cannot be resized", .{});
        if (o.full) return self.say("the float fills the window; widen the terminal to resize it", .{});
        const area = self.paneArea();
        const was = o.pinned orelse o.outer;
        var r = was;
        const min_w = @min(floatMin(o.geometry.min_cols, o.geometry.border), r.width);
        const min_h = @min(floatMin(o.geometry.min_rows, o.geometry.border), r.height);
        switch (v) {
            .resize_right => r.width = @min(r.width +| 1, area.width),
            .resize_left => r.width = @max(r.width -| 1, min_w),
            .resize_down => r.height = @min(r.height +| 1, area.height),
            .resize_up => r.height = @max(r.height -| 1, min_h),
            else => unreachable,
        }
        r.x = @max(area.x, @min(r.x, area.x + area.width - r.width));
        r.y = @max(area.y, @min(r.y, area.y + area.height - r.height));
        if (std.meta.eql(r, was)) return;
        o.pinned = r;
        try self.place();
        self.dirty = true;
        try self.sendFloat(o.pane);
    }
    /// `pane.place` with the pinned geometry of float `id`, in cells, so
    /// every client draws it where this one does.
    fn sendFloat(self: *App, id: []const u8) !void {
        const o = self.overlay(id) orelse return;
        const geo = self.shownGeometry(o);
        var wb: [8]u8 = undefined;
        var hb: [8]u8 = undefined;
        const w = geo.width.text(&wb);
        const h = geo.height.text(&hb);
        const border = @tagName(geo.border);
        const req = self.next_request;
        if (geo.title.len > 0) {
            try self.requestKeyed("pane.place", "float_fix", .{ .pane = o.pane, .float = .{ .width = w, .height = h, .anchor = "top_left", .x = geo.x, .y = geo.y, .border = border, .min_cols = geo.min_cols, .min_rows = geo.min_rows, .title = geo.title } });
        } else {
            try self.requestKeyed("pane.place", "float_fix", .{ .pane = o.pane, .float = .{ .width = w, .height = h, .anchor = "top_left", .x = geo.x, .y = geo.y, .border = border, .min_cols = geo.min_cols, .min_rows = geo.min_rows } });
        }
        o.placing += 1;
        o.place_id = req;
    }
    fn dragging(self: *const App, id: []const u8) bool {
        const d = self.float_drag orelse return false;
        return std.mem.eql(u8, d.pane, id);
    }
    fn endFloatDrag(self: *App) void {
        if (self.float_drag) |d| self.a.free(d.pane);
        self.float_drag = null;
    }
    /// A left press that takes hold of the topmost float under the
    /// pointer. Its top border (the title line) moves it; its left, right
    /// and bottom borders and bottom corners resize it. After the leader a
    /// press anywhere inside it moves it too (or resizes, on those borders).
    /// Popups stay where they are. True when the press was taken.
    fn floatGrab(self: *App, m: term.Input.Mouse) !bool {
        if (self.target != .session or m.action != .press or m.button != .left or m.x < 0 or m.y < 0) return false;
        const x: u16 = @intCast(m.x);
        const y: u16 = @intCast(m.y);
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const order = try self.overlayOrder(arena.allocator());
        var i = order.len;
        const o = while (i > 0) {
            i -= 1;
            const r = order[i].outer;
            if (x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height) break order[i];
        } else return false;
        if (o.layer != .float or o.full) return false;
        const r = o.outer;
        var grip: FloatDrag.Edges = .{};
        var on_border = false;
        if (o.geometry.border != .none and r.width >= 3 and r.height >= 3) {
            const top = y == r.y;
            grip.left = x == r.x and !top;
            grip.right = x == r.x + r.width - 1 and !top;
            grip.bottom = y == r.y + r.height - 1;
            on_border = top or grip.left or grip.right or grip.bottom;
        }
        const leader = self.router.pending();
        if (!on_border and !leader) return false;
        if (leader) self.endLeader();
        self.releaseMouse();
        self.endFloatDrag();
        const start = o.pinned orelse o.outer;
        self.float_drag = .{ .pane = try self.a.dupe(u8, o.pane), .edges = grip, .from_x = m.x, .from_y = m.y, .start = start };
        o.pinned = start;
        try self.setFocus(self.float_drag.?.pane);
        self.dirty = true;
        return true;
    }
    /// The held float follows the pointer, inside the window area and no
    /// smaller than its minimum.
    fn floatDragTo(self: *App, m: term.Input.Mouse) !void {
        const d = self.float_drag.?;
        const o = self.overlay(d.pane) orelse return self.endFloatDrag();
        const area = self.paneArea();
        const s = d.start;
        const dx: i32 = @as(i32, m.x) - d.from_x;
        const dy: i32 = @as(i32, m.y) - d.from_y;
        const ax0: i32 = area.x;
        const ay0: i32 = area.y;
        const ax1: i32 = @as(i32, area.x) + area.width;
        const ay1: i32 = @as(i32, area.y) + area.height;
        const min_w: i32 = @min(floatMin(o.geometry.min_cols, o.geometry.border), s.width);
        const min_h: i32 = @min(floatMin(o.geometry.min_rows, o.geometry.border), s.height);
        var x: i32 = s.x;
        var y: i32 = s.y;
        var w: i32 = s.width;
        var h: i32 = s.height;
        if (d.moving()) {
            x = std.math.clamp(x + dx, ax0, @max(ax0, ax1 - w));
            y = std.math.clamp(y + dy, ay0, @max(ay0, ay1 - h));
        } else {
            if (d.edges.right) w = std.math.clamp(w + dx, min_w, @max(min_w, ax1 - x));
            if (d.edges.left) {
                x = std.math.clamp(x + dx, @min(ax0, x), x + w - min_w);
                w = @as(i32, s.x) + s.width - x;
            }
            if (d.edges.bottom) h = std.math.clamp(h + dy, min_h, @max(min_h, ay1 - y));
        }
        const r: Rect = .{ .x = @intCast(x), .y = @intCast(y), .width = @intCast(w), .height = @intCast(h) };
        if (o.pinned) |p| if (std.meta.eql(p, r)) return;
        o.pinned = r;
        try self.place();
        self.dirty = true;
    }
    /// The drag ends: a float that moved or changed size is placed there;
    /// one that did not goes back to the daemon's geometry.
    fn dropFloat(self: *App) !void {
        const d = self.float_drag orelse return;
        defer self.endFloatDrag();
        const o = self.overlay(d.pane) orelse return;
        const moved = if (o.pinned) |p| !std.meta.eql(p, d.start) else false;
        if (moved) return self.sendFloat(d.pane);
        if (o.placing == 0) o.pinned = null;
        try self.place();
        self.dirty = true;
    }
    /// PTY cells for one press of a resize key: enough to move the divider by
    /// a cell of this client's viewport. The tree is the
    /// window's with this client's unanswered presses laid on it, so a press
    /// sent before the last one's `layout_changed` still moves.
    /// Records the press as `id` when it moves anything.
    fn pressCells(self: *App, pane_id: []const u8, v: Verb, id: i64) !u32 {
        if (self.target == .pane) return 1;
        const w = self.activeWindow() orelse return 1;
        const sizes: ViewSizes = .{ .app = self };
        const axis: layout.Axis = if (v == .resize_left or v == .resize_right) .cols else .rows;
        const sign: i64 = if (v == .resize_left or v == .resize_up) -1 else 1;
        self.prunePresses();
        const tree = try self.a.dupe(layout.Node, w.nodes);
        defer self.a.free(tree);
        for (self.presses.items) |x| {
            if (!std.mem.eql(u8, x.window, w.id)) continue;
            const m = layout.moveDivider(tree, x.pane, x.axis, x.delta, sizes) orelse continue;
            tree[m.split].ratio = m.ratio;
        }
        const cells = try geometry.pressCells(self.a, tree, pane_id, axis, sign, self.tiledArea(), sizes);
        const delta = sign * @as(i64, cells);
        if (layout.moveDivider(tree, pane_id, axis, delta, sizes) == null) return cells;
        const win = try self.a.dupe(u8, w.id);
        errdefer self.a.free(win);
        const pid = try self.a.dupe(u8, pane_id);
        errdefer self.a.free(pid);
        try self.presses.append(self.a, .{ .id = id, .window = win, .pane = pid, .axis = axis, .delta = delta, .expect = std.math.maxInt(u64) });
        return cells;
    }
    /// Forget the presses whose layout their window has taken, and those of
    /// windows that are gone.
    fn prunePresses(self: *App) void {
        var i: usize = 0;
        while (i < self.presses.items.len) {
            const x = self.presses.items[i];
            const done = if (self.window(x.window)) |w| x.expect <= w.revision else true;
            if (done) {
                x.deinit(self.a);
                _ = self.presses.orderedRemove(i);
            } else i += 1;
        }
    }
    /// Replies to the requests behind the presses are lost with a reconnect.
    pub fn clearPresses(self: *App) void {
        for (self.presses.items) |x| x.deinit(self.a);
        self.presses.clearRetainingCapacity();
    }
    fn dropPress(self: *App, id: i64) void {
        for (self.presses.items, 0..) |x, i| if (x.id == id) {
            x.deinit(self.a);
            _ = self.presses.orderedRemove(i);
            return;
        };
    }
    /// The panes' PTY sizes as this client has them: the daemon's size for the
    /// pane once the stream is past attaching (the Vt lags it while the stream
    /// resyncs), and before that this client's own viewport.
    const ViewSizes = struct {
        app: *App,
        pub fn extent(ctx: @This(), id: []const u8, on: layout.Axis) u32 {
            const p = ctx.app.pane(id) orelse return 1;
            const size: Vt.Size = if (p.stream.phase != .attaching) .{ .cols = @max(p.stream.pane_size.cols, 1), .rows = @max(p.stream.pane_size.rows, 1) } else .{ .cols = @max(p.rect.width, 1), .rows = @max(p.rect.height, 1) };
            return if (on == .cols) size.cols else size.rows;
        }
    };
    fn cycleFocus(self: *App, forward: bool) !void {
        const w = self.activeWindow() orelse return;
        var ids: [256][]const u8 = undefined;
        var n: usize = 0;
        for (w.nodes) |node| if (node.kind == .pane and n < ids.len) {
            ids[n] = node.pane.?;
            n += 1;
        };
        if (n == 0) return;
        var at: usize = 0;
        if (self.focus) |f| for (ids[0..n], 0..) |id, i| if (std.mem.eql(u8, id, f)) {
            at = i;
        };
        const next = if (forward) (at + 1) % n else (at + n - 1) % n;
        try self.setFocus(ids[next]);
    }
    const Direction = enum { left, down, up, right };
    /// Cells from `from` to `to` in direction `d`, and how many they share
    /// across it; null when `to` is not on that side or they share none.
    fn neighbour(from: Rect, to: Rect, d: Direction) ?struct { gap: u32, shared: u32 } {
        const fx: i64 = from.x;
        const fy: i64 = from.y;
        const tx: i64 = to.x;
        const ty: i64 = to.y;
        const gap: i64, const low: i64, const high: i64 = switch (d) {
            .left => .{ fx - (tx + to.width), @max(fy, ty), @min(fy + from.height, ty + to.height) },
            .right => .{ tx - (fx + from.width), @max(fy, ty), @min(fy + from.height, ty + to.height) },
            .up => .{ fy - (ty + to.height), @max(fx, tx), @min(fx + from.width, tx + to.width) },
            .down => .{ ty - (fy + from.height), @max(fx, tx), @min(fx + from.width, tx + to.width) },
        };
        if (gap < 0 or high <= low) return null;
        return .{ .gap = @intCast(gap), .shared = @intCast(high - low) };
    }
    /// The tiled pane next to the focused one: the nearest, then the one
    /// sharing the longest edge, then the lowest ID. It stays put at an edge
    /// and on a float, and moving out of a zoomed pane ends the zoom.
    fn focusDirection(self: *App, d: Direction) !void {
        if (self.target != .session) return;
        const w = self.activeWindow() orelse return;
        const f = self.focus orelse return;
        var l = try geometry.compute(self.a, w.nodes, self.tiledArea());
        defer l.deinit(self.a);
        const from = for (l.leaves.items) |leaf| {
            if (std.mem.eql(u8, leaf.pane, f)) break leaf.rect;
        } else return;
        var best: ?geometry.Leaf = null;
        var best_gap: u32 = 0;
        var best_shared: u32 = 0;
        for (l.leaves.items) |leaf| {
            if (std.mem.eql(u8, leaf.pane, f)) continue;
            const n = neighbour(from, leaf.rect, d) orelse continue;
            const better = best == null or n.gap < best_gap or (n.gap == best_gap and (n.shared > best_shared or (n.shared == best_shared and idLess(leaf.pane, best.?.pane))));
            if (!better) continue;
            best = leaf;
            best_gap = n.gap;
            best_shared = n.shared;
        }
        const next = best orelse return;
        if (self.zoom != null) {
            self.unzoom();
            try self.place();
        }
        try self.setFocus(next.pane);
    }
    fn setFocus(self: *App, id: []const u8) !void {
        const changed = self.focus == null or !std.mem.eql(u8, self.focus.?, id);
        const owned = try self.a.dupe(u8, id);
        if (self.focus) |f| self.a.free(f);
        self.focus = owned;
        self.dirty = true;
        if (changed or self.refocus_due) try self.refocusLeader();
        if (changed) try self.clearAttention(id);
    }
    /// A `pane.split` or `window.create` reply this client asked for.
    /// The topology event may come before or after it.
    fn wantFocus(self: *App, ok: Value) !void {
        if (self.target != .session) return;
        const pane_id = string(ok, "pane") orelse return;
        const window_id = string(ok, "window") orelse return;
        const pane_owned = try self.a.dupe(u8, pane_id);
        errdefer self.a.free(pane_owned);
        const window_owned = try self.a.dupe(u8, window_id);
        self.dropWantFocus();
        self.want_focus = .{ .pane = pane_owned, .window = window_owned };
        try self.applyWantFocus();
    }
    fn dropWantFocus(self: *App) void {
        if (self.want_focus) |x| x.deinit(self.a);
        self.want_focus = null;
    }
    /// Focus this client's new pane once its window holds it: switch to that
    /// window if needed and leave a zoom that would hide it. Only this client
    /// moves; focus stays client-local.
    fn applyWantFocus(self: *App) !void {
        const want = self.want_focus orelse return;
        const w = self.window(want.window) orelse return;
        if (!contains(w.nodes, want.pane)) return;
        self.want_focus = null;
        defer want.deinit(self.a);
        if (self.active == null or !std.mem.eql(u8, self.active.?, want.window)) {
            const owned = try self.a.dupe(u8, want.window);
            if (self.active) |old| self.a.free(old);
            self.active = owned;
            self.unzoom();
            // Not `reconcile`: its fallback pane would be focused first.
            try self.reconcileViews();
        } else if (self.zoom) |z| if (!std.mem.eql(u8, z, want.pane)) {
            self.unzoom();
            try self.place();
        };
        try self.setFocus(want.pane);
    }
    /// Focusing a pane clears its attention, sent under this
    /// client's own identity, unless `attention.sticky`.
    fn clearAttention(self: *App, id: []const u8) !void {
        if (self.shared.attention.sticky) return;
        const info = self.shared.pane(id) orelse return;
        if (info.level == .none) return;
        try self.request("pane.attention", .{ .pane = id, .clear = true });
    }
    /// The daemon raises `info` for a BEL or a blocked report without
    /// knowing any client's focus, and on the focused pane the user is already
    /// looking at it. `warn` and `urgent` stay until the user or a product acts.
    fn clearSeenAttention(self: *App, data: Value) !void {
        const f = self.focus orelse return;
        if (!std.mem.eql(u8, string(data, "level") orelse return, "info")) return;
        if (std.mem.eql(u8, string(data, "pane") orelse return, f)) try self.clearAttention(f);
    }
    // ------------------------------------------------------------ pickers

    fn closePicker(self: *App) void {
        if (self.picker) |*p| p.deinit(self.a);
        self.picker = null;
        self.dirty = true;
    }
    /// Takes `picker` on success; on an error the caller still owns it.
    fn setPicker(self: *App, picker: Picker) !void {
        var p = picker;
        errdefer p.shown.deinit(self.a);
        try p.filter(self.a);
        if (self.picker) |*old| old.deinit(self.a);
        self.picker = p;
        self.dirty = true;
    }
    /// `leader ?`: every binding of the tables active for the
    /// focused pane, in table order, after layer precedence.
    fn openKeysPicker(self: *App) !void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const ar = arena.allocator();
        const resolved = try keys.resolve(ar, self.keymap.tables, .{ .ctx = self, .f = whenActive });
        var picker: Picker = .{ .kind = .keys };
        errdefer picker.deinit(self.a);
        for (resolved.entries) |*e| {
            const path = try resolved.path(ar, e.seq.slice()[0 .. e.seq.len - 1]);
            var label: std.ArrayList(u8) = .empty;
            for (path) |part| {
                try label.appendSlice(ar, part);
                try label.appendSlice(ar, " › ");
            }
            try label.appendSlice(ar, e.binding.text());
            try picker.add(self.a, try e.seq.text(ar), "{s}", .{label.items});
            picker.items.items[picker.items.items.len - 1].seq = e.seq;
        }
        // The leader twice sends it to the pane; the popup lists it last.
        var leader: keys.Sequence = .{};
        _ = leader.push(self.keymap.settings.leader);
        try picker.add(self.a, try leader.text(ar), "send-leader", .{});
        picker.items.items[picker.items.items.len - 1].seq = leader;
        try self.setPicker(picker);
    }
    /// The `all-keys` list: typing filters, `⏎` types the selected keys.
    fn keysPickerKey(self: *App, k: term.Input.Key) !void {
        const picker = &self.picker.?;
        const cp = k.codepoint;
        if (cp == @backingInt(named.escape)) return self.closePicker();
        if (cp == @backingInt(named.enter)) {
            const seq = (picker.current() orelse return).seq;
            self.closePicker();
            return self.typeKeys(seq);
        }
        if (cp == @backingInt(named.down) or (cp == 'n' and k.mods.ctrl)) return picker.move(true);
        if (cp == @backingInt(named.up) or (cp == 'p' and k.mods.ctrl)) return picker.move(false);
        const q = &picker.query;
        if (cp == @backingInt(named.backspace)) {
            // Drop the last character, not just its last byte.
            var n = q.items.len;
            while (n > 0) {
                n -= 1;
                if (q.items[n] & 0xc0 != 0x80) break;
            }
            q.items.len = n;
        } else if (cp == 'u' and k.mods.ctrl) {
            q.clearRetainingCapacity();
        } else if (k.mods.ctrl or k.mods.alt) {
            return;
        } else if (k.text) |t| {
            if (t.len == 0 or q.items.len + t.len > Picker.max_query) return;
            try q.appendSlice(self.a, t);
        } else {
            const c = keyChar(k);
            if (c < 0x20 or c >= 0x7f or q.items.len >= Picker.max_query) return;
            try q.append(self.a, @intCast(c));
        }
        picker.selected = 0;
        try picker.filter(self.a);
    }
    /// Feed `seq` to the router as if typed after the leader, so a binding in
    /// a sticky group leaves the client in that group.
    fn typeKeys(self: *App, seq: keys.Sequence) !void {
        const timeout = self.keymap.settings.timeout_ms;
        const active: keys.Active = .{ .ctx = self, .f = whenActive };
        try self.router.begin(self.keymap.tables, active, if (timeout == 0) keys.Router.no_deadline else self.now() + timeout);
        for (seq.slice()) |c| {
            try self.keyOutcome(try self.router.feed(self.keymap.settings, self.keymap.tables, active, c, self.now()));
            if (!self.router.pending()) break;
        }
        self.syncPopup();
    }
    /// `leader w`: the session's windows, in ID order; the active one is selected.
    fn openWindowPicker(self: *App) !void {
        if (self.target != .session) return self.say("window-picker needs attach --session", .{});
        if (!self.topology_ready) return;
        self.sortWindows();
        var picker: Picker = .{ .kind = .window };
        errdefer picker.deinit(self.a);
        for (self.windows.items, 0..) |w, i| {
            var panes: usize = 0;
            for (w.nodes) |n| {
                if (n.kind == .pane) panes += 1;
            }
            const here = self.active != null and std.mem.eql(u8, self.active.?, w.id);
            if (here) picker.selected = i;
            try picker.add(self.a, w.id, "{s}{s} {s}  {d} pane{s}", .{ w.id, if (here) "*" else "", if (here) "(active)" else "", panes, if (panes == 1) "" else "s" });
        }
        if (picker.items.items.len == 0) return self.say("no windows", .{});
        try self.setPicker(picker);
    }
    /// A `session.list` reply for `leader s`: sessions by ID, this one selected.
    fn openSessionPicker(self: *App, ok: Value) !void {
        // A late reply must not cover the prompt or another picker, or reopen
        // one (`leader s` twice asks twice), or outlive a pending quit.
        if (self.picker != null or self.prompt != null or self.quit != null) return;
        const list = field(ok, "sessions") orelse return;
        if (list != .array) return;
        var picker: Picker = .{ .kind = .session };
        errdefer picker.deinit(self.a);
        for (list.array.items) |item| {
            const id = string(item, "session") orelse continue;
            const name = string(item, "name") orelse "";
            const here = self.target == .session and std.mem.eql(u8, self.target.session, id);
            try picker.add(self.a, id, "{s}{s} {s}", .{ id, if (here) "*" else "", name });
        }
        std.mem.sort(Picker.Item, picker.items.items, {}, struct {
            fn lt(_: void, x: Picker.Item, y: Picker.Item) bool {
                return idLess(x.id, y.id);
            }
        }.lt);
        if (self.target == .session) for (picker.items.items, 0..) |i, at| if (std.mem.eql(u8, i.id, self.target.session)) {
            picker.selected = at;
        };
        if (picker.items.items.len == 0) return self.say("no sessions", .{});
        try self.setPicker(picker);
    }
    fn pickerKey(self: *App, k: term.Input.Key) !void {
        const picker = &self.picker.?;
        self.dirty = true;
        if (picker.kind == .keys) return self.keysPickerKey(k);
        if (k.codepoint == @backingInt(named.escape) or (k.codepoint == 'q' and !k.mods.ctrl and !k.mods.alt)) {
            self.closePicker();
        } else if (k.codepoint == @backingInt(named.enter)) {
            const kind = picker.kind;
            const id = try self.a.dupe(u8, (picker.current() orelse return).id);
            defer self.a.free(id);
            self.closePicker();
            switch (kind) {
                .window => try self.selectWindowId(id),
                .session => try self.switchSession(id),
                .keys => unreachable,
            }
        } else if (k.codepoint == @backingInt(named.down) or (k.codepoint == 'j' and !k.mods.ctrl) or (k.codepoint == 'n' and k.mods.ctrl)) {
            picker.move(true);
        } else if (k.codepoint == @backingInt(named.up) or (k.codepoint == 'k' and !k.mods.ctrl) or (k.codepoint == 'p' and k.mods.ctrl)) {
            picker.move(false);
        }
    }
    fn selectWindowId(self: *App, id: []const u8) !void {
        if (self.window(id) == null) return self.say("window {s} is gone", .{id});
        if (self.active) |active| if (std.mem.eql(u8, active, id)) return;
        try self.showWindow(id);
    }
    /// Re-attach this client to another session; the transport does the rest.
    pub fn switchSession(self: *App, id: []const u8) !void {
        if (self.target != .session or std.mem.eql(u8, self.target.session, id)) return;
        const owned = try self.a.dupe(u8, id);
        errdefer self.a.free(owned);
        // A failed detach leaves no pending switch for a later quit to act on.
        for (self.panes.items) |p| try p.stream.detach();
        if (self.switch_to) |old| self.a.free(old);
        self.switch_to = owned;
        self.quit = "switch session";
    }
    fn drawPicker(self: *App, surface: *Surface, picker: *const Picker) !void {
        const area = self.paneArea();
        const keys_list = picker.kind == .keys;
        // The keys list has its query row above the items.
        const head: u16 = @intFromBool(keys_list);
        if (area.width < 5 or area.height < 3 + head) return;
        const cols = struct {
            fn of(s: []const u8) usize {
                return std.unicode.utf8CountCodepoints(s) catch s.len;
            }
        }.of;
        var key_col: usize = 0;
        if (keys_list) for (picker.items.items) |i| {
            key_col = @max(key_col, cols(i.id));
        };
        key_col = @min(key_col, 16);
        const label_at: usize = if (keys_list) key_col + 2 else 0;
        var wide: usize = if (keys_list) 40 else 12;
        for (picker.items.items) |i| wide = @max(wide, cols(i.label) + label_at + 4);
        const width: u16 = @intCast(@min(wide + 2, area.width));
        const n = picker.shown.items.len;
        // An empty keys list still has its `no match` row.
        const listed = if (keys_list) @max(n, 1) else n;
        const rows: u16 = @intCast(@min(listed, area.height - 2 - head));
        const height = rows + 2 + head;
        const outer: Rect = .{ .x = area.x + (area.width - width) / 2, .y = area.y + (area.height - height) / 2, .width = width, .height = height };
        try surface.clear(toRegion(outer), self.floatGround());
        try drawBorder(surface, outer, .rounded, self.floatEdge());
        var title_buf: [48]u8 = undefined;
        const title = switch (picker.kind) {
            .window => " windows ",
            .session => " sessions ",
            .keys => std.fmt.bufPrint(&title_buf, " keys {d}/{d} ", .{ n, picker.items.items.len }) catch " keys ",
        };
        if (width > 4) try surface.text(.{ .x = outer.x + 2, .y = outer.y, .width = width - 4, .height = 1 }, title, self.floatTitle());
        var ground_dim = self.chrome.text(self.chrome.theme.bone_dim);
        ground_dim.bg = self.floatGround().bg;
        if (keys_list) {
            const line: Rect = .{ .x = outer.x + 1, .y = outer.y + 1, .width = width - 2, .height = 1 };
            var mark = self.chrome.text(self.chrome.edition.signal(self.chrome.theme));
            mark.bg = self.floatGround().bg;
            try surface.text(.{ .x = line.x, .y = line.y, .width = 2, .height = 1 }, "› ", mark);
            const rest: Rect = .{ .x = line.x + 2, .y = line.y, .width = line.width -| 2, .height = 1 };
            if (picker.query.items.len == 0) {
                try surface.text(toRegion(rest), "type to filter", ground_dim);
            } else {
                var text_buf: [Picker.max_query + 4]u8 = undefined;
                const shown = std.fmt.bufPrint(&text_buf, "{s}▏", .{picker.query.items}) catch picker.query.items;
                try surface.text(toRegion(rest), shown, self.floatTitle());
            }
            if (n == 0) {
                try surface.text(.{ .x = line.x + 1, .y = line.y + 1, .width = line.width -| 1, .height = 1 }, "no match", ground_dim);
                return;
            }
        }
        // Scroll so the selection is always listed.
        const first = if (picker.selected >= rows) picker.selected + 1 - rows else 0;
        for (0..rows) |r| {
            const item = picker.items.items[picker.shown.items[first + r]];
            const selected = first + r == picker.selected;
            const style: Style = if (selected) self.selectedRow() else ground_dim;
            const row: Rect = .{ .x = outer.x + 1, .y = outer.y + 1 + head + @as(u16, @intCast(r)), .width = width - 2, .height = 1 };
            try surface.clear(toRegion(row), style);
            if (selected) try surface.text(.{ .x = row.x, .y = row.y, .width = 1, .height = 1 }, selected_mark, self.selectedMark());
            if (keys_list) {
                var key_style = self.chrome.text(self.chrome.edition.signal(self.chrome.theme));
                key_style.bg = style.bg;
                try surface.text(.{ .x = row.x + 1, .y = row.y, .width = @intCast(@min(key_col, row.width -| 1)), .height = 1 }, item.id, key_style);
            }
            const at: u16 = @intCast(@min(label_at + 1, row.width));
            try surface.text(.{ .x = row.x + at, .y = row.y, .width = row.width - at, .height = 1 }, item.label, style);
        }
    }
    fn sortWindows(self: *App) void {
        std.mem.sort(Window, self.windows.items, {}, struct {
            fn lt(_: void, x: Window, y: Window) bool {
                return idLess(x.id, y.id);
            }
        }.lt);
    }
    /// `window-<n>`: the n-th window in ID order, counted from 0 here.
    fn selectWindow(self: *App, n: usize) !void {
        if (self.target != .session) return;
        self.sortWindows();
        if (n >= self.windows.items.len) return self.say("no window {d}", .{n + 1});
        const id = self.windows.items[n].id;
        if (self.active) |active| if (std.mem.eql(u8, active, id)) return;
        try self.showWindow(id);
    }
    fn cycleWindow(self: *App, forward: bool) !void {
        if (self.windows.items.len < 2) return;
        self.sortWindows();
        var at: usize = 0;
        if (self.active) |id| for (self.windows.items, 0..) |w, i| if (std.mem.eql(u8, w.id, id)) {
            at = i;
        };
        const n = self.windows.items.len;
        try self.showWindow(self.windows.items[if (forward) (at + 1) % n else (at + n - 1) % n].id);
    }
    fn showWindow(self: *App, id: []const u8) !void {
        const owned = try self.a.dupe(u8, id);
        if (self.active) |old| self.a.free(old);
        self.active = owned;
        if (self.focus) |f| self.a.free(f);
        self.focus = null;
        self.unzoom();
        try self.reconcile();
    }
    /// Rows this client may scroll to: loaded history, or rows still loading,
    /// up to the live view's top. That is below `active` when the view is
    /// cropped, so the cropped active rows are reachable too.
    fn scrollBounds(p: *const PaneView) ?struct { low: u64, high: u64 } {
        const vt = p.stream.vt orelse return null;
        const r = vt.rows();
        const low = if (p.stream.pendingRows()) |pending| pending.low else r.oldest;
        return .{ .low = low, .high = liveTop(p) };
    }
    /// The top row of the live view: `active`, or below it when a pane
    /// shorter than the terminal is cropped to keep the cursor visible.
    fn liveTop(p: *const PaneView) u64 {
        const vt = p.stream.vt orelse return 0;
        const r = vt.rows();
        const cursor = vt.cursor();
        const height = p.rect.height;
        return r.active + if (height > 0 and cursor.y >= height) cursor.y + 1 - height else 0;
    }
    pub fn scrollBy(self: *App, p: *PaneView, delta: i64) void {
        const b = scrollBounds(p) orelse return;
        const epoch = p.stream.vt.?.rows().epoch;
        if (p.scroll != null and p.scroll_epoch != epoch) p.scroll = null;
        const top: i64 = @intCast(p.scroll orelse b.high);
        const next = std.math.clamp(top + delta, @as(i64, @intCast(b.low)), @as(i64, @intCast(b.high)));
        p.scroll = if (next >= b.high) null else @intCast(next);
        p.scroll_epoch = epoch;
        self.dirty = true;
    }
    /// `{` / `}`: put the previous / next OSC 133 A prompt row
    /// at the top of the view. With no mark that way the view stays.
    fn jumpCommand(self: *App, p: *PaneView, dir: enum { prev, next }) void {
        const vt = p.stream.vt orelse return;
        const b = scrollBounds(p) orelse return;
        const rows = vt.rows();
        const top = self.topRow(p);
        const from = std.math.clamp(top, rows.oldest, rows.end);
        // From the loading band the oldest loaded row is below the top too,
        // and `nextPromptRow` only looks strictly below `from`.
        const oldest_starts = dir == .next and top < rows.oldest and rows.oldest < rows.end and
            (vt.rowPrompt(rows.epoch, rows.oldest) catch return) == .start;
        const found = if (oldest_starts) rows.oldest else (switch (dir) {
            .prev => vt.prevPromptRow(rows.epoch, from),
            .next => vt.nextPromptRow(rows.epoch, from),
        }) catch return;
        const row = found orelse return;
        if (row < b.low) return;
        // A mark at or below the live view's top is the live view.
        p.scroll = if (row >= b.high) null else row;
        p.scroll_epoch = rows.epoch;
        self.dirty = true;
    }
    fn paneAt(self: *const App, x: i16, y: i16) ?*PaneView {
        if (x < 0 or y < 0) return null;
        // The topmost overlay under the pointer wins over tiled panes.
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const order = self.overlayOrder(arena.allocator()) catch &.{};
        var i = order.len;
        while (i > 0) {
            i -= 1;
            const o = order[i];
            const r = o.outer;
            if (x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height) return self.pane(o.pane);
        }
        for (self.panes.items) |p| {
            if (self.overlay(p.stream.pane) != null) continue;
            const r = p.rect;
            if (x >= r.x and x < r.x + r.width and y >= r.y and y < r.y + r.height) return p;
        }
        return null;
    }
    fn releaseMouse(self: *App) void {
        if (self.mouse_capture) |capture| self.a.free(capture.pane);
        self.mouse_capture = null;
    }
    fn mouse(self: *App, host_mouse: term.Input.Mouse) !void {
        var m = host_mouse;
        // A held float takes the gesture until the button is let go.
        if (self.float_drag != null) switch (m.action) {
            .drag, .motion => return self.floatDragTo(m),
            .release => return self.dropFloat(),
            // A press without the release before it ends the old drag.
            .press => try self.dropFloat(),
        };
        if (self.mouse_capture == null and try self.floatGrab(m)) return;
        if (self.mouse_capture == null) if (self.statusRow()) |row| if (m.y == row) return self.statusClick(m);
        const p = if (self.mouse_capture) |capture| self.pane(capture.pane) orelse {
            self.releaseMouse();
            return;
        } else self.paneAt(m.x, m.y) orelse return;
        if (p.rect.width == 0 or p.rect.height == 0) {
            self.releaseMouse();
            return;
        }
        // Keep a gesture with the pane where it began; clamp outside drags.
        m.x = @intCast(std.math.clamp(@as(i32, m.x), p.rect.x, @as(i32, p.rect.x) + p.rect.width - 1));
        m.y = @intCast(std.math.clamp(@as(i32, m.y), p.rect.y, @as(i32, p.rect.y) + p.rect.height - 1));
        const vt = p.stream.vt orelse return;
        const modes = try vt.inputModes();
        const local = if (self.mouse_capture) |capture| capture.local else m.mods.shift or !modes.mouse_tracking;
        if (m.action == .press and (m.button == .left or m.button == .middle or m.button == .right)) {
            self.releaseMouse();
            self.mouse_capture = .{ .pane = try self.a.dupe(u8, p.stream.pane), .local = local };
            try self.setFocus(p.stream.pane);
        }
        defer if (m.action == .release) self.releaseMouse();
        if (!local) {
            if (!canInput(p)) return;
            // Scrolling changes which emulator rows are visible. Program
            // mouse input returns to live before mapping the displayed crop.
            self.follow(p);
            m.x -= @intCast(p.rect.x);
            m.y = @intCast(@as(u64, @intCast(m.y)) - p.rect.y + self.topRow(p) - vt.rows().active);
            const bytes = vt.encodeMouse(self.a, m, self.mouse_geometry) catch |err| switch (err) {
                error.Unavailable, error.InvalidValue => return self.say("mouse encoding unavailable (use Shift for local selection)", .{}),
                else => return err,
            };
            defer self.a.free(bytes);
            return p.stream.input(bytes);
        }
        switch (m.button) {
            .wheel_up => return self.scrollBy(p, -3),
            .wheel_down => return self.scrollBy(p, 3),
            .left => {},
            else => return,
        }
        const epoch = vt.rows().epoch;
        const point: Point = .{ .row = self.topRow(p) + @as(u64, @intCast(m.y - @as(i16, @intCast(p.rect.y)))), .col = @intCast(m.x - @as(i16, @intCast(p.rect.x))) };
        switch (m.action) {
            .press => {
                try self.setFocus(p.stream.pane);
                // A mouse selection replaces the keyboard one.
                p.copy = null;
                p.selection = .{ .epoch = epoch, .anchor = point, .head = point };
            },
            .drag, .motion => if (p.selection) |*s| if (s.dragging and s.epoch == epoch) {
                s.head = point;
            },
            .release => if (p.selection) |*s| {
                s.head = point;
                s.dragging = false;
                if (!std.meta.eql(s.anchor, s.head)) try self.copy(p);
            },
        }
        self.dirty = true;
    }
    /// Copy the selection to the host clipboard with OSC 52. Local only.
    fn copy(self: *App, p: *PaneView) !void {
        const text = try self.selectionText(p) orelse return;
        defer self.a.free(text);
        const enc = std.base64.standard.Encoder;
        const buf = try self.a.alloc(u8, enc.calcSize(text.len));
        defer self.a.free(buf);
        try self.host.appendSlice(self.a, "\x1b]52;c;");
        try self.host.appendSlice(self.a, enc.encode(buf, text));
        try self.host.appendSlice(self.a, "\x07");
        self.say("copied {d} bytes", .{text.len});
    }
    /// Start copy mode on the pane's cursor, or on the view's last
    /// row when the cursor is scrolled out of it.
    fn enterCopy(self: *App, p: *PaneView) void {
        const vt = p.stream.vt orelse return;
        const rows = vt.rows();
        if (p.rect.height == 0) return;
        if (p.scroll != null and p.scroll_epoch != rows.epoch) p.scroll = null;
        const top = self.topRow(p);
        const h: u64 = p.rect.height;
        const cur = vt.cursor();
        const y = rows.active + cur.y;
        const at: copy_mode.Point = if (y >= top and y < top + h) .{ .row = y, .col = cur.x } else .{ .row = top + h - 1, .col = 0 };
        p.copy = .{ .epoch = rows.epoch, .cursor = at };
        p.selection = null;
        self.dirty = true;
        const cells: CopyCells = .{ .vt = vt, .epoch = rows.epoch };
        if (self.copyGrid(p, &cells)) |g| p.copy.?.cursor = g.clamp(at);
    }
    fn leaveCopy(self: *App, p: *PaneView) void {
        p.copy = null;
        p.selection = null;
        p.scroll = null;
        self.dirty = true;
    }
    /// Cells as copy mode reads them.
    const CopyCells = struct {
        vt: term.Vt,
        epoch: u64,
        fn charAt(ctx: *const anyopaque, row: u64, col: u16) u21 {
            const self: *const CopyCells = @ptrCast(@alignCast(ctx));
            var buf: term.Vt.CellBuffer = undefined;
            // A grapheme too long for the buffer is still a word character.
            const cell = (self.vt.readCellBuf(&buf, self.epoch, row, col) catch return ' ') orelse return 'x';
            // A wide character's spacer cell belongs to its word.
            if (cell.text.len == 0) return if (cell.width == 0) 'x' else ' ';
            const n = std.unicode.utf8ByteSequenceLength(cell.text[0]) catch return 'x';
            if (n > cell.text.len) return 'x';
            return std.unicode.utf8Decode(cell.text[0..n]) catch 'x';
        }
    };
    /// The rows copy mode may visit: loaded history down to the live view's
    /// last row.
    fn copyGrid(self: *const App, p: *const PaneView, cells: *const CopyCells) ?copy_mode.Grid {
        const rows = cells.vt.rows();
        const h = p.rect.height;
        const cols = @min(cells.vt.size().cols, p.rect.width);
        if (h == 0 or cols == 0) return null;
        const end = @min(rows.end, liveTop(p) + h);
        if (end <= rows.oldest) return null;
        return .{ .ctx = cells, .cols = cols, .low = rows.oldest, .high = end - 1, .top = self.topRow(p), .height = h, .charAt = CopyCells.charAt };
    }
    fn copyKeyOf(k: term.Input.Key) ?copy_mode.Key {
        if (k.mods.alt or k.mods.super) return null;
        const cp = k.codepoint;
        inline for (.{ "escape", "enter", "backspace", "left", "right", "up", "down", "page_up", "page_down", "home", "end" }) |name| {
            if (cp == @backingInt(@field(named, name))) return @field(copy_mode.Key, name);
        }
        if (k.mods.ctrl) return if (cp < 0x80) .{ .ctrl = std.ascii.toLower(@intCast(cp)) } else null;
        const ch = keyChar(k);
        return if (ch >= 0x20 and ch != 0x7f) .{ .char = ch } else null;
    }
    fn copyKey(self: *App, p: *PaneView, k: term.Input.Key) !void {
        self.dirty = true;
        const vt = p.stream.vt orelse return self.leaveCopy(p);
        const rows = vt.rows();
        if (p.copy.?.epoch != rows.epoch) return self.leaveCopy(p);
        const cells: CopyCells = .{ .vt = vt, .epoch = rows.epoch };
        const g = self.copyGrid(p, &cells) orelse return;
        const key = copyKeyOf(k) orelse return;
        const st = &p.copy.?;
        switch (st.key(g, key)) {
            .none, .moved => {},
            .not_found => {
                var buf: [copy_mode.Pattern.max * 4]u8 = undefined;
                self.say("pattern not found: {s}", .{utf8Of(&buf, st.last.slice())});
            },
            .exit => return self.leaveCopy(p),
            .yank => {
                self.syncCopy(p, g.cols);
                try self.copy(p);
                return self.leaveCopy(p);
            },
            .prompt_prev, .prompt_next => |dir| {
                const found = (if (dir == .prompt_prev) vt.prevPromptRow(rows.epoch, st.cursor.row) else vt.nextPromptRow(rows.epoch, st.cursor.row)) catch null;
                if (found) |row| if (row >= g.low and row <= g.high) {
                    st.cursor = .{ .row = row, .col = 0 };
                };
            },
        }
        self.syncCopy(p, g.cols);
        // Keep the cursor in view, scrolling no further than needed.
        const top = self.topRow(p);
        const h: u64 = p.rect.height;
        const row = st.cursor.row;
        const want = if (row < top) row else if (row >= top + h) row + 1 - h else top;
        if (want != top) {
            p.scroll = if (want >= liveTop(p)) null else want;
            p.scroll_epoch = rows.epoch;
        }
    }
    fn utf8Of(buf: []u8, cps: []const u21) []const u8 {
        var n: usize = 0;
        for (cps) |cp| {
            if (n + 4 > buf.len) break;
            n += std.unicode.utf8Encode(cp, buf[n..][0..4]) catch continue;
        }
        return buf[0..n];
    }
    /// The copy mode search line (`/text` or `?text`) on one row,
    /// with the cursor at its end.
    fn drawSearchLine(self: *App, surface: *Surface, row: term.Region, dir: copy_mode.Dir, cps: []const u21) !void {
        var buf: [1 + copy_mode.Pattern.max * 4]u8 = undefined;
        buf[0] = if (dir == .forward) '/' else '?';
        const text = buf[0 .. 1 + utf8Of(buf[1..], cps).len];
        const base = self.chrome.statusBar();
        try surface.clear(row, base);
        try surface.text(row, text, base);
        surface.setCursor(.{ .x = row.x + @as(u16, @intCast(@min(1 + cps.len, row.width -| 1))), .y = row.y });
    }
    /// The last search's matches in view, drawn on `warn`.
    fn searchMatches(self: *App, surface: *Surface, p: *const PaneView, top: u64) !void {
        const st = p.copy orelse return;
        if (st.last.len == 0 or st.editing != null) return;
        const vt = p.stream.vt orelse return;
        const cells: CopyCells = .{ .vt = vt, .epoch = st.epoch };
        const g = self.copyGrid(p, &cells) orelse return;
        const pat = st.last.slice();
        const t = self.chrome.theme;
        const mark = self.chrome.fill(t.void, t.warn);
        const r = p.rect;
        for (0..r.height) |y| {
            const row = top + y;
            if (row < g.low or row > g.high) continue;
            var col: u16 = 0;
            while (col < g.cols) : (col += 1) {
                if (!copy_mode.matchAt(g, pat, row, col)) continue;
                for (0..pat.len) |i| {
                    const sx: u16 = @intCast(r.x + col + i);
                    const sy: u16 = @intCast(r.y + y);
                    const cell = surface.get(sx, sy) orelse continue;
                    const text = try self.a.dupe(u8, cell.text);
                    defer self.a.free(text);
                    try surface.put(sx, sy, .{ .text = text, .width = cell.width, .style = mark });
                }
                col += @intCast(pat.len - 1);
            }
        }
    }
    /// The copy mode's selection is what the client draws and copies.
    fn syncCopy(self: *const App, p: *PaneView, cols: u16) void {
        _ = self;
        const st = p.copy orelse return;
        p.selection = if (st.selection(cols)) |ends| .{ .epoch = st.epoch, .anchor = ends[0], .head = ends[1], .dragging = false } else null;
    }
    fn ordered(s: Selection) struct { Point, Point } {
        const forward = s.anchor.row < s.head.row or (s.anchor.row == s.head.row and s.anchor.col <= s.head.col);
        return if (forward) .{ s.anchor, s.head } else .{ s.head, s.anchor };
    }
    pub fn selectionText(self: *App, p: *const PaneView) !?[]u8 {
        const s = p.selection orelse return null;
        const vt = p.stream.vt orelse return null;
        const r = vt.rows();
        if (s.epoch != r.epoch) return null;
        const start, const end = ordered(s);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.a);
        var row = @max(start.row, r.oldest);
        while (row <= end.row and row < r.end) : (row += 1) {
            const from: u16 = if (row == start.row) start.col else 0;
            const to: u16 = if (row == end.row) @min(end.col, vt.size().cols -| 1) else vt.size().cols -| 1;
            const line_start = out.items.len;
            var col = from;
            while (col <= to) : (col += 1) {
                const cell = try vt.readCell(self.a, r.epoch, row, col);
                defer self.a.free(cell.text);
                if (cell.width != 0) try out.appendSlice(self.a, cell.text);
            }
            // Trailing blanks are layout, not text.
            while (out.items.len > line_start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
            if (row != end.row) try out.append(self.a, '\n');
        }
        return try out.toOwnedSlice(self.a);
    }

    // ------------------------------------------------------------ drawing

    /// The absolute row shown at the top of the pane's rectangle.
    pub fn topRow(self: *const App, p: *const PaneView) u64 {
        _ = self;
        const vt = p.stream.vt orelse return 0;
        const r = vt.rows();
        if (p.scroll) |top| if (p.scroll_epoch == r.epoch) return top;
        return liveTop(p);
    }
    /// Whether the next render would change anything. Not while a pane with
    /// new output is partway through a synchronized-output frame: drawing it
    /// would show the half-drawn frame and the cursor wherever the program
    /// is writing. The frame's end, or `sync_limit_ms`, releases it.
    pub fn needsRender(self: *const App) bool {
        if (self.syncHeld()) return false;
        return self.dirty or self.pane_damage;
    }
    fn syncHeld(self: *const App) bool {
        const t = self.now();
        for (self.panes.items) |p| if (p.damaged) if (p.sync_since) |since| if (t < since + sync_limit_ms) return true;
        return false;
    }
    /// Draws the client. After pane output alone, only the rows those
    /// panes changed are rewritten; anything else redraws everything.
    pub fn render(self: *App, surface: *Surface) !void {
        // What a pane's programs are told is its ground (OSC 10/11, from the
        // daemon's theme) is what its default cells are painted in.
        // Only in truecolor: a 16-colour terminal keeps its own ground.
        surface.setDefaults(if (self.chrome.mode == .truecolor)
            .{ .fg = .{ .rgb = self.chrome.theme.bone.rgb }, .bg = .{ .rgb = self.chrome.theme.void.rgb } }
        else
            .{});
        defer {
            self.pane_damage = false;
            for (self.panes.items) |p| p.damaged = false;
        }
        if (!self.dirty and self.pane_damage and surface.width == self.cols and surface.height == self.rows and try self.renderDamage(surface)) return;
        if (surface.width != self.cols or surface.height != self.rows) try surface.resize(self.cols, self.rows);
        try surface.clear(toRegion(self.paneArea()), .{});
        for (self.panes.items) |p| p.has_title_line = false;
        surface.setCursor(null);
        const area = self.paneArea();
        switch (self.target) {
            .pane => if (self.pane(self.target.pane)) |p| try self.drawPane(surface, p),
            .session => |s| {
                if (!self.topology_ready) {
                    try centered(surface, toRegion(area), "connecting…", self.chrome.mutedText());
                } else if (self.activeWindow()) |w| {
                    if (w.nodes.len == 0) {
                        var buf: [96]u8 = undefined;
                        try self.drawEmpty(surface, toRegion(area), std.fmt.bufPrint(&buf, "window {s} is empty", .{w.id}) catch "empty window", !self.sessionHasPanes());
                    }
                    if (self.zoomed()) |z| {
                        try self.drawBorders(surface, &.{}, z);
                        try self.drawPane(surface, z);
                    } else {
                        var l = try geometry.compute(self.a, w.nodes, self.tiledArea());
                        defer l.deinit(self.a);
                        try self.drawBorders(surface, l.separators.items, null);
                        for (l.leaves.items) |leaf| if (self.pane(leaf.pane)) |p| try self.drawPane(surface, p);
                    }
                    try self.drawOverlays(surface);
                } else if (self.overlays.items.len > 0) {
                    try self.drawOverlays(surface);
                } else {
                    var buf: [96]u8 = undefined;
                    try self.drawEmpty(surface, toRegion(area), std.fmt.bufPrint(&buf, "session {s} has no windows (leader c creates one)", .{s}) catch "no windows", true);
                }
            },
        }
        // Over everything in the pane area, changing no pane.
        if (self.popup.visible()) {
            var arena = std.heap.ArenaAllocator.init(self.a);
            defer arena.deinit();
            const popup_theme = self.floatTheme();
            _ = try popup_widget.draw(surface, toRegion(area), &popup_theme, try self.popupModel(arena.allocator()), .{});
        }
        if (self.picker) |*picker| {
            surface.setCursor(null);
            try self.drawPicker(surface, picker);
        }
        if (self.statusRow() != null) try self.drawStatus(surface);
        self.dirty = false;
    }
    /// Whether any window of the attached session holds a pane.
    fn sessionHasPanes(self: *const App) bool {
        for (self.windows.items) |w| for (w.nodes) |n| if (n.pane != null) return true;
        return false;
    }
    /// The empty state of a session with no panes: the fangs
    /// above the message when the area is tall enough, else the message alone.
    fn drawEmpty(self: *App, surface: *Surface, r: term.Region, message: []const u8, with_fangs: bool) !void {
        try centered(surface, r, message, self.chrome.mutedText());
        if (!with_fangs) return;
        const captions = [_][]const u8{ "venomx " ++ fangs.version, fangs.tagline };
        const mid = r.y + r.height / 2;
        const block = fangs.width(&captions);
        if (mid < r.y + fangs.height + 1 or block > r.width) return;
        try fangs.draw(surface, r, self.chrome, r.x + (r.width - block) / 2, mid - fangs.height - 1, &captions);
    }
    /// The damage-only render. False when it cannot stand in for a full
    /// one: a damaged pane is not drawable row by row, or something is
    /// drawn over it.
    fn renderDamage(self: *App, surface: *Surface) !bool {
        if (self.picker != null) return false;
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const al = arena.allocator();
        // What the full render draws, bottom to top, with what it covers.
        const Shown = struct { p: *PaneView, covers: Rect };
        var shown: std.ArrayList(Shown) = .empty;
        switch (self.target) {
            .pane => |id| if (self.pane(id)) |p| try shown.append(al, .{ .p = p, .covers = p.rect }),
            .session => {
                if (!self.topology_ready) return false;
                if (self.activeWindow()) |w| {
                    if (self.zoomed()) |z| try shown.append(al, .{ .p = z, .covers = z.rect }) else for (w.nodes) |n| if (n.kind == .pane) if (self.pane(n.pane.?)) |p| {
                        try shown.append(al, .{ .p = p, .covers = p.rect });
                    };
                } else if (self.overlays.items.len == 0) return false;
                for (try self.overlayOrder(al)) |o| if (self.pane(o.pane)) |p| try shown.append(al, .{ .p = p, .covers = o.outer });
            },
        }
        // The leader popup is on top of everything, and is not a pane. Panes
        // clear of it can still patch.
        const popup: Rect = if (self.popup.visible()) blk: {
            const outer = popup_widget.place(toRegion(self.paneArea()), try self.popupModel(al), .{}).outer;
            break :blk .{ .x = outer.x, .y = outer.y, .width = outer.width, .height = outer.height };
        } else .{};
        for (shown.items, 0..) |s, i| if (s.p.damaged) {
            if (!self.patchable(s.p)) return false;
            // A new title is on the border, which only a full render draws.
            if (s.p.has_title_line and s.p.drawn_title != self.lineKey(s.p)) return false;
            // Every listed pane's process and cwd are in the status line's
            // blocks, which a full render draws. With the status line off
            // there is nowhere to show them.
            if (self.statusRow() != null and self.status_key != self.statusKey()) return false;
            if (overlaps(s.p.rect, popup)) return false;
            for (shown.items[i + 1 ..]) |above| if (overlaps(s.p.rect, above.covers)) return false;
        };
        for (shown.items) |s| if (s.p.damaged) {
            if (self.focus) |f| if (std.mem.eql(u8, f, s.p.stream.pane)) surface.setCursor(null);
            try self.drawPaneWith(surface, s.p, .changed);
        };
        return true;
    }
    /// A pane whose last draw can be patched row by row: it follows its
    /// live active area, uncropped, with no local selection.
    fn patchable(self: *const App, p: *const PaneView) bool {
        const vt = p.stream.vt orelse return false;
        if (p.scroll != null or p.selection != null or p.rect.width == 0 or p.rect.height == 0) return false;
        return self.topRow(p) == vt.rows().active;
    }
    /// Floats then popups, bottom to top, each over what is below:
    /// cleared, bordered in a theme role with its title, then its pane.
    fn drawOverlays(self: *App, surface: *Surface) !void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const order = try self.overlayOrder(arena.allocator());
        for (order) |o| {
            const p = self.pane(o.pane) orelse continue;
            const r = o.outer;
            if (r.width == 0 or r.height == 0) continue;
            try surface.clear(toRegion(r), self.floatGround());
            if (!o.full and o.geometry.border != .none and r.width >= 3 and r.height >= 3) {
                const focused_here = self.focus != null and std.mem.eql(u8, self.focus.?, o.pane);
                const l = self.level(o.pane);
                // Floats have a `rule_strong` edge; focus wins;
                // only `urgent` recolours an unfocused border.
                var style: Style = if (focused_here) self.chrome.focusedBorder() else if (l == .urgent) self.chrome.text(self.chrome.theme.warn) else self.floatEdge();
                style.bg = self.floatGround().bg;
                try drawBorder(surface, r, o.geometry.border, style);
                const title = if (o.geometry.title.len > 0) o.geometry.title else o.pane;
                var buf: [160]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, " {s} ", .{title}) catch title;
                if (r.width > 4) try surface.text(.{ .x = r.x + 2, .y = r.y, .width = r.width - 4, .height = 1 }, label, self.floatTitle());
            }
            try self.drawPane(surface, p);
        }
        // A focused tiled pane's cursor stays hidden under an overlay.
        if (self.focus) |f| if (self.overlay(f) == null) if (surface.cursor) |cur| for (order) |o| {
            const r = o.outer;
            if (cur.x >= r.x and cur.x < r.x + r.width and cur.y >= r.y and cur.y < r.y + r.height) {
                surface.setCursor(null);
                break;
            }
        };
    }
    fn level(self: *const App, pane_id: []const u8) ac.Level {
        return if (self.shared.pane(pane_id)) |info| info.level else .none;
    }
    /// The state mark of a pane's title line: attention
    /// `info` is `◆`, `warn` and `urgent` are `▲`; otherwise the exit of a
    /// pane whose process ended, then its OSC 7501 report (busy `◆`, waiting
    /// `▲`, done `●`, error `✕`; by summary priority), then the exit
    /// of its last OSC 133 command (`●` or `✕`). A pane with no report is
    /// idle `○`: the mark always stays.
    pub fn paneMark(self: *const App, p: *const PaneView) edges.Mark {
        const m = self.chrome.statusMark(self.paneStatus(p));
        return .{ .glyph = m.glyph, .style = m.style };
    }
    fn paneStatus(self: *const App, p: *const PaneView) term.theme.Status {
        return switch (self.level(p.stream.pane)) {
            .info => .info,
            .warn, .urgent => .warn,
            .none => if (p.stream.exit) |e| switch (e) {
                .code => |c| if (c == 0) term.theme.Status.ok else term.theme.Status.danger,
                .signal => term.theme.Status.danger,
            } else self.reportedStatus(p.stream.pane),
        };
    }
    fn reportedStatus(self: *const App, pane_id: []const u8) term.theme.Status {
        const info = self.shared.pane(pane_id) orelse return .idle;
        return switch (info.program) {
            .blocked => .warn,
            .failed => .danger,
            .done => .ok,
            .working => .info,
            .idle, .none => switch (info.command) {
                .ok => .ok,
                .failed => .danger,
                .none => .idle,
            },
        };
    }
    /// The pane's OSC 2 title, else `argv0`, else empty. Borrowed; the caller removes control and bidi
    /// characters when drawing.
    fn titleOf(self: *const App, p: *const PaneView) []const u8 {
        if (p.stream.vt) |vt| {
            const t = vt.title() catch "";
            if (t.len > 0) return t;
        }
        if (self.shared.pane(p.stream.pane)) |info| if (info.argv0) |x| return x;
        return "";
    }
    /// The naming order for what runs in a pane: a current
    /// OSC 2 title, else the active command's `cmdline`, else the sampled
    /// `process`, else `argv0`, else any title. Borrowed and untrusted.
    fn processOf(self: *const App, p: *const PaneView) []const u8 {
        const title: []const u8 = if (p.stream.vt) |vt| vt.title() catch "" else "";
        const info = self.shared.pane(p.stream.pane) orelse return title;
        if (info.title_current and title.len > 0) return title;
        if (info.cmdline) |x| return x;
        if (info.process) |x| return x;
        if (info.argv0) |x| return x;
        return title;
    }
    fn groupTag(self: *const App, p: *const PaneView) []const u8 {
        return if (self.shared.pane(p.stream.pane)) |i| i.tags.get("group") orelse "" else "";
    }
    fn pwdOf(p: *const PaneView) ?[]const u8 {
        const vt = p.stream.vt orelse return null;
        return vt.pwd() catch null;
    }
    /// What a title line was drawn from, so a change redraws it: damage-only
    /// renders patch cells, not borders.
    fn lineKey(self: *const App, p: *const PaneView) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(self.titleOf(p));
        h.update("\x00");
        h.update(self.groupTag(p));
        h.update("\x00");
        h.update(pwdOf(p) orelse "");
        return h.final();
    }
    /// The right part: tag `group`, else the cwd the
    /// pane reported by OSC 7, else empty. The cwd is copied into `al`.
    fn rightOf(self: *const App, al: std.mem.Allocator, p: *const PaneView) ![]const u8 {
        const tag = self.groupTag(p);
        if (tag.len > 0) return tag;
        return pane_text.rightPart(al, pwdOf(p), self.home, self.local_host);
    }
    fn borderLine(self: *const App, al: std.mem.Allocator, p: *PaneView) !edges.Line {
        const title = self.titleOf(p);
        p.drawn_title = self.lineKey(p);
        p.has_title_line = true;
        const is_focus = if (self.focus) |f| std.mem.eql(u8, f, p.stream.pane) else false;
        return .{
            .rect = p.rect,
            .title = title,
            .tag = try self.rightOf(al, p),
            .mark = self.paneMark(p),
            .look = if (is_focus) .focus else if (self.level(p.stream.pane) == .urgent) .urgent else .rule,
        };
    }
    fn borderStyles(self: *const App) edges.Styles {
        const c = self.chrome;
        var title_focus = c.text(c.theme.bone);
        title_focus.bold = true;
        return .{
            .rule = c.inactiveBorder(),
            .urgent = c.text(c.theme.warn),
            .focus = c.focusedBorder(),
            .title = c.text(c.theme.bone_dim),
            .title_focus = title_focus,
            .tag = c.mutedText(),
        };
    }
    /// Draws the separators and title lines for the tiled panes, or for the
    /// zoomed one alone.
    fn drawBorders(self: *App, surface: *Surface, separators: []const geometry.Separator, zoomed_pane: ?*PaneView) !void {
        const tiled = self.tiledArea();
        if (!self.hasTitleRow() or tiled.y == 0) return;
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        var lines: std.ArrayList(edges.Line) = .empty;
        if (zoomed_pane) |z| {
            try lines.append(arena.allocator(), try self.borderLine(arena.allocator(), z));
        } else if (self.activeWindow()) |w| for (w.nodes) |n| if (n.kind == .pane) if (self.pane(n.pane.?)) |p| {
            if (p.rect.width > 0 and p.rect.height > 0) try lines.append(arena.allocator(), try self.borderLine(arena.allocator(), p));
        };
        try edges.draw(surface, .{
            .lines = lines.items,
            .separators = separators,
            .title_row = .{ .x = tiled.x, .y = tiled.y - 1, .width = tiled.width, .height = 1 },
            .styles = self.borderStyles(),
            .support = self.support,
        });
    }
    const Redraw = enum { all, changed };
    fn drawPane(self: *App, surface: *Surface, p: *PaneView) !void {
        return self.drawPaneWith(surface, p, .all);
    }
    fn drawPaneWith(self: *App, surface: *Surface, p: *PaneView, redraw: Redraw) !void {
        // The attention mark and `urgent` colour are on the pane's border, drawn with it, not over the pane's first row.
        try self.drawPaneContent(surface, p, redraw);
    }
    fn drawPaneContent(self: *App, surface: *Surface, p: *PaneView, redraw: Redraw) !void {
        const r = p.rect;
        if (r.width == 0 or r.height == 0) return;
        const region: term.Region = .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
        const vt = p.stream.vt orelse {
            const label = if (p.stream.closed) |c| c else if (p.stream.phase == .closed) "closed" else "loading…";
            var buf: [96]u8 = undefined;
            // An unreadable leaf stays visible as a placeholder.
            const text = if (p.stream.closed != null and std.mem.startsWith(u8, label, "denied")) std.fmt.bufPrint(&buf, "{s}: unavailable ({s})", .{ p.stream.pane, label }) catch label else label;
            return centered(surface, region, text, self.chrome.mutedText());
        };
        const rows = vt.rows();
        // A resize or reset starts a new epoch; an old scroll row is void.
        if (p.scroll != null and p.scroll_epoch != rows.epoch) p.scroll = null;
        const top = self.topRow(p);
        // Rows still arriving as SCROLLBACK are drawn as a loading band.
        const loading: u16 = if (top < rows.oldest) @intCast(@min(rows.oldest - top, r.height)) else 0;
        const dim = self.chrome.mutedText();
        for (0..loading) |y| try surface.text(.{ .x = r.x, .y = r.y + @as(u16, @intCast(y)), .width = r.width, .height = 1 }, "·· loading history ··", dim);
        if (loading < r.height) {
            const below: term.Region = .{ .x = r.x, .y = r.y + loading, .width = r.width, .height = r.height - loading };
            const first = top + loading;
            if (first == rows.active and p.scroll == null) p.view.follow() else try p.view.scrollTo(vt, first);
            if (redraw == .changed) try p.view.drawChanged(vt, surface, below) else try p.view.draw(vt, surface, below);
        }
        try self.searchMatches(surface, p, top);
        try self.highlight(surface, p, top);
        try self.commandBlock(surface, p, top);
        if (p.stream.exit) |e| {
            var buf: [48]u8 = undefined;
            const label = switch (e) {
                .code => |c| std.fmt.bufPrint(&buf, " {s} exited {d} ", .{ if (c == 0) "●" else "✕", c }) catch " exited ",
                .signal => |sig| std.fmt.bufPrint(&buf, " ✕ {s} ", .{sig}) catch " exited ",
            };
            try cornerLabel(surface, r, label, self.roleFill(if (e == .code and e.code == 0) .ok else .@"error"));
        }
        if (p.scroll != null) {
            var buf: [48]u8 = undefined;
            const label = std.fmt.bufPrint(&buf, " -{d} ", .{liveTop(p) -| top}) catch "";
            try cornerLabel(surface, r, label, self.roleFill(.warn));
        }
        if (p.copy) |st| if (st.epoch != rows.epoch) {
            p.copy = null;
            p.selection = null;
        };
        // A scrolled pane keeps its cursor while the cursor's row is
        // in view. In copy mode the copy cursor replaces it.
        if (self.focus) |f| if (std.mem.eql(u8, f, p.stream.pane) and self.prompt == null) {
            if (p.copy) |st| {
                // With no status line the search line takes the pane's last row.
                if (st.searchLine()) |line| if (self.statusRow() == null)
                    return self.drawSearchLine(surface, .{ .x = r.x, .y = r.y + r.height - 1, .width = r.width, .height = 1 }, line[0], line[1]);
                if (st.cursor.row >= top and st.cursor.row < top + r.height and st.cursor.col < r.width)
                    surface.setCursor(.{ .x = r.x + st.cursor.col, .y = r.y + @as(u16, @intCast(st.cursor.row - top)), .shape = .{ .kind = .block } });
                return;
            }
            const cursor = vt.cursor();
            const y = rows.active + cursor.y;
            // The program's DECSCUSR shape (vim's bar in insert mode)
            // reaches the host; an unshaped cursor keeps the host's own.
            if (cursor.visible and p.stream.exit == null and cursor.x < r.width and y >= top and y < top + r.height)
                surface.setCursor(.{ .x = r.x + cursor.x, .y = r.y + @as(u16, @intCast(y - top)), .shape = try vt.cursorShape() });
        };
    }
    fn highlight(self: *App, surface: *Surface, p: *const PaneView, top: u64) !void {
        const s = p.selection orelse return;
        const vt = p.stream.vt.?;
        if (s.epoch != vt.rows().epoch) return;
        const start, const end = ordered(s);
        const r = p.rect;
        for (0..r.height) |y| {
            const row = top + y;
            if (row < start.row or row > end.row) continue;
            const from: usize = if (row == start.row) start.col else 0;
            const to: usize = if (row == end.row) end.col else r.width -| 1;
            var x = from;
            while (x <= to and x < r.width) : (x += 1) {
                const sx: u16 = @intCast(r.x + x);
                const sy: u16 = @intCast(r.y + y);
                const cell = surface.get(sx, sy) orelse continue;
                const text = try self.a.dupe(u8, cell.text);
                defer self.a.free(text);
                // Pane content, not chrome: a selection inverts whatever colours
                // the program drew the cell in.
                var style = cell.style;
                style.reverse = !style.reverse;
                try surface.put(sx, sy, .{ .text = text, .width = cell.width, .style = style });
            }
        }
    }
    /// While scrolled, the command block holding the top row
    /// (a start row up to before the next one) is drawn on `grave`. The
    /// signal goes only on the command-mark cell of its prompt rows,
    /// and only on a tiled separator left of the pane: a mark never takes a
    /// column from the pane's PTY (a gutter would be separate work). The separator is
    /// found from the layout, not its glyph, which is heavy beside the
    /// focused pane and a junction where splits meet.
    /// A shell that sends only OSC 133 A (no C) leaves libghostty marking
    /// every row up to the next prompt as continuation, so the signal then
    /// runs down the whole block.
    fn commandBlock(self: *App, surface: *Surface, p: *PaneView, top: u64) !void {
        if (p.scroll == null) return;
        const vt = p.stream.vt orelse return;
        const epoch = vt.rows().epoch;
        if (p.scroll_epoch != epoch) return;
        const r = p.rect;
        if (r.width == 0 or r.height == 0) return;
        // The start row at or above the top, cached for this epoch and top
        // while every row it covers is history, which does not change: an
        // active row can be rewritten in place. A trimmed start row or
        // backfill under a null search needs a new search; trimming alone
        // (every frame once history is full) does not.
        const rows = vt.rows();
        const oldest = rows.oldest;
        const cached = if (p.block_cache) |c|
            c.epoch == epoch and c.top == top and top < rows.active and
                (if (c.first) |f| f >= oldest else oldest >= c.oldest)
        else
            false;
        if (!cached) {
            const found: ?u64 = if ((vt.rowPrompt(epoch, top) catch return) == .start) top else (vt.prevPromptRow(epoch, top) catch return);
            p.block_cache = .{ .epoch = epoch, .oldest = oldest, .top = top, .first = found };
        }
        const first = p.block_cache.?.first orelse return;
        const grave = self.chrome.color(self.chrome.theme.grave);
        var mark = self.chrome.text(self.chrome.edition.signal(self.chrome.theme));
        mark.bg = grave;
        // A tiled pane right of another always has a separator column at
        // `r.x - 1` (attach_layout.walk); a zoomed pane, a float, a lone pane
        // and a pane-target client have none.
        const on_separator = self.target == .session and self.zoomed() == null and
            self.overlay(p.stream.pane) == null and r.x > self.tiledArea().x;
        for (0..r.height) |y| {
            const row = top + y;
            const kind = vt.rowPrompt(epoch, row) catch return;
            // The next start row ends the block.
            if (row > first and kind == .start) break;
            const sy: u16 = @intCast(r.y + y);
            for (0..r.width) |x| {
                const sx: u16 = @intCast(r.x + x);
                const cell = surface.get(sx, sy) orelse continue;
                var style = cell.style;
                style.bg = grave;
                try surface.put(sx, sy, .{ .text = cell.text, .width = cell.width, .style = style });
            }
            if (on_separator and kind != .none) try surface.put(r.x - 1, sy, .{ .text = "▌", .width = 1, .style = mark });
        }
    }
    fn drawStatus(self: *App, surface: *Surface) !void {
        const y = self.statusRow().?;
        const base = self.chrome.statusBar();
        try surface.clear(.{ .y = y, .width = self.cols, .height = 1 }, base);
        // What the pane blocks show, even while the prompt covers them, so
        // the damage path does not keep falling back to full renders.
        self.status_key = self.statusKey();
        if (self.focused()) |p| if (p.copy) |*st| if (st.searchLine()) |line|
            return self.drawSearchLine(surface, .{ .y = y, .width = self.cols, .height = 1 }, line[0], line[1]);
        if (self.prompt) |p| {
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(self.a);
            try line.print(self.a, ":{s}", .{p.items});
            try surface.text(.{ .y = y, .width = self.cols, .height = 1 }, line.items, base);
            surface.setCursor(.{ .x = @intCast(@min(line.items.len, self.cols -| 1)), .y = y });
            return;
        }
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const items = try self.statusItems(arena.allocator());
        defer self.pane_blocks = &.{};
        var started = [3]bool{ false, false, false };
        var rule = self.chrome.inactiveBorder();
        rule.bg = base.bg;
        var fang = self.chrome.text(self.chrome.edition.signal(self.chrome.theme));
        fang.bg = base.bg;
        // Where the session block ends: the fang cut goes there, in place of
        // the first separator.
        var block_end: ?u16 = null;
        for (try ac.layout(arena.allocator(), items, self.cols)) |placed| {
            const side = @backingInt(placed.side);
            // The cut belongs to the next item on the block's own (left) side;
            // an item on the other side leaves it pending.
            if (side == 0 and block_end != null) {
                const end = block_end.?;
                if (end < placed.x) try surface.text(.{ .x = end, .y = y, .width = 1, .height = 1 }, self.support.fangCut(), fang);
                block_end = null;
            } else if (started[side] and placed.x >= 2) try surface.text(.{ .x = placed.x - 2, .y = y, .width = 1, .height = 1 }, "│", rule);
            started[side] = true;
            const region: term.Region = .{ .x = placed.x, .y = y, .width = self.cols -| placed.x, .height = 1 };
            if (std.mem.eql(u8, placed.id, "venomx.session")) {
                try surface.text(region, placed.text, self.chrome.sessionBlock());
                block_end = placed.x +| cellsU16(placed.text);
            } else if (std.mem.eql(u8, placed.id, "venomx.mode") or std.mem.eql(u8, placed.id, "venomx.nested")) {
                try surface.text(region, placed.text, self.modeLabel());
            } else if (std.mem.eql(u8, placed.id, "venomx.windows")) {
                try self.drawWindows(surface, region, placed.text);
            } else if (std.mem.eql(u8, placed.id, "venomx.panes")) {
                try self.drawPanes(surface, placed.x, y, placed.text);
            } else try surface.text(region, placed.text, self.barStyle(placed.style));
        }
        // The cut follows the block even when nothing else is placed.
        if (block_end) |end| if (end < self.cols) try surface.text(.{ .x = end, .y = y, .width = 1, .height = 1 }, self.support.fangCut(), fang);
    }
    /// The window list `1 ▸2:name 3`: the active window (marked `▸`) in
    /// `bone` and bold, the others in `muted`.
    fn drawWindows(self: *const App, surface: *Surface, region: term.Region, text: []const u8) !void {
        const bar = self.chrome.statusBar();
        var active = self.chrome.text(self.chrome.theme.bone);
        active.bold = true;
        active.bg = bar.bg;
        var inactive = self.chrome.mutedText();
        inactive.bg = bar.bg;
        var mark = self.chrome.text(self.chrome.edition.signal(self.chrome.theme));
        mark.bg = bar.bg;
        var x = region.x;
        const right = region.x +| region.width;
        var words = std.mem.splitScalar(u8, text, ' ');
        while (words.next()) |word| {
            if (x >= right) break;
            const is_active = std.mem.startsWith(u8, word, active_mark);
            const id = if (is_active) word[active_mark.len..] else word;
            if (is_active) {
                try surface.text(.{ .x = x, .y = region.y, .width = right - x, .height = 1 }, active_mark, mark);
                x +|= 1;
            }
            if (x < right) try surface.text(.{ .x = x, .y = region.y, .width = right - x, .height = 1 }, id, if (is_active) active else inactive);
            x +|= cellsU16(id) +| 1;
        }
    }
    /// The pane blocks: each pane a filled block `cwd › process`,
    /// the focused one in the signal with its process bold,
    /// the others `bone_dim` on `ash`; a lone pane's mark, when not idle,
    /// ends its block. Drawn from `pane_blocks`, cut where the layout cut
    /// `text` (its `…` stays).
    fn drawPanes(self: *const App, surface: *Surface, at: u16, y: u16, text: []const u8) !void {
        const c = self.chrome;
        const bar = c.statusBar();
        const full = blocksWidth(self.pane_blocks);
        const shown = edges.cells(text);
        const cut = shown < full;
        const right: u16 = at +| @as(u16, @intCast(if (cut) shown -| 1 else shown));
        var x = at;
        for (self.pane_blocks, 0..) |blk, i| {
            if (i > 0) x +|= 1;
            // A hidden float is unfilled, dim text on the bar.
            const st = if (blk.hidden) blk: {
                var dim = c.text(c.theme.bone_dim);
                dim.bg = bar.bg;
                break :blk dim;
            } else if (blk.focus) c.fill(c.edition.signal(c.theme), c.edition.onSignal(c.theme)) else c.fill(c.theme.ash, c.theme.bone_dim);
            var bold = st;
            bold.bold = blk.focus;
            const sep = if (blk.cwd.len > 0 and blk.process.len > 0) block_sep else "";
            const mark: []const u8 = if (blk.mark) |m| m.glyph else "";
            const parts = [_]struct { []const u8, Style }{ .{ " ", st }, .{ if (blk.hidden) hidden_glyph ++ " " else "", st }, .{ blk.cwd, st }, .{ sep, st }, .{ blk.process, bold }, .{ if (mark.len > 0) " " else "", st }, .{ mark, st }, .{ " ", st } };
            for (parts) |part| if (part[0].len > 0) {
                if (x >= right) break;
                const w = cellsU16(part[0]);
                try surface.text(.{ .x = x, .y = y, .width = right - x, .height = 1 }, part[0], part[1]);
                x +|= w;
            };
        }
        if (cut and right < self.cols) {
            try surface.text(.{ .x = right, .y = y, .width = 1, .height = 1 }, "…", bar);
        }
    }
    /// What the pane blocks are drawn from, so a change redraws them:
    /// damage-only renders patch pane cells, not the bar.
    fn statusKey(self: *const App) u64 {
        var h = std.hash.Wyhash.init(0);
        var buf: [max_listed]*PaneView = undefined;
        for (self.listedPanes(&buf)) |p| {
            h.update(self.processOf(p));
            h.update("\x00");
            h.update(pwdOf(p) orelse "");
            h.update("\x01");
        }
        var obuf: [max_listed]*Overlay = undefined;
        for (self.windowFloats(&obuf, true)) |o| {
            h.update(o.pane);
            h.update("\x02");
            if (self.shared.pane(o.pane)) |info| h.update(info.cmdline orelse info.process orelse info.argv0 orelse "");
            h.update("\x03");
        }
        return h.final();
    }
    /// A mode label: `bone` bold on `ash`, never the signal.
    fn modeLabel(self: *const App) Style {
        const c = self.chrome;
        var st = c.text(c.theme.bone);
        st.bg = c.color(c.theme.ash);
        st.bold = true;
        return st;
    }
    /// A status item's role as text on the bar's ground (`grave`).
    fn barStyle(self: *const App, role: ac.Style) Style {
        const bar = self.chrome.statusBar();
        if (role == .normal) return bar;
        var st = self.roleStyle(role);
        st.bg = bar.bg;
        return st;
    }
    /// Theme roles as text styles.
    pub fn roleStyle(self: *const App, role: ac.Style) Style {
        const c = self.chrome;
        return switch (role) {
            .normal => c.text(c.theme.bone),
            .muted => c.mutedText(),
            // Info (◆) is `info`, frost; the edition signal is for focus only.
            .accent => c.statusMark(.info).style,
            .ok => c.statusMark(.ok).style,
            .warn => c.statusMark(.warn).style,
            .@"error" => err: {
                var st = c.statusMark(.danger).style;
                st.bold = true;
                break :err st;
            },
        };
    }
    /// A role as a filled label: the role's colour as the ground, with its
    /// `on-` text (`void` where the theme defines no `on-` token).
    fn roleFill(self: *const App, role: ac.Style) Style {
        const c = self.chrome;
        const t = c.theme;
        return switch (role) {
            .normal => c.fill(t.bone, t.void),
            .muted => c.fill(t.muted, t.void),
            .accent => c.fill(t.info, t.void),
            .ok => c.fill(t.ok, t.on_lichen),
            .warn => c.fill(t.warn, t.void),
            .@"error" => c.fill(t.danger, t.on_blood),
        };
    }
    /// A selected row: `bone` on `grave`; its first cell is
    /// `▌` in the signal.
    fn selectedRow(self: *const App) Style {
        const c = self.chrome;
        var st = c.text(c.theme.bone);
        st.bg = c.color(c.theme.grave);
        return st;
    }
    fn selectedMark(self: *const App) Style {
        var st = self.chrome.text(self.chrome.edition.signal(self.chrome.theme));
        st.bg = self.chrome.color(self.chrome.theme.grave);
        return st;
    }
    /// Floating surfaces are drawn on `crypt`.
    fn floatGround(self: *const App) Style {
        return .{ .bg = self.chrome.color(self.chrome.theme.crypt) };
    }
    fn floatEdge(self: *const App) Style {
        var st = self.chrome.text(self.chrome.theme.rule_strong);
        st.bg = self.floatGround().bg;
        return st;
    }
    fn floatTitle(self: *const App) Style {
        var st = self.chrome.text(self.chrome.theme.bone);
        st.bold = true;
        st.bg = self.floatGround().bg;
        return st;
    }
    /// The widgets' roles on `crypt`, border `rule_strong`, title `bone` bold.
    fn floatTheme(self: *const App) term.widgets.Theme {
        var t = self.chrome.widgets();
        const ground = self.floatGround().bg;
        inline for (.{ "normal", "secondary", "muted", "faint", "accent", "ok", "warn", "err", "info" }) |f| @field(t, f).bg = ground;
        t.border = self.floatEdge();
        t.border_focus = self.floatEdge();
        t.title = self.floatTitle();
        t.title_focus = self.floatTitle();
        return t;
    }
    /// The window list text: `index` or `index:name` per window, the index
    /// being the window's 1-based place in ID order (leader N selects the
    /// window drawn with N), the active one prefixed `▸`.
    /// `a` must be an arena: the result and the builder's growth are never
    /// freed one by one, and an error part-way leaves them to the arena.
    fn windowsText(self: *const App, a: std.mem.Allocator) ![]const u8 {
        var ws: std.ArrayList(u8) = .empty;
        // A `venomx.windows` template renders each window.
        if (self.shared.status.format("venomx.windows")) |f| {
            for (self.windows.items) |*w| {
                const vars: Vars = .{ .app = self, .a = a, .window = w, .clock = self.clockNow() };
                const text = (try ac.template.renderSource(a, f, .segment, vars.lookup())) orelse break;
                if (text.len == 0) continue;
                const is_active = self.active != null and std.mem.eql(u8, self.active.?, w.id);
                try ws.print(a, "{s}{s}", .{ if (ws.items.len > 0) " " else "", if (is_active) active_mark else "" });
                for (text) |ch| if (ch == ' ') try ws.appendSlice(a, nbsp) else try ws.append(a, ch);
            } else return ws.items;
            ws.clearRetainingCapacity();
        }
        for (self.windows.items) |w| {
            var rank: usize = 0;
            for (self.windows.items) |o| {
                if (idLess(o.id, w.id)) rank += 1;
            }
            const is_active = self.active != null and std.mem.eql(u8, self.active.?, w.id);
            try ws.print(a, "{s}{s}{d}", .{ if (ws.items.len > 0) " " else "", if (is_active) active_mark else "", rank + 1 });
            var nbuf: [128]u8 = undefined;
            const name = windowLabel(&nbuf, w.name);
            if (name.len > 0) {
                try ws.append(a, ':');
                // A name may hold spaces; U+00A0 keeps it one word for drawWindows.
                for (name) |ch| if (ch == ' ') try ws.appendSlice(a, nbsp) else try ws.append(a, ch);
            }
        }
        return ws.items;
    }
    /// The panes the status line lists: the active window's tiled panes in
    /// layout order, its shown floats bottom to top, then a focused
    /// popup (or the one pane of a pane-target client). At most `max_listed`.
    fn listedPanes(self: *const App, buf: *[max_listed]*PaneView) []*PaneView {
        var n: usize = 0;
        var listed_focus = false;
        switch (self.target) {
            .session => if (self.activeWindow()) |w| {
                for (w.nodes) |node| if (node.kind == .pane) if (self.pane(node.pane.?)) |p| {
                    if (n == buf.len) break;
                    buf[n] = p;
                    n += 1;
                    if (self.focus) |f| listed_focus = listed_focus or std.mem.eql(u8, f, p.stream.pane);
                };
                var obuf: [max_listed]*Overlay = undefined;
                for (self.windowFloats(&obuf, false)) |o| if (self.pane(o.pane)) |p| {
                    if (n == buf.len) break;
                    buf[n] = p;
                    n += 1;
                    if (self.focus) |f| listed_focus = listed_focus or std.mem.eql(u8, f, p.stream.pane);
                };
            },
            .pane => {},
        }
        if (!listed_focus and n < buf.len) if (self.focused()) |p| {
            buf[n] = p;
            n += 1;
        };
        return buf[0..n];
    }
    /// The active window's floats this client shows (`hidden` false) or
    /// hides with `leader f` (true), by z from the bottom. At most `max_listed`.
    fn windowFloats(self: *const App, buf: *[max_listed]*Overlay, hidden: bool) []*Overlay {
        if (self.target != .session or self.floats_hidden != hidden) return buf[0..0];
        const active = self.active orelse return buf[0..0];
        var n: usize = 0;
        for (self.overlays.items) |*o| {
            if (o.layer != .float or !std.mem.eql(u8, o.window, active)) continue;
            if (n == buf.len) break;
            // Insertion by z keeps the order the floats are drawn in.
            var i = n;
            while (i > 0 and buf[i - 1].z > o.z) : (i -= 1) buf[i] = buf[i - 1];
            buf[i] = o;
            n += 1;
        }
        return buf[0..n];
    }
    /// A hidden float's block: it has no stream here, so no cwd or
    /// OSC 2 title; its process is what the daemon reports runs in it, else its float title, else its pane ID.
    fn hiddenBlock(self: *const App, a: std.mem.Allocator, o: *const Overlay) !PaneBlock {
        const reported: ?[]const u8 = if (self.shared.pane(o.pane)) |x| x.cmdline orelse x.process orelse x.argv0 else null;
        const name: []const u8 = reported orelse o.geometry.title;
        var proc = trimBlank(edges.clean(try a.alloc(u8, name.len), name));
        if (proc.len > 1 and proc[0] == '-') proc = proc[1..];
        proc = trimBlank(edges.cutCells(proc, process_cells));
        if (proc.len == 0) proc = o.pane;
        return .{ .cwd = "", .process = proc, .focus = false, .hidden = true };
    }
    /// One pane's block: its cwd (OSC 7, `~`-shortened) and
    /// process (`processOf`, without a login shell's leading `-`), both
    /// cleaned like a title line; the pane ID when it has neither.
    fn paneBlock(self: *const App, a: std.mem.Allocator, p: *const PaneView) !PaneBlock {
        const raw_cwd = try pane_text.rightPart(a, pwdOf(p), self.home, self.local_host);
        var cwd = trimBlank(edges.clean(try a.alloc(u8, raw_cwd.len), raw_cwd));
        cwd = try tailCells(a, cwd, cwd_cells);
        const title = self.processOf(p);
        var proc = trimBlank(edges.clean(try a.alloc(u8, title.len), title));
        if (proc.len > 1 and proc[0] == '-') proc = proc[1..];
        proc = trimBlank(edges.cutCells(proc, process_cells));
        if (cwd.len == 0 and proc.len == 0) proc = p.stream.pane;
        const is_focus = if (self.focus) |f| std.mem.eql(u8, f, p.stream.pane) else false;
        return .{ .cwd = cwd, .process = proc, .focus = is_focus };
    }
    /// The pane blocks' text, as wide as `drawPanes` draws them, and
    /// `pane_blocks` for it. A lone pane has no title line, so
    /// its mark is in its block, unless it is idle.
    /// `a` must be an arena (see `windowsText`).
    fn panesText(self: *App, a: std.mem.Allocator) ![]const u8 {
        var buf: [max_listed]*PaneView = undefined;
        var listed = self.listedPanes(&buf);
        // `.panes = .focused` lists the focused pane alone.
        const entry = self.shared.status.segment("venomx.panes");
        if (entry != null and entry.?.panes == .focused) {
            if (self.focused()) |p| {
                buf[0] = p;
                listed = buf[0..1];
            } else listed = buf[0..0];
        }
        // Floats this client hides keep a dimmed block at the end.
        var obuf: [max_listed]*Overlay = undefined;
        const hidden = if (entry != null and entry.?.panes == .focused) obuf[0..0] else self.windowFloats(&obuf, true);
        const all = try a.alloc(PaneBlock, @min(listed.len + hidden.len, max_listed));
        const blocks = all[0..listed.len];
        for (all[listed.len..], hidden[0 .. all.len - listed.len]) |*blk, o| blk.* = try self.hiddenBlock(a, o);
        const format = if (entry) |e| e.format else null;
        for (listed, blocks) |p, *blk| blk.* = if (format) |f| .{
            // A custom item template is one part, cut from its end.
            .cwd = "",
            .process = blk: {
                const vars: Vars = .{ .app = self, .a = a, .pane = p, .clock = self.clockNow() };
                break :blk (try ac.template.renderSource(a, f, .segment, vars.lookup())) orelse p.stream.pane;
            },
            .focus = if (self.focus) |id| std.mem.eql(u8, id, p.stream.pane) else false,
        } else try self.paneBlock(a, p);
        if (self.target == .session and !self.hasTitleRow()) if (self.activeWindow()) |w| if (self.lonePane(w)) |p| {
            const status = self.paneStatus(p);
            if (status != .idle) for (listed, blocks) |q, *blk| if (q == p) {
                const m = self.chrome.statusMark(status);
                blk.mark = .{ .glyph = m.glyph, .style = m.style };
            };
        };
        self.pane_blocks = all;
        return blocksText(a, all);
    }
    /// The blocks give way to the other items, as the middle did: with less room than they need, the cwds go first, then the
    /// blocks are cut with `…`. They keep `blocks_min` cells at least.
    fn fitPanes(self: *App, a: std.mem.Allocator, items: []ac.Item) !void {
        const at = for (items, 0..) |it, i| {
            if (std.mem.eql(u8, it.id, "venomx.panes")) break i;
        } else return;
        var others: std.ArrayList(ac.Item) = .empty;
        for (items, 0..) |it, i| if (i != at) try others.append(a, it);
        var used = [3]usize{ 0, 0, 0 };
        var count = [3]usize{ 0, 0, 0 };
        for (try ac.layout(a, others.items, self.cols)) |placed| {
            const side = @backingInt(placed.side);
            used[side] += edges.cells(placed.text) + (if (count[side] > 0) @as(usize, ac.separator_width) else 0);
            count[side] += 1;
        }
        // One blank column between non-empty sides, a separator before the
        // blocks when their side has other items.
        const own = @backingInt(items[at].side);
        var sides: usize = 1;
        for (count, 0..) |n, i| if (i != own and n > 0) {
            sides += 1;
        };
        const lead: usize = if (count[own] > 0) @as(usize, ac.separator_width) else 0;
        const room = @max(@as(usize, self.cols) -| (used[0] + used[1] + used[2] + lead + sides - 1), blocks_min);
        if (edges.cells(items[at].text) <= room) return;
        const blocks = try a.dupe(PaneBlock, self.pane_blocks);
        for (blocks) |*blk| if (blk.process.len > 0) {
            blk.cwd = "";
        };
        self.pane_blocks = blocks;
        const text = try blocksText(a, blocks);
        items[at].text = if (edges.cells(text) <= room) text else try std.fmt.allocPrint(a, "{s}…", .{edges.cutCells(text, room - 1)});
    }
    /// The focused pane's notes (`[Z]`, `[float]`, its archive state,
    /// `(watching)`, `loading`, the attention reason), space-separated; empty
    /// when it has none. `a` must be an arena (see `windowsText`).
    fn paneNotes(self: *const App, a: std.mem.Allocator) ![]const u8 {
        const p = self.focused() orelse return "";
        var line: std.ArrayList(u8) = .empty;
        if (self.zoomed() == p) try line.appendSlice(a, " [Z]");
        if (self.overlay(p.stream.pane)) |o| try line.print(a, " [{s}]", .{@tagName(o.layer)});
        if (self.archive(p.stream.pane)) |x| {
            try line.print(a, " archive: {s}, text {s}", .{ @tagName(x.process_state), @tagName(x.text_state) });
            if (x.cut_rows > 0) try line.print(a, " ({d} cut rows)", .{x.cut_rows});
        }
        if (!p.stream.writer and p.stream.phase == .live) try line.appendSlice(a, " (watching)");
        if (p.stream.backfill == .pending) try line.appendSlice(a, " loading");
        if (self.shared.pane(p.stream.pane)) |info| if (info.level != .none and info.reason.len > 0) try line.print(a, " {s}", .{info.reason});
        return if (line.items.len > 0) line.items[1..] else "";
    }
    /// Template variables as this client sees them: its
    /// session, the shown window (or `window`, inside `venomx.windows`) and
    /// the focused pane (or `pane`, inside `venomx.panes`). Values live in `a`.
    const Vars = struct {
        app: *const App,
        a: std.mem.Allocator,
        window: ?*const Window = null,
        pane: ?*const PaneView = null,
        clock: ?ac.template.Clock = null,
        fn lookup(self: *const Vars) ac.template.Lookup {
            return .{ .ctx = self, .get = get, .clock_now = self.clock };
        }
        fn get(ctx: ?*const anyopaque, name: []const u8) ?[]const u8 {
            const self: *const Vars = @ptrCast(@alignCast(ctx.?));
            return self.app.variable(self.a, name, self.window, self.pane) catch null;
        }
    };
    fn sessionId(self: *const App) []const u8 {
        return switch (self.target) {
            .session => |s| s,
            .pane => |p| if (self.shared.pane(p)) |info| info.session else "",
        };
    }
    fn attentionCount(self: *const App) usize {
        var count: usize = 0;
        for (self.shared.panes.items) |info| if (info.level != .none and self.shows(info.id)) {
            count += 1;
        };
        return count;
    }
    /// One template variable, or null when it is empty or unknown.
    fn variable(self: *const App, a: std.mem.Allocator, name: []const u8, win: ?*const Window, pane_view: ?*const PaneView) !?[]const u8 {
        const eqs = std.mem.eql;
        if (eqs(u8, name, "session.id")) return self.sessionId();
        if (eqs(u8, name, "session.name")) {
            const id = self.sessionId();
            const n = self.session_name orelse return id;
            return if (n.len > 0) try a.dupe(u8, n) else id;
        }
        if (std.mem.startsWith(u8, name, "window.")) {
            const w: *const Window = win orelse self.activeWindow() orelse return null;
            var rank: usize = 0;
            for (self.windows.items) |o| {
                if (idLess(o.id, w.id)) rank += 1;
            }
            var nbuf: [128]u8 = undefined;
            const label = windowLabel(&nbuf, w.name);
            const part = name["window.".len..];
            if (eqs(u8, part, "index")) return try std.fmt.allocPrint(a, "{d}", .{rank + 1});
            if (eqs(u8, part, "name")) return try a.dupe(u8, label);
            if (eqs(u8, part, "id")) return w.id;
            if (eqs(u8, part, "label")) return if (label.len > 0) try std.fmt.allocPrint(a, "{d}:{s}", .{ rank + 1, label }) else try std.fmt.allocPrint(a, "{d}", .{rank + 1});
            return null;
        }
        if (std.mem.startsWith(u8, name, "pane.")) {
            const p: *const PaneView = pane_view orelse self.focused() orelse return null;
            const part = name["pane.".len..];
            const info = self.shared.pane(p.stream.pane);
            if (eqs(u8, part, "id")) return p.stream.pane;
            if (std.mem.startsWith(u8, part, "tag.")) return if (info) |i| i.tags.get(part["tag.".len..]) else null;
            if (eqs(u8, part, "command")) return if (info) |i| i.cmdline else null;
            if (eqs(u8, part, "title")) return self.titleOf(p);
            if (eqs(u8, part, "program")) return if (info) |i| switch (i.program) {
                .none => null,
                .failed => "error",
                else => @tagName(i.program),
            } else null;
            const blk = try self.paneBlock(a, p);
            if (eqs(u8, part, "cwd")) return blk.cwd;
            if (eqs(u8, part, "process")) {
                // Unlike a block, an empty process is empty (no pane-ID fallback).
                return if (eqs(u8, blk.process, p.stream.pane) and blk.cwd.len == 0) null else blk.process;
            }
            if (eqs(u8, part, "label")) return try blocksText(a, &.{blk});
            return null;
        }
        if (eqs(u8, name, "attention.count")) {
            const n = self.attentionCount();
            return if (n > 0) try std.fmt.allocPrint(a, "{d}", .{n}) else null;
        }
        if (eqs(u8, name, "host")) return if (self.local_host.len > 0) self.local_host else null;
        if (eqs(u8, name, "user")) return if (std.c.getenv("USER")) |u| std.mem.span(u) else null;
        return null;
    }
    fn clockNow(self: *const App) ac.template.Clock {
        const seconds = if (self.fixed_now) |ms| @divFloor(ms, 1000) else wallSeconds();
        return ac.template.Clock.fromEpoch(seconds, utcOffset(seconds));
    }
    /// A configured template for a built-in, rendered; null
    /// without one, or when it does not parse (config check reports it).
    fn builtinFormat(self: *const App, a: std.mem.Allocator, id: []const u8, vars: *const Vars) !?[]const u8 {
        const f = self.shared.status.format(id) orelse return null;
        return ac.template.renderSource(a, f, .segment, vars.lookup());
    }
    /// Built-in `venomx.*` segments, the visible shared ones and the
    /// config's own `user.*` sources, through the client's `status` config. `a` must be an arena (see `windowsText`).
    pub fn statusItems(self: *App, a: std.mem.Allocator) ![]ac.Item {
        var b = self.shared.builder(a, self.toggled.items);
        const focused_info = if (self.focus) |f| self.shared.pane(f) else null;
        // A config `.when` is checked against the focused pane.
        if (focused_info) |info| b.focused_tags = info.tags.slice();
        var vars: Vars = .{ .app = self, .a = a, .clock = self.clockNow() };
        const session_id = self.sessionId();
        const session_text: []const u8 = if (try self.builtinFormat(a, "venomx.session", &vars)) |t| t else switch (self.target) {
            .session => |s| blk: {
                const name = if (self.session_name) |n| (if (n.len > 0) n else s) else s;
                var nbuf: [128]u8 = undefined;
                const shown = trimBlank(edges.cutCells(edges.clean(&nbuf, name), session_name_cells));
                break :blk try a.dupe(u8, if (shown.len > 0) shown else s);
            },
            .pane => |p| p,
        };
        if (session_text.len > 0) try b.add("venomx.session", try std.fmt.allocPrint(a, " {s} ", .{session_text}), .left, 100, .normal);
        if (self.target == .session) try b.add("venomx.windows", try self.windowsText(a), .left, 90, .normal);
        const state = try self.router.modeText(a);
        // Each mode is its own label, drawn on `ash`, never in a role colour.
        if (self.nested) try b.add("venomx.nested", " NESTED ", .left, 96, .normal);
        // Copy mode is a mode of the focused pane, shown while no
        // leader state is.
        const mode = if (state.len == 0 and self.copying()) "COPY" else state;
        if (mode.len > 0) try b.add("venomx.mode", try std.fmt.allocPrint(a, " {s} ", .{mode}), .left, 95, .normal);
        try b.add("venomx.panes", try self.panesText(a), .left, 85, .normal);
        // An empty `venomx.pane` template means the fixed notes.
        const notes = try self.builtinFormat(a, "venomx.pane", &vars);
        try b.add("venomx.pane", if (notes != null and self.shared.status.format("venomx.pane").?.len > 0) notes.? else try self.paneNotes(a), .left, 84, .normal);
        try b.add("venomx.message", self.message.items, .right, 99, .normal);
        if (self.shared.newest(self.now())) |n| try b.add("venomx.notify", n.text, .right, 85, ac.notifyStyle(n.level));
        // The tray draws the `tray` group's members.
        try b.addSegment(.{ .id = "venomx.tray", .side = .right, .priority = 60, .group_of = "tray" });
        const count = self.attentionCount();
        if (count > 0) try b.add("venomx.attention", try std.fmt.allocPrint(a, "{d} attention", .{count}), .right, 80, .warn);
        var clock_buf: [8]u8 = undefined;
        const seconds = wallSeconds();
        self.shown_minute = @divFloor(seconds, 60);
        const clock = if (try self.builtinFormat(a, "venomx.clock", &vars)) |t| t else self.fixed_clock orelse try a.dupe(u8, localClock(&clock_buf, seconds));
        try b.add("venomx.clock", clock, .right, 10, .normal);
        for (self.shared.segments.items) |seg| {
            if (std.mem.startsWith(u8, seg.id, "venomx.")) continue;
            if (!std.mem.eql(u8, seg.scope, "server") and !std.mem.eql(u8, seg.scope, session_id)) continue;
            // A config `.when` replaces the segment's own; the
            // builder checks that one.
            const overridden = if (self.shared.status.segment(seg.id)) |s| s.when.len > 0 else false;
            if (!overridden and seg.when.items.items.len > 0) {
                const info = focused_info orelse continue;
                if (!info.tags.matches(seg.when.items.items)) continue;
            }
            try b.addSegment(.{ .id = seg.id, .text = seg.text, .side = seg.side, .priority = seg.priority, .style = seg.style, .group = seg.group, .icon = seg.icon });
        }
        try b.addConfigured(vars.lookup());
        const items = try b.items();
        try self.fitPanes(a, items);
        return items;
    }
    /// A left click on the status line runs the clicked
    /// segment's (or group member's) target as this client, as a key press
    /// would. A segment without one does nothing; the click never reaches a
    /// pane. A config slot override's `click` wins over the product's.
    fn statusClick(self: *App, m: term.Input.Mouse) !void {
        if (m.action != .press or m.button != .left or m.x < 0) return;
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const x = arena.allocator();
        const items = try self.statusItems(x);
        defer self.pane_blocks = &.{};
        const id = ac.hit(try ac.layout(x, items, self.cols), @intCast(m.x)) orelse return;
        const target: ac.Click = if (self.shared.status.segment(id)) |s| s.click orelse
            (if (self.shared.segment(id)) |seg| seg.click orelse return else return) else if (self.shared.segment(id)) |seg| seg.click orelse return else return;
        switch (try keys.parseBinding(x, .{ .key = "a", .local = target.local, .verb = target.verb, .args = target.args, .exec = target.exec }, "click")) {
            .ok => |binding| try self.runTarget(binding.target),
            .failed => self.say("{s}: invalid click target", .{id}),
        }
    }
    /// `toggle-segment <id>`: hide or show a segment on this
    /// client only, until it detaches.
    pub fn toggleSegment(self: *App, id: []const u8) !void {
        self.dirty = true;
        for (self.toggled.items, 0..) |t, i| if (std.mem.eql(u8, t, id)) {
            self.a.free(self.toggled.orderedRemove(i));
            return;
        };
        try self.toggled.ensureUnusedCapacity(self.a, 1);
        self.toggled.appendAssumeCapacity(try self.a.dupe(u8, id));
    }
    /// Whether this client shows the pane (any window of its session, or
    /// its one pane).
    fn shows(self: *const App, id: []const u8) bool {
        return switch (self.target) {
            .pane => |p| std.mem.eql(u8, p, id),
            .session => for (self.windows.items) |w| {
                if (contains(w.nodes, id)) break true;
            } else self.overlay(id) != null,
        };
    }
};

/// Whether a grapheme draws nothing a reader could see: zero cells wide, or a
/// single Unicode space separator (Zs, other than U+00A0, which `edges.clean`
/// drops). Cell widths come from `term.widgets.text`.
fn isBlank(g: []const u8) bool {
    if (text_width.graphemeWidth(g) == 0) return true;
    const cp = std.unicode.utf8Decode(g) catch return false;
    return cp == ' ' or cp == 0x1680 or (cp >= 0x2000 and cp <= 0x200a) or cp == 0x202f or cp == 0x205f or cp == 0x3000;
}
/// `s` without its blank graphemes at either end.
fn trimBlank(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        const next = text_width.nextGrapheme(s, start);
        if (!isBlank(s[start..next])) break;
        start = next;
    }
    var end = s.len;
    while (end > start) {
        const prev = text_width.prevGrapheme(s, start, end);
        if (!isBlank(s[prev..end])) break;
        end = prev;
    }
    return s[start..end];
}

/// The text of a window's label after its index: control characters and
/// invalid UTF-8 dropped, outer blanks (any Unicode space, not only U+0020)
/// trimmed, at most `window_name_cells`. A name with no visible cell is empty.
pub fn windowLabel(buf: *[128]u8, name: []const u8) []const u8 {
    const cleaned = trimBlank(edges.clean(buf, name));
    return trimBlank(edges.cutCells(cleaned, window_name_cells));
}

/// A label at the top right of a pane, by display width, inside the pane.
pub fn cornerLabel(surface: *Surface, r: Rect, label: []const u8, style: Style) !void {
    const w: u16 = @intCast(@min(ac.width(label), r.width));
    try surface.text(.{ .x = r.x + r.width - w, .y = r.y, .width = w, .height = 1 }, label, style);
}
fn cellsU16(s: []const u8) u16 {
    return @intCast(@min(ac.width(s), std.math.maxInt(u16)));
}
/// The last cells of `s` within `limit`, after a `…` when cut, allocated
/// from `a` when cut (an arena).
fn tailCells(a: std.mem.Allocator, s: []const u8, limit: usize) ![]const u8 {
    if (edges.cells(s) <= limit) return s;
    if (limit == 0) return "";
    var n: usize = 0;
    var start = s.len;
    while (start > 0) {
        const prev = text_width.prevGrapheme(s, 0, start);
        const w = text_width.graphemeWidth(s[prev..start]);
        if (n + w + 1 > limit) break;
        n += w;
        start = prev;
    }
    return std.fmt.allocPrint(a, "…{s}", .{s[start..]});
}
fn centered(surface: *Surface, r: term.Region, text: []const u8, style: Style) !void {
    if (r.width == 0 or r.height == 0) return;
    const len: u16 = @intCast(@min(std.unicode.utf8CountCodepoints(text) catch text.len, r.width));
    try surface.text(.{ .x = r.x + (r.width - len) / 2, .y = r.y + r.height / 2, .width = r.width - (r.width - len) / 2, .height = 1 }, text, style);
}
const Tm = extern struct { sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int, wday: c_int, yday: c_int, isdst: c_int, gmtoff: c_long, zone: ?[*:0]const u8 };
extern "c" fn time(t: ?*c_long) c_long;
extern "c" fn localtime_r(t: *const c_long, out: *Tm) ?*Tm;
fn wallSeconds() i64 {
    return time(null);
}
/// The C library's local UTC offset at `seconds`, for `{clock}` templates.
fn utcOffset(seconds: i64) i32 {
    var t: c_long = @intCast(seconds);
    var tm: Tm = undefined;
    _ = localtime_r(&t, &tm) orelse return 0;
    return @intCast(std.math.clamp(tm.gmtoff, -86400, 86400));
}
/// `HH:MM` in local time, for `venomx.clock`.
fn localClock(buf: []u8, seconds: i64) []const u8 {
    var t: c_long = @intCast(seconds);
    var tm: Tm = undefined;
    _ = localtime_r(&t, &tm) orelse return "";
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ @as(u32, @intCast(tm.hour)), @as(u32, @intCast(tm.min)) }) catch "";
}
fn drawBorder(surface: *Surface, r: Rect, border: floats.Border, style: Style) !void {
    const glyphs: [6][]const u8 = switch (border) {
        .none => return,
        .single => .{ "┌", "┐", "└", "┘", "─", "│" },
        .rounded => .{ "╭", "╮", "╰", "╯", "─", "│" },
        .heavy => .{ "┏", "┓", "┗", "┛", "━", "┃" },
    };
    const right = r.x + r.width - 1;
    const bottom = r.y + r.height - 1;
    for (r.x + 1..right) |x| {
        try surface.put(@intCast(x), r.y, .{ .text = glyphs[4], .style = style });
        try surface.put(@intCast(x), bottom, .{ .text = glyphs[4], .style = style });
    }
    for (r.y + 1..bottom) |y| {
        try surface.put(r.x, @intCast(y), .{ .text = glyphs[5], .style = style });
        try surface.put(right, @intCast(y), .{ .text = glyphs[5], .style = style });
    }
    try surface.put(r.x, r.y, .{ .text = glyphs[0], .style = style });
    try surface.put(right, r.y, .{ .text = glyphs[1], .style = style });
    try surface.put(r.x, bottom, .{ .text = glyphs[2], .style = style });
    try surface.put(right, bottom, .{ .text = glyphs[3], .style = style });
}
fn replaceTicket(a: std.mem.Allocator, v: Value, ticket: []const u8) !Value {
    switch (v) {
        .string => |s| if (std.mem.eql(u8, s, keys.placeholders[3])) return .{ .string = ticket },
        .array => |arr| {
            var out: std.json.Array = .init(a);
            for (arr.items) |x| try out.append(try replaceTicket(a, x, ticket));
            return .{ .array = out };
        },
        .object => |o| {
            var out: std.json.ObjectMap = .empty;
            var it = o.iterator();
            while (it.next()) |e| try out.put(a, e.key_ptr.*, try replaceTicket(a, e.value_ptr.*, ticket));
            return .{ .object = out };
        },
        else => {},
    }
    return v;
}
const WantFocus = struct {
    pane: []u8,
    window: []u8,
    fn deinit(self: WantFocus, a: std.mem.Allocator) void {
        a.free(self.pane);
        a.free(self.window);
    }
};
fn contains(nodes: []const layout.Node, id: []const u8) bool {
    for (nodes) |n| if (n.kind == .pane and std.mem.eql(u8, n.pane.?, id)) return true;
    return false;
}
fn lowest(nodes: []const layout.Node) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (nodes) |n| if (n.kind == .pane and (best == null or idLess(n.pane.?, best.?))) {
        best = n.pane.?;
    };
    return best;
}
/// IDs are ordered by their numeric counters (`p10` after `p9`).
pub fn idLess(x: []const u8, y: []const u8) bool {
    const nx = std.fmt.parseInt(u64, if (x.len > 1) x[1..] else "", 10) catch return std.mem.lessThan(u8, x, y);
    const ny = std.fmt.parseInt(u64, if (y.len > 1) y[1..] else "", 10) catch return std.mem.lessThan(u8, x, y);
    return nx < ny;
}
fn field(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}
fn string(v: Value, key: []const u8) ?[]const u8 {
    const f = field(v, key) orelse return null;
    return if (f == .string) f.string else null;
}
fn index(v: Value) !usize {
    if (v != .integer or v.integer < 0) return error.BadEvent;
    return @intCast(v.integer);
}
fn overlaps(x: Rect, y: Rect) bool {
    return x.width > 0 and x.height > 0 and y.width > 0 and y.height > 0 and
        @as(u32, x.x) < @as(u32, y.x) + y.width and @as(u32, y.x) < @as(u32, x.x) + x.width and
        @as(u32, x.y) < @as(u32, y.y) + y.height and @as(u32, y.y) < @as(u32, x.y) + x.height;
}
fn toRegion(r: Rect) term.Region {
    return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
}
fn hostCell(g: Vt.MouseGeometry) ?Vt.CellSize {
    return .{ .width = g.cell_width orelse return null, .height = g.cell_height orelse return null };
}
