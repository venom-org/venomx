//! `pane.capture_rows`: selection, limits and pagination over one
//! authoritative Vt, read on the reactor between two `Vt.feed` calls. The
//! daemon keeps no state between pages; `(epoch, next, end)` is the cursor.
const std = @import("std");
const Vt = @import("vt").Vt;

/// `k × cols` never exceeds 2²² cells.
pub const cell_limit: u64 = 1 << 22;
pub const default_max_rows: u64 = 1000;
pub const default_max_bytes: u64 = 262144;
/// Rows exported per `Vt.exportRows` call while filling a page.
const chunk_rows: u64 = 128;

pub const Request = struct {
    tail: ?u64 = null,
    epoch: ?u64 = null,
    start: ?u64 = null,
    end: ?u64 = null,
    max_rows: u64 = default_max_rows,
    max_bytes: u64 = default_max_bytes,
};

pub const Bounds = struct { oldest: u64, active: u64, end: u64 };

/// The result object, in the documented field order.
pub const Page = struct {
    pane: []const u8,
    screen: []const u8,
    epoch: u64,
    offset: u64,
    cols: u16,
    rows: u16,
    bounds: Bounds,
    start: u64,
    end: u64,
    next: ?u64 = null,
    done: bool,
    lines: []const []const u8,
};

pub const State = struct { screen: []const u8, epoch: u64, oldest: u64, end: u64 };
pub const Failure = union(enum) {
    /// invalid_params.rows
    params: struct { param: []const u8, reason: []const u8 },
    /// not_found.rows
    rows: struct { reason: []const u8, screen: []const u8, epoch: u64, oldest: u64, end: u64, first: u64, last: u64 },
    /// conflict.epoch
    epoch: struct { given: u64, state: State },
    /// unsupported.result_size
    size: struct { row: u64, bytes: u64 },

    pub fn code(self: Failure) []const u8 {
        return switch (self) {
            .params => "invalid_params.rows",
            .rows => "not_found.rows",
            .epoch => "conflict.epoch",
            .size => "unsupported.result_size",
        };
    }
};
pub const Outcome = union(enum) { page: Page, failure: Failure };

fn screenName(vt: Vt) []const u8 {
    return @tagName(vt.screen());
}

/// Read one page. `frame_budget` is the most bytes the encoded result object
/// may take (the connection's `max_frame` minus the response envelope).
/// Everything returned is allocated in `a` (the call arena).
pub fn read(a: std.mem.Allocator, vt: Vt, pane: []const u8, offset: u64, req: Request, frame_budget: u64) !Outcome {
    // Parameter rules, before any pane state is consulted.
    if (req.tail != null and (req.epoch != null or req.start != null or req.end != null)) return .{ .failure = .{ .params = .{ .param = "tail", .reason = "exclusive" } } };
    if (req.epoch == null and (req.start != null or req.end != null)) return .{ .failure = .{ .params = .{ .param = if (req.start != null) "start" else "end", .reason = "epoch_required" } } };
    if (req.start != null and req.end != null and req.end.? < req.start.?) return .{ .failure = .{ .params = .{ .param = "end", .reason = "order" } } };

    const b = vt.rows();
    const size = vt.size();
    const screen = screenName(vt);
    const state: State = .{ .screen = screen, .epoch = b.epoch, .oldest = b.oldest, .end = b.end };
    if (req.epoch) |e| if (e != b.epoch) return .{ .failure = .{ .epoch = .{ .given = e, .state = state } } };
    var s: u64 = b.oldest;
    var e: u64 = b.end;
    if (req.tail) |n| {
        s = if (b.end - b.oldest > n) b.end - n else b.oldest;
    } else {
        if (req.start) |v| s = v;
        if (req.end) |v| e = v;
    }
    // Never clamp: report exactly which rows are missing.
    if (s < b.oldest) return .{ .failure = .{ .rows = .{ .reason = "evicted", .screen = screen, .epoch = b.epoch, .oldest = b.oldest, .end = b.end, .first = s, .last = @min(e, b.oldest) -| 1 } } };
    if (e > b.end or s > b.end) return .{ .failure = .{ .rows = .{ .reason = "future", .screen = screen, .epoch = b.epoch, .oldest = b.oldest, .end = b.end, .first = @max(s, b.end), .last = @max(e, s + 1) - 1 } } };
    if (e < s) return .{ .failure = .{ .params = .{ .param = "end", .reason = "order" } } };

    var page: Page = .{ .pane = pane, .screen = screen, .epoch = b.epoch, .offset = offset, .cols = size.cols, .rows = size.rows, .bounds = .{ .oldest = b.oldest, .active = b.active, .end = b.end }, .start = s, .end = e, .done = true, .lines = &.{} };
    // Worst-case envelope of the result: `next` present with as many digits
    // as `end`, and no lines.
    var probe = page;
    probe.next = e;
    probe.done = false;
    const base = (try std.json.Stringify.valueAlloc(a, probe, .{})).len;
    const cols: u64 = @max(1, size.cols);
    const cap = @min(e - s, req.max_rows, cell_limit / cols);
    var lines: std.ArrayList([]const u8) = .empty;
    try lines.ensureTotalCapacity(a, @intCast(cap));
    var text_bytes: u64 = 0;
    var frame_bytes: u64 = base;
    var row = s;
    fill: while (row < s + cap) {
        const upto = @min(s + cap, row + chunk_rows);
        const chunk = vt.exportRows(a, b.epoch, row, upto) catch |err| switch (err) {
            // Single-threaded: bounds were just checked. Report the current
            // epoch rather than any rows from a different one.
            error.StaleRows => return .{ .failure = .{ .epoch = .{ .given = b.epoch, .state = state } } },
            else => return err,
        };
        var it = std.mem.splitScalar(u8, chunk[0 .. chunk.len - @intFromBool(chunk.len > 0)], '\n');
        while (it.next()) |line| {
            const json = jsonLen(line) + 1;
            if (text_bytes + line.len > req.max_bytes or frame_bytes + json > frame_budget) {
                if (lines.items.len == 0) return .{ .failure = .{ .size = .{ .row = s, .bytes = line.len } } };
                break :fill;
            }
            text_bytes += line.len;
            frame_bytes += json;
            lines.appendAssumeCapacity(line);
            row += 1;
        }
    }
    page.lines = lines.items;
    if (s + lines.items.len < e) {
        page.next = s + lines.items.len;
        page.done = false;
    }
    return .{ .page = page };
}

/// Bytes std.json uses for `line` as a string, quotes included.
fn jsonLen(line: []const u8) u64 {
    var n: u64 = 2;
    for (line) |ch| n += switch (ch) {
        '"', '\\', '\n', '\r', '\t', 0x08, 0x0c => 2,
        0...0x07, 0x0b, 0x0e...0x1f => 6,
        else => 1,
    };
    return n;
}

const testing = std.testing;
fn seqVt(cols: u16, rows: u16, n: usize, scrollback: usize) !Vt {
    var vt = try Vt.init(testing.allocator, .{ .cols = cols, .rows = rows, .scrollback_lines = scrollback });
    errdefer vt.deinit();
    for (1..n + 1) |i| {
        var buf: [32]u8 = undefined;
        try vt.feed(try std.fmt.bufPrint(&buf, "{d}\r\n", .{i}));
    }
    return vt;
}
fn expectPage(o: Outcome) !Page {
    return switch (o) {
        .page => |p| p,
        .failure => |f| {
            std.debug.print("unexpected {s}\n", .{f.code()});
            return error.TestUnexpectedResult;
        },
    };
}
fn expectFailure(o: Outcome) !Failure {
    return switch (o) {
        .failure => |f| f,
        .page => error.TestUnexpectedResult,
    };
}

test "capture_rows: tail, default selection, paging and next chaining" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vt = try seqVt(20, 4, 1000, 10_000);
    defer vt.deinit();
    const b = vt.rows();
    try testing.expectEqual(@as(u64, 1001), b.end - b.oldest);
    const t = try expectPage(try read(a, vt, "p0", 4893, .{ .tail = 3 }, 1 << 20));
    try testing.expectEqual(@as(u64, 998), t.start);
    try testing.expect(t.done and t.next == null);
    try testing.expectEqualStrings("999                 ", t.lines[0]);
    try testing.expectEqualStrings("1000                ", t.lines[1]);
    try testing.expectEqualStrings("                    ", t.lines[2]);
    // Default selection paged by 100: 11 pages, rows N-1 hold N.
    var start: ?u64 = null;
    var pages: usize = 0;
    var seen: u64 = 0;
    while (true) {
        const req: Request = if (start) |s| .{ .epoch = b.epoch, .start = s, .end = b.end, .max_rows = 100 } else .{ .max_rows = 100 };
        const p = try expectPage(try read(a, vt, "p0", 0, req, 1 << 20));
        pages += 1;
        for (p.lines, 0..) |line, i| {
            const n = p.start + i + 1;
            if (n <= 1000) {
                var buf: [32]u8 = undefined;
                const want = try std.fmt.bufPrint(&buf, "{d}", .{n});
                try testing.expect(std.mem.startsWith(u8, line, want));
                try testing.expectEqual(@as(usize, 20), line.len);
            }
        }
        seen += p.lines.len;
        if (p.done) {
            try testing.expect(p.next == null);
            break;
        }
        try testing.expectEqual(p.start + p.lines.len, p.next.?);
        start = p.next;
    }
    try testing.expectEqual(@as(usize, 11), pages);
    try testing.expectEqual(@as(u64, 1001), seen);
}

test "capture_rows: parameter rules, epochs, eviction and future rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vt = try seqVt(20, 4, 2500, 5);
    defer vt.deinit();
    const b = vt.rows();
    try testing.expect(b.oldest > 0);
    try testing.expectEqualStrings("exclusive", (try expectFailure(try read(a, vt, "p", 0, .{ .tail = 1, .epoch = b.epoch }, 1 << 20))).params.reason);
    try testing.expectEqualStrings("epoch_required", (try expectFailure(try read(a, vt, "p", 0, .{ .start = 0 }, 1 << 20))).params.reason);
    try testing.expectEqualStrings("order", (try expectFailure(try read(a, vt, "p", 0, .{ .epoch = b.epoch, .start = b.end, .end = b.end - 1 }, 1 << 20))).params.reason);
    try testing.expectEqualStrings("conflict.epoch", (try expectFailure(try read(a, vt, "p", 0, .{ .epoch = b.epoch + 7 }, 1 << 20))).code());
    const ev = (try expectFailure(try read(a, vt, "p", 0, .{ .epoch = b.epoch, .start = b.oldest - 1 }, 1 << 20))).rows;
    try testing.expectEqualStrings("evicted", ev.reason);
    try testing.expectEqual(b.oldest, ev.oldest);
    const fu = (try expectFailure(try read(a, vt, "p", 0, .{ .epoch = b.epoch, .end = b.end + 1 }, 1 << 20))).rows;
    try testing.expectEqualStrings("future", fu.reason);
    try testing.expectEqual(b.end, fu.first);
    const empty = try expectPage(try read(a, vt, "p", 0, .{ .epoch = b.epoch, .start = b.end - 2, .end = b.end - 2 }, 1 << 20));
    try testing.expect(empty.done and empty.lines.len == 0 and empty.start == b.end - 2);
    // Tail larger than retention is the retained rows, not an error.
    const all = try expectPage(try read(a, vt, "p", 0, .{ .tail = 1_000_000 }, 1 << 20));
    try testing.expectEqual(b.oldest, all.start);
    try testing.expectEqual(b.end - b.oldest, all.lines.len);
    // History is immutable within an epoch.
    const before = try expectPage(try read(a, vt, "p", 0, .{ .epoch = b.epoch, .start = b.oldest, .end = b.oldest + 3 }, 1 << 20));
    try vt.feed("more\r\n");
    const after = try expectPage(try read(a, vt, "p", 0, .{ .epoch = b.epoch, .start = b.oldest + 1, .end = b.oldest + 3 }, 1 << 20));
    try testing.expectEqualStrings(before.lines[1], after.lines[0]);
    // Resize, CSI 3 J and RIS each start a new epoch.
    for ([_][]const u8{ "", "\x1b[3J", "\x1bc" }) |bytes| {
        const old = vt.rows().epoch;
        if (bytes.len == 0) try vt.resize(30, 5) else try vt.feed(bytes);
        try testing.expectEqualStrings("conflict.epoch", (try expectFailure(try read(a, vt, "p", 0, .{ .epoch = old, .start = vt.rows().active }, 1 << 20))).code());
    }
}

test "capture_rows: byte, cell and frame limits never truncate a line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vt = try Vt.init(testing.allocator, .{ .cols = 4, .rows = 2 });
    defer vt.deinit();
    // Each row: four 3-byte characters = 12 bytes.
    for (0..10) |_| try vt.feed("€€€€");
    const b = vt.rows();
    const sel: Request = .{ .epoch = b.epoch, .start = b.oldest, .end = b.oldest + 5, .max_bytes = 30 };
    const p = try expectPage(try read(a, vt, "p", 0, sel, 1 << 20));
    try testing.expectEqual(@as(usize, 2), p.lines.len);
    try testing.expectEqual(b.oldest + 2, p.next.?);
    for (p.lines) |line| try testing.expectEqualStrings("€€€€", line);
    var small = sel;
    small.max_bytes = 11;
    const f = (try expectFailure(try read(a, vt, "p", 0, small, 1 << 20))).size;
    try testing.expectEqual(b.oldest, f.row);
    try testing.expectEqual(@as(u64, 12), f.bytes);
    // Frame: the encoded result always fits the budget.
    var budget: u64 = 260;
    while (budget < 400) : (budget += 7) {
        const o = try read(a, vt, "p", 0, .{ .epoch = b.epoch, .start = b.oldest, .end = b.oldest + 5 }, budget);
        switch (o) {
            .page => |pg| {
                const bytes = try std.json.Stringify.valueAlloc(a, pg, .{ .emit_null_optional_fields = false });
                try testing.expect(bytes.len <= budget);
                try testing.expect(pg.lines.len >= 1);
            },
            .failure => |fl| try testing.expectEqualStrings("unsupported.result_size", fl.code()),
        }
    }
    // Cell limit: at most 64 rows of 65535 columns.
    var wide = try Vt.init(testing.allocator, .{ .cols = 65535, .rows = 2, .scrollback_lines = 200 });
    defer wide.deinit();
    for (0..70) |_| try wide.feed("x\r\n");
    const w = try expectPage(try read(a, wide, "p", 0, .{ .max_bytes = 16 << 20 }, 64 << 20));
    try testing.expectEqual(@as(usize, 64), w.lines.len);
    try testing.expect(!w.done);
}

test "capture_rows: alternate screen has no history" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vt = try seqVt(10, 3, 50, 1000);
    defer vt.deinit();
    const primary = vt.rows().epoch;
    try vt.feed("\x1b[?1049h\x1b[HALT");
    const p = try expectPage(try read(a, vt, "p", 0, .{}, 1 << 20));
    try testing.expectEqualStrings("alternate", p.screen);
    try testing.expectEqual(p.bounds.oldest, p.bounds.active);
    try testing.expectEqual(@as(usize, 3), p.lines.len);
    try testing.expectEqualStrings("ALT       ", p.lines[0]);
    try vt.feed("\x1b[?1049l");
    try testing.expectEqualStrings("conflict.epoch", (try expectFailure(try read(a, vt, "p", 0, .{ .epoch = primary }, 1 << 20))).code());
    try testing.expectEqualStrings("primary", (try expectPage(try read(a, vt, "p", 0, .{ .tail = 1 }, 1 << 20))).screen);
}
