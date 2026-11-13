//! Nonblocking PTY ownership. Only the pane reactor writes the master.
const std = @import("std");
const c = std.c;
const Vt = @import("vt").Vt;
const Size = Vt.Size;
fn pixels(cells: u16, cell: u32) u16 {
    return @intCast(@min(@as(u64, cells) * cell, std.math.maxInt(u16)));
}
extern "c" fn forkpty(*c_int, ?[*]u8, ?*const std.posix.termios, ?*const std.posix.winsize) c_int;
extern "c" fn execvp([*:0]const u8, [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;

extern "c" fn chdir([*:0]const u8) c_int;
extern "c" fn execve([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8) c_int;

/// What the child is to run. Everything is built before
/// fork; the child only calls chdir, execve, write and _exit.
pub const Launch = struct {
    /// Tried in order; empty means "not found".
    candidates: [*:null]const ?[*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    env: [*:null]const ?[*:0]const u8,
    cwd: ?[*:0]const u8 = null,
};
/// A failed child start as reported through the exec-status pipe.
pub const Failure = struct {
    phase: Phase,
    errno: std.posix.E,
    pub const Phase = enum(u8) { cwd = 1, exec = 2 };
};

/// A child remains behind a start barrier until its principal is bound. The
/// CLOEXEC status pipe distinguishes failed exec from successful exit 127 and
/// carries the failing phase and errno.
pub const Prepared = struct {
    pty: Pty,
    gate: c_int,
    status: c_int,
    /// Set when `start` returns error.ExecFailed.
    failure: ?Failure = null,
    pub fn abort(self: *Prepared) void {
        _ = c.close(self.gate);
        _ = c.close(self.status);
        self.pty.deinit();
    }
    pub fn start(self: *Prepared) !Pty {
        const byte = [_]u8{1};
        if (c.send(self.gate, &byte, 1, c.MSG.NOSIGNAL) != 1) return error.ChildStart;
        _ = c.close(self.gate);
        self.gate = -1;
        var fds = [_]c.pollfd{.{ .fd = self.status, .events = c.POLL.IN, .revents = 0 }};
        const deadline = @import("server.zig").nowMs() + 2000;
        var report: [3]u8 = undefined;
        var got: usize = 0;
        while (true) {
            const left = deadline - @import("server.zig").nowMs();
            if (left <= 0) return error.ExecTimeout;
            const n = c.poll(&fds, 1, @intCast(left));
            if (n < 0 and c.errno(n) == .INTR) continue;
            if (n <= 0) return error.ChildStart;
            const received = c.read(self.status, report[got..].ptr, report.len - got);
            if (received < 0 and c.errno(received) == .INTR) continue;
            if (received < 0) return error.ChildStart;
            got += @intCast(received);
            if (received != 0 and got < report.len) continue;
            if (got != 0) {
                self.failure = .{
                    .phase = if (report[0] == @backingInt(Failure.Phase.cwd)) .cwd else .exec,
                    .errno = if (got == report.len) @fromBackingInt(@intCast(std.mem.readInt(u16, report[1..3], .little))) else .INVAL,
                };
                return error.ExecFailed;
            }
            _ = c.close(self.status);
            self.status = -1;
            return self.pty;
        }
    }
};
fn childErrno() u16 {
    return @intCast(@backingInt(c.errno(@as(c_int, -1))));
}
/// Async-signal-safe: one write of three bytes (below PIPE_BUF), then _exit.
fn childFail(fd: c_int, phase: Failure.Phase, errno: u16) noreturn {
    var report = [3]u8{ @backingInt(phase), @truncate(errno), @truncate(errno >> 8) };
    _ = c.write(fd, &report, report.len);
    c._exit(127);
}
pub const Pty = struct {
    fd: c_int,
    pid: c.pid_t,
    reaped: bool = false,
    eof: bool = false,
    /// Adopted by supervisor.Leaders, the only code that may wait on it.
    supervised: bool = false,
    pub fn spawn(argv: [*:null]const ?[*:0]const u8, size: Size) !Pty {
        const ws: std.posix.winsize = .{ .col = size.cols, .row = size.rows, .xpixel = 0, .ypixel = 0 };
        var fd: c_int = -1;
        const pid = forkpty(&fd, null, null, &ws);
        if (pid < 0) return error.ForkPty;
        if (pid == 0) {
            _ = setenv("TERM", "xterm-256color", 1);
            _ = execvp(argv[0].?, argv);
            c._exit(127);
        }
        var self: Pty = .{ .fd = fd, .pid = pid };
        errdefer self.deinit();
        const flags = c.fcntl(fd, c.F.GETFL);
        const nb: c_int = @bitCast(@as(c.O, .{ .NONBLOCK = true }));
        if (flags < 0 or c.fcntl(fd, c.F.SETFL, flags | nb) < 0 or c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.SystemResources;
        return self;
    }
    pub fn prepare(launch: Launch, size: Size) !Prepared {
        var gate: [2]c_int = undefined;
        var status: [2]c_int = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &gate) != 0) return error.SystemResources;
        defer _ = c.close(gate[0]);
        errdefer _ = c.close(gate[1]);
        if (c.pipe(&status) != 0) return error.SystemResources;
        defer _ = c.close(status[1]);
        errdefer _ = c.close(status[0]);
        for (gate ++ status) |fd| if (c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.SystemResources;
        const ws: std.posix.winsize = .{ .col = size.cols, .row = size.rows, .xpixel = 0, .ypixel = 0 };
        var fd: c_int = -1;
        const pid = forkpty(&fd, null, null, &ws);
        if (pid < 0) return error.ForkPty;
        if (pid == 0) {
            _ = c.close(gate[1]);
            _ = c.close(status[0]);
            var byte: [1]u8 = undefined;
            var n = c.read(gate[0], &byte, 1);
            while (n < 0 and c.errno(n) == .INTR) n = c.read(gate[0], &byte, 1);
            if (n != 1) c._exit(127);
            _ = c.close(gate[0]);
            if (launch.cwd) |dir| if (chdir(dir) != 0) childFail(status[1], .cwd, childErrno());
            // Try each candidate; never fall back to a shell.
            const not_found: u16 = @backingInt(std.posix.E.NOENT);
            var last: u16 = not_found;
            var denied = false;
            var i: usize = 0;
            while (launch.candidates[i]) |candidate| : (i += 1) {
                _ = execve(candidate, launch.argv, launch.env);
                const e = childErrno();
                switch (@as(std.posix.E, @fromBackingInt(@intCast(e)))) {
                    .NOENT, .NOTDIR, .LOOP, .NAMETOOLONG => last = e,
                    .ACCES => denied = true,
                    else => childFail(status[1], .exec, e),
                }
            }
            childFail(status[1], .exec, if (denied) @backingInt(std.posix.E.ACCES) else last);
        }
        var pty: Pty = .{ .fd = fd, .pid = pid };
        errdefer pty.deinit();
        const flags = c.fcntl(fd, c.F.GETFL);
        const nb: c_int = @bitCast(@as(c.O, .{ .NONBLOCK = true }));
        if (flags < 0 or c.fcntl(fd, c.F.SETFL, flags | nb) < 0 or c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0) return error.SystemResources;
        return .{ .pty = pty, .gate = gate[1], .status = status[0] };
    }
    pub fn deinit(self: *Pty) void {
        _ = c.close(self.fd);
        if (!self.reaped and !self.supervised) {
            _ = c.kill(-self.pid, .KILL);
            _ = c.kill(self.pid, .KILL);
            // Last-resort cleanup is bounded even for an unkillable OS task.
            _ = self.reapUntil(@import("server.zig").nowMs() + 200);
        }
    }
    pub fn reapUntil(self: *Pty, deadline: i64) bool {
        if (self.reaped) return true;
        while (true) {
            const n = c.waitpid(self.pid, null, c.W.NOHANG);
            if (n == self.pid or (n < 0 and c.errno(n) == .CHILD)) {
                self.reaped = true;
                return true;
            }
            if (n < 0 and c.errno(n) != .INTR) return false;
            if (@import("server.zig").nowMs() >= deadline) return false;
            const pause: c.timespec = .{ .sec = 0, .nsec = 1000000 };
            _ = c.nanosleep(&pause, null);
        }
    }
    /// `cell` is one cell's size in pixels (zero when unknown); the PTY's
    /// pixel size is the grid's, clamped to what winsize holds.
    pub fn resize(self: Pty, size: Size, cell: Vt.CellSize) !void {
        const ws: std.posix.winsize = .{ .col = size.cols, .row = size.rows, .xpixel = pixels(size.cols, cell.width), .ypixel = pixels(size.rows, cell.height) };
        if (c.ioctl(self.fd, @import("os.zig").TIOCSWINSZ, @intFromPtr(&ws)) != 0) return error.SystemResources;
    }
    pub fn read(self: *Pty, buf: []u8) !usize {
        if (self.eof) return 0;
        const n = c.read(self.fd, buf.ptr, buf.len);
        if (n > 0) return @intCast(n);
        if (n < 0) switch (c.errno(n)) {
            .AGAIN, .INTR => return 0,
            .IO => {}, // Linux masters report EIO after the slave closes.
            else => return error.PtyRead,
        };
        self.eof = true;
        return 0;
    }
    pub fn write(self: Pty, bytes: []const u8) !usize {
        const n = c.write(self.fd, bytes.ptr, bytes.len);
        if (n >= 0) return @intCast(n);
        return switch (c.errno(n)) {
            .AGAIN, .INTR => 0,
            else => error.PtyWrite,
        };
    }
    /// Only report exit after EOF, so buffered PTY output precedes EXIT.
    pub fn exited(self: *Pty) !?u32 {
        std.debug.assert(!self.supervised);
        if (!self.eof or self.reaped) return null;
        var status: c_int = 0;
        const n = c.waitpid(self.pid, &status, c.W.NOHANG);
        if (n == 0) return null;
        if (n < 0) return if (c.errno(n) == .INTR) null else error.WaitPid;
        self.reaped = true;
        return @bitCast(status);
    }
};

test "the PTY's pixel size is the grid times the cell size" {
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", "sleep 5" };
    var pty = try Pty.spawn(&argv, .{ .cols = 80, .rows = 24 });
    defer pty.deinit();
    var ws: std.posix.winsize = undefined;
    const get = @as(c_int, @bitCast(@as(u32, @intCast(std.posix.T.IOCGWINSZ))));
    try std.testing.expectEqual(@as(c_int, 0), c.ioctl(pty.fd, get, @intFromPtr(&ws)));
    try std.testing.expectEqual(@as(u16, 0), ws.xpixel);
    try pty.resize(.{ .cols = 100, .rows = 30 }, .{ .width = 9, .height = 18 });
    try std.testing.expectEqual(@as(c_int, 0), c.ioctl(pty.fd, get, @intFromPtr(&ws)));
    try std.testing.expectEqual(std.posix.winsize{ .col = 100, .row = 30, .xpixel = 900, .ypixel = 540 }, ws);
    // Clamped to what winsize holds.
    try pty.resize(.{ .cols = 65535, .rows = 1 }, .{ .width = 4096, .height = 1 });
    try std.testing.expectEqual(@as(c_int, 0), c.ioctl(pty.fd, get, @intFromPtr(&ws)));
    try std.testing.expectEqual(@as(u16, 65535), ws.xpixel);
}
