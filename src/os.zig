//! The few libc calls whose Linux form doesn't exist on macOS. Linux keeps
//! the exact calls it used before; Darwin gets the portable equivalent.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

const darwin = builtin.os.tag.isDarwin();

fn request(value: anytype) c_int {
    return @bitCast(@as(u32, @intCast(value)));
}

/// `ioctl` request numbers for the window size. Darwin's `TIOCSWINSZ` is
/// `_IOW('t', 103, struct winsize)`, missing from Zig's bindings.
pub const TIOCSWINSZ: c_int = if (darwin) request(0x80087467) else request(std.posix.T.IOCSWINSZ);
pub const TIOCGWINSZ: c_int = request(std.posix.T.IOCGWINSZ);

/// `pipe2(2)`. Darwin has no `pipe2`: `pipe` then `fcntl`. Not atomic against
/// a concurrent fork, so set it up before forking threads exist or accept it.
pub fn pipe2(fds: *[2]c.fd_t, flags: c.O) c_int {
    if (!darwin) return c.pipe2(fds, flags);
    if (c.pipe(fds) != 0) return -1;
    for (fds) |fd| {
        const ok = (!flags.CLOEXEC or c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) != -1) and
            (!flags.NONBLOCK or setNonblock(fd));
        if (!ok) {
            _ = c.close(fds[0]);
            _ = c.close(fds[1]);
            return -1;
        }
    }
    return 0;
}

fn setNonblock(fd: c.fd_t) bool {
    const fl = c.fcntl(fd, c.F.GETFL);
    if (fl == -1) return false;
    const nonblock: c_int = @bitCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
    return c.fcntl(fd, c.F.SETFL, fl | nonblock) != -1;
}

/// Fills `buf` from the kernel CSPRNG.
pub fn randomBytes(buf: []u8) void {
    if (darwin) return c.arc4random_buf(buf.ptr, buf.len);
    var got: usize = 0;
    while (got < buf.len) {
        const n = c.getrandom(buf[got..].ptr, buf.len - got, 0);
        if (n > 0) got += @intCast(n);
    }
}

/// `execvpe(3)`: Darwin has none, so set `environ` and `execvp`. Call it only
/// in a forked child, where nothing else reads the environment.
pub fn execvpe(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int {
    if (!darwin) return linux_execvpe(file, argv, envp);
    c.environ = @ptrCast(@constCast(envp));
    return execvp(file, argv);
}
const linux_execvpe = @extern(*const fn ([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8) callconv(.c) c_int, .{ .name = "execvpe" });
extern "c" fn execvp([*:0]const u8, [*:null]const ?[*:0]const u8) c_int;

pub const FileStat = struct { mode: u32, uid: u32, nlink: u64, size: u64 };

/// `fstat` of an open fd; null on error.
pub fn fstat(fd: c.fd_t) ?FileStat {
    if (darwin) {
        var st: c.Stat = undefined;
        if (c.fstat(fd, &st) != 0) return null;
        return fromStat(&st);
    }
    var st: std.os.linux.Statx = undefined;
    if (c.statx(fd, "", c.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .UID = true, .NLINK = true, .SIZE = true }, &st) != 0) return null;
    return .{ .mode = st.mode, .uid = st.uid, .nlink = st.nlink, .size = st.size };
}

/// `stat` of a path (follows symlinks); null on error.
pub fn stat(path: [*:0]const u8) ?FileStat {
    if (darwin) {
        var st: c.Stat = undefined;
        if (c.stat(path, &st) != 0) return null;
        return fromStat(&st);
    }
    var st: std.os.linux.Statx = undefined;
    if (c.statx(c.AT.FDCWD, path, 0, .{ .TYPE = true, .MODE = true, .UID = true, .NLINK = true, .SIZE = true }, &st) != 0) return null;
    return .{ .mode = st.mode, .uid = st.uid, .nlink = st.nlink, .size = st.size };
}

fn fromStat(st: *const c.Stat) FileStat {
    return .{ .mode = st.mode, .uid = st.uid, .nlink = st.nlink, .size = @intCast(st.size) };
}

test "os: pipe2 gives a nonblocking cloexec pair" {
    var fds: [2]c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true }));
    defer for (fds) |fd| {
        _ = c.close(fd);
    };
    try std.testing.expect(c.fcntl(fds[0], c.F.GETFD) & c.FD_CLOEXEC != 0);
    var b: [1]u8 = undefined;
    try std.testing.expect(c.read(fds[0], &b, 1) < 0);
    const st = fstat(fds[0]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, c.S.IFIFO), st.mode & c.S.IFMT);
}

test "os: randomBytes fills the buffer" {
    var a: [32]u8 = @splat(0);
    randomBytes(&a);
    try std.testing.expect(!std.mem.allEqual(u8, &a, 0));
}
