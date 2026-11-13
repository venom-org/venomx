//! Daemon test seam, compiled in only with `-Dtest-seams=true`
//! (the integration binary). Production builds use kill(2) directly.
//!
//! * `VENOMX_TEST_SIGNAL_LOG=<path>` appends `<pid> <signal>\n` for every
//!   signal the daemon sends (kill(2) convention: negative is a group).
//! * A leader whose argv[0] basename is `venomx-stuck` stands in for an
//!   unkillable process: its SIGKILLs are withheld. The test ends it itself.
//!
//! Startup fault injection, on-demand serve only:
//! * `VENOMX_TEST_STARTUP_FAIL` (any value) fails candidate initialization
//!   after the listener exists, before readiness.
//! * `VENOMX_TEST_STARTUP_DELAY_MS=<ms>` withholds readiness (listening, not
//!   dispatching) for that long after process entry, bounded by the budget.
//! * `VENOMX_TEST_DROP_REPLY` drops the first committed session.create
//!   response and closes that connection: a lost reply.
//!
//! Run lost-reply cases: `VENOMX_TEST_RUN_DROP=before` closes the first
//! `run` connection just before the child-start barrier is released (the
//! start rolls back); `=after` drops the first committed `run` response and
//! closes that connection (a lost reply).
//!
//! Spawn seams:
//!
//! * `VENOMX_TEST_SEAM_LOG=<path>` appends `realpath\n` for every cwd
//!   resolution, so a test can prove an unauthorized request touched no path.
//! * A resolved cwd whose basename starts with `venomx-vanish` is removed
//!   right after resolution, before the child's chdir.
//! * `VENOMX_TEST_SPAWN_FAIL=<step>` fails that preparation step after cwd
//!   resolution: `prepare`, `adopt`, `stat` or `start`.
//!
//! capture_rows seam:
//!
//! * `VENOMX_TEST_SCROLLBACK_LINES=<n>` gives new panes a small scrollback,
//!   so scrollback eviction cases need little output (Debug emulation is slow).
const std = @import("std");
const c = std.c;
const options = @import("build_options");
const SIG = std.posix.SIG;

pub const enabled = options.test_seams;

var log_fd: c.fd_t = -1;
var fail_startup = false;
var delay_ms: i64 = 0;
var drop_reply = false;
var run_drop: enum { none, before, after } = .none;
var seam_fd: c.fd_t = -1;
var fail_step: [16]u8 = @splat(0);
var fail_len: usize = 0;
var stuck: [64]c.pid_t = @splat(0);
/// Scrollback for new panes' Vt, or null for the library default.
pub var scrollback_lines: ?usize = null;

fn openLog(path: []const u8) c.fd_t {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return -1;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return c.open(@ptrCast(&buf), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
}

pub fn init(environ: std.process.Environ) void {
    if (!enabled) return;
    fail_startup = environ.getPosix("VENOMX_TEST_STARTUP_FAIL") != null;
    drop_reply = environ.getPosix("VENOMX_TEST_DROP_REPLY") != null;
    if (environ.getPosix("VENOMX_TEST_RUN_DROP")) |v| run_drop = if (std.mem.eql(u8, v, "before")) .before else if (std.mem.eql(u8, v, "after")) .after else .none;
    if (environ.getPosix("VENOMX_TEST_STARTUP_DELAY_MS")) |v| delay_ms = std.fmt.parseInt(i64, v, 10) catch 0;
    if (environ.getPosix("VENOMX_TEST_SIGNAL_LOG")) |path| log_fd = openLog(path);
    if (environ.getPosix("VENOMX_TEST_SEAM_LOG")) |path| seam_fd = openLog(path);
    if (environ.getPosix("VENOMX_TEST_SCROLLBACK_LINES")) |n| scrollback_lines = std.fmt.parseInt(usize, n, 10) catch null;
    if (environ.getPosix("VENOMX_TEST_SPAWN_FAIL")) |step| if (step.len <= fail_step.len) {
        @memcpy(fail_step[0..step.len], step);
        fail_len = step.len;
    };
}

/// Called for every cwd resolution, before `realpath`.
pub fn resolving() void {
    if (!enabled or seam_fd < 0) return;
    _ = c.write(seam_fd, "realpath\n", 9);
}

/// Called with the resolved cwd, before preparation.
pub fn resolved(path: [:0]const u8) void {
    if (!enabled) return;
    if (std.mem.startsWith(u8, std.fs.path.basename(path), "venomx-vanish")) _ = c.rmdir(path.ptr);
}

/// Whether the integration test asked this preparation step to fail.
pub fn fails(step: []const u8) bool {
    return enabled and fail_len > 0 and std.mem.eql(u8, fail_step[0..fail_len], step);
}

/// Marks `pid` as unkillable if its program is the stuck stand-in.
pub fn spawned(argv0: []const u8, pid: c.pid_t) void {
    if (!enabled) return;
    if (!std.mem.eql(u8, std.fs.path.basename(argv0), "venomx-stuck")) return;
    for (&stuck) |*slot| if (slot.* == 0) {
        slot.* = pid;
        return;
    };
}

pub fn send(pid: c.pid_t, sig: SIG) c_int {
    if (log_fd >= 0) {
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{d} {d}\n", .{ pid, @backingInt(sig) }) catch unreachable;
        _ = c.write(log_fd, line.ptr, line.len);
    }
    if (sig == .KILL) for (stuck) |s| if (s != 0 and (s == pid or -s == pid)) return 0;
    if (c.kill(pid, sig) == 0) return 0;
    return @intCast(@backingInt(c.errno(@as(c_int, -1))));
}

pub fn startupFailure() bool {
    return enabled and fail_startup;
}
/// True while readiness is still withheld, `elapsed_ms` after process entry.
pub fn startupDelay(elapsed_ms: i64) bool {
    return enabled and elapsed_ms < delay_ms;
}
/// One-shot: discard the queued create response and close the connection.
pub fn createCommitted(conn: anytype) void {
    if (!enabled or !drop_reply) return;
    drop_reply = false;
    conn.output.clearRetainingCapacity();
    conn.sent = 0;
    conn.closing = true;
}
/// One-shot: the `run` connection closes before the barrier is released.
pub fn runBarrier(conn: anytype) void {
    if (!enabled or run_drop != .before) return;
    run_drop = .none;
    conn.closing = true;
}
/// One-shot: discard the committed `run` response and close the connection.
pub fn runCommitted(conn: anytype) void {
    if (!enabled or run_drop != .after) return;
    run_drop = .none;
    conn.output.clearRetainingCapacity();
    conn.sent = 0;
    conn.closing = true;
}
