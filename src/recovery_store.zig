//! Private checkpoint store: `<state>/venomx/recovery/<key>/`.
//! Every operation is directory-relative and no-follow; files are validated
//! on the opened handle and read from that same handle. Publication is
//! exclusive temp file, fsync, rename to a fresh name, then directory fsync.
const std = @import("std");
const c = std.c;
const os = @import("os.zig");
const format = @import("recovery_format.zig");

pub const Error = error{ Unsafe, Io, OutOfMemory, TooLarge, Missing };

/// Interrupted-write cases. Only the test seam sets one.
pub const Fault = enum { none, before_write, short_write, fsync, rename, dir_fsync, prune, text_export };

/// Lowercase SHA-256 of the absolute socket path.
pub fn socketKey(socket: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(socket, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn z(buf: []u8, name: []const u8) [:0]const u8 {
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    return buf[0..name.len :0];
}
const Stat = struct { size: u64 };
fn fstatSafe(fd: c.fd_t, kind: u32) Error!Stat {
    const st = os.fstat(fd) orelse return error.Io;
    if (st.mode & c.S.IFMT != kind or st.uid != c.getuid() or st.mode & 0o077 != 0) return error.Unsafe;
    if (kind == c.S.IFREG and st.nlink != 1) return error.Unsafe;
    return .{ .size = st.size };
}
/// Opens (optionally creating 0700) one private directory component.
fn openDir(parent: c.fd_t, name: []const u8, create: bool) Error!?c.fd_t {
    var buf: [256]u8 = undefined;
    const path = z(&buf, name);
    var fd = c.openat(parent, path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (fd < 0 and c.errno(fd) == .NOENT) {
        if (!create) return null;
        if (c.mkdirat(parent, path, 0o700) != 0 and c.errno(-1) != .EXIST) return error.Io;
        fd = c.openat(parent, path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    }
    if (fd < 0) return switch (c.errno(fd)) {
        .LOOP, .NOTDIR => error.Unsafe,
        else => error.Io,
    };
    errdefer _ = c.close(fd);
    _ = try fstatSafe(fd, c.S.IFDIR);
    return fd;
}
/// Opens the base directory (creating missing components 0700 when asked).
fn openBase(base: []const u8, create: bool) Error!?c.fd_t {
    if (base.len == 0 or base[0] != '/' or base.len >= 4096) return error.Unsafe;
    var fd = c.open("/", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (fd < 0) return error.Io;
    var parts = std.mem.tokenizeScalar(u8, base, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..") or part.len > 255) {
            _ = c.close(fd);
            return error.Unsafe;
        }
        var buf: [256]u8 = undefined;
        const path = z(&buf, part);
        // The user's own base may be reached through symlinks; the private
        // subtree below it may not.
        var next = c.openat(fd, path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
        if (next < 0 and c.errno(next) == .NOENT and create) {
            if (c.mkdirat(fd, path, 0o700) != 0 and c.errno(-1) != .EXIST) {
                _ = c.close(fd);
                return error.Io;
            }
            next = c.openat(fd, path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
        }
        _ = c.close(fd);
        if (next < 0) return if (c.errno(next) == .NOENT) null else error.Io;
        fd = next;
    }
    return fd;
}

pub const Kind = enum { final, temporary };
pub const Entry = struct {
    name: [64]u8 = undefined,
    len: u8 = 0,
    kind: Kind,
    pub fn slice(self: *const Entry) []const u8 {
        return self.name[0..self.len];
    }
    /// The checkpoint ID of a final entry.
    pub fn id(self: *const Entry) []const u8 {
        return self.name[0 .. self.len - 5];
    }
};
fn classify(name: []const u8) ?Kind {
    if (name.len == 42 and std.mem.endsWith(u8, name, ".json") and format.validId(name[0..37])) return .final;
    if (std.mem.startsWith(u8, name, ".tmp-") and name.len == 41) return .temporary;
    return null;
}

/// Every method takes `*const Store` and is directory-relative, so one
/// reactor thread and one checkpoint writer thread may use the same store
/// at once; `fault` and `delay_ms` are set before either starts.
pub const Store = struct {
    dir: c.fd_t,
    fault: Fault = .none,
    /// Test seam: the writer sleeps this long before publishing, standing
    /// in for a slow fsync (off-reactor writer busy and coalescing cases).
    delay_ms: u32 = 0,

    /// Opens `<base>/venomx/recovery/<key>`; null when absent and not creating.
    pub fn open(base: []const u8, key: []const u8, create: bool) Error!?Store {
        const b = (try openBase(base, create)) orelse return null;
        defer _ = c.close(b);
        const tool = (try openDir(b, "venomx", create)) orelse return null;
        defer _ = c.close(tool);
        const rec = (try openDir(tool, "recovery", create)) orelse return null;
        defer _ = c.close(rec);
        const leaf = (try openDir(rec, key, create)) orelse return null;
        return .{ .dir = leaf };
    }
    pub fn close(self: *Store) void {
        _ = c.close(self.dir);
        self.dir = -1;
    }
    /// The held handle still names a private directory owned by this UID.
    pub fn check(self: *const Store) Error!void {
        _ = try fstatSafe(self.dir, c.S.IFDIR);
    }
    /// Final and temporary entries, bounded by `max`. Other names are ignored.
    pub fn list(self: *const Store, a: std.mem.Allocator, max: usize) Error![]Entry {
        // A fresh open description, not dup(): its directory offset is not
        // shared, so the reactor and the off-reactor writer can
        // enumerate concurrently. Revalidated on the new handle.
        const fd = c.openat(self.dir, ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
        if (fd < 0) return error.Io;
        _ = fstatSafe(fd, c.S.IFDIR) catch |err| {
            _ = c.close(fd);
            return err;
        };
        const d = c.fdopendir(fd) orelse {
            _ = c.close(fd);
            return error.Io;
        };
        defer _ = c.closedir(d);
        var out: std.ArrayList(Entry) = .empty;
        errdefer out.deinit(a);
        while (c.readdir(d)) |ent| {
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
            const kind = classify(name) orelse continue;
            if (out.items.len >= max) return error.TooLarge;
            var e: Entry = .{ .kind = kind, .len = @intCast(name.len) };
            @memcpy(e.name[0..name.len], name);
            try out.append(a, e);
        }
        std.mem.sort(Entry, out.items, {}, struct {
            fn lt(_: void, x: Entry, y: Entry) bool {
                return std.mem.lessThan(u8, x.slice(), y.slice());
            }
        }.lt);
        return out.toOwnedSlice(a);
    }
    fn openFile(self: *const Store, name: []const u8) Error!c.fd_t {
        var buf: [256]u8 = undefined;
        const fd = c.openat(self.dir, z(&buf, name), .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true });
        if (fd < 0) return switch (c.errno(fd)) {
            .NOENT => error.Missing,
            .LOOP => error.Unsafe,
            else => error.Io,
        };
        return fd;
    }
    /// Validates owner, mode, link count, type and size on the opened handle
    /// and reads that same handle.
    pub fn read(self: *const Store, a: std.mem.Allocator, name: []const u8, limit: usize) Error![]u8 {
        const fd = try self.openFile(name);
        defer _ = c.close(fd);
        const st = try fstatSafe(fd, c.S.IFREG);
        if (st.size > limit) return error.TooLarge;
        const size: usize = @intCast(st.size);
        if (size > limit) return error.TooLarge;
        const out = try a.alloc(u8, size);
        errdefer a.free(out);
        var got: usize = 0;
        while (got < size) {
            const n = c.read(fd, out[got..].ptr, size - got);
            if (n < 0 and c.errno(n) == .INTR) continue;
            if (n <= 0) return error.Io;
            got += @intCast(n);
        }
        // Growth after fstat is a replaced or concurrently written file.
        var extra: [1]u8 = undefined;
        if (c.read(fd, &extra, 1) != 0) return error.Io;
        return out;
    }
    /// The file is a safely owned regular file (for forget and pruning).
    pub fn safe(self: *const Store, name: []const u8) Error!void {
        const fd = try self.openFile(name);
        defer _ = c.close(fd);
        _ = try fstatSafe(fd, c.S.IFREG);
    }
    pub fn remove(self: *const Store, name: []const u8) Error!void {
        if (self.fault == .prune) return error.Io;
        var buf: [256]u8 = undefined;
        if (c.unlinkat(self.dir, z(&buf, name), 0) != 0) return if (c.errno(-1) == .NOENT) error.Missing else error.Io;
    }
    pub fn sync(self: *const Store) Error!void {
        if (c.fsync(self.dir) != 0) return error.Io;
    }
    /// Durable publication of `bytes` as `<id>.json` (temp file, fsync, rename).
    /// Success means the directory fsync after rename returned success.
    pub fn publish(self: *const Store, id: []const u8, temp_id: []const u8, bytes: []const u8) Error!void {
        var tbuf: [64]u8 = undefined;
        const temp = std.fmt.bufPrintSentinel(&tbuf, ".tmp-{s}", .{temp_id[1..]}, 0) catch unreachable;
        var fbuf: [64]u8 = undefined;
        const final = std.fmt.bufPrintSentinel(&fbuf, "{s}.json", .{id}, 0) catch unreachable;
        if (self.delay_ms > 0) {
            var ts: c.timespec = .{ .sec = @intCast(self.delay_ms / 1000), .nsec = @intCast(@as(u64, self.delay_ms % 1000) * 1_000_000) };
            while (c.nanosleep(&ts, &ts) != 0 and c.errno(@as(c_int, -1)) == .INTR) {}
        }
        if (self.fault == .before_write) return error.Io;
        const fd = c.openat(self.dir, temp, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
        if (fd < 0) return error.Io;
        var linked = true;
        defer if (linked) {
            _ = c.unlinkat(self.dir, temp, 0);
        };
        {
            defer _ = c.close(fd);
            if (c.fchmod(fd, 0o600) != 0) return error.Io;
            const limit = if (self.fault == .short_write) bytes.len / 2 else bytes.len;
            var sent: usize = 0;
            while (sent < limit) {
                const n = c.write(fd, bytes[sent..limit].ptr, limit - sent);
                if (n < 0 and c.errno(n) == .INTR) continue;
                if (n <= 0) return error.Io;
                sent += @intCast(n);
            }
            if (sent != bytes.len) return error.Io; // ENOSPC stand-in
            if (self.fault == .fsync or c.fsync(fd) != 0) return error.Io;
        }
        // The final name is a fresh random ID; never replace an existing file.
        if (c.faccessat(self.dir, final, c.F_OK, c.AT.SYMLINK_NOFOLLOW) == 0) return error.Io;
        if (self.fault == .rename or c.renameat(self.dir, temp, self.dir, final) != 0) return error.Io;
        linked = false;
        if (self.fault == .dir_fsync) return error.Io;
        try self.sync();
    }
};

const testing = std.testing;
fn tmpBase(buf: []u8) ![]const u8 {
    var rnd: [8]u8 = undefined;
    os.randomBytes(&rnd);
    const hex = std.fmt.bytesToHex(rnd, .lower);
    const tmp = std.c.getenv("TMPDIR");
    const root = if (tmp) |t| std.mem.span(t) else "/tmp";
    return std.fmt.bufPrint(buf, "{s}/vx-store-{s}", .{ root, hex });
}
fn rmTree(path: []const u8) void {
    var buf: [512]u8 = undefined;
    const cmd = std.fmt.bufPrintSentinel(&buf, "rm -rf '{s}'", .{path}, 0) catch return;
    _ = system(cmd);
}
extern "c" fn system([*:0]const u8) c_int;

test "store: private creation, atomic publish, interrupted writes and unsafe entries" {
    const a = testing.allocator;
    var pbuf: [256]u8 = undefined;
    const base = try tmpBase(&pbuf);
    defer rmTree(base);
    try testing.expect(try Store.open(base, "k", false) == null);
    var store = (try Store.open(base, "k", true)).?;
    defer store.close();
    const id1 = format.newId(&@splat(1));
    const tmp1 = format.newId(&@splat(2));
    try store.publish(&id1, &tmp1, "one\n");
    // Every interrupted stage leaves the published file and no temporary.
    for ([_]Fault{ .before_write, .short_write, .fsync, .rename }) |fault| {
        store.fault = fault;
        const id = format.newId(&@splat(@as(u8, @backingInt(fault)) + 10));
        try testing.expectError(error.Io, store.publish(&id, &tmp1, "two\n"));
    }
    store.fault = .dir_fsync;
    const visible = format.newId(&@splat(40));
    // A rename whose directory sync failed is visible but not acknowledged.
    try testing.expectError(error.Io, store.publish(&visible, &tmp1, "three\n"));
    store.fault = .none;
    const entries = try store.list(a, 100);
    defer a.free(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    for (entries) |e| try testing.expectEqual(Kind.final, e.kind);
    const name1 = try std.fmt.allocPrint(a, "{s}.json", .{&id1});
    defer a.free(name1);
    const bytes = try store.read(a, name1, 100);
    defer a.free(bytes);
    try testing.expectEqualStrings("one\n", bytes);
    try testing.expectError(error.TooLarge, store.read(a, name1, 2));
    // Hard link, symlink and permissive mode are all unsafe; nothing chmods.
    var buf: [256]u8 = undefined;
    _ = c.linkat(store.dir, z(&buf, name1), store.dir, "c11111111-1111-4111-8111-111111111111.json", 0);
    try testing.expectError(error.Unsafe, store.read(a, name1, 100));
    _ = c.unlinkat(store.dir, "c11111111-1111-4111-8111-111111111111.json", 0);
    _ = c.symlinkat("/etc/passwd", store.dir, "c22222222-2222-4222-8222-222222222222.json");
    try testing.expectError(error.Unsafe, store.read(a, "c22222222-2222-4222-8222-222222222222.json", 100000));
    var mode_buf: [256]u8 = undefined;
    _ = c.fchmodat(store.dir, z(&mode_buf, name1), 0o644, 0);
    try testing.expectError(error.Unsafe, store.safe(name1));
    try store.remove("c22222222-2222-4222-8222-222222222222.json");
    // A permissive store directory is never repaired by a reader.
    var store_path: [512]u8 = undefined;
    const leaf = try std.fmt.bufPrintSentinel(&store_path, "{s}/venomx/recovery/k", .{base}, 0);
    _ = c.chmod(leaf, 0o755);
    try testing.expectError(error.Unsafe, Store.open(base, "k", false));
    try testing.expectError(error.Unsafe, store.check());
}
