//! Raw attach output tokenizer. Ordinary runs are written in one call;
//! only control sequences are buffered, across arbitrarily split PTY frames.
//!
//! The host terminal belongs to the user: colors, cursor style and tab stops
//! they set before attaching (e.g. a shell theme via OSC 4/10/11) must
//! survive. So the filter never forwards RIS, which would wipe them, and it
//! records which of that host state forwarded output changed, so `undo` can
//! put it back on detach. Colors and cursor style return to what
//! `host_probe` found on the host. What the host didn't report goes
//! to the terminal's defaults, and so do tab stops and the Kitty-only colors,
//! which have no such snapshot.
const std = @import("std");
const host_probe = @import("host_probe.zig");
const pane_stream = @import("pane_stream");

/// RIS without the parts of the host terminal that belong to the user:
/// palette, dynamic colors, cursor style, tab stops. Synchronized output off
/// so the rest shows, soft reset (modes, SGR, margins, charsets, keypad),
/// autowrap on, mouse/paste/focus reports and keyboard flags off, then a
/// cleared screen with the cursor home.
pub const soft_reset = "\x1b[?2026l\x1b[!p\x1b[?7h\x1b[?1l\x1b>\x1b(B\x0f\x1b[r" ++
    "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l\x1b[?1004l\x1b[?2004l\x1b[=0u\x1b[H\x1b[2J";

/// Host modes `attach` turns off on exit, whichever ones it or a raw pane
/// turned on. The alternate screen is left separately.
pub const restore_modes = "\x1b[?2026l\x1b[?2004l\x1b[?1004l\x1b[?1000l\x1b[?1003l\x1b[?1016l\x1b[?1015l\x1b[?1005l\x1b[>4;0m\x1b[r\x1b[?1006l\x1b[?1002l\x1b[0m\x1b[?25h";
/// Gives the host terminal back on exit. `presented`: this client
/// drew on the host's alternate screen with Kitty keyboard flags pushed
/// there. `raw`: the filter of a raw stream that forwarded pane output to
/// the host; what that output changed is undone, and nothing else. Colors
/// the user set before attaching come back from the filter's snapshot.
pub fn restoreHost(out: *std.Io.Writer, presented: bool, raw: ?*Filter) !void {
    if (presented) try out.writeAll("\x1b[<u");
    try out.writeAll(restore_modes);
    if (presented) try out.writeAll("\x1b[?1049l");
    const f = raw orelse return;
    // Leaving the presentation's alternate screen already left the raw one.
    if (presented) f.touched.alt_screen = false;
    try f.undo(out);
    // Raw output may have left keypad, cursor-key, charset, origin or wrap
    // modes on the primary screen, and keyboard flags (pushed per screen).
    try out.writeAll("\x1b[!p\x1b[?7h\x1b[?1l\x1b>\x1b(B\x0f\x1b[=0u");
}

/// A raw pane stream's `pane_stream.Passthrough`: pane output goes through
/// `filter` to the host terminal `out`.
pub const Host = struct {
    filter: Filter = .{},
    out: *std.Io.Writer,

    pub fn passthrough(self: *Host) pane_stream.Passthrough {
        return .{ .ctx = self, .begin = begin, .feed = feed };
    }
    /// A soft reset establishes the baseline the VT replay expects. Not RIS:
    /// that also wipes the colors, cursor style and tab stops the user set on
    /// the host. No alternate screen: replayed history belongs to
    /// host scrollback.
    fn begin(ctx: *anyopaque) anyerror!void {
        const self: *Host = @ptrCast(@alignCast(ctx));
        self.filter.reset();
        try self.filter.hostReset(self.out);
    }
    fn feed(ctx: *anyopaque, bytes: []const u8, clipboard: bool) anyerror!void {
        const self: *Host = @ptrCast(@alignCast(ctx));
        self.filter.clipboard = clipboard;
        try self.filter.feed(self.out, bytes);
    }
};

/// OSC 21 keys with no xterm code. Undo can only reset them.
const kitty_keys = [_][]const u8{
    "cursor_text",
    "visual_bell",
    "transparent_background_color1",
    "transparent_background_color2",
    "transparent_background_color3",
    "transparent_background_color4",
    "transparent_background_color5",
    "transparent_background_color6",
    "transparent_background_color7",
};
const no_snapshot: host_probe.Snapshot = .{};

/// Host state that forwarded output changed and detach must undo.
pub const Touched = struct {
    /// One bit per palette index.
    palette: u256 = 0,
    /// One bit per xterm special color (OSC 5).
    special: u5 = 0,
    /// One bit per entry of `host_probe.dynamic_codes`.
    dynamic: u5 = 0,
    /// One bit per entry of `kitty_keys`.
    kitty: u9 = 0,
    cursor_shape: bool = false,
    tabstops: bool = false,
    /// Current state, not history: the host is on its alternate screen.
    alt_screen: bool = false,
};

pub const Filter = struct {
    state: enum { ground, escape, csi, osc, dcs, string } = .ground,
    pending: [65536]u8 = undefined,
    len: usize = 0,
    overflow: bool = false,
    escaped: bool = false,
    clipboard: bool = false,
    intro: usize = 2,
    utf8_left: u3 = 0,
    /// Survives `reset`, which only drops a partial sequence.
    touched: Touched = .{},
    /// The host's own colors, for a raw stream that probed them.
    snapshot: ?*const host_probe.Snapshot = null,

    /// Puts back what forwarded output changed: leaves an alternate screen
    /// it entered, restores colors and cursor style to the snapshot's, and
    /// resets whatever it lacks, and tab stops, to the terminal's defaults.
    /// Writes nothing when output changed none of them.
    pub fn undo(self: *Filter, out: *std.Io.Writer) !void {
        const t = self.touched;
        const snap = self.snapshot orelse &no_snapshot;
        if (t.alt_screen) try out.writeAll("\x1b[?1049l");
        try restoreTable(out, t.palette, &snap.palette, 4, 104);
        try restoreTable(out, t.special, &snap.special, 5, 105);
        for (host_probe.dynamic_codes, 0..) |code, i| if (t.dynamic >> @intCast(i) & 1 != 0) {
            if (snap.dynamic[i].text()) |spec| {
                try out.print("\x1b]{d};{s}\x1b\\", .{ code, spec });
            } else try out.print("\x1b]{d}\x1b\\", .{code + 100});
        };
        for (kitty_keys, 0..) |key, i| if (t.kitty >> @intCast(i) & 1 != 0) {
            // A key with no `=` resets it; `key=` would select a dynamic color.
            try out.print("\x1b]21;{s}\x1b\\", .{key});
        };
        if (t.cursor_shape) try out.print("\x1b[{d} q", .{snap.cursor_shape orelse 0});
        if (t.tabstops) try out.writeAll("\x1b[?5W");
        self.touched = .{};
        // The answers can still come: a later undo, at the latest on detach,
        // restores these once more from what they say.
        if (snap.pending) {
            self.touched.palette = t.palette;
            self.touched.special = t.special;
            self.touched.dynamic = t.dynamic;
            self.touched.cursor_shape = t.cursor_shape;
        }
    }
    fn restoreTable(out: *std.Io.Writer, mask: anytype, specs: []const host_probe.Spec, set: u16, unset: u16) !void {
        if (mask == 0) return;
        const known = for (specs, 0..) |*s, i| {
            if (mask >> @intCast(i) & 1 != 0 and s.len > 0) break true;
        } else false;
        if (!known and mask == std.math.maxInt(@TypeOf(mask))) return out.print("\x1b]{d}\x1b\\", .{unset});
        for (specs, 0..) |*s, i| if (mask >> @intCast(i) & 1 != 0) {
            if (s.text()) |spec| {
                try out.print("\x1b]{d};{d};{s}\x1b\\", .{ set, i, spec });
            } else try out.print("\x1b]{d};{d}\x1b\\", .{ unset, i });
        };
    }
    /// The baseline a VT replay expects, in place of RIS.
    pub fn hostReset(self: *Filter, out: *std.Io.Writer) !void {
        try self.undo(out);
        try out.writeAll(soft_reset);
    }

    pub fn reset(self: *Filter) void {
        self.state = .ground;
        self.len = 0;
        self.overflow = false;
        self.escaped = false;
        self.utf8_left = 0;
    }
    pub fn feed(self: *Filter, out: *std.Io.Writer, bytes: []const u8) !void {
        var i: usize = 0;
        while (i < bytes.len) {
            if (self.state == .ground) {
                const start = i;
                while (i < bytes.len) : (i += 1) {
                    // Most raw output is ASCII. Skip it a vector at a time;
                    // scalar tokenization starts only at ESC or UTF-8/C1.
                    const lanes = std.simd.suggestVectorLength(u8) orelse 16;
                    const Vec = @Vector(lanes, u8);
                    while (self.utf8_left == 0 and bytes.len - i >= lanes) {
                        const v: Vec = bytes[i..][0..lanes].*;
                        const special = (v == @as(Vec, @splat(0x1b))) | (v >= @as(Vec, @splat(0x80)));
                        if (std.simd.firstTrue(special)) |at| {
                            i += at;
                            break;
                        }
                        i += lanes;
                    }
                    if (i == bytes.len) break;
                    const b = bytes[i];
                    const control = self.isControl(b);
                    if (b == 0x1b or (control and (b == 0x90 or b == 0x98 or b == 0x9b or b == 0x9d or b == 0x9e or b == 0x9f))) break;
                }
                try out.writeAll(bytes[start..i]);
                if (i == bytes.len) break;
                const b = bytes[i];
                i += 1;
                self.intro = if (b == 0x1b) 2 else 1;
                self.state = switch (b) {
                    0x90 => .dcs,
                    0x9b => .csi,
                    0x9d => .osc,
                    0x98, 0x9e, 0x9f => .string,
                    else => .escape,
                };
                self.pending[0] = b;
                self.len = 1;
                continue;
            }
            const b = bytes[i];
            const control = self.isControl(b);
            i += 1;
            const in_string = self.state == .osc or self.state == .dcs or self.state == .string;
            if (in_string and self.escaped and b != '\\') {
                // ESC followed by a non-ST byte aborts the string and starts
                // a new escape. Do not pass an embedded query hidden inside
                // an aborted DCS/OSC/APC to the host.
                self.reset();
                self.state = .escape;
                self.pending[0] = 0x1b;
                self.len = 1;
                self.intro = 2;
            }
            if (b == 0x1b and self.state != .osc and self.state != .dcs and self.state != .string) {
                self.reset();
                self.state = .escape;
                self.pending[0] = b;
                self.len = 1;
                self.intro = 2;
                continue;
            }
            if (control and (b == 0x90 or b == 0x98 or b == 0x9b or b == 0x9d or b == 0x9e or b == 0x9f)) {
                self.reset();
                self.intro = 1;
                self.state = switch (b) {
                    0x90 => .dcs,
                    0x9b => .csi,
                    0x9d => .osc,
                    else => .string,
                };
                self.pending[0] = b;
                self.len = 1;
                continue;
            }
            if (self.len < self.pending.len) {
                self.pending[self.len] = b;
                self.len += 1;
            } else self.overflow = true;
            if (b == 0x18 or b == 0x1a) { // CAN/SUB cancel any sequence.
                self.reset();
                continue;
            }
            switch (self.state) {
                .ground => unreachable,
                .escape => {
                    if (self.len == 1) continue;
                    self.state = switch (b) {
                        '[' => .csi,
                        ']' => .osc,
                        'P' => .dcs,
                        '_', '^', 'X' => .string,
                        else => .escape,
                    };
                    if (self.state == .escape and b >= 0x30 and b <= 0x7e) try self.finish(out);
                },
                .csi => {
                    if (b == 0x1b) {
                        self.reset();
                        self.state = .escape;
                        self.pending[0] = b;
                        self.len = 1;
                    } else if (b >= 0x40 and b <= 0x7e) try self.finish(out);
                },
                .osc, .dcs, .string => {
                    if ((self.escaped and b == '\\') or (control and b == 0x9c) or (self.state == .osc and b == 7)) {
                        try self.finish(out);
                    } else self.escaped = b == 0x1b;
                },
            }
        }
    }
    /// C1 bytes inside UTF-8 characters are text, including across frames.
    fn isControl(self: *Filter, b: u8) bool {
        if (b >= 0x80 and b <= 0xbf and self.utf8_left > 0) {
            self.utf8_left -= 1;
            return false;
        }
        self.utf8_left = if (b >= 0xc2 and b <= 0xdf) 1 else if (b >= 0xe0 and b <= 0xef) 2 else if (b >= 0xf0 and b <= 0xf4) 3 else 0;
        return b >= 0x80 and b <= 0x9f;
    }
    fn finish(self: *Filter, out: *std.Io.Writer) !void {
        // Overlong controls are dropped with bounded storage, including their
        // terminator. A malformed string cannot escape as printable bytes.
        if (!self.overflow and !self.remove()) {
            const p = self.pending[0..self.len];
            if (self.state == .escape and p.len == 2 and p[1] == 'c') {
                // A program's RIS resets the host to defaults, which here
                // are the user's settings from before attaching.
                self.reset();
                return self.hostReset(out);
            }
            self.track(p);
            try out.writeAll(p);
        }
        self.reset();
    }
    fn track(self: *Filter, p: []const u8) void {
        const t = &self.touched;
        switch (self.state) {
            .escape => if (p.len == 2 and p[1] == 'H') {
                t.tabstops = true;
            },
            .csi => {
                const final = p[p.len - 1];
                const body = p[self.intro .. p.len - 1];
                switch (final) {
                    'q' => if (std.mem.endsWith(u8, body, " ")) {
                        t.cursor_shape = true;
                    },
                    'g' => t.tabstops = true,
                    'h', 'l' => if (body.len > 0 and body[0] == '?') {
                        var modes = std.mem.splitScalar(u8, body[1..], ';');
                        while (modes.next()) |m| {
                            if (std.mem.eql(u8, m, "1049") or std.mem.eql(u8, m, "1047") or std.mem.eql(u8, m, "47")) t.alt_screen = final == 'h';
                        }
                    },
                    else => {},
                }
            },
            .osc => {
                var body = p[self.intro..];
                for ([_][]const u8{ "\x1b\\", "\x07", "\x9c" }) |st| if (std.mem.endsWith(u8, body, st)) {
                    body = body[0 .. body.len - st.len];
                    break;
                };
                var fields = std.mem.splitScalar(u8, body, ';');
                const code = std.fmt.parseInt(u16, fields.first(), 10) catch return;
                switch (code) {
                    4, 5 => while (fields.next()) |index| {
                        const color = fields.next() orelse break;
                        if (isColor(color)) markIndex(t, code, index);
                    },
                    104, 105 => {
                        var any = false;
                        while (fields.next()) |index| {
                            if (index.len > 0) any = true;
                            markIndex(t, code - 100, index);
                        }
                        if (!any and code == 104) t.palette = std.math.maxInt(u256);
                        if (!any and code == 105) t.special = std.math.maxInt(u5);
                    },
                    // OSC 10 to 19 may carry the following dynamic colors too.
                    // An empty field skips one, and leaves it as it was.
                    10...19 => {
                        var next = code;
                        while (fields.next()) |color| : (next += 1) {
                            if (isColor(color)) markDynamic(t, next);
                        }
                    },
                    110, 111, 112, 117, 119 => markDynamic(t, code - 100),
                    21 => while (fields.next()) |field| markKitty(t, field),
                    else => {},
                }
            },
            else => {},
        }
    }
    fn isColor(field: []const u8) bool {
        return field.len > 0 and !std.mem.eql(u8, field, "?");
    }
    /// `code` is 4 or 5. OSC 4 numbers the special colors after the palette.
    fn markIndex(t: *Touched, code: u16, field: []const u8) void {
        const index = std.fmt.parseInt(u16, field, 10) catch return;
        const special = if (code == 5) index else index -| 256;
        if (code == 4 and index < 256) {
            t.palette |= @as(u256, 1) << @intCast(index);
        } else if (special < host_probe.special_count) {
            t.special |= @as(u5, 1) << @intCast(special);
        }
    }
    fn markDynamic(t: *Touched, code: u16) void {
        if (host_probe.dynamicIndex(code)) |i| t.dynamic |= @as(u5, 1) << i;
    }
    /// Kitty colour protocol. `key=color`, `key=` (dynamic color) and `key`
    /// (reset) all change the host; `key=?` is a query and never gets here.
    fn markKitty(t: *Touched, field: []const u8) void {
        const key = field[0 .. std.mem.indexOfScalar(u8, field, '=') orelse field.len];
        if (std.mem.eql(u8, field[key.len..], "=?")) return;
        const named = [_]struct { []const u8, u16 }{
            .{ "foreground", 10 },
            .{ "background", 11 },
            .{ "cursor", 12 },
            .{ "selection_background", 17 },
            .{ "selection_foreground", 19 },
        };
        for (named) |n| if (std.mem.eql(u8, key, n[0])) return markDynamic(t, n[1]);
        for (kitty_keys, 0..) |k, i| if (std.mem.eql(u8, key, k)) {
            t.kitty |= @as(u9, 1) << @intCast(i);
            return;
        };
        if (std.ascii.isDigit(if (key.len > 0) key[0] else 0)) markIndex(t, 4, key);
    }
    fn remove(self: *const Filter) bool {
        const p = self.pending[0..self.len];
        switch (self.state) {
            .csi => {
                const final = p[p.len - 1];
                const body = p[self.intro .. p.len - 1];
                return switch (final) {
                    'c', 'n' => true,
                    'p' => std.mem.indexOfScalar(u8, body, '$') != null,
                    'q' => std.mem.indexOfScalar(u8, body, '>') != null,
                    'u' => std.mem.indexOfScalar(u8, body, '?') != null,
                    // Keep resize operations; remove window reports.
                    't' => blk: {
                        var parts = std.mem.splitScalar(u8, body, ';');
                        const code = std.fmt.parseInt(u16, parts.first(), 10) catch break :blk true;
                        break :blk code >= 11;
                    },
                    else => false,
                };
            },
            .dcs => return std.mem.startsWith(u8, p[self.intro..], "$q") or std.mem.startsWith(u8, p[self.intro..], "+q"),
            .osc => {
                var fields = std.mem.splitScalar(u8, p[self.intro..], ';');
                const code = std.fmt.parseInt(u16, fields.first(), 10) catch return false;
                const query = std.mem.indexOfScalar(u8, p[self.intro..], '?') != null;
                return switch (code) {
                    // Any color this filter tracks: a reply would reach the pane.
                    4, 5, 10...19, 21, 104, 105 => query,
                    52 => query or !self.clipboard,
                    else => false,
                };
            },
            else => return false,
        }
    }
};

test "raw tokenizer filters queries and clipboard at every frame boundary" {
    const input = "plain λ\x1b[31mred\x1b[0m\x1b[c\x1b[>c\x1b[=c\x1b[6n\x1b[?6n\x1b[?1$p\x1bP$qm\x1b\\\x1bP+q544e\x1b\\\x1b[>q\x1b[?u\x1b[18t\x1b]4;0;?\x07\x1b]10;?\x1b\\\x1b]11;?\x07\x1b]12;?\x07\x1b]104;?\x07\x1b]52;c;?\x07\x1b]52;c;eA==\x07\x1b]2;title\x07\x1b_Ggraphics\x1b\\tail";
    const normal = "plain λ\x1b[31mred\x1b[0m";
    const tail = "\x1b]2;title\x07\x1b_Ggraphics\x1b\\tail";
    for ([_]bool{ false, true }) |clipboard| {
        for (0..input.len + 1) |split| {
            var filter: Filter = .{ .clipboard = clipboard };
            var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer out.deinit();
            try filter.feed(&out.writer, input[0..split]);
            try filter.feed(&out.writer, input[split..]);
            try std.testing.expectEqualStrings(if (clipboard) normal ++ "\x1b]52;c;eA==\x07" ++ tail else normal ++ tail, out.written());
        }
    }
}

test "C1 queries are filtered without mistaking UTF-8 continuation bytes" {
    const input = "a\x9b6n\x9d52;c;?\x9c\x90$qm\x9c\xc2\x9b6n\xc2\x9d52;c;?\xc2\x9cZ";
    for (0..input.len + 1) |split| {
        var f: Filter = .{};
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try f.feed(&out.writer, input[0..split]);
        try f.feed(&out.writer, input[split..]);
        try std.testing.expectEqualStrings("a\xc2\x9b6n\xc2\x9d52;c;?\xc2\x9cZ", out.written());
    }
}

test "overlong strings are dropped through terminator, then text resumes" {
    var f: Filter = .{};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try f.feed(&out.writer, "\x1b]52;c;");
    const data: [65536]u8 = @splat('x');
    try f.feed(&out.writer, &data);
    try f.feed(&out.writer, "\x07after");
    try std.testing.expectEqualStrings("after", out.written());
}

test "aborted strings and repeated ESC cannot hide queries or clipboard reads" {
    const input = "\x1bPignored\x1b[6n\x1b\x1b]52;c;?\x07\x1b]ignored\x1b]52;c;?\x07\x1bPignored\x9b6nvisible";
    for (0..input.len + 1) |split| {
        var f: Filter = .{ .clipboard = true };
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try f.feed(&out.writer, input[0..split]);
        try f.feed(&out.writer, input[split..]);
        try std.testing.expectEqualStrings("visible", out.written());
    }
}

test "undo resets only host state forwarded output changed" {
    const input = "a\x1b]4;1;rgb:ff/00/00\x07\x1b]11;#000000\x1b\\\x1b]10;?\x07\x1b[5 q\x1b[?1049;1004h\x1bHb";
    for (0..input.len + 1) |split| {
        var f: Filter = .{};
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try f.feed(&out.writer, input[0..split]);
        try f.feed(&out.writer, input[split..]);
        // Queries are neither forwarded nor counted as changes.
        try std.testing.expectEqualStrings("a\x1b]4;1;rgb:ff/00/00\x07\x1b]11;#000000\x1b\\\x1b[5 q\x1b[?1049;1004h\x1bHb", out.written());
        out.clearRetainingCapacity();
        try f.undo(&out.writer);
        try std.testing.expectEqualStrings("\x1b[?1049l\x1b]104;1\x1b\\\x1b]111\x1b\\\x1b[0 q\x1b[?5W", out.written());
        // Undone state is not undone twice.
        out.clearRetainingCapacity();
        try f.undo(&out.writer);
        try std.testing.expectEqualStrings("", out.written());
    }
}

test "OSC 10 with several colors, resets and left alternate screens" {
    var f: Filter = .{};
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try f.feed(&out.writer, "\x1b]10;red;blue;green\x07\x1b[?1049h\x1b[?1049l\x1b]104\x07");
    out.clearRetainingCapacity();
    try f.undo(&out.writer);
    try std.testing.expectEqualStrings("\x1b]104\x1b\\\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\", out.written());
    // Plain output and SGR leave the user's host colors alone.
    try f.feed(&out.writer, "\x1b[31;48;5;4mx\x1b[0m\x1b[?25l");
    out.clearRetainingCapacity();
    try f.undo(&out.writer);
    try std.testing.expectEqualStrings("", out.written());
}

test "a program's RIS never reaches the host" {
    const input = "\x1b]11;#101010\x07x\x1bcy";
    for (0..input.len + 1) |split| {
        var f: Filter = .{};
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try f.feed(&out.writer, input[0..split]);
        try f.feed(&out.writer, input[split..]);
        try std.testing.expectEqualStrings("\x1b]11;#101010\x07x\x1b]111\x1b\\" ++ soft_reset ++ "y", out.written());
        try std.testing.expect(std.mem.indexOf(u8, out.written(), "\x1bc") == null);
        try std.testing.expectEqual(Touched{}, f.touched);
    }
}

fn undone(f: *Filter, input: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try f.feed(&out.writer, input);
    out.clearRetainingCapacity();
    try f.undo(&out.writer);
    return out.toOwnedSlice();
}
fn expectUndo(input: []const u8, expected: []const u8) !void {
    var f: Filter = .{};
    const got = try undone(&f, input);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
}

test "every color code is tracked and reset by its own code" {
    try expectUndo("\x1b]5;1;red;3;blue\x07", "\x1b]105;1\x1b\\\x1b]105;3\x1b\\");
    try expectUndo("\x1b]105;2\x07", "\x1b]105;2\x1b\\");
    try expectUndo("\x1b]105\x07", "\x1b]105\x1b\\");
    try expectUndo("\x1b]4;258;red\x07", "\x1b]105;2\x1b\\");
    try expectUndo("\x1b]17;red\x07", "\x1b]117\x1b\\");
    try expectUndo("\x1b]19;red\x07", "\x1b]119\x1b\\");
    try expectUndo("\x1b]117\x07\x1b]119\x07", "\x1b]117\x1b\\\x1b]119\x1b\\");
    try expectUndo("\x1b]104;7;9\x07", "\x1b]104;7\x1b\\\x1b]104;9\x1b\\");
    try expectUndo("\x1b]104\x07", "\x1b]104\x1b\\");
    try expectUndo("\x1b]104;\x07", "\x1b]104\x1b\\");
    try expectUndo("\x1b]4;1;red;2;blue\x07", "\x1b]104;1\x1b\\\x1b]104;2\x1b\\");
    // Colors nothing restores are not tracked.
    try expectUndo("\x1b]13;red\x07\x1b]14;red\x07\x1b]18;red\x07", "");
    try expectUndo("\x1b]4;999;red\x07\x1b]4;x;red\x07", "");
}

test "OSC 21 sets, dynamic values and resets count, by key" {
    try expectUndo("\x1b]21;foreground=red;cursor=;background\x07", "\x1b]110\x1b\\\x1b]111\x1b\\\x1b]112\x1b\\");
    try expectUndo("\x1b]21;selection_background=red;selection_foreground=blue\x07", "\x1b]117\x1b\\\x1b]119\x1b\\");
    try expectUndo("\x1b]21;7=red;255=blue\x07", "\x1b]104;7\x1b\\\x1b]104;255\x1b\\");
    // A key with no `=` is the reset form. `key=` would pick a dynamic color.
    try expectUndo("\x1b]21;cursor_text=red;visual_bell;transparent_background_color3=\x07", "\x1b]21;cursor_text\x1b\\\x1b]21;visual_bell\x1b\\\x1b]21;transparent_background_color3\x1b\\");
    try expectUndo("\x1b]21;nonsense=red;999=blue;=red\x07", "");
}

test "empty and query fields in multi-color OSC are not changes" {
    try expectUndo("\x1b]10;;blue\x07", "\x1b]111\x1b\\");
    try expectUndo("\x1b]10;red;;green\x07", "\x1b]110\x1b\\\x1b]112\x1b\\");
    try expectUndo("\x1b]11;\x07", "");
    try expectUndo("\x1b]11;;red\x07", "\x1b]112\x1b\\");
    try expectUndo("\x1b]10;;;\x07", "");
    // Field by field the chain runs from 10 up to 19.
    try expectUndo("\x1b]17;;;blue\x07", "\x1b]119\x1b\\");
    try expectUndo("\x1b]10;;;;;;;;;;blue;red\x07", "\x1b]119\x1b\\");
    try expectUndo("\x1b]4;1;\x07", "");
    // A field holding a query takes the whole sequence off the wire, so it
    // changes nothing on the host and must not count.
    for ([_][]const u8{ "\x1b]10;?;blue\x07", "\x1b]11;red;?\x07", "\x1b]5;1;?\x07", "\x1b]17;?\x07", "\x1b]19;?\x1b\\", "\x1b]13;?\x07", "\x1b]21;foreground=?\x07", "\x1b]21;7=?;cursor=?\x07", "\x1b]105;?\x07" }) |query| {
        var f: Filter = .{};
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try f.feed(&out.writer, query);
        try std.testing.expectEqualStrings("", out.written());
        try std.testing.expectEqual(Touched{}, f.touched);
    }
}

test "undo restores what the host reported, resets the rest" {
    var snap: host_probe.Snapshot = .{};
    snap.palette[1] = host_probe.Spec.parse("rgb:01/02/03").?;
    snap.special[2] = host_probe.Spec.parse("rgb:04/05/06").?;
    snap.dynamic[1] = host_probe.Spec.parse("rgb:10/20/30").?;
    snap.dynamic[3] = host_probe.Spec.parse("rgb:07/08/09").?;
    snap.cursor_shape = 4;
    var f: Filter = .{ .snapshot = &snap };
    const got = try undone(&f, "\x1b]4;1;red;2;red\x07\x1b]5;2;red\x07\x1b]10;red\x07\x1b]11;red\x07\x1b]17;red\x07\x1b[2 q\x1b[3g");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("\x1b]4;1;rgb:01/02/03\x1b\\\x1b]104;2\x1b\\\x1b]5;2;rgb:04/05/06\x1b\\" ++
        "\x1b]110\x1b\\\x1b]11;rgb:10/20/30\x1b\\\x1b]17;rgb:07/08/09\x1b\\\x1b[4 q\x1b[?5W", got);
    try std.testing.expectEqual(Touched{}, f.touched);

    // A pane that resets everything: known entries come back one by one.
    var g: Filter = .{ .snapshot = &snap };
    const all = try undone(&g, "\x1b]104\x07");
    defer std.testing.allocator.free(all);
    try std.testing.expect(std.mem.indexOf(u8, all, "\x1b]4;1;rgb:01/02/03\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "\x1b]104;255\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "\x1b]104\x1b\\") == null);
}

test "an undo before the replies came stays due" {
    var snap: host_probe.Snapshot = .{ .pending = true };
    var f: Filter = .{ .snapshot = &snap };
    const early = try undone(&f, "\x1b]11;red\x07\x1b[?1049h\x1b[2 q\x1b]21;visual_bell=red\x07");
    defer std.testing.allocator.free(early);
    try std.testing.expectEqualStrings("\x1b[?1049l\x1b]111\x1b\\\x1b]21;visual_bell\x1b\\\x1b[0 q", early);
    snap.dynamic[1] = host_probe.Spec.parse("rgb:10/20/30").?;
    snap.cursor_shape = 3;
    snap.pending = false;
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try f.undo(&out.writer);
    // The alternate screen and the Kitty key were left and reset for good.
    try std.testing.expectEqualStrings("\x1b]11;rgb:10/20/30\x1b\\\x1b[3 q", out.written());
    try std.testing.expectEqual(Touched{}, f.touched);
}

test "soft reset turns off every mouse encoding and synchronized output" {
    for ([_][]const u8{ "\x1b[?1005l", "\x1b[?1006l", "\x1b[?1015l", "\x1b[?1016l", "\x1b[?1000l", "\x1b[?1002l", "\x1b[?1003l", "\x1b[?2026l" }) |mode| {
        try std.testing.expect(std.mem.indexOf(u8, soft_reset, mode) != null);
    }
}
