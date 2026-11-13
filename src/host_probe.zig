//! Raw attach's snapshot of the host terminal's own colors.
//!
//! `queries` goes to the host before any pane output. A terminal handles
//! output in order, so its answers describe the host from before the pane
//! could change anything, however late they arrive. That is why attach never
//! waits for them: `Probe.feed` sits on stdin, takes the replies out and keeps
//! everything else as input, so replies cannot reach a pane and typed bytes
//! cannot be lost. DA1 is the last query and nearly every terminal answers it,
//! so its reply ends the probe. A terminal that answers nothing costs no delay
//! on attach, and `window_ms` ends the probe.
const std = @import("std");

/// How long replies are expected. Only exact reply shapes are removed, so a
/// long window costs nothing on a terminal that answers.
pub const window_ms: i64 = 5000;
/// A lone ESC may be the start of a reply or the Escape key. Replies arrive in
/// bursts, so one that has no continuation by now is the key.
pub const lone_escape_ms: i64 = 100;
/// Detach's bound on waiting for replies still outstanding.
pub const settle_ms: i64 = 200;

/// xterm dynamic colors worth restoring. Their reset is the code plus 100.
pub const dynamic_codes = [_]u16{ 10, 11, 12, 17, 19 };
/// xterm special colors: bold, underline, blink, reverse, italic.
pub const special_count = 5;

pub fn dynamicIndex(code: u16) ?u3 {
    for (dynamic_codes, 0..) |c, i| if (c == code) return @intCast(i);
    return null;
}

/// A color exactly as the host reported it, safe to write back: only
/// `rgb:h/h/h` with one to four hex digits per channel.
pub const Spec = struct {
    len: u8 = 0,
    bytes: [18]u8 = undefined,

    pub fn text(self: *const Spec) ?[]const u8 {
        return if (self.len == 0) null else self.bytes[0..self.len];
    }
    pub fn parse(s: []const u8) ?Spec {
        if (s.len > 18 or !std.mem.startsWith(u8, s, "rgb:")) return null;
        var channels = std.mem.splitScalar(u8, s[4..], '/');
        var count: usize = 0;
        while (channels.next()) |c| : (count += 1) {
            if (c.len < 1 or c.len > 4) return null;
            for (c) |h| if (!std.ascii.isHex(h)) return null;
        }
        if (count != 3) return null;
        var spec: Spec = .{ .len = @intCast(s.len) };
        @memcpy(spec.bytes[0..s.len], s);
        return spec;
    }
};

/// What the host reported. An entry that stays empty is reset to the
/// terminal's default on undo, which is all that can be done for it.
pub const Snapshot = struct {
    palette: [256]Spec = @splat(.{}),
    special: [special_count]Spec = @splat(.{}),
    dynamic: [dynamic_codes.len]Spec = @splat(.{}),
    cursor_shape: ?u8 = null,
    /// Replies may still come, so an undo now can't be the last word.
    pending: bool = false,
};

/// Cursor style, special and dynamic colors, palette, then DA1 as sentinel.
pub const queries = blk: {
    @setEvalBranchQuota(1_000_000);
    var q: []const u8 = "\x1bP$q q\x1b\\";
    for (0..special_count) |i| q = q ++ std.fmt.comptimePrint("\x1b]5;{d};?\x1b\\", .{i});
    for (dynamic_codes) |c| q = q ++ std.fmt.comptimePrint("\x1b]{d};?\x1b\\", .{c});
    for (0..256) |i| q = q ++ std.fmt.comptimePrint("\x1b]4;{d};?\x1b\\", .{i});
    const all = q ++ "\x1b[c";
    break :blk all;
};

const Shape = enum { partial, complete, mismatch };

/// Whether `s`, which starts with ESC, is a reply this probe asked for.
fn classify(s: []const u8) Shape {
    if (s.len < 2) return .partial;
    switch (s[1]) {
        '[' => {
            if (s.len == 2) return .partial;
            if (s[2] != '?') return .mismatch;
            for (s[3..]) |b| switch (b) {
                '0'...'9', ';' => {},
                'c' => return .complete,
                else => return .mismatch,
            };
            return .partial;
        },
        ']' => {
            var i: usize = 2;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
            if (i == s.len) return .partial;
            if (s[i] != ';') return .mismatch;
            const code = std.fmt.parseInt(u16, s[2..i], 10) catch return .mismatch;
            if (code != 4 and code != 5 and dynamicIndex(code) == null) return .mismatch;
            return stringBody(s[i + 1 ..]);
        },
        'P' => {
            for (s[2..@min(s.len, 5)], "1$r"[0..@min(s.len - 2, 3)], 0..) |b, want, i| {
                if (b != want and !(i == 0 and b == '0')) return .mismatch;
            }
            if (s.len < 5) return .partial;
            return stringBody(s[5..]);
        },
        else => return .mismatch,
    }
}
fn stringBody(body: []const u8) Shape {
    for (body, 0..) |b, i| {
        if (b == 0x07 or b == 0x9c) return .complete;
        if (b == 0x1b) {
            if (i + 1 == body.len) return .partial;
            return if (body[i + 1] == '\\') .complete else .mismatch;
        }
        if (b < 0x20 or b > 0x7e) return .mismatch;
    }
    return .partial;
}

pub const Probe = struct {
    snapshot: Snapshot = .{},
    /// Inert until `start`: bytes pass through untouched.
    done: bool = true,
    deadline: i64 = 0,
    held: [max_held]u8 = undefined,
    held_len: usize = 0,
    held_at: i64 = 0,

    /// Longer than any reply this probe asks for.
    pub const max_held = 64;

    /// Call after writing `queries`.
    pub fn start(self: *Probe, now: i64) void {
        self.done = false;
        self.deadline = now + window_ms;
        self.held_len = 0;
        self.snapshot.pending = true;
    }

    /// Writes `bytes` to `dest` without the replies and returns the length.
    /// A reply may span calls. `dest` must hold `bytes.len + max_held`.
    pub fn feed(self: *Probe, bytes: []const u8, dest: []u8, now: i64) usize {
        std.debug.assert(dest.len >= bytes.len + max_held);
        var n: usize = 0;
        for (bytes) |b| n = self.byte(b, dest, n, now);
        return n;
    }

    /// Gives back held bytes that time showed to be input, and ends the probe
    /// at its deadline. Writes at most `max_held` bytes to `dest`.
    pub fn tick(self: *Probe, dest: []u8, now: i64) usize {
        if (self.done) return 0;
        if (now >= self.deadline) {
            self.finish();
        } else if (!(self.held_len == 1 and now - self.held_at >= lone_escape_ms)) return 0;
        const n = self.held_len;
        @memcpy(dest[0..n], self.held[0..n]);
        self.held_len = 0;
        return n;
    }

    /// When `tick` next has something to do.
    pub fn nextWake(self: *const Probe) ?i64 {
        if (self.done) return null;
        return if (self.held_len == 1) @min(self.deadline, self.held_at + lone_escape_ms) else self.deadline;
    }

    /// Stops expecting replies; anything held is dropped with the session.
    pub fn giveUp(self: *Probe) void {
        self.finish();
        self.held_len = 0;
    }

    fn finish(self: *Probe) void {
        self.done = true;
        self.snapshot.pending = false;
    }

    fn byte(self: *Probe, b: u8, dest: []u8, at: usize, now: i64) usize {
        if (self.done or (self.held_len == 0 and b != 0x1b)) {
            dest[at] = b;
            return at + 1;
        }
        if (self.held_len == 0) self.held_at = now;
        self.held[self.held_len] = b;
        self.held_len += 1;
        const seq = self.held[0..self.held_len];
        switch (if (self.held_len == 1) Shape.partial else classify(seq)) {
            .partial => if (self.held_len < max_held) return at else return self.spill(dest, at, now),
            .complete => {
                self.apply(seq);
                self.held_len = 0;
                return at;
            },
            .mismatch => return self.spill(dest, at, now),
        }
    }

    /// Not a reply: its first byte is input, and a reply may start after it.
    fn spill(self: *Probe, dest: []u8, at: usize, now: i64) usize {
        const copy = self.held;
        const len = self.held_len;
        self.held_len = 0;
        dest[at] = copy[0];
        var n = at + 1;
        for (copy[1..len]) |b| n = self.byte(b, dest, n, now);
        return n;
    }

    fn apply(self: *Probe, seq: []const u8) void {
        var body = seq[2..];
        for ([_][]const u8{ "\x1b\\", "\x07", "\x9c" }) |st| if (std.mem.endsWith(u8, body, st)) {
            body = body[0 .. body.len - st.len];
            break;
        };
        const snap = &self.snapshot;
        switch (seq[1]) {
            '[' => self.finish(),
            'P' => if (std.mem.startsWith(u8, body, "1$r") and std.mem.endsWith(u8, body, " q")) {
                snap.cursor_shape = std.fmt.parseInt(u8, body[3 .. body.len - 2], 10) catch null;
            },
            ']' => {
                var fields = std.mem.splitScalar(u8, body, ';');
                const code = std.fmt.parseInt(u16, fields.first(), 10) catch return;
                if (dynamicIndex(code)) |d| {
                    snap.dynamic[d] = Spec.parse(fields.next() orelse return) orelse return;
                    return;
                }
                const index = std.fmt.parseInt(u16, fields.next() orelse return, 10) catch return;
                const spec = Spec.parse(fields.next() orelse return) orelse return;
                // xterm numbers its special colors after the palette in OSC 4.
                const special = if (code == 5) index else index -| 256;
                if (code == 4 and index < 256) {
                    snap.palette[index] = spec;
                } else if (special < special_count) {
                    snap.special[special] = spec;
                }
            },
            else => {},
        }
    }
};

const testing = std.testing;

fn everySplit(input: []const u8, expected: []const u8, check: anytype) !void {
    for (0..input.len + 1) |split| {
        var p: Probe = .{};
        p.start(0);
        var dest: [4096]u8 = undefined;
        var n = p.feed(input[0..split], &dest, 0);
        n += p.feed(input[split..], dest[n..], 0);
        try testing.expectEqualStrings(expected, dest[0..n]);
        try check.run(&p);
    }
}

test "queries end with the DA1 sentinel and ask for everything undo restores" {
    try testing.expect(std.mem.endsWith(u8, queries, "\x1b[c"));
    for ([_][]const u8{ "\x1bP$q q\x1b\\", "\x1b]5;4;?\x1b\\", "\x1b]10;?\x1b\\", "\x1b]11;?\x1b\\", "\x1b]12;?\x1b\\", "\x1b]17;?\x1b\\", "\x1b]19;?\x1b\\", "\x1b]4;0;?\x1b\\", "\x1b]4;255;?\x1b\\" }) |q| {
        try testing.expect(std.mem.indexOf(u8, queries, q) != null);
    }
}

test "replies are recorded and removed at every read boundary, input is kept in order" {
    // Typed bytes before, between and after replies, including keys that
    // look like the start of one.
    const input = "ls\x1b[A" ++ "\x1b]11;rgb:10/20/30\x1b\\" ++ "x\x1b" ++ "\x1b]4;1;rgb:aaaa/bbbb/cccc\x07" ++ "\x1bOP" ++
        "\x1bP1$r2 q\x1b\\" ++ "\x1b]5;3;rgb:1/2/3\x1b\\" ++ "\x1b]4;258;rgb:4/5/6\x1b\\" ++ "\x1b]17;rgb:7/8/9\x9c" ++ "y" ++ "\x1b[?62;22c" ++ "\x1b]11;rgb:ff/ff/ff\x1b\\z";
    try everySplit(input, "ls\x1b[Ax\x1b\x1bOPy\x1b]11;rgb:ff/ff/ff\x1b\\z", struct {
        fn run(p: *Probe) !void {
            try testing.expect(p.done and !p.snapshot.pending);
            const s = &p.snapshot;
            // The reply after the sentinel was input; the first answer stands.
            try testing.expectEqualStrings("rgb:10/20/30", s.dynamic[1].text().?);
            try testing.expectEqualStrings("rgb:aaaa/bbbb/cccc", s.palette[1].text().?);
            try testing.expectEqualStrings("rgb:1/2/3", s.special[3].text().?);
            try testing.expectEqualStrings("rgb:4/5/6", s.special[2].text().?);
            try testing.expectEqualStrings("rgb:7/8/9", s.dynamic[3].text().?);
            try testing.expectEqual(@as(?u8, 2), s.cursor_shape);
            try testing.expectEqual(@as(?[]const u8, null), s.dynamic[0].text());
        }
    });
}

test "a reply that cannot be written back is removed and not recorded" {
    const input = "\x1b]11;rgb:10/20/30;\x1b[31m\x1b\\" ++ "\x1b]10;#ffffff\x1b\\" ++ "\x1b]12;rgb:1/2\x1b\\" ++ "\x1b]4;999;rgb:1/2/3\x1b\\" ++ "\x1bP0$r\x1b\\" ++ "\x1bP1$rfoo q\x1b\\" ++ "\x1b[?1c";
    var p: Probe = .{};
    p.start(0);
    var dest: [256]u8 = undefined;
    const n = p.feed(input, &dest, 0);
    // The first aborts at its embedded ESC, so it is treated as input up to
    // there; the rest is exact reply shapes and goes.
    try testing.expectEqualStrings("\x1b]11;rgb:10/20/30;\x1b[31m\x1b\\", dest[0..n]);
    try testing.expectEqual(@as(?[]const u8, null), p.snapshot.dynamic[1].text());
    try testing.expectEqual(@as(?[]const u8, null), p.snapshot.dynamic[0].text());
    try testing.expectEqual(@as(?[]const u8, null), p.snapshot.dynamic[2].text());
    try testing.expectEqual(@as(?u8, null), p.snapshot.cursor_shape);
    for (&p.snapshot.palette) |*s| try testing.expectEqual(@as(?[]const u8, null), s.text());
}

test "an inert probe passes every byte through" {
    var p: Probe = .{};
    var dest: [256]u8 = undefined;
    const input = "\x1b]11;rgb:10/20/30\x1b\\\x1b[?1c";
    const n = p.feed(input, &dest, 0);
    try testing.expectEqualStrings(input, dest[0..n]);
    try testing.expectEqual(@as(?i64, null), p.nextWake());
    try testing.expectEqual(@as(usize, 0), p.tick(&dest, 1_000_000));
}

test "a lone ESC comes back as the Escape key, a started reply waits for the deadline" {
    var p: Probe = .{};
    p.start(1000);
    var dest: [256]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), p.feed("\x1b", &dest, 1000));
    try testing.expectEqual(@as(?i64, 1000 + lone_escape_ms), p.nextWake());
    try testing.expectEqual(@as(usize, 0), p.tick(&dest, 1000 + lone_escape_ms - 1));
    const n = p.tick(&dest, 1000 + lone_escape_ms);
    try testing.expectEqualStrings("\x1b", dest[0..n]);
    try testing.expect(!p.done);
    // A reply cut in two is not mistaken for typing just because time passed.
    try testing.expectEqual(@as(usize, 0), p.feed("\x1b]11;rgb:10", &dest, 1200));
    try testing.expectEqual(@as(usize, 0), p.tick(&dest, 3000));
    try testing.expectEqual(@as(usize, 0), p.feed("/20/30\x07", &dest, 3000));
    try testing.expectEqualStrings("rgb:10/20/30", p.snapshot.dynamic[1].text().?);
}

test "a terminal that never answers ends the probe at the deadline, input intact" {
    var p: Probe = .{};
    p.start(0);
    try testing.expect(p.snapshot.pending);
    var dest: [256]u8 = undefined;
    var n = p.feed("a\x1b]", &dest, 10);
    try testing.expectEqualStrings("a", dest[0..n]);
    try testing.expectEqual(@as(?i64, window_ms), p.nextWake());
    n = p.tick(&dest, window_ms);
    try testing.expectEqualStrings("\x1b]", dest[0..n]);
    try testing.expect(p.done and !p.snapshot.pending);
    n = p.feed("\x1b[?1c", &dest, window_ms);
    try testing.expectEqualStrings("\x1b[?1c", dest[0..n]);
}

test "held bytes never grow past the bound" {
    var p: Probe = .{};
    p.start(0);
    const body: [Probe.max_held * 2]u8 = @splat('x');
    var dest: [Probe.max_held * 4]u8 = undefined;
    var n = p.feed("\x1b]11;", &dest, 0);
    n += p.feed(&body, dest[n..], 0);
    try testing.expectEqual(@as(usize, 5 + body.len), n);
    try testing.expectEqual(@as(usize, 0), p.held_len);
}
