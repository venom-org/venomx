//! Floating panes, per-client popups with tickets, float
//! presets and placement intent.
//!
//! The daemon keeps the geometry *spec* of every float (preset name, explicit
//! fields, and the spec resolved from `floats.default`, registered presets and
//! config presets) and its z-order. Each presentation client resolves the
//! spec against its own window area (`rect`), so one spec works on every
//! terminal size; the pane stream then sizes the PTY from the writers' rectangles.
//! A config reload re-resolves every float and announces changes with
//! `pane.placed`.
const std = @import("std");
const proto = @import("proto");
const cfg = @import("cfg");
const cli = @import("cli");
const g = proto.grants;
const chrome = @import("chrome.zig");
const layout = @import("layout.zig");
const product_mod = @import("product.zig");
const Product = product_mod.Product;
const Pane = product_mod.Pane;
const Window = product_mod.Window;
const Session = product_mod.Session;
const Batch = product_mod.Batch;
const Value = std.json.Value;
const eq = std.mem.eql;
extern "c" fn getentropy(buf: [*]u8, len: usize) c_int;

// ---------------------------------------------------------------- geometry

pub const Layer = enum { tile, float, popup };
pub const Anchor = enum { center, top, bottom, left, right, top_left, top_right, bottom_left, bottom_right };
pub const Border = enum { none, single, rounded, heavy };

/// A size: cells (`"80"`) or percent of the window area (`"60%"`). ZON and
/// JSON give it as a string so one field type carries both forms.
pub const Size = union(enum) {
    cells: u16,
    percent: u8,
    pub fn parse(t: []const u8) ?Size {
        if (t.len == 0 or t.len > 6) return null;
        if (t[t.len - 1] == '%') {
            const n = std.fmt.parseInt(u8, t[0 .. t.len - 1], 10) catch return null;
            if (n < 1 or n > 100 or t[0] == '+') return null;
            return .{ .percent = n };
        }
        if (t[0] == '+') return null;
        const n = std.fmt.parseInt(u16, t, 10) catch return null;
        if (n < 1) return null;
        return .{ .cells = n };
    }
    pub fn text(self: Size, buf: []u8) []const u8 {
        return switch (self) {
            .cells => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch unreachable,
            .percent => |n| std.fmt.bufPrint(buf, "{d}%", .{n}) catch unreachable,
        };
    }
    /// Cells of an extent of `total` cells.
    pub fn of(self: Size, total: u16) u16 {
        return switch (self) {
            .cells => |n| n,
            .percent => |n| @intCast((@as(u32, total) * n + 50) / 100),
        };
    }
};

/// One layer of geometry fields (config default, a preset, explicit params).
/// Absent fields fall through to the layer below.
pub const Spec = struct {
    width: ?[]const u8 = null,
    height: ?[]const u8 = null,
    anchor: ?Anchor = null,
    x: ?i32 = null,
    y: ?i32 = null,
    min_cols: ?u16 = null,
    min_rows: ?u16 = null,
    border: ?Border = null,
    title: ?[]const u8 = null,
    /// Null when valid, else the failing field.
    pub fn invalid(self: Spec) ?[]const u8 {
        if (self.width) |w| if (Size.parse(w) == null) return "width";
        if (self.height) |h| if (Size.parse(h) == null) return "height";
        if (self.x) |x| if (x < -max_offset or x > max_offset) return "x";
        if (self.y) |y| if (y < -max_offset or y > max_offset) return "y";
        if (self.min_cols) |n| if (n == 0) return "min_cols";
        if (self.min_rows) |n| if (n == 0) return "min_rows";
        if (self.title) |t| if (!validTitle(t)) return "title";
        return null;
    }
    fn dupe(self: Spec, a: std.mem.Allocator) !Spec {
        var out = self;
        if (self.width) |w| out.width = try a.dupe(u8, w);
        if (self.height) |h| out.height = try a.dupe(u8, h);
        if (self.title) |t| out.title = try a.dupe(u8, t);
        return out;
    }
};
pub const max_offset = 4096;
pub fn validTitle(t: []const u8) bool {
    return t.len <= 128 and chrome.validText(t, 0, 128);
}
pub const builtin_default: Spec = .{ .width = "60%", .height = "60%", .anchor = .center, .x = 0, .y = 0, .border = .rounded, .min_cols = 20, .min_rows = 5 };

/// A fully resolved spec, as the daemon publishes it and clients read it.
pub const Geometry = struct {
    width: Size = .{ .percent = 60 },
    height: Size = .{ .percent = 60 },
    anchor: Anchor = .center,
    x: i32 = 0,
    y: i32 = 0,
    min_cols: u16 = 20,
    min_rows: u16 = 5,
    border: Border = .rounded,
    /// Empty: the pane's OSC 2 title is shown.
    title: []const u8 = "",
    pub fn apply(self: *Geometry, s: Spec) void {
        if (s.width) |w| if (Size.parse(w)) |v| {
            self.width = v;
        };
        if (s.height) |h| if (Size.parse(h)) |v| {
            self.height = v;
        };
        if (s.anchor) |v| self.anchor = v;
        if (s.x) |v| self.x = v;
        if (s.y) |v| self.y = v;
        if (s.min_cols) |v| self.min_cols = @max(v, 1);
        if (s.min_rows) |v| self.min_rows = @max(v, 1);
        if (s.border) |v| self.border = v;
        if (s.title) |v| self.title = v;
    }
    pub fn eql(x: Geometry, y: Geometry) bool {
        return std.meta.eql(x.width, y.width) and std.meta.eql(x.height, y.height) and x.anchor == y.anchor and x.x == y.x and x.y == y.y and
            x.min_cols == y.min_cols and x.min_rows == y.min_rows and x.border == y.border and eq(u8, x.title, y.title);
    }
    /// The wire form (events, snapshots, pane.list); strings in `a`.
    pub fn wire(self: Geometry, a: std.mem.Allocator, preset: ?[]const u8, z: u64) !Wire {
        var wb: [8]u8 = undefined;
        var hb: [8]u8 = undefined;
        return .{ .preset = preset, .width = try a.dupe(u8, self.width.text(&wb)), .height = try a.dupe(u8, self.height.text(&hb)), .anchor = @tagName(self.anchor), .x = self.x, .y = self.y, .min_cols = self.min_cols, .min_rows = self.min_rows, .border = @tagName(self.border), .title = if (self.title.len > 0) self.title else null, .z = z };
    }
    /// Reads a wire object. `title` borrows from `v`.
    pub fn fromWire(v: Value) ?struct { geometry: Geometry, z: u64 } {
        if (v != .object) return null;
        const o = v.object;
        var out: Geometry = .{};
        out.width = Size.parse(str(o.get("width")) orelse return null) orelse return null;
        out.height = Size.parse(str(o.get("height")) orelse return null) orelse return null;
        out.anchor = std.meta.stringToEnum(Anchor, str(o.get("anchor")) orelse return null) orelse return null;
        out.border = std.meta.stringToEnum(Border, str(o.get("border")) orelse return null) orelse return null;
        out.x = @intCast(std.math.clamp(int(o.get("x")) orelse 0, -max_offset, max_offset));
        out.y = @intCast(std.math.clamp(int(o.get("y")) orelse 0, -max_offset, max_offset));
        out.min_cols = @intCast(std.math.clamp(int(o.get("min_cols")) orelse 1, 1, 65535));
        out.min_rows = @intCast(std.math.clamp(int(o.get("min_rows")) orelse 1, 1, 65535));
        out.title = str(o.get("title")) orelse "";
        const z = int(o.get("z")) orelse 0;
        return .{ .geometry = out, .z = @intCast(@max(z, 0)) };
    }
};
pub const Wire = struct {
    preset: ?[]const u8 = null,
    width: []const u8,
    height: []const u8,
    anchor: []const u8,
    x: i32,
    y: i32,
    min_cols: u16,
    min_rows: u16,
    border: []const u8,
    title: ?[]const u8 = null,
    z: u64,
};

pub const Rect = @import("attach_layout.zig").Rect;
/// Where a client draws a float in its window area `area`: the outer
/// rectangle (with border) and the inner one (the pane's viewport). Below
/// `min_cols`/`min_rows` the float fills the area without a border.
pub const Placed = struct { outer: Rect, inner: Rect, full: bool };
pub fn rect(geo: Geometry, area: Rect) Placed {
    if (area.width == 0 or area.height == 0) return .{ .outer = area, .inner = area, .full = true };
    if (area.width < geo.min_cols or area.height < geo.min_rows) return .{ .outer = area, .inner = area, .full = true };
    const w = std.math.clamp(@max(geo.width.of(area.width), geo.min_cols), 1, area.width);
    const h = std.math.clamp(@max(geo.height.of(area.height), geo.min_rows), 1, area.height);
    const free_x: i32 = area.width - w;
    const free_y: i32 = area.height - h;
    const ax: i32 = switch (geo.anchor) {
        .left, .top_left, .bottom_left => 0,
        .right, .top_right, .bottom_right => free_x,
        .center, .top, .bottom => @divFloor(free_x, 2),
    };
    const ay: i32 = switch (geo.anchor) {
        .top, .top_left, .top_right => 0,
        .bottom, .bottom_left, .bottom_right => free_y,
        .center, .left, .right => @divFloor(free_y, 2),
    };
    const x = std.math.clamp(ax + geo.x, 0, free_x);
    const y = std.math.clamp(ay + geo.y, 0, free_y);
    const outer: Rect = .{ .x = area.x + @as(u16, @intCast(x)), .y = area.y + @as(u16, @intCast(y)), .width = w, .height = h };
    var inner = outer;
    if (geo.border != .none and w >= 3 and h >= 3) inner = .{ .x = outer.x + 1, .y = outer.y + 1, .width = w - 2, .height = h - 2 };
    return .{ .outer = outer, .inner = inner, .full = false };
}

// ------------------------------------------------------------------ config

/// The `floats` config. Preset names are namespaced like segment ids.
pub const Config = struct {
    default: Spec = builtin_default,
    presets: cfg.Map(Spec) = .{},
    pub fn check(self: Config) !void {
        if (self.default.invalid() != null) return error.InvalidConfig;
        for (self.presets.entries) |e| {
            if (!chrome.validSegmentId(e.name)) return error.InvalidConfig;
            if (e.value.invalid() != null) return error.InvalidConfig;
        }
    }
};

// ------------------------------------------------------------------- state

/// A float's or popup's placement record, owned by its pane.
pub const Float = struct {
    arena: std.heap.ArenaAllocator,
    preset: ?[]const u8 = null,
    explicit: Spec = .{},
    geometry: Geometry = .{},
    z: u64 = 0,
    /// The preset names nothing (falls back to floats.default; doctor).
    unknown: bool = false,
    /// Popups: the client they were opened for.
    client: ?*Client = null,
    /// Popup whose client detached: hung up and removed once it exits.
    orphaned: bool = false,
    hung_up: bool = false,
    pub fn create(a: std.mem.Allocator, preset: ?[]const u8, explicit: Spec) !*Float {
        const f = try a.create(Float);
        errdefer a.destroy(f);
        f.* = .{ .arena = .init(a) };
        errdefer f.arena.deinit();
        const x = f.arena.allocator();
        f.preset = if (preset) |p| try x.dupe(u8, p) else null;
        f.explicit = try explicit.dupe(x);
        return f;
    }
    pub fn destroy(self: *Float, a: std.mem.Allocator) void {
        self.arena.deinit();
        a.destroy(self);
    }
    pub fn wire(self: *const Float, a: std.mem.Allocator) !Wire {
        return self.geometry.wire(a, self.preset, self.z);
    }
};
/// A presentation client that minted a ticket: its popups show only there.
pub const Client = struct {
    id: []const u8,
    conn: ?*proto.Connection,
};
pub const ticket_ms = 10_000;
pub const max_tickets = 16;
pub const Ticket = struct {
    token: [32]u8,
    client: *Client,
    session: *Session,
    window: *Window,
    expires: i64,
};
pub const max_registered = 64;
/// A `floats.register` preset (product layer; config presets win).
pub const Registered = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    spec: Spec,
    conn: ?*proto.Connection,
    principal: g.Id,
    fn destroy(self: *Registered, a: std.mem.Allocator) void {
        self.arena.deinit();
        a.destroy(self);
    }
};
pub const State = struct {
    /// The active `floats` config (the cfg store's, set every reactor turn).
    config: Config = .{},
    registered: std.ArrayList(*Registered) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    tickets: std.ArrayList(Ticket) = .empty,
    next_client: u64 = 0,
    next_z: u64 = 0,
    /// Doctor counters.
    denied_tickets: u64 = 0,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        for (self.registered.items) |r| r.destroy(a);
        self.registered.deinit(a);
        for (self.clients.items) |c| {
            a.free(c.id);
            a.destroy(c);
        }
        self.clients.deinit(a);
        self.tickets.deinit(a);
    }
    pub fn registeredPreset(self: *const State, name: []const u8) ?*Registered {
        for (self.registered.items) |r| if (eq(u8, r.name, name)) return r;
        return null;
    }
    /// A ticket still names it: removed records stay until it expires.
    pub fn refsWindow(self: *const State, w: *const Window) bool {
        for (self.tickets.items) |t| if (t.window == w) return true;
        return false;
    }
    pub fn refsSession(self: *const State, x: *const Session) bool {
        for (self.tickets.items) |t| if (t.session == x) return true;
        return false;
    }
    pub fn clientOf(self: *const State, conn: *const proto.Connection) ?*Client {
        for (self.clients.items) |c| if (c.conn == conn) return c;
        return null;
    }
    /// floats.default, then the registered preset, then the config preset,
    /// then the explicit fields. Strings borrow from the layers.
    pub fn resolve(self: *const State, preset: ?[]const u8, explicit: Spec) struct { geometry: Geometry, unknown: bool } {
        var geo: Geometry = .{};
        geo.apply(builtin_default);
        geo.apply(self.config.default);
        var unknown = false;
        if (preset) |name| {
            const reg = self.registeredPreset(name);
            const conf = self.config.presets.get(name);
            if (reg) |r| geo.apply(r.spec);
            if (conf) |s| geo.apply(s);
            unknown = reg == null and conf == null;
        }
        geo.apply(explicit);
        return .{ .geometry = geo, .unknown = unknown };
    }
    /// Resolve into `f`, copying borrowed strings into its arena. True when
    /// the geometry changed.
    pub fn place(self: *const State, f: *Float) !bool {
        const r = self.resolve(f.preset, f.explicit);
        f.unknown = r.unknown;
        if (r.geometry.eql(f.geometry)) return false;
        var geo = r.geometry;
        geo.title = try f.arena.allocator().dupe(u8, geo.title);
        f.geometry = geo;
        return true;
    }
};

// ------------------------------------------------------------------ params

fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}
fn int(v: ?Value) ?i64 {
    const x = v orelse return null;
    return if (x == .integer) x.integer else null;
}
/// Geometry fields of a params object (`pane.float`, `pane.popup`,
/// `floats.register`, `pane.place`'s `float`). Strings borrow from `o`.
pub fn specOf(o: std.json.ObjectMap) union(enum) { ok: Spec, failed: []const u8 } {
    var s: Spec = .{};
    s.width = str(o.get("width"));
    s.height = str(o.get("height"));
    if (str(o.get("anchor"))) |t| s.anchor = std.meta.stringToEnum(Anchor, t) orelse return .{ .failed = "anchor" };
    if (str(o.get("border"))) |t| s.border = std.meta.stringToEnum(Border, t) orelse return .{ .failed = "border" };
    if (int(o.get("x"))) |n| s.x = std.math.cast(i32, n) orelse return .{ .failed = "x" };
    if (int(o.get("y"))) |n| s.y = std.math.cast(i32, n) orelse return .{ .failed = "y" };
    if (int(o.get("min_cols"))) |n| s.min_cols = std.math.cast(u16, n) orelse return .{ .failed = "min_cols" };
    if (int(o.get("min_rows"))) |n| s.min_rows = std.math.cast(u16, n) orelse return .{ .failed = "min_rows" };
    s.title = str(o.get("title"));
    if (s.invalid()) |f| return .{ .failed = f };
    return .{ .ok = s };
}
fn geometryInvalid(c: *proto.Call, param: []const u8) !void {
    return c.fail("invalid_params.geometry", "unparsable float geometry", .{ .param = param });
}
fn result(c: *proto.Call, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(c.arena(), value, .{ .emit_null_optional_fields = false });
    if (bytes.len + c.id_json.len + 16 > c.conn.max_frame) return c.fail("unsupported.result_size", "unsupported.result_size", struct {}{});
    try c.ok(try std.json.parseFromSliceLeaky(Value, c.arena(), bytes, .{}));
}
fn fail(c: *proto.Call, code: []const u8) !void {
    return c.fail(code, code, struct {}{});
}
/// A float record from params; null once the call has been answered.
fn floatOf(p: *Product, c: *proto.Call, o: std.json.ObjectMap) !?*Float {
    const spec = switch (specOf(o)) {
        .ok => |s| s,
        .failed => |param| {
            try geometryInvalid(c, param);
            return null;
        },
    };
    const preset = str(o.get("preset"));
    if (preset) |name| if (!chrome.validSegmentId(name)) {
        try geometryInvalid(c, "preset");
        return null;
    };
    const f = try Float.create(p.a, preset, spec);
    errdefer f.destroy(p.a);
    _ = try p.floats.place(f);
    return f;
}

// ------------------------------------------------------------------- verbs

/// How `Product.spawn` places a new pane.
pub const Place = struct {
    layer: Layer = .tile,
    /// The float's or popup's window.
    window: ?*Window = null,
    /// Ownership moves to the pane at commit (then this is null).
    float: ?*Float = null,
    /// A popup's ticket, consumed at commit.
    ticket: ?[32]u8 = null,
    /// `near` placement of window.create: split this axis.
    axis: ?layout.Axis = null,
};

pub fn call(p: *Product, c: *proto.Call) !void {
    const verb = c.verb.name;
    if (eq(u8, verb, "pane.float")) return paneFloat(p, c);
    if (eq(u8, verb, "pane.popup")) return panePopup(p, c);
    if (eq(u8, verb, "popup.ticket")) return mintTicket(p, c);
    if (eq(u8, verb, "floats.register")) return register(p, c);
    unreachable;
}

fn liveWindow(p: *Product, id: []const u8) ?*Window {
    for (p.windows.items) |w| if (!w.removed and eq(u8, w.id, id)) return w;
    return null;
}

fn paneFloat(p: *Product, c: *proto.Call) !void {
    const wid = c.params.object.get("window").?.string;
    if (!try p.admit(c, .spawn, .{ .kind = "window", .id = wid })) return;
    const w = liveWindow(p, wid) orelse return fail(c, "not_found.window");
    if (w.sealed > 0 or w.session.sealed > 0) return fail(c, "conflict.removing");
    var place: Place = .{ .layer = .float, .window = w };
    place.float = (try floatOf(p, c, c.params.object)) orelse return;
    defer if (place.float) |f| f.destroy(p.a);
    place.float.?.z = p.floats.next_z + 1;
    return p.spawnPlaced(c, w.session, &place);
}

fn findTicket(p: *Product, token: []const u8) ?usize {
    if (token.len != 32) return null;
    for (p.floats.tickets.items, 0..) |t, i| if (std.crypto.timing_safe.eql([32]u8, t.token, token[0..32].*)) return i;
    return null;
}
fn ticketDenied(p: *Product, c: *proto.Call, reason: []const u8) !void {
    p.floats.denied_tickets += 1;
    return c.fail("denied.popup_ticket", "a valid popup ticket from the client's own binding is required", .{ .reason = reason });
}

/// A popup needs a client-minted, single-use ticket valid for 10 s.
fn panePopup(p: *Product, c: *proto.Call) !void {
    const token = str(c.params.object.get("ticket")) orelse "";
    const index = findTicket(p, token) orelse return ticketDenied(p, c, if (token.len == 0) "missing" else "unknown");
    const t = p.floats.tickets.items[index];
    if (p.leaders.now() >= t.expires) {
        _ = p.floats.tickets.orderedRemove(index);
        return ticketDenied(p, c, "expired");
    }
    if (!try p.admit(c, .spawn, .{ .kind = "session", .id = t.session.id })) return;
    // Only that human may cause one: another presentation client cannot
    // spend a ticket that was minted for someone else's screen.
    if (p.floats.clientOf(c.conn)) |caller| if (caller != t.client) return ticketDenied(p, c, "client");
    if (t.client.conn == null) return c.fail("not_found.client", "the ticket's client has detached", .{ .client = t.client.id });
    if (t.session.removed) return fail(c, "not_found.session");
    const w = if (!t.window.removed) t.window else for (p.windows.items) |x| {
        if (!x.removed and x.session == t.session) break x;
    } else return fail(c, "not_found.window");
    if (w.sealed > 0 or w.session.sealed > 0) return fail(c, "conflict.removing");
    var place: Place = .{ .layer = .popup, .window = w, .ticket = t.token };
    place.float = (try floatOf(p, c, c.params.object)) orelse return;
    defer if (place.float) |f| f.destroy(p.a);
    place.float.?.client = t.client;
    place.float.?.z = p.floats.next_z + 1;
    return p.spawnPlaced(c, w.session, &place);
}
/// At a popup's commit: its ticket is spent.
pub fn consume(p: *Product, token: [32]u8) void {
    for (p.floats.tickets.items, 0..) |t, i| if (eql32(t.token, token)) {
        _ = p.floats.tickets.orderedRemove(i);
        return;
    };
}
fn eql32(x: [32]u8, y: [32]u8) bool {
    return std.crypto.timing_safe.eql([32]u8, x, y);
}

fn mintTicket(p: *Product, c: *proto.Call) !void {
    const sid = c.params.object.get("session").?.string;
    if (!try p.admit(c, .read, .{ .kind = "session", .id = sid })) return;
    const s = p.session(sid) orelse return fail(c, "not_found.session");
    const w = if (str(c.params.object.get("window"))) |wid| blk: {
        const x = liveWindow(p, wid) orelse return fail(c, "not_found.window");
        if (x.session != s) return fail(c, "not_found.window");
        break :blk x;
    } else for (p.windows.items) |x| {
        if (!x.removed and x.session == s) break x;
    } else return fail(c, "not_found.window");
    var raw: [16]u8 = undefined;
    if (getentropy(&raw, raw.len) != 0) return fail(c, "unavailable.entropy");
    const token = std.fmt.bytesToHex(raw, .lower);
    const client = p.floats.clientOf(c.conn) orelse blk: {
        try p.floats.clients.ensureUnusedCapacity(p.a, 1);
        const x = try p.a.create(Client);
        errdefer p.a.destroy(x);
        if (p.floats.next_client == std.math.maxInt(u64)) return error.Overflow;
        x.* = .{ .id = try std.fmt.allocPrint(p.a, "c{d}", .{p.floats.next_client}), .conn = c.conn };
        p.floats.next_client += 1;
        p.floats.clients.appendAssumeCapacity(x);
        break :blk x;
    };
    // At most 16 outstanding tickets per client; the oldest goes first.
    var count: usize = 0;
    for (p.floats.tickets.items) |t| count += @intFromBool(t.client == client);
    if (count >= max_tickets) for (p.floats.tickets.items, 0..) |t, i| if (t.client == client) {
        _ = p.floats.tickets.orderedRemove(i);
        break;
    };
    try p.floats.tickets.ensureUnusedCapacity(p.a, 1);
    try result(c, .{ .ticket = &token, .client = client.id, .session = s.id, .window = w.id, .ttl_ms = @as(u64, ticket_ms) });
    p.floats.tickets.appendAssumeCapacity(.{ .token = token, .client = client, .session = s, .window = w, .expires = p.leaders.now() + ticket_ms });
}

fn register(p: *Product, c: *proto.Call) !void {
    const o = c.params.object;
    if (!try p.admit(c, .write, .{ .kind = "server", .id = "root" })) return;
    const name = o.get("name").?.string;
    if (!chrome.validSegmentId(name)) return geometryInvalid(c, "name");
    if (!chrome.mayRegister(c.conn.identity.principal, c.namespace(), chrome.idNamespace(name), chrome.isolated(c))) return c.fail("denied.namespace", "the preset name must be in the caller's namespace (the owner may use any but venomx.*)", .{ .id = name, .namespace = c.namespace() });
    const spec = switch (specOf(o)) {
        .ok => |s| s,
        .failed => |param| return geometryInvalid(c, param),
    };
    const existing = p.floats.registeredPreset(name);
    if (existing == null and p.floats.registered.items.len >= max_registered) return c.fail("conflict.preset_limit", "too many registered presets", .{ .limit = @as(u64, max_registered) });
    const r = try p.a.create(Registered);
    var committed = false;
    defer if (!committed) p.a.destroy(r);
    r.arena = .init(p.a);
    defer if (!committed) r.arena.deinit();
    const x = r.arena.allocator();
    const bind = std.meta.stringToEnum(chrome.Bind, o.get("bind").?.string).?;
    r.* = .{ .arena = r.arena, .name = try x.dupe(u8, name), .spec = try spec.dupe(x), .conn = if (bind == .connection) c.conn else null, .principal = c.conn.identity.principal };
    if (existing == null) try p.floats.registered.ensureUnusedCapacity(p.a, 1);
    try result(c, .{ .name = name, .layer = "product" });
    if (existing) |old| {
        for (p.floats.registered.items) |*slot| if (slot.* == old) {
            slot.* = r;
        };
        old.destroy(p.a);
    } else p.floats.registered.appendAssumeCapacity(r);
    committed = true;
    reresolve(p);
}

/// `pane.place`: re-geometry a float, float a tiled pane, or tile a float.
pub fn panePlace(p: *Product, c: *proto.Call, pane: *Pane) !void {
    const a = c.arena();
    const o = c.params.object;
    const w = pane.window;
    if (!try c.authorize(.write, .{ .kind = "window", .id = w.id })) return;
    if (pane.layer == .popup) return c.fail("conflict.layer", "popups cannot be placed", .{ .layer = "popup" });
    if (pane.sealed > 0 or w.sealed > 0) return fail(c, "conflict.removing");
    if (pane.archive != null) return c.fail("conflict.layer", "restored archives keep their layer; relaunch first", .{ .layer = @tagName(pane.layer) });
    const float_v = o.get("float");
    const tile_v = o.get("tile");
    if ((float_v == null) == (tile_v == null)) return c.fail("invalid_params.place", "give exactly one of float or tile", .{ .param = "float" });
    if (w.revision == proto.events.max_seq) return error.Overflow;
    var batch = try Batch.init(p.events);
    defer batch.deinit();
    const wres = try Product.resourceName(a, "window", w.id);
    const pres = try Product.resourceName(a, "pane", pane.id);
    if (float_v) |fv| {
        const f = (try floatOf(p, c, fv.object)) orelse return;
        var keep = false;
        defer if (!keep) f.destroy(p.a);
        f.z = if (pane.float) |old| old.z else p.floats.next_z + 1;
        var nodes: ?[]layout.Node = null;
        defer if (!keep) if (nodes) |n| p.a.free(n);
        // `pane.placed` first, so a client never sees the pane in
        // neither layer and moves its focus away.
        try batch.append(pres, "pane.placed", .{ .pane = pane.id, .window = w.id, .layer = "float", .float = try f.wire(a) });
        if (pane.layer == .tile) {
            nodes = try layout.edit(p.a, w.nodes, pane.id, null);
            try batch.append(wres, "window.layout_changed", .{ .window = w.id, .session = w.session.id, .revision = w.revision + 1, .nodes = nodes.? });
        }
        try batch.reserve();
        try result(c, .{ .pane = pane.id, .layer = "float" });
        keep = true;
        if (nodes) |n| {
            p.a.free(w.nodes);
            w.nodes = n;
            w.revision += 1;
            p.floats.next_z += 1;
        }
        if (pane.float) |old| old.destroy(p.a);
        pane.float = f;
        pane.layer = .float;
        batch.commit();
        return;
    }
    const t = tile_v.?.object;
    const target = str(t.get("target"));
    const axis_text = str(t.get("axis"));
    const removed_nodes = if (pane.layer == .tile) try layout.edit(a, w.nodes, pane.id, null) else w.nodes;
    var nodes: []layout.Node = undefined;
    if (removed_nodes.len == 0) {
        nodes = try p.a.dupe(layout.Node, &.{.{ .kind = .pane, .pane = pane.id }});
    } else {
        const tid = target orelse return c.fail("invalid_params.place", "tile.target is required while the window has tiled panes", .{ .param = "tile.target" });
        const axis = std.meta.stringToEnum(layout.Axis, axis_text orelse "") orelse return c.fail("invalid_params.place", "tile.axis is cols or rows", .{ .param = "tile.axis" });
        const present = for (removed_nodes) |n| {
            if (n.kind == .pane and eq(u8, n.pane.?, tid)) break true;
        } else false;
        if (!present or eq(u8, tid, pane.id)) return c.fail("invalid_params.place", "tile.target is not another tiled pane of this window", .{ .param = "tile.target" });
        nodes = try layout.editSplit(p.a, removed_nodes, tid, .{ .kind = .pane, .pane = pane.id, .axis = axis }, Product.PaneSizes{ .product = p });
    }
    var keep = false;
    defer if (!keep) p.a.free(nodes);
    try batch.append(wres, "window.layout_changed", .{ .window = w.id, .session = w.session.id, .revision = w.revision + 1, .nodes = nodes });
    try batch.append(pres, "pane.placed", .{ .pane = pane.id, .window = w.id, .layer = "tile" });
    try batch.reserve();
    try result(c, .{ .pane = pane.id, .layer = "tile" });
    keep = true;
    p.a.free(w.nodes);
    w.nodes = nodes;
    w.revision += 1;
    if (pane.float) |old| old.destroy(p.a);
    pane.float = null;
    pane.layer = .tile;
    batch.commit();
}

pub fn paneRaise(p: *Product, c: *proto.Call, pane: *Pane) !void {
    const w = pane.window;
    if (!try c.authorize(.write, .{ .kind = "window", .id = w.id })) return;
    const f = pane.float orelse return c.fail("conflict.layer", "only floating panes and popups have a z-order", .{ .layer = "tile" });
    if (p.floats.next_z == std.math.maxInt(u64)) return error.Overflow;
    const z = p.floats.next_z + 1;
    var batch = try Batch.init(p.events);
    defer batch.deinit();
    try batch.append(try Product.resourceName(c.arena(), "pane", pane.id), "pane.raised", .{ .pane = pane.id, .window = w.id, .z = z });
    try batch.reserve();
    try result(c, .{ .pane = pane.id, .z = z });
    p.floats.next_z = z;
    f.z = z;
    batch.commit();
}

/// Re-resolve every float after a config or preset change; each changed
/// one is announced with `pane.placed`.
pub fn reresolve(p: *Product) void {
    var scratch = std.heap.ArenaAllocator.init(p.a);
    defer scratch.deinit();
    const a = scratch.allocator();
    for (p.panes.items) |pane| if (!pane.removed) if (pane.float) |f| {
        const changed = p.floats.place(f) catch continue;
        if (!changed) continue;
        const wire = f.wire(a) catch continue;
        const res = Product.resourceName(a, "pane", pane.id) catch continue;
        p.events.append(res, "pane.placed", .{ .pane = pane.id, .window = pane.window.id, .layer = @tagName(pane.layer), .float = wire }) catch {};
    };
}
/// The cfg store's active `floats` each reactor turn: a reload (a new
/// snapshot) re-resolves every float.
pub fn configure(p: *Product, config: Config) void {
    if (std.meta.eql(p.floats.config, config)) return;
    p.floats.config = config;
    reresolve(p);
}

/// Connection closed: the client's popups close, its tickets can no
/// longer be used (`not_found.client`), its connection-bound presets go.
pub fn closed(p: *Product, conn: *proto.Connection) void {
    if (p.floats.clientOf(conn)) |client| {
        client.conn = null;
        for (p.panes.items) |pane| if (!pane.removed) if (pane.float) |f| if (f.client == client) {
            f.orphaned = true;
        };
    }
    var dropped = false;
    var i: usize = 0;
    while (i < p.floats.registered.items.len) {
        const r = p.floats.registered.items[i];
        if (r.conn == conn) {
            _ = p.floats.registered.orderedRemove(i);
            r.destroy(p.a);
            dropped = true;
        } else i += 1;
    }
    if (dropped) reresolve(p);
}

pub fn tick(p: *Product) !void {
    const now = p.leaders.now();
    var i: usize = 0;
    while (i < p.floats.tickets.items.len) {
        if (now >= p.floats.tickets.items[i].expires + ticket_ms) _ = p.floats.tickets.orderedRemove(i) else i += 1;
    }
    // Orphaned popups: SIGHUP their group; on_exit removal follows the exit.
    if (!p.shutting_down) for (p.panes.items) |pane| if (!pane.removed) if (pane.float) |f| if (f.orphaned and !f.hung_up) {
        f.hung_up = true;
        if (pane.pane.status == null and pane.leader != null) try p.hangUp(pane);
    };
    // Revoked principals' presets go.
    var dropped = false;
    i = 0;
    while (i < p.floats.registered.items.len) {
        const r = p.floats.registered.items[i];
        if (r.principal != g.owner) if (p.registry.get(r.principal)) |entry| if (entry.revoked) {
            _ = p.floats.registered.orderedRemove(i);
            r.destroy(p.a);
            dropped = true;
            continue;
        };
        i += 1;
    }
    if (dropped) reresolve(p);
    // Detached clients nothing refers to any more.
    i = 0;
    while (i < p.floats.clients.items.len) {
        const client = p.floats.clients.items[i];
        const used = client.conn != null or for (p.floats.tickets.items) |t| {
            if (t.client == client) break true;
        } else for (p.panes.items) |pane| {
            if (!pane.removed) if (pane.float) |f| if (f.client == client) break true;
        } else false;
        if (used) {
            i += 1;
            continue;
        }
        for (p.panes.items) |pane| if (pane.float) |f| if (f.client == client) {
            f.client = null;
        };
        _ = p.floats.clients.orderedRemove(i);
        p.a.free(client.id);
        p.a.destroy(client);
    }
}

/// `near`: the largest live tiled pane of the session whose tags match
/// and that the caller may split. Null without `near` or a match; false
/// when the call has been answered.
pub fn nearSource(p: *Product, c: *proto.Call, s: *Session) !union(enum) { none, pane: *Pane, answered } {
    const v = c.params.object.get("near") orelse return .none;
    const pairs = switch (try chrome.parsePairs(c.arena(), v, "near", true)) {
        .ok => |x| x,
        .failed => |f| {
            try c.fail("invalid_params.tags", "invalid near tags", f);
            return .answered;
        },
    };
    if (pairs.len == 0) return .none;
    var best: ?*Pane = null;
    var best_area: u64 = 0;
    const now = g.nowSeconds();
    for (p.panes.items) |x| {
        if (x.removed or x.layer != .tile or x.archive != null or x.window.session != s) continue;
        if (x.sealed > 0 or x.window.sealed > 0 or x.pane.terminating or x.pane.status != null) continue;
        if (!x.tags.matches(pairs)) continue;
        if (!p.registry.allows(c.conn.identity, .spawn, .{ .kind = "pane", .id = x.id }, now)) continue;
        const size = x.pane.vt.size();
        const area = @as(u64, size.cols) * size.rows;
        if (best == null or area > best_area) {
            best = x;
            best_area = area;
        }
    }
    return if (best) |b| .{ .pane = b } else .none;
}
/// The axis that keeps the halves closest to square (cells are about twice
/// as tall as wide).
pub fn autoAxis(pane: *const Pane) layout.Axis {
    const size = pane.pane.vt.size();
    return if (size.cols >= @as(u32, size.rows) * 2) .cols else .rows;
}

/// Floats whose preset names nothing fall back to floats.default.
pub fn doctor(r: *cli.doctor.Report, p: *Product) !void {
    const fix = try r.command("{s} config get --key floats.presets --json", r.tool);
    var names: std.ArrayList(u8) = .empty;
    var n: usize = 0;
    for (p.panes.items) |pane| if (!pane.removed) if (pane.float) |f| if (f.unknown) {
        n += 1;
        if (n <= 4) try names.print(r.arena, "{s}{s} ({s})", .{ if (n > 1) ", " else "", pane.id, f.preset.? });
    };
    if (n > 0) {
        try r.add("floats.presets", .warn, try r.print("{d} float(s) use an unknown preset and fall back to floats.default: {s}", .{ n, names.items }), fix);
    } else try r.add("floats.presets", .ok, try r.print("{d} config presets, {d} registered presets; every float's preset is known", .{ p.floats.config.presets.entries.len, p.floats.registered.items.len }), fix);
    var floats: usize = 0;
    var popups: usize = 0;
    for (p.panes.items) |pane| if (!pane.removed) switch (pane.layer) {
        .float => floats += 1,
        .popup => popups += 1,
        .tile => {},
    };
    try r.add("floats.layer", .ok, try r.print("{d} floating panes, {d} popups, {d} popup tickets outstanding, {d} denied.popup_ticket", .{ floats, popups, p.floats.tickets.items.len, p.floats.denied_tickets }), try r.command("{s} pane list --json", r.tool));
}

/// Window-level float list for `window.get`, in z order.
pub const FloatItem = struct { pane: []const u8, layer: []const u8, z: u64 };
pub fn windowFloats(a: std.mem.Allocator, p: *Product, w: *Window) ![]const FloatItem {
    var out: std.ArrayList(FloatItem) = .empty;
    for (p.panes.items) |pane| if (!pane.removed and pane.window == w and pane.layer == .float) try out.append(a, .{ .pane = pane.id, .layer = "float", .z = pane.float.?.z });
    std.mem.sort(FloatItem, out.items, {}, struct {
        fn lt(_: void, x: FloatItem, y: FloatItem) bool {
            return x.z < y.z;
        }
    }.lt);
    return out.items;
}

test "sizes, specs and client rectangles" {
    const t = std.testing;
    try t.expectEqual(Size{ .percent = 60 }, Size.parse("60%").?);
    try t.expectEqual(Size{ .cells = 80 }, Size.parse("80").?);
    for ([_][]const u8{ "", "0", "0%", "101%", "-3", "+3", "x%", "70000", "%" }) |bad| try t.expect(Size.parse(bad) == null);
    try t.expectEqualStrings("width", (Spec{ .width = "big" }).invalid().?);
    try t.expect((Spec{ .width = "100%", .x = -2, .title = "t" }).invalid() == null);
    var geo: Geometry = .{};
    geo.apply(builtin_default);
    // 60% of 100x30 centred, rounded border inside.
    var r = rect(geo, .{ .y = 1, .width = 100, .height = 30 });
    try t.expectEqual(Rect{ .x = 20, .y = 1 + 6, .width = 60, .height = 18 }, r.outer);
    try t.expectEqual(Rect{ .x = 21, .y = 8, .width = 58, .height = 16 }, r.inner);
    // Anchors and offsets clamp to the area.
    geo.anchor = .bottom_right;
    geo.x = 5;
    r = rect(geo, .{ .width = 100, .height = 30 });
    try t.expectEqual(@as(u16, 40), r.outer.x);
    try t.expectEqual(@as(u16, 12), r.outer.y);
    geo.anchor = .top;
    geo.x = 0;
    geo.y = 2;
    r = rect(geo, .{ .width = 100, .height = 30 });
    try t.expectEqual(@as(u16, 2), r.outer.y);
    // Below the minimums: full window, no border.
    r = rect(geo, .{ .width = 19, .height = 30 });
    try t.expect(r.full);
    try t.expectEqual(@as(u16, 19), r.inner.width);
    // Cells clamp to the area; minimums raise small sizes.
    geo.width = .{ .cells = 500 };
    geo.height = .{ .cells = 1 };
    geo.border = .none;
    r = rect(geo, .{ .width = 100, .height = 30 });
    try t.expectEqual(@as(u16, 100), r.inner.width);
    try t.expectEqual(@as(u16, 5), r.inner.height);
}

test "resolution: default, registered, config preset, explicit; unknown falls back" {
    var state: State = .{};
    defer state.deinit(std.testing.allocator);
    state.config.presets = .{ .entries = &.{.{ .name = "venom.settings", .value = .{ .width = "80%", .title = "venom settings" } }} };
    var res = state.resolve("venom.settings", .{ .height = "10" });
    try std.testing.expectEqual(Size{ .percent = 80 }, res.geometry.width);
    try std.testing.expectEqual(Size{ .cells = 10 }, res.geometry.height);
    try std.testing.expectEqualStrings("venom settings", res.geometry.title);
    try std.testing.expect(!res.unknown);
    res = state.resolve("venom.nope", .{});
    try std.testing.expect(res.unknown);
    try std.testing.expectEqual(Size{ .percent = 60 }, res.geometry.width);
    try (Config{}).check();
    try std.testing.expectError(error.InvalidConfig, (Config{ .presets = .{ .entries = &.{.{ .name = "mine", .value = .{} }} } }).check());
    try std.testing.expectError(error.InvalidConfig, (Config{ .default = .{ .width = "0%" } }).check());
}
