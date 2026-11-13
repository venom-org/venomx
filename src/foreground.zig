//! `process`: the name of a PTY's foreground process group
//! leader, and `cmdline`: the shell's command line from OSC 133 C.
//! Both are untrusted display text, never an identity.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

/// The longest `process` label, in bytes; cut like `argv0`.
pub const max_process = 255;
/// The longest `cmdline`, in bytes.
pub const max_cmdline = 1024;
/// Output, OSC 133 and OSC 2 sample at most this often per pane.
pub const min_interval_ms = 250;
/// The slow timer for silent commands, at most once a second.
pub const timer_ms = 1000;

extern "c" fn tcgetpgrp(fd: c.fd_t) c.pid_t;
extern "c" fn proc_name(pid: c_int, buffer: [*]u8, size: u32) c_int;

/// The foreground process group of the terminal whose master is `fd`, or
/// null when it can't be read (closed master, no foreground group).
pub fn group(fd: c.fd_t) ?c.pid_t {
    const pgid = tcgetpgrp(fd);
    return if (pgid > 0) pgid else null;
}

/// The name of process `pid` into `buf`, sanitized by `label`. Null when the
/// platform has no source, the process is gone, or the name is unusable.
pub fn name(pid: c.pid_t, buf: *[256]u8) ?[]const u8 {
    switch (builtin.os.tag) {
        .linux => {
            var path: [32]u8 = undefined;
            const p = std.fmt.bufPrintSentinel(&path, "/proc/{d}/comm", .{pid}, 0) catch return null;
            const fd = c.open(p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
            if (fd < 0) return null;
            defer _ = c.close(fd);
            const n = c.read(fd, buf, buf.len);
            if (n <= 0) return null;
            var raw = buf[0..@intCast(n)];
            if (raw.len > 0 and raw[raw.len - 1] == '\n') raw = raw[0 .. raw.len - 1];
            return label(raw);
        },
        .macos => {
            const n = proc_name(pid, buf, buf.len);
            if (n <= 0) return null;
            return label(buf[0..@intCast(n)]);
        },
        else => return null,
    }
}

/// Cut to `max_process` bytes on a UTF-8 code-point boundary;
/// none when empty or not valid UTF-8. Borrows `raw`.
pub fn label(raw: []const u8) ?[]const u8 {
    if (!std.unicode.utf8ValidateSlice(raw)) return null;
    const cut = cutUtf8(raw, max_process);
    return if (cut.len == 0) null else cut;
}

/// The decoded `cmdline_url` text with each C0 or C1 control and
/// DEL replaced by U+FFFD, cut to `max_cmdline` bytes on a code-point
/// boundary. None when it is empty or not valid UTF-8. Caller owns the result.
pub fn cmdline(a: std.mem.Allocator, decoded: []const u8) !?[]u8 {
    if (decoded.len == 0 or !std.unicode.utf8ValidateSlice(decoded)) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var it = std.unicode.Utf8View.initUnchecked(decoded).iterator();
    while (it.nextCodepointSlice()) |cp| {
        const v = std.unicode.utf8Decode(cp) catch unreachable;
        const piece: []const u8 = if (v < 0x20 or v == 0x7f or (v >= 0x80 and v <= 0x9f)) "\u{fffd}" else cp;
        if (out.items.len + piece.len > max_cmdline) break;
        try out.appendSlice(a, piece);
    }
    if (out.items.len == 0) {
        out.deinit(a);
        return null;
    }
    return try out.toOwnedSlice(a);
}

fn cutUtf8(s: []const u8, limit: usize) []const u8 {
    if (s.len <= limit) return s;
    var end = limit;
    while (end > 0 and s[end] & 0xC0 == 0x80) end -= 1;
    return s[0..end];
}

/// When a pane samples next. `trigger` is output, an OSC 133
/// marker or a title change since the last sample.
pub fn due(trigger: bool, last_ms: i64, now_ms: i64) bool {
    const since = now_ms - last_ms;
    return if (trigger) since >= min_interval_ms else since >= timer_ms;
}

const testing = std.testing;

test "label cuts and rejects like a process label" {
    try testing.expectEqualStrings("ping", label("ping").?);
    try testing.expect(label("") == null);
    try testing.expect(label("a\xffb") == null);
    var wide: [300]u8 = @splat('a');
    @memcpy(wide[254..257], "\u{2603}");
    try testing.expectEqual(@as(usize, 254), label(&wide).?.len);
}

test "cmdline replaces controls, cuts on a code point and drops bad UTF-8" {
    const a = testing.allocator;
    const plain = (try cmdline(a, "ping google.com")).?;
    defer a.free(plain);
    try testing.expectEqualStrings("ping google.com", plain);
    const ctl = (try cmdline(a, "a\x1bb\x7fc\u{85}d")).?;
    defer a.free(ctl);
    try testing.expectEqualStrings("a\u{fffd}b\u{fffd}c\u{fffd}d", ctl);
    try testing.expect(try cmdline(a, "a\xffc") == null);
    try testing.expect(try cmdline(a, "") == null);
    var long: [1100]u8 = @splat('x');
    @memcpy(long[1022..1025], "\u{2603}");
    const cut = (try cmdline(a, &long)).?;
    defer a.free(cut);
    try testing.expectEqual(@as(usize, 1022), cut.len);
}

test "cmdline survives allocation failure without leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            if (try cmdline(a, "ls \x07 -la")) |x| a.free(x);
        }
    }.run, .{});
}

test "due bounds the rate to 4 per second and the timer to 1 per second" {
    try testing.expect(due(true, 0, 250));
    try testing.expect(!due(true, 0, 249));
    try testing.expect(!due(false, 0, 999));
    try testing.expect(due(false, 0, 1000));
}

test "group and name read this process's terminal when it has one" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var buf: [256]u8 = undefined;
    const self_name = name(std.c.getpid(), &buf) orelse return error.TestUnexpectedResult;
    try testing.expect(self_name.len > 0);
    try testing.expect(group(-1) == null);
}
