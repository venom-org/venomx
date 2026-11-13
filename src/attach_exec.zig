//! `exec` key binding targets, run by the presentation client:
//! argv directly (no shell), stdin from the null device, output discarded,
//! and no venomx token in the child's environment, so the
//! child is authorized by whatever tool it calls under that tool's rules.
const std = @import("std");
const c = std.c;

const execvpe = @import("os.zig").execvpe;
extern "c" fn setsid() c_int;

/// Whether an environment entry is withheld from an exec child: the venomx
/// token and principal, and any value carrying a credential. The same rule
/// venom-desk applies: venom-term's `chrome.exec_env`.
pub const withheld = @import("term_chrome").exec_env.withheld;

/// The child environment: the client's own minus `withheld` entries. The
/// pointers borrow `environ`; the list itself is owned by `a`.
pub fn childEnviron(a: std.mem.Allocator, environ: std.process.Environ) ![:null]?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    errdefer list.deinit(a);
    for (environ.block.slice) |entry| {
        const bytes = std.mem.span(entry.?);
        if (!withheld(bytes)) try list.append(a, entry.?);
    }
    return list.toOwnedSliceSentinel(a, null);
}

/// Starts `argv` and returns its pid. Everything is prepared before fork;
/// the child only calls setsid, dup2, execvpe and _exit.
pub fn spawn(a: std.mem.Allocator, argv: []const []const u8, env: [:null]const ?[*:0]const u8) !c.pid_t {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const x = arena.allocator();
    const args = try x.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, args) |arg, *dst| dst.* = try x.dupeSentinel(u8, arg, 0);
    const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
    if (null_fd < 0) return error.SpawnFailed;
    defer _ = c.close(null_fd);
    const pid = c.fork();
    if (pid < 0) return error.SpawnFailed;
    if (pid == 0) {
        // A new session: a later terminal hangup of the client never
        // reaches the child, and it cannot read the client's terminal.
        _ = setsid();
        for ([_]c_int{ 0, 1, 2 }) |fd| _ = c.dup2(null_fd, fd);
        _ = execvpe(args[0].?, args.ptr, env.ptr);
        c._exit(127);
    }
    return pid;
}

/// Children still running; reaped without blocking once per transport turn.
pub const Children = struct {
    pids: std.ArrayList(c.pid_t) = .empty,
    pub fn deinit(self: *Children, a: std.mem.Allocator) void {
        self.pids.deinit(a);
    }
    pub const Exit = struct { status: u8, signaled: bool };
    /// The first child that has exited unsuccessfully since the last call,
    /// if any; successful exits are dropped silently.
    pub fn reap(self: *Children) ?Exit {
        var i: usize = 0;
        var failed: ?Exit = null;
        while (i < self.pids.items.len) {
            var status: c_int = 0;
            const n = c.waitpid(self.pids.items[i], &status, c.W.NOHANG);
            if (n == 0) {
                i += 1;
                continue;
            }
            _ = self.pids.swapRemove(i);
            if (n < 0) continue;
            const s: u32 = @bitCast(status);
            if (std.posix.W.IFSIGNALED(s)) {
                if (failed == null) failed = .{ .status = @intCast(@backingInt(std.posix.W.TERMSIG(s))), .signaled = true };
            } else if (std.posix.W.EXITSTATUS(s) != 0) {
                if (failed == null) failed = .{ .status = std.posix.W.EXITSTATUS(s), .signaled = false };
            }
        }
        return failed;
    }
};

test "exec children get no venomx token, principal or credential" {
    const t = std.testing;
    try t.expect(withheld("VENOMX_TOKEN=@owner"));
    try t.expect(withheld("VENOMX_PRINCIPAL=g3"));
    try t.expect(withheld("OTHER_TOKEN=@owner"));
    try t.expect(withheld("NOTE=prefix vnt1.venomx.g7.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"));
    try t.expect(!withheld("HOME=/home/x"));
    try t.expect(!withheld("VENOMX_PANE=p3"));
}
