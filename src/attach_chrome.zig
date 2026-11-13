//! The presentation client's copy of the daemon's shared chrome state (segments, pane
//! tags, attention, notifications). The status-line layout is
//! venom-term's `chrome.status`; content is shared, layout and truncation
//! are each client's own.
const std = @import("std");
const chrome = @import("chrome.zig");
const Value = std.json.Value;
const eq = std.mem.eql;
pub const Side = chrome.Side;
pub const Style = chrome.Style;
pub const Level = chrome.Level;

pub const Segment = struct {
    id: []u8,
    text: []u8,
    side: Side,
    priority: u8,
    style: Style,
    when: chrome.Tags,
    scope: []u8,
    /// Drawn inside that group; what a group draws for
    /// it; the binding target a click runs. Owned by `arena`.
    group: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    click: ?Click = null,
    arena: ?*std.heap.ArenaAllocator = null,
    fn deinit(self: *Segment, a: std.mem.Allocator) void {
        a.free(self.id);
        a.free(self.text);
        a.free(self.scope);
        self.when.deinit(a);
        if (self.arena) |x| {
            x.deinit();
            a.destroy(x);
        }
    }
};
pub const Click = @import("term_chrome").status.Click;
pub const Note = struct {
    id: []u8,
    text: []u8,
    level: chrome.NotifyLevel,
    expires: i64,
    fn deinit(self: *Note, a: std.mem.Allocator) void {
        a.free(self.id);
        a.free(self.text);
    }
};
/// Ascending by summary priority, so the highest
/// record wins: blocked > error > done > working > idle.
pub const Program = enum { none, idle, working, done, failed, blocked };
pub const Command = enum { none, ok, failed };
pub const PaneInfo = struct {
    id: []u8,
    session: []u8,
    tags: chrome.Tags = .{},
    level: Level = .none,
    reason: []u8 = &.{},
    /// The pane's OSC 7501 report (`blocked` is waiting,
    /// `working` is busy) and the exit of its last OSC 133 command, both
    /// from daemon events. Observations only; `none` is no report.
    program: Program = .none,
    command: Command = .none,
    /// The basename of the pane's spawn `argv[0]`; null
    /// when the daemon has none (a restored pane). Untrusted display text.
    argv0: ?[]u8 = null,
    /// The daemon-sampled foreground process name, and
    /// whether the OSC 2 title was set since the foreground last changed.
    process: ?[]u8 = null,
    title_current: bool = false,
    /// The active command's shell-reported `cmdline`.
    cmdline: ?[]u8 = null,
    fn deinit(self: *PaneInfo, a: std.mem.Allocator) void {
        a.free(self.id);
        if (self.argv0) |x| a.free(x);
        if (self.process) |x| a.free(x);
        if (self.cmdline) |x| a.free(x);
        a.free(self.session);
        a.free(self.reason);
        self.tags.deinit(a);
    }
};

pub const State = struct {
    a: std.mem.Allocator,
    segments: std.ArrayList(Segment) = .empty,
    notes: std.ArrayList(Note) = .empty,
    panes: std.ArrayList(PaneInfo) = .empty,
    /// `status` and `attention` config, from `config.get`; defaults until then.
    arena: ?std.heap.ArenaAllocator = null,
    status: chrome.StatusConfig = .{},
    attention_arena: ?std.heap.ArenaAllocator = null,
    attention: chrome.AttentionConfig = .{},

    pub fn deinit(self: *State) void {
        self.reset();
        self.segments.deinit(self.a);
        self.notes.deinit(self.a);
        self.panes.deinit(self.a);
        if (self.arena) |*x| x.deinit();
        if (self.attention_arena) |*x| x.deinit();
    }
    /// A new snapshot replaces all shared content.
    pub fn reset(self: *State) void {
        for (self.segments.items) |*s| s.deinit(self.a);
        self.segments.clearRetainingCapacity();
        for (self.notes.items) |*n| n.deinit(self.a);
        self.notes.clearRetainingCapacity();
        for (self.panes.items) |*p| p.deinit(self.a);
        self.panes.clearRetainingCapacity();
    }
    pub fn pane(self: *const State, id: []const u8) ?*PaneInfo {
        for (self.panes.items) |*p| if (eq(u8, p.id, id)) return p;
        return null;
    }
    fn paneOrNew(self: *State, id: []const u8, session: ?[]const u8) !*PaneInfo {
        if (self.pane(id)) |p| {
            if (session) |s| if (!eq(u8, p.session, s)) {
                const owned = try self.a.dupe(u8, s);
                self.a.free(p.session);
                p.session = owned;
            };
            return p;
        }
        try self.panes.ensureUnusedCapacity(self.a, 1);
        const owned_id = try self.a.dupe(u8, id);
        errdefer self.a.free(owned_id);
        self.panes.appendAssumeCapacity(.{ .id = owned_id, .session = try self.a.dupe(u8, session orelse "") });
        return &self.panes.items[self.panes.items.len - 1];
    }
    pub fn removePane(self: *State, id: []const u8) void {
        for (self.panes.items, 0..) |*p, i| if (eq(u8, p.id, id)) {
            p.deinit(self.a);
            _ = self.panes.orderedRemove(i);
            return;
        };
    }
    fn readTags(self: *State, v: Value) !chrome.Tags {
        var tags: chrome.Tags = .{};
        errdefer tags.deinit(self.a);
        if (v != .array) return error.BadEvent;
        for (v.array.items) |item| {
            const k = str(item, "key") orelse return error.BadEvent;
            const val = str(item, "value") orelse return error.BadEvent;
            try tags.put(self.a, k, val);
        }
        return tags;
    }
    fn setTags(self: *State, p: *PaneInfo, v: Value) !void {
        var tags = try self.readTags(v);
        std.mem.swap(chrome.Tags, &p.tags, &tags);
        tags.deinit(self.a);
    }
    fn setArgv0(self: *State, p: *PaneInfo, v: Value) !void {
        const name = str(v, "argv0") orelse return;
        const owned = try self.a.dupe(u8, name);
        if (p.argv0) |old| self.a.free(old);
        p.argv0 = owned;
    }
    /// Replace `slot` with a copy of `v`'s string `key`, or null when absent.
    fn setOptional(self: *State, slot: *?[]u8, v: Value, key: []const u8) !void {
        const next: ?[]u8 = if (str(v, key)) |x| try self.a.dupe(u8, x) else null;
        if (slot.*) |old| self.a.free(old);
        slot.* = next;
    }
    fn setAttention(self: *State, p: *PaneInfo, level: []const u8, reason: []const u8) !void {
        const l = std.meta.stringToEnum(Level, level) orelse return error.BadEvent;
        const owned = try self.a.dupe(u8, reason);
        self.a.free(p.reason);
        p.reason = owned;
        p.level = l;
    }
    /// A `pane` snapshot entity's content.
    pub fn paneEntity(self: *State, v: Value) !void {
        const id = str(v, "pane") orelse return error.BadEvent;
        var tags: ?chrome.Tags = if (get(v, "tags")) |t| try self.readTags(t) else null;
        defer if (tags) |*t| t.deinit(self.a);
        const level: []const u8 = if (get(v, "attention")) |at| str(at, "level") orelse return error.BadEvent else "none";
        if (std.meta.stringToEnum(Level, level) == null) return error.BadEvent;
        const reason: []const u8 = if (get(v, "attention")) |at| str(at, "reason") orelse "" else "";
        const current = if (get(v, "title_current")) |b| (if (b == .bool) b.bool else return error.BadEvent) else false;
        const p = try self.paneOrNew(id, str(v, "session"));
        try self.setArgv0(p, v);
        try self.setOptional(&p.process, v, "process");
        p.title_current = current;
        if (tags) |*t| std.mem.swap(chrome.Tags, &p.tags, t);
        try self.setAttention(p, level, reason);
    }
    /// `program.status_changed`'s `records`, or a `program_status` snapshot
    /// entity: the pane's summary is its highest-priority record state. A
    /// malformed report changes nothing, and a report for an unknown pane
    /// (a late event for a closed one) is ignored: it creates no pane.
    pub fn programChanged(self: *State, data: Value) !void {
        const id = str(data, "pane") orelse return error.BadEvent;
        const records = get(data, "records") orelse return error.BadEvent;
        if (records != .array) return error.BadEvent;
        var next: Program = .none;
        for (records.array.items) |r| {
            const state = str(r, "state") orelse return error.BadEvent;
            const one: Program = if (eq(u8, state, "blocked")) .blocked else if (eq(u8, state, "error")) .failed else if (eq(u8, state, "done")) .done else if (eq(u8, state, "working")) .working else if (eq(u8, state, "idle")) .idle else return error.BadEvent;
            if (@backingInt(one) > @backingInt(next)) next = one;
        }
        (self.pane(id) orelse return).program = next;
    }
    /// `command.started` clears the last exit and makes the title stale; its
    /// `cmdline` is the active command's. Unknown panes are ignored.
    pub fn commandStarted(self: *State, data: Value) !void {
        const id = str(data, "pane") orelse return error.BadEvent;
        const p = self.pane(id) orelse return;
        try self.setOptional(&p.cmdline, data, "cmdline");
        p.command = .none;
        p.title_current = false;
    }
    /// A `command` snapshot entity: the active command's `cmdline`.
    pub fn commandEntity(self: *State, v: Value) !void {
        const id = str(v, "pane") orelse return error.BadEvent;
        try self.setOptional(&(self.pane(id) orelse return).cmdline, v, "cmdline");
    }
    /// `pane.process_changed`: the new name, absent when
    /// unknown; the title is stale. Unknown panes are ignored.
    pub fn processChanged(self: *State, data: Value) !void {
        const id = str(data, "pane") orelse return error.BadEvent;
        const p = self.pane(id) orelse return;
        try self.setOptional(&p.process, data, "process");
        p.title_current = false;
    }
    /// `pane.title_changed`: a nonempty title is current. Unknown panes are ignored.
    pub fn titleChanged(self: *State, data: Value) !void {
        const id = str(data, "pane") orelse return error.BadEvent;
        const title = str(data, "title") orelse return error.BadEvent;
        (self.pane(id) orelse return).title_current = title.len > 0;
    }
    /// `command.finished` sets it from `exit_code`; absent means unknown, and
    /// a present value must be an integer in 0..255. Unknown panes are ignored.
    pub fn commandFinished(self: *State, data: Value) !void {
        const id = str(data, "pane") orelse return error.BadEvent;
        const next: Command = if (get(data, "exit_code")) |v| blk: {
            if (v != .integer or v.integer < 0 or v.integer > 255) return error.BadEvent;
            break :blk if (v.integer == 0) .ok else .failed;
        } else .none;
        const p = self.pane(id) orelse return;
        p.command = next;
        if (p.cmdline) |x| self.a.free(x);
        p.cmdline = null;
        p.title_current = false;
    }
    /// A rejected event creates no pane: each handler below validates its
    /// whole payload before `paneOrNew`.
    pub fn tagsChanged(self: *State, data: Value) !void {
        const id = str(data, "pane") orelse return error.BadEvent;
        var tags = try self.readTags(get(data, "tags") orelse return error.BadEvent);
        defer tags.deinit(self.a);
        const p = try self.paneOrNew(id, null);
        std.mem.swap(chrome.Tags, &p.tags, &tags);
    }
    pub fn attentionChanged(self: *State, data: Value) !void {
        const id = str(data, "pane") orelse return error.BadEvent;
        const level = str(data, "level") orelse return error.BadEvent;
        if (std.meta.stringToEnum(Level, level) == null) return error.BadEvent;
        try self.setAttention(try self.paneOrNew(id, null), level, str(data, "reason") orelse "");
    }
    pub fn paneCreated(self: *State, data: Value) !void {
        const id = str(data, "pane") orelse return error.BadEvent;
        var tags: ?chrome.Tags = if (get(data, "tags")) |t| try self.readTags(t) else null;
        defer if (tags) |*t| t.deinit(self.a);
        const p = try self.paneOrNew(id, str(data, "session"));
        try self.setArgv0(p, data);
        if (tags) |*t| std.mem.swap(chrome.Tags, &p.tags, t);
    }
    /// `status.changed`'s `segment`, or a `status` snapshot entity.
    pub fn upsertSegment(self: *State, v: Value) !void {
        const id = str(v, "id") orelse return error.BadEvent;
        var s: Segment = .{
            .id = try self.a.dupe(u8, id),
            .text = &.{},
            .side = std.meta.stringToEnum(Side, str(v, "side") orelse "right") orelse return error.BadEvent,
            .priority = @intCast(std.math.clamp(int(v, "priority") orelse 50, 0, 100)),
            .style = std.meta.stringToEnum(Style, str(v, "style") orelse "normal") orelse return error.BadEvent,
            .when = .{},
            .scope = &.{},
        };
        errdefer s.deinit(self.a);
        s.text = try self.a.dupe(u8, str(v, "text") orelse return error.BadEvent);
        s.scope = try self.a.dupe(u8, str(v, "scope") orelse "server");
        if (get(v, "when")) |w| s.when = try self.readTags(w);
        if (str(v, "group") != null or str(v, "icon") != null or get(v, "click") != null) {
            const arena = try self.a.create(std.heap.ArenaAllocator);
            arena.* = .init(self.a);
            s.arena = arena;
            const x = arena.allocator();
            if (str(v, "group")) |g| s.group = try x.dupe(u8, g);
            if (str(v, "icon")) |i| s.icon = try x.dupe(u8, i);
            if (get(v, "click")) |c| if (c == .object) {
                var click: Click = .{};
                if (str(c, "local")) |l| click.local = try x.dupe(u8, l);
                if (str(c, "verb")) |l| click.verb = try x.dupe(u8, l);
                if (str(c, "args")) |l| click.args = try x.dupe(u8, l);
                if (get(c, "exec")) |e| if (e == .array) {
                    const argv = try x.alloc([]const u8, e.array.items.len);
                    for (e.array.items, argv) |item, *dst| dst.* = try x.dupe(u8, if (item == .string) item.string else "");
                    click.exec = argv;
                };
                s.click = click;
            };
        }
        for (self.segments.items) |*old| if (eq(u8, old.id, id)) {
            old.deinit(self.a);
            old.* = s;
            return;
        };
        try self.segments.append(self.a, s);
    }
    pub fn dropSegment(self: *State, id: []const u8) void {
        for (self.segments.items, 0..) |*s, i| if (eq(u8, s.id, id)) {
            s.deinit(self.a);
            _ = self.segments.orderedRemove(i);
            return;
        };
    }
    pub fn posted(self: *State, v: Value, now: i64) !void {
        const id = str(v, "id") orelse return error.BadEvent;
        self.dismiss(id);
        const owned_id = try self.a.dupe(u8, id);
        errdefer self.a.free(owned_id);
        const owned_text = try self.a.dupe(u8, str(v, "text") orelse return error.BadEvent);
        errdefer self.a.free(owned_text);
        const level = std.meta.stringToEnum(chrome.NotifyLevel, str(v, "level") orelse "info") orelse .info;
        try self.notes.append(self.a, .{ .id = owned_id, .text = owned_text, .level = level, .expires = now + (int(v, "ttl_ms") orelse 8000) });
        // Mirror the daemon's bound.
        if (self.notes.items.len > chrome.max_notifications) {
            var old = self.notes.orderedRemove(0);
            old.deinit(self.a);
        }
    }
    /// A notification of this client's own, not the daemon's (it is never
    /// sent anywhere). Replaces one with the same `id`.
    pub fn postLocal(self: *State, id: []const u8, text: []const u8, level: chrome.NotifyLevel, ttl_ms: i64, now: i64) !void {
        self.dismiss(id);
        const owned_id = try self.a.dupe(u8, id);
        errdefer self.a.free(owned_id);
        const owned_text = try self.a.dupe(u8, text);
        errdefer self.a.free(owned_text);
        try self.notes.append(self.a, .{ .id = owned_id, .text = owned_text, .level = level, .expires = now + ttl_ms });
        if (self.notes.items.len > chrome.max_notifications) {
            var old = self.notes.orderedRemove(0);
            old.deinit(self.a);
        }
    }
    pub fn dismiss(self: *State, id: []const u8) void {
        for (self.notes.items, 0..) |*n, i| if (eq(u8, n.id, id)) {
            n.deinit(self.a);
            _ = self.notes.orderedRemove(i);
            return;
        };
    }
    /// The newest unexpired notification.
    pub fn newest(self: *State, now: i64) ?*const Note {
        var i: usize = 0;
        while (i < self.notes.items.len) {
            if (self.notes.items[i].expires <= now) {
                var n = self.notes.orderedRemove(i);
                n.deinit(self.a);
            } else i += 1;
        }
        return if (self.notes.items.len > 0) &self.notes.items[self.notes.items.len - 1] else null;
    }
    /// The result content of `config.get` for `status` or `attention`.
    pub fn applyConfig(self: *State, key: []const u8, content: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.a);
        errdefer arena.deinit();
        const source = try arena.allocator().dupeSentinel(u8, content, 0);
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        const options: std.zon.parse.Options = .{ .gpa = arena.allocator(), .arena = arena.allocator(), .source = source, .diagnostics = &diagnostics, .ignore_unknown_fields = true };
        if (eq(u8, key, "status")) {
            const parsed = std.zon.parse.fromSlice(chrome.StatusConfig, options) catch |err| return if (err == error.OutOfMemory) err else error.BadConfig;
            if (self.arena) |*old| old.deinit();
            self.arena = arena;
            self.status = parsed;
        } else {
            const parsed = std.zon.parse.fromSlice(chrome.AttentionConfig, options) catch |err| return if (err == error.OutOfMemory) err else error.BadConfig;
            if (self.attention_arena) |*old| old.deinit();
            self.attention_arena = arena;
            self.attention = parsed;
        }
    }
    /// A status item builder with this client's `status` config and its
    /// `toggle-segment` flips.
    pub fn builder(self: *const State, a: std.mem.Allocator, toggled: []const []const u8) Builder {
        return .{ .a = a, .config = self.status.shared(), .toggled = toggled };
    }
    pub fn segment(self: *const State, id: []const u8) ?*const Segment {
        for (self.segments.items) |*s| if (eq(u8, s.id, id)) return s;
        return null;
    }
};

// ---------------------------------------------------------------- layout

// Glyphs, items and the status-line layout are venom-term's `chrome.status`,
// shared with every presentation client.
const cs = @import("term_chrome").status;
pub const glyph = cs.glyph;
pub const width = cs.width;
pub const levelStyle = cs.levelStyle;
pub const notifyStyle = cs.notifyStyle;
pub const Item = cs.Item;
pub const Placed = cs.Placed;
pub const Builder = cs.Builder;
pub const separator = cs.separator;
pub const separator_width = cs.separator_width;
pub const layout = cs.layout;
pub const hit = cs.hit;
pub const template = cs.template;
pub const Input = cs.Input;

fn get(v: Value, key: []const u8) ?Value {
    return if (v == .object) v.object.get(key) else null;
}
fn str(v: Value, key: []const u8) ?[]const u8 {
    const f = get(v, key) orelse return null;
    return if (f == .string) f.string else null;
}
fn int(v: Value, key: []const u8) ?i64 {
    const f = get(v, key) orelse return null;
    return if (f == .integer) f.integer else null;
}

fn argv0Run(a: std.mem.Allocator, created_first: bool) !void {
    var st: State = .{ .a = a };
    defer st.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entity = try std.json.parseFromSliceLeaky(Value, arena.allocator(), "{\"pane\":\"p0\",\"session\":\"s0\",\"argv0\":\"nvim\",\"tags\":[{\"key\":\"group\",\"value\":\"g\"}]}", .{});
    if (created_first) try st.paneCreated(entity) else try st.paneEntity(entity);
    // A second report replaces, never leaks, the first argv0.
    try st.paneCreated(entity);
    try std.testing.expectEqualStrings("nvim", st.pane("p0").?.argv0.?);
}

test "argv0 from paneEntity and paneCreated survives allocation failure without leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, argv0Run, .{true});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, argv0Run, .{false});
}
