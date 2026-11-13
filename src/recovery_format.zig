//! Durable recovery formats: an allowlisted encoder and a strict reader.
//! The writer emits format 3; the reader accepts formats 1, 2 and 3. Format 2
//! is format 1 plus the float layer (`layer`, `float`) on pane
//! records and the pane `tags`; format 3 is format 2
//! plus the split `ratio`. Each file is read
//! strictly under its own format: an older file rejects the newer fields as
//! unknown, and its splits restore equal.
//! The reader checks hard bounds before any unbounded allocation or
//! traversal, rejects duplicate keys, unknown fields, unsafe integers and
//! inconsistent topology, and never repairs or salvages input.
const std = @import("std");
const layout = @import("layout.zig");
const floats = @import("floats.zig");
const chrome = @import("chrome.zig");
const Node = layout.Node;
const eq = std.mem.eql;
const Value = std.json.Value;

pub const max_safe: u64 = 9007199254740991;
/// The format the encoder writes.
pub const current_format: u8 = 3;
/// The oldest format the reader still accepts.
pub const oldest_format: u8 = 1;
/// Whole-file reader bound, independent of configuration.
pub const hard_max_bytes: usize = 64 * 1024 * 1024;
pub const max_depth = 32;
pub const max_resources = 100_000;
/// Per-pane text bounds (venom-term's `plain_max_rows` / `plain_max_bytes`).
pub const text_max_rows: usize = 100_000;
pub const text_max_bytes: usize = 16 * 1024 * 1024;

pub const Shutdown = enum { open, clean };
pub const State = enum { running, exited };
pub const ProcessState = enum { exited, interrupted };
pub const Exit = union(enum) { code: u8, signal: []const u8 };
pub const Plain = struct {
    saved_at_ms: i64,
    expires_at_ms: i64,
    screen: []const []const u8,
    history: []const []const u8,
};
pub const Text = union(enum) { omitted, expired, plain: Plain };
/// `on_exit`/`on_empty` policies are optional keys, written only when "remove".
pub const Policy = enum { keep, remove };
/// Pane layers that are durable. Popups belong to one client and are
/// never written.
pub const Layer = enum { tile, float };
/// A floating pane's placement: its preset name, the explicit geometry
/// fields (the spec, not the geometry resolved against config) and z-order.
pub const FloatRec = struct { preset: ?[]const u8 = null, explicit: floats.Spec = .{}, z: u64 };
pub const SessionRec = struct { session: []const u8, name: []const u8, on_empty: Policy = .keep };
pub const WindowRec = struct { window: []const u8, session: []const u8, name: []const u8, revision: u64, nodes: []const Node };
pub const PaneRec = struct {
    pane: []const u8,
    window: []const u8,
    session: []const u8,
    cols: u16,
    rows: u16,
    state: State,
    exit: ?Exit = null,
    previous_state: ?ProcessState = null,
    text: Text = .omitted,
    on_exit: Policy = .keep,
    layer: Layer = .tile,
    /// Present exactly when `layer == .float`.
    float: ?FloatRec = null,
    /// Pane tags, `owner` included, sorted by key (format 2).
    tags: []const chrome.Tag = &.{},
};
pub const Checkpoint = struct {
    checkpoint: []const u8,
    generation: u64,
    socket: []const u8,
    uid: u32,
    captured_at_ms: i64,
    shutdown: Shutdown,
    sessions: []const SessionRec,
    windows: []const WindowRec,
    panes: []PaneRec,
};

// ---------------------------------------------------------------- identifiers

/// `c` followed by a lowercase UUID v4.
pub fn validId(id: []const u8) bool {
    if (id.len != 37 or id[0] != 'c') return false;
    const u = id[1..];
    for (u, 0..) |ch, i| switch (i) {
        8, 13, 18, 23 => if (ch != '-') return false,
        else => if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return false,
    };
    return u[14] == '4' and (u[19] == '8' or u[19] == '9' or u[19] == 'a' or u[19] == 'b');
}
pub const Id = [37]u8;
pub fn newId(random: *const [16]u8) Id {
    var b = random.*;
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    var out: Id = undefined;
    out[0] = 'c';
    const hex = "0123456789abcdef";
    var at: usize = 1;
    for (b, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[at] = '-';
            at += 1;
        }
        out[at] = hex[byte >> 4];
        out[at + 1] = hex[byte & 15];
        at += 2;
    }
    std.debug.assert(validId(&out));
    return out;
}
/// Resource IDs: prefix and a canonical decimal number.
pub fn resourceNumber(prefix: u8, id: []const u8) ?u64 {
    if (id.len < 2 or id[0] != prefix) return null;
    const digits = id[1..];
    if (digits.len > 1 and digits[0] == '0') return null;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(u64, digits, 10) catch null;
}
pub fn nameValid(name: []const u8) bool {
    if (name.len > 128 or !std.unicode.utf8ValidateSlice(name)) return false;
    for (name) |ch| if (ch < 32 or ch == 127) return false;
    return true;
}
pub fn signalValid(name: []const u8) bool {
    if (name.len < 4 or name.len > 32 or !std.mem.startsWith(u8, name, "SIG")) return false;
    for (name[3..]) |ch| if (!std.ascii.isUpper(ch) and !std.ascii.isDigit(ch)) return false;
    return true;
}
/// Plain cell text: UTF-8 without C0, DEL or C1 characters.
pub fn plainRowValid(row: []const u8) bool {
    var it = (std.unicode.Utf8View.init(row) catch return false).iterator();
    while (it.nextCodepoint()) |cp| if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) return false;
    return true;
}

// ---------------------------------------------------------------- time

/// UTC RFC 3339 with milliseconds: `2026-11-06T22:00:00.000Z`.
pub const Timestamp = [24]u8;
pub fn formatTime(ms: i64) Timestamp {
    const clamped: u64 = @intCast(@max(ms, 0));
    const secs = clamped / 1000;
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    var out: Timestamp = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(), clamped % 1000 }) catch unreachable;
    return out;
}
/// Strict inverse of `formatTime`: only the canonical spelling parses.
pub fn parseTime(text: []const u8) ?i64 {
    if (text.len != 24) return null;
    const year = std.fmt.parseInt(u16, text[0..4], 10) catch return null;
    if (year < 1970 or year > 9999) return null;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const mday = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
    if (month < 1 or month > 12 or mday < 1) return null;
    const ys = std.time.epoch;
    if (mday > ys.getDaysInMonth(year, @fromBackingInt(@intCast(month)))) return null;
    var days: u64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += ys.getDaysInYear(y);
    var m: u8 = 1;
    while (m < month) : (m += 1) days += ys.getDaysInMonth(year, @fromBackingInt(@intCast(m)));
    days += mday - 1;
    const hh = std.fmt.parseInt(u8, text[11..13], 10) catch return null;
    const mm = std.fmt.parseInt(u8, text[14..16], 10) catch return null;
    const ss = std.fmt.parseInt(u8, text[17..19], 10) catch return null;
    const ms = std.fmt.parseInt(u16, text[20..23], 10) catch return null;
    const value: i64 = @intCast(((days * 86400 + @as(u64, hh) * 3600 + @as(u64, mm) * 60 + ss) * 1000) + ms);
    const round = formatTime(value);
    if (!eq(u8, &round, text)) return null;
    return value;
}

// ---------------------------------------------------------------- encoder

const TextOut = struct {
    availability: []const u8,
    saved_at: ?[]const u8 = null,
    expires_at: ?[]const u8 = null,
    screen: ?[]const []const u8 = null,
    history: ?[]const []const u8 = null,
};
const PaneOut = struct {
    pane: []const u8,
    window: []const u8,
    session: []const u8,
    cols: u16,
    rows: u16,
    state: []const u8,
    exit_code: ?u8 = null,
    signal: ?[]const u8 = null,
    previous_state: ?[]const u8 = null,
    on_exit: ?[]const u8 = null,
    layer: ?[]const u8 = null,
    float: ?FloatOut = null,
    tags: ?[]const chrome.Tag = null,
    text: TextOut,
};
const FloatOut = struct {
    preset: ?[]const u8 = null,
    width: ?[]const u8 = null,
    height: ?[]const u8 = null,
    anchor: ?[]const u8 = null,
    x: ?i32 = null,
    y: ?i32 = null,
    min_cols: ?u16 = null,
    min_rows: ?u16 = null,
    border: ?[]const u8 = null,
    title: ?[]const u8 = null,
    z: u64,
};
const SessionOut = struct { session: []const u8, name: []const u8, on_empty: ?[]const u8 = null };

/// The complete envelope (with trailing newline). The payload is an
/// allowlist of the fields above; nothing else can reach the file.
pub fn encode(a: std.mem.Allocator, cp: Checkpoint) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const t = arena.allocator();
    const panes = try t.alloc(PaneOut, cp.panes.len);
    for (cp.panes, panes) |p, *o| {
        o.* = .{ .pane = p.pane, .window = p.window, .session = p.session, .cols = p.cols, .rows = p.rows, .state = @tagName(p.state), .previous_state = if (p.previous_state) |s| @tagName(s) else null, .on_exit = if (p.on_exit == .remove) "remove" else null, .text = .{ .availability = @tagName(p.text) } };
        if (p.exit) |e| switch (e) {
            .code => |code| o.exit_code = code,
            .signal => |sig| o.signal = sig,
        };
        if (p.tags.len > 0) o.tags = p.tags;
        if (p.float) |f| {
            const e = f.explicit;
            o.layer = "float";
            o.float = .{ .preset = f.preset, .width = e.width, .height = e.height, .anchor = if (e.anchor) |v| @tagName(v) else null, .x = e.x, .y = e.y, .min_cols = e.min_cols, .min_rows = e.min_rows, .border = if (e.border) |v| @tagName(v) else null, .title = e.title, .z = f.z };
        }
        if (p.text == .plain) {
            const plain = p.text.plain;
            o.text.saved_at = try t.dupe(u8, &formatTime(plain.saved_at_ms));
            o.text.expires_at = try t.dupe(u8, &formatTime(plain.expires_at_ms));
            o.text.screen = plain.screen;
            o.text.history = plain.history;
        }
    }
    // Format 3 split nodes carry their live ratio, omitted when equal.
    const windows = cp.windows;
    const sessions = try t.alloc(SessionOut, cp.sessions.len);
    for (cp.sessions, sessions) |x, *o| o.* = .{ .session = x.session, .name = x.name, .on_empty = if (x.on_empty == .remove) "remove" else null };
    const captured = formatTime(cp.captured_at_ms);
    const payload = try std.json.Stringify.valueAlloc(t, .{
        .checkpoint = cp.checkpoint,
        .generation = cp.generation,
        .socket = cp.socket,
        .uid = cp.uid,
        .captured_at = @as([]const u8, &captured),
        .shutdown = @tagName(cp.shutdown),
        .sessions = sessions,
        .windows = windows,
        .panes = panes,
    }, .{ .emit_null_optional_fields = false });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    const envelope = try std.json.Stringify.valueAlloc(t, .{ .format = current_format, .payload = payload, .sha256 = @as([]const u8, &hex) }, .{});
    const out = try a.alloc(u8, envelope.len + 1);
    @memcpy(out[0..envelope.len], envelope);
    out[envelope.len] = '\n';
    return out;
}

// ---------------------------------------------------------------- reader

pub const Failure = enum {
    /// Checksum, schema, topology or store-identity mismatch.
    corrupt,
    /// A format this reader does not know (not 1, 2 or 3).
    incompatible,
    /// Whole-file, count or depth bounds exceeded.
    size,
};
pub const Expect = struct {
    /// The filename's checkpoint ID.
    checkpoint: []const u8,
    socket: []const u8,
    uid: u32,
    max_bytes: usize,
};
pub const Decoded = union(enum) { ok: Checkpoint, bad: Failure };

/// Nesting depth and object count of JSON text, without allocating.
fn shape(bytes: []const u8) struct { depth: usize, objects: usize } {
    var depth: usize = 0;
    var deepest: usize = 0;
    var objects: usize = 0;
    var in_string = false;
    var escaped = false;
    for (bytes) |ch| {
        if (in_string) {
            if (escaped) escaped = false else if (ch == '\\') escaped = true else if (ch == '"') in_string = false;
            continue;
        }
        switch (ch) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                deepest = @max(deepest, depth);
                if (ch == '{') objects += 1;
            },
            '}', ']' => depth -|= 1,
            else => {},
        }
    }
    return .{ .depth = deepest, .objects = objects };
}
const Bad = error{ Corrupt, Incompatible, Size, OutOfMemory };
fn parseJson(a: std.mem.Allocator, bytes: []const u8) Bad!Value {
    const s = shape(bytes);
    if (s.depth > max_depth) return error.Size;
    // Sessions, windows, panes (and their text, float and tag objects) and
    // nodes are the only repeated objects; a payload over the bound is
    // rejected before parsing.
    if (s.objects > (3 + chrome.max_tags) * max_resources + 2) return error.Size;
    return std.json.parseFromSliceLeaky(Value, a, bytes, .{ .duplicate_field_behavior = .@"error", .max_value_len = bytes.len }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Corrupt,
    };
}
fn keys(obj: std.json.ObjectMap, required: []const []const u8, optional: []const []const u8) Bad!void {
    for (required) |k| if (!obj.contains(k)) return error.Corrupt;
    var it = obj.iterator();
    outer: while (it.next()) |e| {
        for (required) |k| if (eq(u8, k, e.key_ptr.*)) continue :outer;
        for (optional) |k| if (eq(u8, k, e.key_ptr.*)) continue :outer;
        return error.Corrupt;
    }
}
fn object(v: Value) Bad!std.json.ObjectMap {
    return if (v == .object) v.object else error.Corrupt;
}
fn array(v: Value) Bad![]Value {
    return if (v == .array) v.array.items else error.Corrupt;
}
fn string(v: Value) Bad![]const u8 {
    return if (v == .string) v.string else error.Corrupt;
}
fn integer(v: Value, min: u64, max: u64) Bad!u64 {
    if (v != .integer or v.integer < 0) return error.Corrupt;
    const n: u64 = @intCast(v.integer);
    if (n < min or n > max) return error.Corrupt;
    return n;
}
fn signed(v: Value, bound: i64) Bad!i32 {
    if (v != .integer or v.integer < -bound or v.integer > bound) return error.Corrupt;
    return @intCast(v.integer);
}
fn choice(comptime E: type, v: Value) Bad!E {
    return std.meta.stringToEnum(E, try string(v)) orelse error.Corrupt;
}
fn time(v: Value) Bad!i64 {
    return parseTime(try string(v)) orelse error.Corrupt;
}

/// Strict decode of a whole file. `a` should be an arena: every allocation
/// lives as long as the returned checkpoint.
pub fn decode(a: std.mem.Allocator, bytes: []const u8, expect: Expect) error{OutOfMemory}!Decoded {
    return .{ .ok = decodeInner(a, bytes, expect) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Corrupt => .{ .bad = .corrupt },
        error.Incompatible => .{ .bad = .incompatible },
        error.Size => .{ .bad = .size },
    } };
}
fn decodeInner(a: std.mem.Allocator, bytes: []const u8, expect: Expect) Bad!Checkpoint {
    if (bytes.len > @min(expect.max_bytes, hard_max_bytes)) return error.Size;
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.Corrupt;
    const outer = try object(try parseJson(a, bytes));
    // Version first: no best-effort interpretation of another format.
    const format = outer.get("format") orelse return error.Corrupt;
    if (format != .integer) return error.Corrupt;
    if (format.integer < oldest_format or format.integer > current_format) return error.Incompatible;
    const version: u8 = @intCast(format.integer);
    try keys(outer, &.{ "format", "payload", "sha256" }, &.{});
    const payload = try string(outer.get("payload").?);
    const sum = try string(outer.get("sha256").?);
    if (sum.len != 64) return error.Corrupt;
    for (sum) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return error.Corrupt;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    if (!eq(u8, &std.fmt.bytesToHex(digest, .lower), sum)) return error.Corrupt;
    const p = try object(try parseJson(a, payload));
    try keys(p, &.{ "checkpoint", "generation", "socket", "uid", "captured_at", "shutdown", "sessions", "windows", "panes" }, &.{});
    const id = try string(p.get("checkpoint").?);
    if (!validId(id) or !eq(u8, id, expect.checkpoint)) return error.Corrupt;
    const generation = try integer(p.get("generation").?, 1, max_safe);
    if (!eq(u8, try string(p.get("socket").?), expect.socket)) return error.Corrupt;
    if (try integer(p.get("uid").?, 0, max_safe) != expect.uid) return error.Corrupt;
    const captured = try time(p.get("captured_at").?);
    const shutdown = try choice(Shutdown, p.get("shutdown").?);
    const sessions_v = try array(p.get("sessions").?);
    const windows_v = try array(p.get("windows").?);
    const panes_v = try array(p.get("panes").?);
    var total: usize = sessions_v.len + windows_v.len + panes_v.len;
    if (total > max_resources) return error.Size;
    for (windows_v) |w| if (w == .object) if (w.object.get("nodes")) |n| if (n == .array) {
        total += n.array.items.len;
    };
    if (total > max_resources) return error.Size;

    const sessions = try a.alloc(SessionRec, sessions_v.len);
    var last: ?u64 = null;
    for (sessions_v, sessions) |v, *s| {
        const o = try object(v);
        try keys(o, &.{ "session", "name" }, &.{"on_empty"});
        s.* = .{ .session = try string(o.get("session").?), .name = try string(o.get("name").?) };
        if (o.get("on_empty")) |policy| s.on_empty = try removeOnly(policy);
        const n = resourceNumber('s', s.session) orelse return error.Corrupt;
        if (last != null and n <= last.?) return error.Corrupt;
        last = n;
        if (!nameValid(s.name)) return error.Corrupt;
    }
    const windows = try a.alloc(WindowRec, windows_v.len);
    last = null;
    for (windows_v, windows) |v, *w| {
        const o = try object(v);
        try keys(o, &.{ "window", "session", "name", "revision", "nodes" }, &.{});
        w.* = .{ .window = try string(o.get("window").?), .session = try string(o.get("session").?), .name = try string(o.get("name").?), .revision = try integer(o.get("revision").?, 1, max_safe), .nodes = &.{} };
        const n = resourceNumber('w', w.window) orelse return error.Corrupt;
        if (last != null and n <= last.?) return error.Corrupt;
        last = n;
        if (!nameValid(w.name) or findSession(sessions, w.session) == null) return error.Corrupt;
        const nodes_v = try array(o.get("nodes").?);
        const nodes = try a.alloc(Node, nodes_v.len);
        for (nodes_v, nodes) |nv, *node| {
            const no = try object(nv);
            const kind = no.get("kind") orelse return error.Corrupt;
            if (eq(u8, try string(kind), "pane")) {
                try keys(no, &.{ "kind", "pane" }, &.{});
                node.* = .{ .kind = .pane, .pane = try string(no.get("pane").?) };
                if (resourceNumber('p', node.pane.?) == null) return error.Corrupt;
            } else if (eq(u8, kind.string, "split")) {
                // Formats 1 and 2 hold no ratio: their splits restore equal.
                try keys(no, &.{ "kind", "axis", "first", "second" }, if (version >= 3) &.{"ratio"} else &.{});
                node.* = .{ .kind = .split, .axis = try choice(layout.Axis, no.get("axis").?), .first = @intCast(try integer(no.get("first").?, 0, nodes_v.len)), .second = @intCast(try integer(no.get("second").?, 0, nodes_v.len)) };
                if (no.get("ratio")) |r| node.ratio = @intCast(try integer(r, 1, layout.ratio_scale - 1));
            } else return error.Corrupt;
        }
        // Preorder indexes, no cycles, no extra or orphan nodes, unique leaves.
        if (!layout.valid(nodes)) return error.Corrupt;
        w.nodes = nodes;
    }
    const panes = try a.alloc(PaneRec, panes_v.len);
    last = null;
    for (panes_v, panes) |v, *pr| {
        const o = try object(v);
        const optional: []const []const u8 = if (version >= 2) &.{ "exit_code", "signal", "previous_state", "on_exit", "layer", "float", "tags" } else &.{ "exit_code", "signal", "previous_state", "on_exit" };
        try keys(o, &.{ "pane", "window", "session", "cols", "rows", "state", "text" }, optional);
        pr.* = .{ .pane = try string(o.get("pane").?), .window = try string(o.get("window").?), .session = try string(o.get("session").?), .cols = @intCast(try integer(o.get("cols").?, 1, 65535)), .rows = @intCast(try integer(o.get("rows").?, 1, 65535)), .state = try choice(State, o.get("state").?) };
        const n = resourceNumber('p', pr.pane) orelse return error.Corrupt;
        if (last != null and n <= last.?) return error.Corrupt;
        last = n;
        const w = findWindow(windows, pr.window) orelse return error.Corrupt;
        if (!eq(u8, w.session, pr.session)) return error.Corrupt;
        const code = o.get("exit_code");
        const signal = o.get("signal");
        const previous = o.get("previous_state");
        if (pr.state == .running and (code != null or signal != null or previous != null)) return error.Corrupt;
        if (code != null and signal != null) return error.Corrupt;
        if (code) |c| pr.exit = .{ .code = @intCast(try integer(c, 0, 255)) };
        if (signal) |sv| {
            const name = try string(sv);
            if (!signalValid(name)) return error.Corrupt;
            pr.exit = .{ .signal = name };
        }
        if (previous) |pv| pr.previous_state = try choice(ProcessState, pv);
        if (o.get("on_exit")) |policy| pr.on_exit = try removeOnly(policy);
        // The canonical encoding omits the default layer; a float carries
        // its placement record, and nothing else does.
        if (o.get("layer")) |lv| {
            if (lv != .string or !eq(u8, lv.string, "float")) return error.Corrupt;
            pr.layer = .float;
        }
        if ((pr.layer == .float) != (o.get("float") != null)) return error.Corrupt;
        if (o.get("float")) |fv| pr.float = try decodeFloat(try object(fv));
        if (o.get("tags")) |tv| pr.tags = try decodeTags(a, try array(tv));
        if (shutdown == .clean and pr.state == .running) return error.Corrupt;
        pr.text = try decodeText(a, try object(o.get("text").?), pr.rows);
    }
    // Every leaf refers to exactly one tiled pane of its window; every tiled
    // pane appears once and no float appears in a tree.
    for (windows) |w| for (w.nodes) |node| if (node.kind == .pane) {
        const pr = findPane(panes, node.pane.?) orelse return error.Corrupt;
        if (!eq(u8, pr.window, w.window) or pr.layer != .tile) return error.Corrupt;
    };
    for (panes) |pr| {
        var seen: usize = 0;
        for (findWindow(windows, pr.window).?.nodes) |node| if (node.kind == .pane and eq(u8, node.pane.?, pr.pane)) {
            seen += 1;
        };
        if (seen != @as(usize, if (pr.layer == .tile) 1 else 0)) return error.Corrupt;
    }
    return .{ .checkpoint = id, .generation = generation, .socket = expect.socket, .uid = expect.uid, .captured_at_ms = captured, .shutdown = shutdown, .sessions = sessions, .windows = windows, .panes = panes };
}
/// Canonical tags: 1–16 pairs with pane tag syntax, strictly ascending
/// by key (so no duplicates). An empty map is written by omission.
fn decodeTags(a: std.mem.Allocator, items: []Value) Bad![]const chrome.Tag {
    if (items.len == 0) return error.Corrupt;
    if (items.len > chrome.max_tags) return error.Size;
    const out = try a.alloc(chrome.Tag, items.len);
    for (items, out, 0..) |v, *t, i| {
        const o = try object(v);
        try keys(o, &.{ "key", "value" }, &.{});
        t.* = .{ .key = try string(o.get("key").?), .value = try string(o.get("value").?) };
        if (!chrome.validKey(t.key) or !chrome.validValue(t.value)) return error.Corrupt;
        if (i > 0 and !std.mem.lessThan(u8, out[i - 1].key, t.key)) return error.Corrupt;
    }
    return out;
}
fn decodeFloat(o: std.json.ObjectMap) Bad!FloatRec {
    try keys(o, &.{"z"}, &.{ "preset", "width", "height", "anchor", "x", "y", "min_cols", "min_rows", "border", "title" });
    var f: FloatRec = .{ .z = try integer(o.get("z").?, 1, max_safe) };
    if (o.get("preset")) |v| {
        const name = try string(v);
        if (!chrome.validSegmentId(name)) return error.Corrupt;
        f.preset = name;
    }
    const e = &f.explicit;
    if (o.get("width")) |v| e.width = try string(v);
    if (o.get("height")) |v| e.height = try string(v);
    if (o.get("anchor")) |v| e.anchor = try choice(floats.Anchor, v);
    if (o.get("x")) |v| e.x = try signed(v, floats.max_offset);
    if (o.get("y")) |v| e.y = try signed(v, floats.max_offset);
    if (o.get("min_cols")) |v| e.min_cols = @intCast(try integer(v, 1, 65535));
    if (o.get("min_rows")) |v| e.min_rows = @intCast(try integer(v, 1, 65535));
    if (o.get("border")) |v| e.border = try choice(floats.Border, v);
    if (o.get("title")) |v| e.title = try string(v);
    if (e.invalid() != null) return error.Corrupt;
    return f;
}
fn decodeText(a: std.mem.Allocator, o: std.json.ObjectMap, rows: u16) Bad!Text {
    const availability = try string(o.get("availability") orelse return error.Corrupt);
    if (eq(u8, availability, "omitted") or eq(u8, availability, "expired")) {
        try keys(o, &.{"availability"}, &.{});
        return if (availability[0] == 'o') .omitted else .expired;
    }
    if (!eq(u8, availability, "plain")) return error.Corrupt;
    try keys(o, &.{ "availability", "saved_at", "expires_at", "screen", "history" }, &.{});
    const screen_v = try array(o.get("screen").?);
    const history_v = try array(o.get("history").?);
    if (screen_v.len != rows) return error.Corrupt;
    if (screen_v.len + history_v.len > text_max_rows) return error.Size;
    var bytes: usize = 0;
    const screen = try a.alloc([]const u8, screen_v.len);
    const history = try a.alloc([]const u8, history_v.len);
    for ([_][]Value{ screen_v, history_v }, [_][][]const u8{ screen, history }) |src, dst| for (src, dst) |v, *d| {
        d.* = try string(v);
        bytes += d.len;
        if (bytes > text_max_bytes) return error.Size;
        if (!plainRowValid(d.*)) return error.Corrupt;
    };
    return .{ .plain = .{ .saved_at_ms = try time(o.get("saved_at").?), .expires_at_ms = try time(o.get("expires_at").?), .screen = screen, .history = history } };
}
fn findSession(list: []const SessionRec, id: []const u8) ?*const SessionRec {
    for (list) |*s| if (eq(u8, s.session, id)) return s;
    return null;
}
fn findWindow(list: []const WindowRec, id: []const u8) ?*const WindowRec {
    for (list) |*w| if (eq(u8, w.window, id)) return w;
    return null;
}
/// The canonical encoding omits the default, so only "remove" is accepted.
fn removeOnly(v: Value) !Policy {
    if (v != .string or !eq(u8, v.string, "remove")) return error.Corrupt;
    return .remove;
}
fn findPane(list: []const PaneRec, id: []const u8) ?*const PaneRec {
    for (list) |*p| if (eq(u8, p.pane, id)) return p;
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const sample_id = "c01234567-89ab-4cde-8fab-0123456789ab";
const expect_sample: Expect = .{ .checkpoint = sample_id, .socket = "/run/user/1000/venomx.sock", .uid = 1000, .max_bytes = 16777216 };
fn wrap(a: std.mem.Allocator, payload: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.json.Stringify.valueAlloc(a, .{ .format = @as(u8, 1), .payload = payload, .sha256 = @as([]const u8, &hex) }, .{});
}
const rfc_example =
    \\{"checkpoint":"c01234567-89ab-4cde-8fab-0123456789ab","generation":1,"socket":"/run/user/1000/venomx.sock","uid":1000,"captured_at":"2026-11-06T22:00:00.000Z","shutdown":"open","sessions":[{"session":"s0","name":"work"}],"windows":[{"window":"w0","session":"s0","name":"shell","revision":1,"nodes":[{"kind":"pane","pane":"p0"}]}],"panes":[{"pane":"p0","window":"w0","session":"s0","cols":80,"rows":24,"state":"running","text":{"availability":"omitted"}}]}
;
fn decodeSample(a: std.mem.Allocator, payload: []const u8) !Decoded {
    return decode(a, try wrap(a, payload), expect_sample);
}

test "format: documented example decodes and round-trips through the encoder" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const d = try decodeSample(a, rfc_example);
    const cp = d.ok;
    try testing.expectEqual(@as(u64, 1), cp.generation);
    try testing.expectEqualStrings("work", cp.sessions[0].name);
    try testing.expectEqual(State.running, cp.panes[0].state);
    const bytes = try encode(a, cp);
    try testing.expect(bytes[bytes.len - 1] == '\n');
    const again = try decode(a, bytes, expect_sample);
    try testing.expectEqual(@as(i64, 1794002400000), again.ok.captured_at_ms);
    // The encoder's payload is byte-identical to the documented canonical example.
    const outer = try std.json.parseFromSliceLeaky(Value, a, bytes, .{});
    try testing.expectEqualStrings(rfc_example, outer.object.get("payload").?.string);
}

test "format: corrupt, incompatible and oversized input fail without salvage" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try wrap(a, rfc_example);
    // Truncation, trailing data, bad checksum, invalid UTF-8.
    try testing.expectEqual(Failure.corrupt, (try decode(a, good[0 .. good.len / 2], expect_sample)).bad);
    try testing.expectEqual(Failure.corrupt, (try decode(a, try std.mem.concat(a, u8, &.{ good, "{}" }), expect_sample)).bad);
    const flipped = try a.dupe(u8, good);
    flipped[std.mem.indexOf(u8, flipped, "work").?] = 'W';
    try testing.expectEqual(Failure.corrupt, (try decode(a, flipped, expect_sample)).bad);
    try testing.expectEqual(Failure.corrupt, (try decode(a, "{\"format\":1,\"payload\":\"\xff\",\"sha256\":\"\"}", expect_sample)).bad);
    // Duplicate keys at either level; unknown fields at any level.
    try testing.expectEqual(Failure.corrupt, (try decode(a, "{\"format\":1,\"format\":1,\"payload\":\"\",\"sha256\":\"\"}", expect_sample)).bad);
    const dup_inner = try std.mem.replaceOwned(u8, a, rfc_example, "\"generation\":1,", "\"generation\":1,\"generation\":2,");
    try testing.expectEqual(Failure.corrupt, (try decodeSample(a, dup_inner)).bad);
    const unknown = try std.mem.replaceOwned(u8, a, rfc_example, "\"availability\":\"omitted\"", "\"availability\":\"omitted\",\"argv\":[\"sh\"]");
    try testing.expectEqual(Failure.corrupt, (try decodeSample(a, unknown)).bad);
    // Version mismatch is incompatible, never best-effort.
    try testing.expectEqual(Failure.incompatible, (try decode(a, "{\"format\":4,\"payload\":\"x\",\"sha256\":\"0\"}", expect_sample)).bad);
    try testing.expectEqual(Failure.incompatible, (try decode(a, "{\"format\":0,\"payload\":\"x\",\"sha256\":\"0\"}", expect_sample)).bad);
    // Whole-file and depth bounds precede parsing.
    var small = expect_sample;
    small.max_bytes = 100;
    try testing.expectEqual(Failure.size, (try decode(a, good, small)).bad);
    const deep = try a.alloc(u8, 66);
    @memset(deep[0..33], '[');
    @memset(deep[33..], ']');
    try testing.expectEqual(Failure.size, (try decode(a, deep, expect_sample)).bad);
    // Unsafe integers, wrong store identity, duplicate IDs, invalid tree.
    for ([_][2][]const u8{
        .{ "\"generation\":1", "\"generation\":9007199254740992" },
        .{ "\"generation\":1", "\"generation\":1.0" },
        .{ "\"uid\":1000", "\"uid\":1001" },
        .{ "venomx.sock", "other.sock" },
        .{ "\"cols\":80", "\"cols\":0" },
        .{ "\"state\":\"running\"", "\"state\":\"running\",\"exit_code\":0" },
        .{ "\"shutdown\":\"open\"", "\"shutdown\":\"clean\"" },
        .{ "{\"kind\":\"pane\",\"pane\":\"p0\"}", "{\"kind\":\"pane\",\"pane\":\"p0\"},{\"kind\":\"pane\",\"pane\":\"p0\"}" },
        .{ "{\"kind\":\"pane\",\"pane\":\"p0\"}", "{\"kind\":\"split\",\"axis\":\"cols\",\"first\":0,\"second\":0}" },
        .{ "{\"kind\":\"pane\",\"pane\":\"p0\"}]", "]" },
        .{ "\"window\":\"w0\",\"session\":\"s0\",\"name\"", "\"window\":\"w0\",\"session\":\"s9\",\"name\"" },
        .{ "c01234567-89ab-4cde-8fab-0123456789ab", "c01234567-89ab-4cde-8fab-0123456789ac" },
        .{ "\"captured_at\":\"2026-11-06T22:00:00.000Z\"", "\"captured_at\":\"2026-11-06T22:00:00Z\"" },
    }) |swap| {
        const bad = try std.mem.replaceOwned(u8, a, rfc_example, swap[0], swap[1]);
        try testing.expect(!eq(u8, bad, rfc_example));
        try testing.expect((try decodeSample(a, bad)) == .bad);
    }
}

test "format: nested topology, exited panes, empty containers and plain text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var screen = [_][]const u8{ "ready ✓", "" };
    var history = [_][]const u8{"previous"};
    var panes = [_]PaneRec{
        .{ .pane = "p1", .window = "w1", .session = "s1", .cols = 10, .rows = 2, .state = .exited, .exit = .{ .code = 3 }, .text = .{ .plain = .{ .saved_at_ms = 1000, .expires_at_ms = 2000, .screen = &screen, .history = &history } } },
        .{ .pane = "p2", .window = "w1", .session = "s1", .cols = 10, .rows = 2, .state = .exited, .exit = .{ .signal = "SIGXCPU" }, .previous_state = .interrupted, .on_exit = .remove },
        .{ .pane = "p7", .window = "w1", .session = "s1", .cols = 10, .rows = 2, .state = .exited, .text = .expired },
    };
    const nodes = [_]Node{
        .{ .kind = .split, .axis = .cols, .first = 1, .second = 2 },
        .{ .kind = .pane, .pane = "p1" },
        .{ .kind = .split, .axis = .rows, .first = 3, .second = 4 },
        .{ .kind = .pane, .pane = "p2" },
        .{ .kind = .pane, .pane = "p7" },
    };
    const cp: Checkpoint = .{ .checkpoint = sample_id, .generation = 5, .socket = expect_sample.socket, .uid = 1000, .captured_at_ms = 1500, .shutdown = .clean, .sessions = &.{ .{ .session = "s0", .name = "" }, .{ .session = "s1", .name = "x", .on_empty = .remove } }, .windows = &.{ .{ .window = "w0", .session = "s0", .name = "empty", .revision = 9, .nodes = &.{} }, .{ .window = "w1", .session = "s1", .name = "", .revision = 4, .nodes = &nodes } }, .panes = &panes };
    const back = (try decode(a, try encode(a, cp), expect_sample)).ok;
    try testing.expectEqual(@as(usize, 2), back.sessions.len);
    try testing.expectEqual(@as(usize, 0), back.windows[0].nodes.len);
    try testing.expectEqualStrings("ready ✓", back.panes[0].text.plain.screen[0]);
    try testing.expectEqualStrings("SIGXCPU", back.panes[1].exit.?.signal);
    try testing.expectEqual(ProcessState.interrupted, back.panes[1].previous_state.?);
    try testing.expectEqual(Text.expired, back.panes[2].text);
    // Recorded policies round-trip; defaults are not written.
    try testing.expectEqual(Policy.remove, back.panes[1].on_exit);
    try testing.expectEqual(Policy.keep, back.panes[0].on_exit);
    try testing.expectEqual(Policy.remove, back.sessions[1].on_empty);
    try testing.expectEqual(Policy.keep, back.sessions[0].on_empty);
    const bytes = try encode(a, cp);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "on_exit"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "on_empty"));
    // Only the non-default spelling is canonical.
    const keep = try wrap(a, "{\"checkpoint\":\"c01234567-89ab-4cde-8fab-0123456789ab\",\"generation\":1,\"socket\":\"/run/user/1000/venomx.sock\",\"uid\":1000,\"captured_at\":\"2026-11-06T22:00:00.000Z\",\"shutdown\":\"open\",\"sessions\":[{\"session\":\"s0\",\"name\":\"work\",\"on_empty\":\"keep\"}],\"windows\":[],\"panes\":[]}");
    try testing.expectEqual(Failure.corrupt, (try decode(a, keep, expect_sample)).bad);
    // A control character in plain text never decodes.
    screen[1] = "\x1b[2J";
    try testing.expectEqual(Failure.corrupt, (try decode(a, try encode(a, cp), expect_sample)).bad);
}

fn wrapAt(a: std.mem.Allocator, version: u8, payload: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.json.Stringify.valueAlloc(a, .{ .format = version, .payload = payload, .sha256 = @as([]const u8, &hex) }, .{});
}

test "format 2: floats round-trip with preset, explicit fields and z; never in a tree" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var panes = [_]PaneRec{
        .{ .pane = "p0", .window = "w0", .session = "s0", .cols = 80, .rows = 24, .state = .running },
        .{ .pane = "p1", .window = "w0", .session = "s0", .cols = 40, .rows = 10, .state = .running, .layer = .float, .float = .{ .preset = "venom.settings", .explicit = .{ .width = "50%", .anchor = .top_left, .x = -3, .border = .heavy, .title = "logs ✓" }, .z = 7 } },
        .{ .pane = "p2", .window = "w0", .session = "s0", .cols = 20, .rows = 5, .state = .running, .layer = .float, .float = .{ .z = 3 } },
    };
    const nodes = [_]Node{.{ .kind = .pane, .pane = "p0" }};
    const cp: Checkpoint = .{ .checkpoint = sample_id, .generation = 2, .socket = expect_sample.socket, .uid = 1000, .captured_at_ms = 1500, .shutdown = .open, .sessions = &.{.{ .session = "s0", .name = "" }}, .windows = &.{.{ .window = "w0", .session = "s0", .name = "", .revision = 1, .nodes = &nodes }}, .panes = &panes };
    const bytes = try encode(a, cp);
    try testing.expect(std.mem.startsWith(u8, bytes, "{\"format\":3,"));
    const back = (try decode(a, bytes, expect_sample)).ok;
    try testing.expectEqual(Layer.tile, back.panes[0].layer);
    try testing.expect(back.panes[0].float == null);
    const f = back.panes[1].float.?;
    try testing.expectEqual(Layer.float, back.panes[1].layer);
    try testing.expectEqualStrings("venom.settings", f.preset.?);
    try testing.expectEqualStrings("50%", f.explicit.width.?);
    try testing.expect(f.explicit.height == null and f.explicit.y == null);
    try testing.expectEqual(floats.Anchor.top_left, f.explicit.anchor.?);
    try testing.expectEqual(@as(i32, -3), f.explicit.x.?);
    try testing.expectEqual(floats.Border.heavy, f.explicit.border.?);
    try testing.expectEqualStrings("logs ✓", f.explicit.title.?);
    try testing.expectEqual(@as(u64, 7), f.z);
    try testing.expect(back.panes[2].float.?.preset == null);
    try testing.expectEqual(@as(u64, 3), back.panes[2].float.?.z);
    // Tiled panes carry neither field; the default layer is never written.
    const payload = (try std.json.parseFromSliceLeaky(Value, a, bytes, .{})).object.get("payload").?.string;
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, payload, "\"layer\":\"float\""));
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, payload, "\"tile\""));
    // Broken float records never decode.
    for ([_][2][]const u8{
        .{ "\"layer\":\"float\",", "" }, // float without layer
        .{ "\"layer\":\"float\"", "\"layer\":\"popup\"" },
        .{ "\"layer\":\"float\"", "\"layer\":\"tile\"" },
        .{ "\"z\":3", "\"z\":0" },
        .{ "\"z\":3", "\"z\":3,\"client\":\"k0\"" },
        .{ "\"width\":\"50%\"", "\"width\":\"150%\"" },
        .{ "\"x\":-3", "\"x\":-5000" },
        .{ "\"anchor\":\"top_left\"", "\"anchor\":\"middle\"" },
        .{ "\"preset\":\"venom.settings\"", "\"preset\":\"settings\"" },
        .{ "{\"kind\":\"pane\",\"pane\":\"p0\"}", "{\"kind\":\"split\",\"axis\":\"cols\",\"first\":1,\"second\":2},{\"kind\":\"pane\",\"pane\":\"p0\"},{\"kind\":\"pane\",\"pane\":\"p2\"}" }, // a float in the tree
    }) |swap| {
        const bad = try std.mem.replaceOwned(u8, a, payload, swap[0], swap[1]);
        try testing.expect(!eq(u8, bad, payload));
        try testing.expect((try decode(a, try wrapAt(a, 2, bad), expect_sample)) == .bad);
    }
    // The same payload under format 1 is corrupt: format 1 has no float layer.
    try testing.expectEqual(Failure.corrupt, (try decode(a, try wrapAt(a, 1, payload), expect_sample)).bad);
    // A format-1 checkpoint still decodes, and format 2 reads it unchanged.
    try testing.expectEqual(Layer.tile, (try decode(a, try wrapAt(a, 1, rfc_example), expect_sample)).ok.panes[0].layer);
    try testing.expectEqual(Layer.tile, (try decode(a, try wrapAt(a, 2, rfc_example), expect_sample)).ok.panes[0].layer);
}

test "format 2: pane tags round-trip, owner included; non-canonical tags never decode" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tags = [_]chrome.Tag{ .{ .key = "group", .value = "thread-7" }, .{ .key = "owner", .value = "venom" }, .{ .key = "role", .value = "agent ✓" } };
    var panes = [_]PaneRec{
        .{ .pane = "p0", .window = "w0", .session = "s0", .cols = 80, .rows = 24, .state = .running, .tags = &tags },
        .{ .pane = "p1", .window = "w0", .session = "s0", .cols = 80, .rows = 24, .state = .running },
    };
    const nodes = [_]Node{ .{ .kind = .split, .axis = .cols, .first = 1, .second = 2 }, .{ .kind = .pane, .pane = "p0" }, .{ .kind = .pane, .pane = "p1" } };
    const cp: Checkpoint = .{ .checkpoint = sample_id, .generation = 2, .socket = expect_sample.socket, .uid = 1000, .captured_at_ms = 1500, .shutdown = .open, .sessions = &.{.{ .session = "s0", .name = "" }}, .windows = &.{.{ .window = "w0", .session = "s0", .name = "", .revision = 1, .nodes = &nodes }}, .panes = &panes };
    const bytes = try encode(a, cp);
    const back = (try decode(a, bytes, expect_sample)).ok;
    try testing.expectEqual(@as(usize, 3), back.panes[0].tags.len);
    try testing.expectEqualStrings("owner", back.panes[0].tags[1].key);
    try testing.expectEqualStrings("venom", back.panes[0].tags[1].value);
    try testing.expectEqualStrings("agent ✓", back.panes[0].tags[2].value);
    try testing.expectEqual(@as(usize, 0), back.panes[1].tags.len);
    const payload = (try std.json.parseFromSliceLeaky(Value, a, bytes, .{})).object.get("payload").?.string;
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, payload, "\"tags\""));
    for ([_][2][]const u8{
        .{ "{\"key\":\"group\",\"value\":\"thread-7\"},", "" ++ "{\"key\":\"role\",\"value\":\"x\"}," }, // unsorted / duplicate
        .{ "\"key\":\"group\"", "\"key\":\"Group\"" },
        .{ "\"value\":\"thread-7\"", "\"value\":\"\"" },
        .{ "\"value\":\"thread-7\"", "\"value\":\"a\\u001bb\"" },
        .{ "\"value\":\"thread-7\"", "\"value\":\"thread-7\",\"scope\":\"x\"" },
        .{ "\"rows\":24,\"state\":\"running\",\"text\":{\"availability\":\"omitted\"}}]", "\"rows\":24,\"state\":\"running\",\"tags\":[],\"text\":{\"availability\":\"omitted\"}}]" },
    }) |swap| {
        const bad = try std.mem.replaceOwned(u8, a, payload, swap[0], swap[1]);
        try testing.expect(!eq(u8, bad, payload));
        try testing.expect((try decode(a, try wrapAt(a, 2, bad), expect_sample)) == .bad);
    }
    // Format 1 has no tags.
    try testing.expectEqual(Failure.corrupt, (try decode(a, try wrapAt(a, 1, payload), expect_sample)).bad);
}

test "format: identifiers and timestamps are canonical" {
    try testing.expect(validId(sample_id));
    try testing.expect(!validId("c01234567-89ab-1cde-8fab-0123456789ab"));
    try testing.expect(!validId("C01234567-89ab-4cde-8fab-0123456789ab"));
    try testing.expect(!validId("../../etc/passwd"));
    const id = newId(&@splat(0xff));
    try testing.expect(validId(&id));
    try testing.expectEqual(@as(?u64, 12), resourceNumber('p', "p12"));
    try testing.expect(resourceNumber('p', "p012") == null);
    try testing.expectEqualStrings("1970-01-01T00:00:00.000Z", &formatTime(0));
    const t = parseTime("2024-02-29T23:59:59.999Z").?;
    try testing.expectEqualStrings("2024-02-29T23:59:59.999Z", &formatTime(t));
    try testing.expect(parseTime("2023-02-29T00:00:00.000Z") == null);
    try testing.expect(signalValid("SIGRTMIN1"));
    try testing.expect(!signalValid("SIGkill"));
}
/// The documented format-3 example payload.
const rfc_example_3 =
    \\{"checkpoint":"c01234567-89ab-4cde-8fab-0123456789ab","generation":3,"socket":"/run/user/1000/venomx.sock","uid":1000,"captured_at":"2026-11-09T12:00:00.000Z","shutdown":"open","sessions":[{"session":"s0","name":"work"}],"windows":[{"window":"w0","session":"s0","name":"agents","revision":4,"nodes":[{"kind":"split","axis":"cols","first":1,"second":2,"ratio":6250},{"kind":"pane","pane":"p0"},{"kind":"split","axis":"rows","first":3,"second":4},{"kind":"pane","pane":"p1"},{"kind":"pane","pane":"p2"}]}],"panes":[{"pane":"p0","window":"w0","session":"s0","cols":50,"rows":24,"state":"running","tags":[{"key":"owner","value":"venomx"}],"text":{"availability":"omitted"}},{"pane":"p1","window":"w0","session":"s0","cols":29,"rows":12,"state":"running","tags":[{"key":"owner","value":"venomx"}],"text":{"availability":"omitted"}},{"pane":"p2","window":"w0","session":"s0","cols":29,"rows":11,"state":"running","tags":[{"key":"owner","value":"venomx"}],"text":{"availability":"omitted"}}]}
;
test "format 3: split ratios round-trip; the documented example is byte for byte what the writer emits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cp = (try decode(a, try wrapAt(a, 3, rfc_example_3), expect_sample)).ok;
    const nodes = cp.windows[0].nodes;
    try testing.expectEqual(@as(?u16, 6250), nodes[0].ratio);
    // An equal split has no ratio, in memory and on disk.
    try testing.expect(nodes[2].ratio == null);
    const bytes = try encode(a, cp);
    try testing.expect(std.mem.startsWith(u8, bytes, "{\"format\":3,"));
    const outer = try std.json.parseFromSliceLeaky(Value, a, bytes, .{});
    try testing.expectEqualStrings(rfc_example_3, outer.object.get("payload").?.string);
    // Formats 1 and 2 hold no ratio: in them it is an unknown field.
    try testing.expectEqual(Failure.corrupt, (try decode(a, try wrapAt(a, 2, rfc_example_3), expect_sample)).bad);
    try testing.expectEqual(Failure.corrupt, (try decode(a, try wrapAt(a, 1, rfc_example_3), expect_sample)).bad);
    // Without the ratio, the same tree is a valid format-2 file whose splits
    // restore equal.
    const equal = try std.mem.replaceOwned(u8, a, rfc_example_3, ",\"ratio\":6250", "");
    const old = (try decode(a, try wrapAt(a, 2, equal), expect_sample)).ok;
    for (old.windows[0].nodes) |n| try testing.expect(n.ratio == null);
    // The next checkpoint after that is format 3, still without a ratio.
    const rewritten = try encode(a, old);
    try testing.expect(std.mem.startsWith(u8, rewritten, "{\"format\":3,"));
    try testing.expect(std.mem.indexOf(u8, rewritten, "\"ratio\"") == null);
    // Out-of-range or mistyped ratios, and a ratio on a pane node, are corrupt.
    for ([_][]const u8{ "\"ratio\":0", "\"ratio\":10000", "\"ratio\":-1", "\"ratio\":62.5", "\"ratio\":\"6250\"", "\"ratio\":null" }) |bad| {
        const changed = try std.mem.replaceOwned(u8, a, rfc_example_3, "\"ratio\":6250", bad);
        try testing.expectEqual(Failure.corrupt, (try decode(a, try wrapAt(a, 3, changed), expect_sample)).bad);
    }
    // Every ratio in 1–9999 is accepted, even one that draws an equal split.
    for ([_][]const u8{ "\"ratio\":1", "\"ratio\":5000", "\"ratio\":9999" }) |edge| {
        const changed = try std.mem.replaceOwned(u8, a, rfc_example_3, "\"ratio\":6250", edge);
        _ = (try decode(a, try wrapAt(a, 3, changed), expect_sample)).ok;
    }
    const on_pane = try std.mem.replaceOwned(u8, a, rfc_example_3, "{\"kind\":\"pane\",\"pane\":\"p0\"}", "{\"kind\":\"pane\",\"pane\":\"p0\",\"ratio\":5000}");
    try testing.expectEqual(Failure.corrupt, (try decode(a, try wrapAt(a, 3, on_pane), expect_sample)).bad);
}
test "format 3 keeps a resized split's ratio through encode and decode" {
    const a = testing.allocator;
    const nodes = [_]Node{ .{ .kind = .split, .axis = .cols, .first = 1, .second = 2, .ratio = 2500 }, .{ .kind = .pane, .pane = "p0" }, .{ .kind = .pane, .pane = "p1" } };
    var panes = [_]PaneRec{
        .{ .pane = "p0", .window = "w0", .session = "s0", .cols = 80, .rows = 24, .state = .exited, .text = .omitted },
        .{ .pane = "p1", .window = "w0", .session = "s0", .cols = 80, .rows = 24, .state = .exited, .text = .omitted },
    };
    const cp: Checkpoint = .{ .checkpoint = sample_id, .generation = 2, .socket = expect_sample.socket, .uid = 1000, .captured_at_ms = 1500, .shutdown = .open, .sessions = &.{.{ .session = "s0", .name = "" }}, .windows = &.{.{ .window = "w0", .session = "s0", .name = "", .revision = 3, .nodes = &nodes }}, .panes = &panes };
    const bytes = try encode(a, cp);
    defer a.free(bytes);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const back = (try decode(arena.allocator(), bytes, expect_sample)).ok;
    try testing.expectEqual(@as(?u16, 2500), back.windows[0].nodes[0].ratio);
    try testing.expect(back.windows[0].nodes[1].ratio == null);
}
