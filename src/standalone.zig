//! Standalone entry point, client side: `venomx` / `venomx new`,
//! the selector-less `attach` choice and the last-used session file. Every
//! effect is an ordinary daemon verb sent through a normal connection; the
//! only daemon-side policy here is starting an on-demand daemon the way the
//! lifecycle module does, with `--origin interactive`.
const std = @import("std");
const c = std.c;
const proto = @import("proto");
const Value = std.json.Value;
const eq = std.mem.eql;

/// Client-side settings read from the persisted config (restart-only for the
/// daemon; the client reads them only when it needs them).
pub const Settings = struct {
    interactive_start: bool = true,
    startup_timeout_ms: u32 = 5000,
    /// "exit" or "next".
    on_session_end: []const u8 = "exit",
};

/// What `new` needs from the binary that it cannot build itself: the config
/// store (owned by main) and the on-demand daemon launcher.
pub const Host = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        settings: *const fn (*anyopaque, std.mem.Allocator, std.process.Environ) anyerror!Settings,
        /// Fork the on-demand candidate on the absolute `socket`.
        launch: *const fn (*anyopaque, std.mem.Allocator, []const u8, std.process.Environ) anyerror!void,
        /// Observe the candidate; true once it failed (the winner of a race
        /// is absorbed as not failed).
        failed: *const fn (*anyopaque) anyerror!bool,
    };
};

// ------------------------------------------------------------ argv shim

/// Command-line forms the shared parser does not have: bare
/// `venomx` (optionally with only `--socket`/`--json`) means `new`; inside
/// `new`, `-A`, `-d` and bare `--nested` are the boolean flags and a
/// trailing `-- program args...` becomes `--argv=<json>`. Everything else
/// is passed through unchanged to the generated parser.
pub fn rewriteArgs(a: std.mem.Allocator, argv: []const []const u8) ![]const []const u8 {
    var only_globals = true;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (eq(u8, arg, "--json")) continue;
        if (std.mem.startsWith(u8, arg, "--socket=")) continue;
        if (eq(u8, arg, "--socket") and i + 1 < argv.len) {
            i += 1;
            continue;
        }
        only_globals = false;
        break;
    }
    if (only_globals) {
        const out = try a.alloc([]const u8, argv.len + 1);
        out[0] = "new";
        @memcpy(out[1..], argv);
        return out;
    }
    // Only a leading `new` command is rewritten.
    if (argv.len == 0 or !eq(u8, argv[0], "new")) return argv;
    var out: std.ArrayList([]const u8) = .empty;
    try out.append(a, "new");
    i = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (eq(u8, arg, "--")) {
            const rest = argv[i + 1 ..];
            if (rest.len > 0) try out.append(a, try std.fmt.allocPrint(a, "--argv={f}", .{std.json.fmt(rest, .{})}));
            break;
        }
        if (eq(u8, arg, "-A")) {
            try out.append(a, "--attach-existing=true");
        } else if (eq(u8, arg, "-d")) {
            try out.append(a, "--detached=true");
        } else if (eq(u8, arg, "-Ad") or eq(u8, arg, "-dA")) {
            try out.append(a, "--attach-existing=true");
            try out.append(a, "--detached=true");
        } else if (eq(u8, arg, "--nested")) {
            try out.append(a, "--nested=true");
        } else try out.append(a, arg);
    }
    return out.items;
}

// ------------------------------------------------------------ defaults

/// `$SHELL` if absolute and executable, else the password database's login
/// shell, else /bin/sh.
pub fn defaultShell(a: std.mem.Allocator, environ: std.process.Environ) ![]const u8 {
    if (environ.getPosix("SHELL")) |sh| if (executable(a, sh)) return a.dupe(u8, sh);
    if (getpwuid(c.getuid())) |pw| if (pw.shell) |s| {
        const sh = std.mem.span(s);
        if (executable(a, sh)) return a.dupe(u8, sh);
    };
    return "/bin/sh";
}
fn executable(a: std.mem.Allocator, path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path) or path.len >= std.posix.PATH_MAX) return false;
    const z = a.dupeSentinel(u8, path, 0) catch return false;
    defer a.free(z);
    return c.access(z, c.X_OK) == 0;
}
/// The argv that starts `shell` as a login shell, with
/// `program` naming the file: `/bin/zsh` runs as `-zsh`.
pub fn loginArgv(a: std.mem.Allocator, shell: []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, 1);
    out[0] = try std.fmt.allocPrint(a, "-{s}", .{std.fs.path.basename(shell)});
    return out;
}

/// Basename of `cwd`, `/` gives `root`, truncated to 128 UTF-8 bytes on a
/// code point boundary. Control characters (which resource names reject)
/// become `_`.
pub fn defaultName(a: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const trimmed = std.mem.trimEnd(u8, cwd, "/");
    if (trimmed.len == 0) return "root";
    var base = std.fs.path.basename(trimmed);
    if (base.len > 128) {
        var end: usize = 128;
        while (end > 0 and (base[end] & 0xc0) == 0x80) end -= 1;
        base = base[0..end];
    }
    if (!std.unicode.utf8ValidateSlice(base)) return "root";
    const out = try a.dupe(u8, base);
    for (out) |*ch| if (ch.* < 32 or ch.* == 127) {
        ch.* = '_';
    };
    return out;
}

pub fn currentDir(a: std.mem.Allocator) ![]const u8 {
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    if (c.getcwd(&buf, buf.len) == null) return error.NoCwd;
    return a.dupe(u8, std.mem.sliceTo(&buf, 0));
}

// ------------------------------------------------------------ last session

pub const Last = struct { epoch: []const u8, session: []const u8 };

/// `$XDG_STATE_HOME/venomx/last-session`, else `$HOME/.local/state/...`.
pub fn lastPath(a: std.mem.Allocator, environ: std.process.Environ) !?[]const u8 {
    if (environ.getPosix("XDG_STATE_HOME")) |dir| if (std.fs.path.isAbsolute(dir)) return try std.fs.path.join(a, &.{ dir, "venomx", "last-session" });
    const home = environ.getPosix("HOME") orelse return null;
    if (!std.fs.path.isAbsolute(home)) return null;
    return try std.fs.path.join(a, &.{ home, ".local", "state", "venomx", "last-session" });
}

/// Bounded read; any malformed or oversized file reads as absent.
pub fn readLast(a: std.mem.Allocator, environ: std.process.Environ) !?Last {
    const path = (try lastPath(a, environ)) orelse return null;
    const z = try a.dupeSentinel(u8, path, 0);
    const fd = c.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .NONBLOCK = true });
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var buf: [1024]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0 or n == buf.len) return null;
    const parsed = std.json.parseFromSliceLeaky(Value, a, std.mem.trim(u8, buf[0..@intCast(n)], " \n"), .{}) catch return null;
    if (parsed != .object) return null;
    const epoch = parsed.object.get("epoch") orelse return null;
    const session = parsed.object.get("session") orelse return null;
    if (epoch != .string or session != .string) return null;
    return .{ .epoch = epoch.string, .session = session.string };
}

/// Best effort: private directory and file, written whole then renamed.
pub fn writeLast(a: std.mem.Allocator, environ: std.process.Environ, epoch: []const u8, session: []const u8) void {
    writeLastFallible(a, environ, epoch, session) catch {};
}
fn writeLastFallible(a: std.mem.Allocator, environ: std.process.Environ, epoch: []const u8, session: []const u8) !void {
    const path = (try lastPath(a, environ)) orelse return;
    const dir = std.fs.path.dirname(path).?;
    // mkdir -p the state directory and venomx/, both 0700.
    var at: usize = 1;
    while (at <= dir.len) : (at += 1) {
        if (at == dir.len or dir[at] == '/') {
            const part = try a.dupeSentinel(u8, dir[0..at], 0);
            _ = c.mkdir(part, 0o700);
        }
    }
    const tmp = try std.fmt.allocPrintSentinel(a, "{s}.{d}.tmp", .{ path, c.getpid() }, 0);
    const final = try a.dupeSentinel(u8, path, 0);
    const body = try std.fmt.allocPrint(a, "{f}\n", .{std.json.fmt(.{ .epoch = epoch, .session = session }, .{})});
    const fd = c.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.Open;
    const written = c.write(fd, body.ptr, body.len);
    _ = c.close(fd);
    if (written != @as(isize, @intCast(body.len)) or c.rename(tmp, final) != 0) {
        _ = c.unlink(tmp);
        return error.Write;
    }
}

// ------------------------------------------------------------ choosing

/// Session IDs are `s<n>`; a higher n is more recently created.
fn number(id: []const u8) ?u64 {
    if (id.len < 2 or id[0] != 's') return null;
    return std.fmt.parseInt(u64, id[1..], 10) catch null;
}
/// Selector-less attach: the last-attached session if it still
/// exists on this daemon (same epoch), else the most recently created one,
/// skipping `exclude`.
pub fn choose(sessions: []const Value, last: ?Last, epoch: []const u8, exclude: ?[]const u8) ?[]const u8 {
    if (last) |l| if (eq(u8, l.epoch, epoch)) for (sessions) |s| {
        const id = s.object.get("session").?.string;
        if (exclude != null and eq(u8, exclude.?, id)) continue;
        if (eq(u8, id, l.session)) return id;
    };
    var best: ?[]const u8 = null;
    var best_n: u64 = 0;
    for (sessions) |s| {
        const id = s.object.get("session").?.string;
        if (exclude != null and eq(u8, exclude.?, id)) continue;
        const n = number(id) orelse continue;
        if (best == null or n > best_n) {
            best = id;
            best_n = n;
        }
    }
    return best;
}

// ------------------------------------------------------------ NDJSON calls

/// A blocking NDJSON request on a ready client. Returns the response object
/// (`ok` or `error`), allocated in `a`.
pub fn request(a: std.mem.Allocator, client: *proto.Client, id: i64, verb: []const u8, params: anytype, stopped: *const std.atomic.Value(bool)) !Value {
    try client.request(id, verb, params);
    while (true) {
        if (stopped.load(.monotonic)) return error.Interrupted;
        const msg = try client.receive(100) orelse continue;
        if (msg != .ndjson) continue;
        const v = try std.json.parseFromSliceLeaky(Value, a, msg.ndjson, .{ .allocate = .alloc_always });
        if (v != .object) return error.InvalidResponse;
        const got = v.object.get("id") orelse continue;
        if (got != .integer or got.integer != id) continue;
        return v;
    }
}
pub fn errorCode(v: Value) ?[]const u8 {
    const e = v.object.get("error") orelse return null;
    const code = e.object.get("code") orelse return "internal";
    return if (code == .string) code.string else "internal";
}
pub fn okValue(v: Value) ?Value {
    return v.object.get("ok");
}

test "standalone: argv shim" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bare = try rewriteArgs(a, &.{});
    try t.expectEqual(@as(usize, 1), bare.len);
    try t.expectEqualStrings("new", bare[0]);
    const sock = try rewriteArgs(a, &.{ "--socket", "/x", "--json" });
    try t.expectEqualStrings("new", sock[0]);
    try t.expectEqualStrings("/x", sock[2]);
    const help = try rewriteArgs(a, &.{"--help"});
    try t.expectEqualStrings("--help", help[0]);
    const n = try rewriteArgs(a, &.{ "new", "-A", "--name", "work", "-d", "--nested", "--", "htop", "-d", "5" });
    try t.expectEqualStrings("--attach-existing=true", n[1]);
    try t.expectEqualStrings("--detached=true", n[4]);
    try t.expectEqualStrings("--nested=true", n[5]);
    try t.expectEqualStrings("--argv=[\"htop\",\"-d\",\"5\"]", n[6]);
    const other = try rewriteArgs(a, &.{ "session", "list" });
    try t.expectEqualStrings("session", other[0]);
}
test "standalone: login argv is the shell's basename after a dash" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const argv = try loginArgv(arena.allocator(), "/usr/bin/zsh");
    try t.expectEqual(@as(usize, 1), argv.len);
    try t.expectEqualStrings("-zsh", argv[0]);
}
test "standalone: default names" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("root", try defaultName(a, "/"));
    try t.expectEqualStrings("venomx", try defaultName(a, "/home/u/src/venomx"));
    try t.expectEqualStrings("venomx", try defaultName(a, "/home/u/src/venomx/"));
    var long_buf: [141]u8 = undefined;
    long_buf[0] = '/';
    for (0..70) |i| @memcpy(long_buf[1 + 2 * i ..][0..2], "\xc3\xa9");
    const long: []const u8 = &long_buf; // 140 name bytes; truncation keeps whole code points
    const name = try defaultName(a, long);
    try t.expectEqual(@as(usize, 128), name.len);
    try t.expect(std.unicode.utf8ValidateSlice(name));
    try t.expectEqualStrings("a_b", try defaultName(a, "/a\x01b"));
}
test "standalone: choosing a session" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try std.json.parseFromSliceLeaky(Value, a, "[{\"session\":\"s2\",\"name\":\"\"},{\"session\":\"s10\",\"name\":\"\"},{\"session\":\"s3\",\"name\":\"\"}]", .{});
    const items = list.array.items;
    try t.expectEqualStrings("s10", choose(items, null, "e1", null).?);
    try t.expectEqualStrings("s3", choose(items, .{ .epoch = "e1", .session = "s3" }, "e1", null).?);
    // A stale epoch is ignored.
    try t.expectEqualStrings("s10", choose(items, .{ .epoch = "e0", .session = "s3" }, "e1", null).?);
    try t.expectEqualStrings("s3", choose(items, null, "e1", "s10").?);
    try t.expectEqual(@as(?[]const u8, null), choose(items[0..0], null, "e1", null));
}

const Passwd = extern struct { name: ?[*:0]const u8, passwd: ?[*:0]const u8, uid: c.uid_t, gid: c.gid_t, gecos: ?[*:0]const u8, dir: ?[*:0]const u8, shell: ?[*:0]const u8 };
extern "c" fn getpwuid(uid: c.uid_t) ?*const Passwd;
