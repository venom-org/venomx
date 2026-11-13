//! Per-request working directory and environment: validation, the
//! credential table, the child environment and the
//! executable candidate list. Everything here runs in the daemon before
//! fork; the child only walks the prepared arrays.
const std = @import("std");
const Value = std.json.Value;
const eq = std.mem.eql;

pub const max_cwd = 4095;
pub const max_name = 255;
pub const max_value = 65536;
/// The longest `argv0`, in bytes.
pub const max_argv0 = 255;

/// The display label of the `argv[0]` the daemon executes.
/// The bytes after the last `/`, none when that is empty, cut to at most
/// `max_argv0` bytes on a UTF-8 code-point boundary. Borrows `argv0`.
pub fn argv0Label(argv0: []const u8) ?[]const u8 {
    const start = if (std.mem.lastIndexOfScalar(u8, argv0, '/')) |i| i + 1 else 0;
    const base = argv0[start..];
    if (base.len == 0) return null;
    if (base.len <= max_argv0) return base;
    var end: usize = max_argv0;
    while (end > 0 and base[end] & 0xC0 == 0x80) end -= 1;
    return if (end == 0) null else base[0..end];
}
pub const max_entries = 256;
pub const max_total = 262144;

/// The `data` of an `invalid_params.env` / `invalid_params.cwd` failure.
/// `param` is a dotted path (`env.3.name`); never a name or value.
pub const Failure = struct { param: []const u8, reason: []const u8 };

pub const env_reasons = [_][]const u8{ "syntax", "size", "nul", "count", "duplicate", "reserved", "credential", "owner_credential" };
pub const cwd_reasons = [_][]const u8{ "permission", "changed", "other" };
pub const spawn_reasons = [_][]const u8{ "not_found", "permission", "exec_format", "too_large", "resource", "other" };

pub fn reasonIndex(comptime list: []const []const u8, reason: []const u8) usize {
    for (list, 0..) |r, i| if (eq(u8, r, reason)) return i;
    unreachable;
}

/// Cwd syntax: absolute, 1–4095 bytes, no NUL. No filesystem access.
pub fn checkCwd(cwd: []const u8) ?[]const u8 {
    if (cwd.len == 0 or cwd[0] != '/') return "relative";
    if (cwd.len > max_cwd) return "size";
    if (std.mem.indexOfScalar(u8, cwd, 0) != null) return "nul";
    return null;
}

fn nameSyntax(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return true;
}

fn reserved(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "VENOMX_");
}

/// The token-shaped pattern and credential table. They live in
/// venom-term's `chrome.exec_env` so the presentation clients' `exec`
/// environment and this one share one implementation.
const exec_env = @import("term_chrome").exec_env;
pub const Token = exec_env.Token;
pub const findToken = exec_env.findToken;
pub const containsToken = exec_env.containsToken;
pub const credential = exec_env.credential;

/// The `env` and `env_unset` request entries, already schema-validated.
pub const Request = struct {
    env: []const Value = &.{},
    unset: []const Value = &.{},
    pub fn from(params: std.json.ObjectMap) Request {
        return .{
            .env = if (params.get("env")) |v| v.array.items else &.{},
            .unset = if (params.get("env_unset")) |v| v.array.items else &.{},
        };
    }
    pub fn name(self: Request, i: usize) []const u8 {
        return self.env[i].object.get("name").?.string;
    }
    pub fn value(self: Request, i: usize) []const u8 {
        return self.env[i].object.get("value").?.string;
    }
    /// Whether the request names `key` in `env` or `env_unset`.
    pub fn names(self: Request, key: []const u8) bool {
        for (0..self.env.len) |i| if (eq(u8, self.name(i), key)) return true;
        for (self.unset) |u| if (eq(u8, u.string, key)) return true;
        return false;
    }
};

/// Validation rules in table order; the first failure wins. `a` holds `param`.
pub fn check(a: std.mem.Allocator, r: Request) !?Failure {
    if (r.env.len > max_entries) return .{ .param = "env", .reason = "count" };
    if (r.unset.len > max_entries) return .{ .param = "env_unset", .reason = "count" };
    // syntax, size and NUL of each entry (NUL first: a NUL name is not a syntax question).
    for (0..r.env.len) |i| {
        const n = r.name(i);
        const v = r.value(i);
        if (std.mem.indexOfScalar(u8, n, 0) != null) return try failAt(a, "env.{d}.name", i, "nul");
        if (!nameSyntax(n)) return try failAt(a, "env.{d}.name", i, "syntax");
        if (std.mem.indexOfScalar(u8, v, 0) != null) return try failAt(a, "env.{d}.value", i, "nul");
        if (v.len > max_value) return try failAt(a, "env.{d}.value", i, "size");
    }
    for (r.unset, 0..) |u, i| {
        if (std.mem.indexOfScalar(u8, u.string, 0) != null) return try failAt(a, "env_unset.{d}", i, "nul");
        if (!nameSyntax(u.string)) return try failAt(a, "env_unset.{d}", i, "syntax");
    }
    var total: usize = 0;
    for (0..r.env.len) |i| total += r.name(i).len + r.value(i).len + 2;
    if (total > max_total) return .{ .param = "env", .reason = "size" };
    // A name at most once across both arrays; the later occurrence is named.
    for (0..r.env.len) |i| for (0..i) |j| if (eq(u8, r.name(i), r.name(j))) return try failAt(a, "env.{d}.name", i, "duplicate");
    for (r.unset, 0..) |u, i| {
        for (0..r.env.len) |j| if (eq(u8, u.string, r.name(j))) return try failAt(a, "env_unset.{d}", i, "duplicate");
        for (r.unset[0..i]) |prev| if (eq(u8, u.string, prev.string)) return try failAt(a, "env_unset.{d}", i, "duplicate");
    }
    for (0..r.env.len) |i| if (reserved(r.name(i))) return try failAt(a, "env.{d}.name", i, "reserved");
    for (r.unset, 0..) |u, i| if (reserved(u.string)) return try failAt(a, "env_unset.{d}", i, "reserved");
    for (0..r.env.len) |i| if (credential(r.name(i), r.value(i))) |reason| return try failAt(a, "env.{d}.value", i, reason);
    return null;
}

fn failAt(a: std.mem.Allocator, comptime fmt: []const u8, i: usize, reason: []const u8) !Failure {
    return .{ .param = try std.fmt.allocPrint(a, fmt, .{i}), .reason = reason };
}

/// Counts of base variables removed by each strip rule.
pub const Stripped = struct { token: u64 = 0, principal: u64 = 0, venomx: u64 = 0, token_shaped: u64 = 0 };

extern "c" fn confstr(name: c_int, buf: ?[*]u8, len: usize) usize;
const cs_path: c_int = 0; // _CS_PATH on Linux (glibc and musl)

/// The daemon's own environment as captured at `serve` start, after the
/// strip rules. Entries point into the daemon's environment block.
pub const Base = struct {
    entries: []const [*:0]const u8 = &.{},
    stripped: Stripped = .{},
    /// `confstr(_CS_PATH)`, for a final environment without PATH.
    default_path: []const u8 = "/bin:/usr/bin",
    path_buf: ?[]u8 = null,
    /// Daemon-supplied terminal type; a request may override it.
    pub const term = "TERM=xterm-256color";

    pub fn init(a: std.mem.Allocator, environ: std.process.Environ) !Base {
        var list: std.ArrayList([*:0]const u8) = .empty;
        errdefer list.deinit(a);
        var stripped: Stripped = .{};
        for (environ.block.slice) |entry| {
            const bytes = std.mem.span(entry.?);
            const equal = std.mem.indexOfScalar(u8, bytes, '=') orelse continue;
            const key = bytes[0..equal];
            if (std.mem.endsWith(u8, key, "_TOKEN")) {
                stripped.token += 1;
            } else if (std.mem.endsWith(u8, key, "_PRINCIPAL")) {
                stripped.principal += 1;
            } else if (std.mem.startsWith(u8, key, "VENOMX_")) {
                stripped.venomx += 1;
            } else if (containsToken(bytes[equal + 1 ..])) {
                stripped.token_shaped += 1;
            } else if (!eq(u8, key, "TERM")) try list.append(a, entry.?);
        }
        try list.append(a, term);
        var out: Base = .{ .stripped = stripped };
        const n = confstr(cs_path, null, 0);
        if (n > 1) {
            const buf = try a.alloc(u8, n);
            errdefer a.free(buf);
            _ = confstr(cs_path, buf.ptr, n);
            out.path_buf = buf;
            out.default_path = buf[0 .. n - 1];
        }
        errdefer if (out.path_buf) |b| a.free(b);
        out.entries = try list.toOwnedSlice(a);
        return out;
    }
    pub fn deinit(self: *Base, a: std.mem.Allocator) void {
        a.free(self.entries);
        if (self.path_buf) |b| a.free(b);
        self.* = .{};
    }
    pub fn get(self: Base, key: []const u8) ?[]const u8 {
        for (self.entries) |e| {
            const s = std.mem.span(e);
            if (s.len > key.len and s[key.len] == '=' and eq(u8, s[0..key.len], key)) return s[key.len + 1 ..];
        }
        return null;
    }
    /// Doctor `spawn.path`: no PATH, or empty / relative entries.
    pub fn pathWarning(self: Base) ?[]const u8 {
        const p = self.get("PATH") orelse return "the daemon environment has no PATH; children use confstr(_CS_PATH)";
        var it = std.mem.splitScalar(u8, p, ':');
        while (it.next()) |entry| if (entry.len == 0 or entry[0] != '/') return "the daemon PATH has empty or relative entries, which spawn skips";
        return null;
    }
};

/// Strings built for one spawn. They may hold explicit values, the child
/// token or the resolved cwd, so each is zeroed before it is freed.
pub const Scratch = struct {
    a: std.mem.Allocator,
    owned: std.ArrayList([]u8) = .empty,
    arrays: std.ArrayList([:null]?[*:0]const u8) = .empty,
    pub fn deinit(self: *Scratch) void {
        for (self.owned.items) |s| {
            std.crypto.secureZero(u8, s);
            self.a.free(s);
        }
        self.owned.deinit(self.a);
        for (self.arrays.items) |arr| self.a.free(arr);
        self.arrays.deinit(self.a);
    }
    pub fn keep(self: *Scratch, s: []u8) ![]u8 {
        errdefer {
            std.crypto.secureZero(u8, s);
            self.a.free(s);
        }
        try self.owned.append(self.a, s);
        return s;
    }
    pub fn printZ(self: *Scratch, comptime fmt: []const u8, args: anytype) ![:0]u8 {
        const s = try std.fmt.allocPrintSentinel(self.a, fmt, args, 0);
        _ = try self.keep(s[0 .. s.len + 1]);
        return s;
    }
    pub fn pointers(self: *Scratch, items: []const [*:0]const u8) ![*:null]const ?[*:0]const u8 {
        const out = try self.a.allocSentinel(?[*:0]const u8, items.len, null);
        self.arrays.append(self.a, out) catch |err| {
            self.a.free(out);
            return err;
        };
        for (items, out) |item, *o| o.* = item;
        return out.ptr;
    }
};

fn keyOf(entry: [*:0]const u8) []const u8 {
    const s = std.mem.span(entry);
    return s[0 .. std.mem.indexOfScalar(u8, s, '=') orelse s.len];
}

fn remove(list: *std.ArrayList([*:0]const u8), key: []const u8) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (eq(u8, keyOf(list.items[i]), key)) _ = list.orderedRemove(i) else i += 1;
    }
}

/// Daemon-controlled values for a new pane (the last build step).
pub const Identity = struct { token: []const u8, principal: []const u8, pane: []const u8, socket: []const u8, run: []const u8 = "" };

pub const Built = struct {
    envp: [*:null]const ?[*:0]const u8,
    /// The final environment's PATH, or the confstr default.
    path: []const u8,
    /// The final environment's TERM, empty when unset: what a pane answers
    /// to an XTGETTCAP `TN` query.
    term: []const u8 = "",
};

/// The child environment build steps and the PWD rule. All storage lives in `scratch`.
pub fn build(scratch: *Scratch, base: Base, r: Request, id: Identity, cwd: ?[]const u8) !Built {
    const a = scratch.a;
    var list: std.ArrayList([*:0]const u8) = .empty;
    defer list.deinit(a);
    try list.appendSlice(a, base.entries);
    for (r.unset) |u| remove(&list, u.string);
    for (0..r.env.len) |i| {
        remove(&list, r.name(i));
        try list.append(a, try scratch.printZ("{s}={s}", .{ r.name(i), r.value(i) }));
    }
    if (cwd) |dir| if (!r.names("PWD")) {
        remove(&list, "PWD");
        try list.append(a, try scratch.printZ("PWD={s}", .{dir}));
    };
    for ([_][2][]const u8{ .{ "VENOMX_TOKEN", id.token }, .{ "VENOMX_PRINCIPAL", id.principal }, .{ "VENOMX_PANE", id.pane }, .{ "VENOMX_SOCKET", id.socket } }) |kv| {
        remove(&list, kv[0]);
        try list.append(a, try scratch.printZ("{s}={s}", .{ kv[0], kv[1] }));
    }
    // Informational, never trusted (like VENOMX_PANE).
    if (id.run.len > 0) {
        remove(&list, "VENOMX_RUN");
        try list.append(a, try scratch.printZ("VENOMX_RUN={s}", .{id.run}));
    }
    var path: []const u8 = base.default_path;
    for (list.items) |e| if (eq(u8, keyOf(e), "PATH")) {
        path = std.mem.span(e)[5..];
    };
    var term: []const u8 = "";
    for (list.items) |e| if (eq(u8, keyOf(e), "TERM")) {
        term = std.mem.span(e)[5..];
    };
    return .{ .envp = try scratch.pointers(list.items), .path = path, .term = term };
}

/// The executable candidate list, for `program` or else `argv[0]`: the name itself when it contains `/`, otherwise each
/// absolute PATH entry joined with it; empty and relative entries skipped.
pub fn candidates(scratch: *Scratch, argv0: []const u8, path: []const u8) ![*:null]const ?[*:0]const u8 {
    const a = scratch.a;
    var list: std.ArrayList([*:0]const u8) = .empty;
    defer list.deinit(a);
    if (std.mem.indexOfScalar(u8, argv0, '/') != null) {
        try list.append(a, try scratch.printZ("{s}", .{argv0}));
    } else {
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |entry| {
            if (entry.len == 0 or entry[0] != '/') continue;
            const sep: []const u8 = if (entry[entry.len - 1] == '/') "" else "/";
            if (entry.len + sep.len + argv0.len > max_cwd) continue;
            try list.append(a, try scratch.printZ("{s}{s}{s}", .{ entry, sep, argv0 }));
        }
    }
    return scratch.pointers(list.items);
}

/// `unavailable.spawn` reason for an exec-phase errno.
pub fn execReason(errno: std.posix.E) []const u8 {
    return switch (errno) {
        .NOENT, .NOTDIR, .LOOP, .NAMETOOLONG => "not_found",
        .ACCES => "permission",
        .NOEXEC => "exec_format",
        .@"2BIG" => "too_large",
        .AGAIN, .NOMEM, .MFILE, .NFILE => "resource",
        else => "other",
    };
}

/// `unavailable.cwd` reason for a cwd-phase (chdir) errno.
pub fn chdirReason(errno: std.posix.E) []const u8 {
    return switch (errno) {
        .NOENT, .NOTDIR => "changed",
        .ACCES => "permission",
        else => "other",
    };
}

const testing = std.testing;
fn rep(comptime n: usize, comptime ch: []const u8) *const [n]u8 {
    const frozen = comptime blk: {
        const out: [n]u8 = @splat(ch[0]);
        break :blk out;
    };
    return &frozen;
}
const fake = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"; // 43 secret chars

test "token-shaped substrings follow the credential pattern" {
    try testing.expect(containsToken("vnt1.venom.g7." ++ fake));
    try testing.expect(containsToken("x vnt1.venom-desk.owner." ++ fake ++ " y"));
    try testing.expect(containsToken("vnt1.venomx.unknown." ++ fake));
    try testing.expect(!containsToken("vnt1.venom.g0." ++ fake));
    try testing.expect(!containsToken("vnt1.Venom.g1." ++ fake));
    try testing.expect(!containsToken("vnt1.venom.g1." ++ fake[0..42]));
    try testing.expect(!containsToken("vnt1." ++ rep(33, "a") ++ ".g1." ++ fake));
    try testing.expect(containsToken("vnt1." ++ rep(32, "a") ++ ".g1." ++ fake));
    // A failed partial match does not hide a later real one.
    try testing.expect(containsToken("vnt1.vnt1.venom.g2." ++ fake));
}

test "credential table" {
    const venom = "vnt1.venom.g7." ++ fake;
    try testing.expect(credential("GITHUB_TOKEN", "canary") == null);
    try testing.expect(credential("VENOM_TOKEN", venom) == null);
    try testing.expect(credential("VENOM_DESK_TOKEN", "vnt1.venom-desk.g2." ++ fake) == null);
    try testing.expect(credential("VENOM_PRINCIPAL", "g7") == null);
    try testing.expectEqualStrings("owner_credential", credential("VENOM_TOKEN", "@owner").?);
    try testing.expect(credential("NOTE", "@owner") == null);
    try testing.expectEqualStrings("owner_credential", credential("VENOM_TOKEN", "vnt1.venom.owner." ++ fake).?);
    try testing.expectEqualStrings("owner_credential", credential("NOTE", "prefix vnt1.venom-desk.owner." ++ fake).?);
    try testing.expectEqualStrings("credential", credential("OTHER", "vnt1.venomx.g3." ++ fake).?);
    try testing.expectEqualStrings("credential", credential("VENOM_DESK_TOKEN", venom).?);
    try testing.expectEqualStrings("credential", credential("VENOM_TOKEN", venom ++ " trailing").?);
    try testing.expectEqualStrings("credential", credential("VENOM_TOKEN", venom ++ venom).?);
}

fn parse(a: std.mem.Allocator, json: []const u8) !Request {
    const v = try std.json.parseFromSliceLeaky(Value, a, json, .{});
    return Request.from(v.object);
}

fn failure(json: []const u8) !?Failure {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try check(arena.allocator(), try parse(arena.allocator(), json)) orelse return null;
    // Copy out of the arena: the param path is a static or tiny string.
    return .{ .param = try std.fmt.bufPrint(&param_buf, "{s}", .{f.param}), .reason = f.reason };
}
var param_buf: [32]u8 = undefined;

fn expectFailure(json: []const u8, param: []const u8, reason: []const u8) !void {
    const f = (try failure(json)) orelse return error.TestExpectedFailure;
    try testing.expectEqualStrings(param, f.param);
    try testing.expectEqualStrings(reason, f.reason);
}

test "validation rules, paths and reasons" {
    try testing.expect(try failure("{\"env\":[{\"name\":\"A\",\"value\":\"1\"}],\"env_unset\":[\"B\"]}") == null);
    try testing.expect(try failure("{\"env\":[],\"env_unset\":[]}") == null);
    try expectFailure("{\"env\":[{\"name\":\"1X\",\"value\":\"\"}]}", "env.0.name", "syntax");
    try expectFailure("{\"env\":[{\"name\":\"A\",\"value\":\"\"},{\"name\":\"A-B\",\"value\":\"\"}]}", "env.1.name", "syntax");
    try expectFailure("{\"env\":[{\"name\":\"" ++ rep(256, "A") ++ "\",\"value\":\"\"}]}", "env.0.name", "syntax");
    try expectFailure("{\"env\":[{\"name\":\"A\",\"value\":\"" ++ rep(65537, "v") ++ "\"}]}", "env.0.value", "size");
    try expectFailure("{\"env\":[{\"name\":\"A\\u0000\",\"value\":\"\"}]}", "env.0.name", "nul");
    try expectFailure("{\"env\":[{\"name\":\"A\",\"value\":\"x\\u0000\"}]}", "env.0.value", "nul");
    try expectFailure("{\"env_unset\":[\"A\\u0000\"]}", "env_unset.0", "nul");
    try expectFailure("{\"env\":[{\"name\":\"A\",\"value\":\"\"},{\"name\":\"A\",\"value\":\"\"}]}", "env.1.name", "duplicate");
    try expectFailure("{\"env\":[{\"name\":\"A\",\"value\":\"\"}],\"env_unset\":[\"A\"]}", "env_unset.0", "duplicate");
    try expectFailure("{\"env_unset\":[\"B\",\"B\"]}", "env_unset.1", "duplicate");
    try expectFailure("{\"env\":[{\"name\":\"VENOMX_TOKEN\",\"value\":\"x\"}]}", "env.0.name", "reserved");
    try expectFailure("{\"env_unset\":[\"VENOMX_SOCKET\"]}", "env_unset.0", "reserved");
    try expectFailure("{\"env\":[{\"name\":\"VENOM_TOKEN\",\"value\":\"@owner\"}]}", "env.0.value", "owner_credential");
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    try big.appendSlice(testing.allocator, "{\"env\":[");
    for (0..257) |i| try big.print(testing.allocator, "{s}{{\"name\":\"V{d}\",\"value\":\"\"}}", .{ if (i == 0) "" else ",", i });
    try big.appendSlice(testing.allocator, "]}");
    try expectFailure(big.items, "env", "count");
    // 4 values of 65530 bytes plus 4 of ~520: total just over 262144.
    big.clearRetainingCapacity();
    try big.appendSlice(testing.allocator, "{\"env\":[");
    for (0..5) |i| {
        try big.print(testing.allocator, "{s}{{\"name\":\"V{d}\",\"value\":\"", .{ if (i == 0) "" else ",", i });
        try big.appendNTimes(testing.allocator, 'v', if (i < 4) 65530 else 145 - 2);
        try big.appendSlice(testing.allocator, "\"}");
    }
    try big.appendSlice(testing.allocator, "]}");
    try expectFailure(big.items, "env", "size");
}

test "cwd syntax" {
    try testing.expectEqualStrings("relative", checkCwd(".").?);
    try testing.expectEqualStrings("relative", checkCwd("").?);
    try testing.expectEqualStrings("size", checkCwd("/" ++ rep(4095, "a")).?);
    try testing.expectEqualStrings("nul", checkCwd("/tmp\x00x").?);
    try testing.expect(checkCwd("/" ++ rep(4094, "a")) == null);
}

test "environment build order, PWD and candidates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const base: Base = .{ .entries = &.{ "BASE=1", "LANG=C", "PWD=/old", "PATH=/usr/bin::rel:/bin/", Base.term } };
    var scratch: Scratch = .{ .a = testing.allocator };
    defer scratch.deinit();
    const r = try parse(arena.allocator(), "{\"env\":[{\"name\":\"BASE\",\"value\":\"2\"},{\"name\":\"NEW\",\"value\":\"x=y\"}],\"env_unset\":[\"LANG\",\"ABSENT\"]}");
    const built = try build(&scratch, base, r, .{ .token = "tok", .principal = "g2", .pane = "p1", .socket = "/s" }, "/real");
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(testing.allocator);
    var i: usize = 0;
    while (built.envp[i]) |e| : (i += 1) try got.print(testing.allocator, "{s};", .{e});
    try testing.expectEqualStrings("PATH=/usr/bin::rel:/bin/;TERM=xterm-256color;BASE=2;NEW=x=y;PWD=/real;VENOMX_TOKEN=tok;VENOMX_PRINCIPAL=g2;VENOMX_PANE=p1;VENOMX_SOCKET=/s;", got.items);
    const cands = try candidates(&scratch, "tool", built.path);
    try testing.expectEqualStrings("/usr/bin/tool", std.mem.span(cands[0].?));
    try testing.expectEqualStrings("/bin/tool", std.mem.span(cands[1].?));
    try testing.expect(cands[2] == null);
    const direct = try candidates(&scratch, "./tool", built.path);
    try testing.expectEqualStrings("./tool", std.mem.span(direct[0].?));
    // The caller's PWD choice wins over the resolved cwd.
    const r2 = try parse(arena.allocator(), "{\"env_unset\":[\"PWD\",\"PATH\"]}");
    const b2 = try build(&scratch, base, r2, .{ .token = "t", .principal = "g", .pane = "p", .socket = "s" }, "/real");
    i = 0;
    while (b2.envp[i]) |e| : (i += 1) try testing.expect(!std.mem.startsWith(u8, std.mem.span(e), "PWD="));
    try testing.expectEqualStrings(base.default_path, b2.path);
}

test "base strip rules count by rule" {
    const owner_shaped = "FOO=vnt1.venomx.owner." ++ fake;
    var block = [_:null]?[*:0]const u8{ "BASE=1", "X_TOKEN=a", "VENOM_PRINCIPAL=g1", "VENOMX_DEBUG=1", owner_shaped, "VENOMX_TOKEN=@owner", "TERM=dumb", "PATH=/bin" };
    var base = try Base.init(testing.allocator, .{ .block = .{ .slice = &block } });
    defer base.deinit(testing.allocator);
    try testing.expectEqual(Stripped{ .token = 2, .principal = 1, .venomx = 1, .token_shaped = 1 }, base.stripped);
    try testing.expectEqual(@as(usize, 3), base.entries.len);
    try testing.expectEqualStrings("1", base.get("BASE").?);
    try testing.expectEqualStrings("xterm-256color", base.get("TERM").?);
    try testing.expect(base.pathWarning() == null);
    try testing.expect(base.default_path.len > 0);
}

test "argv0Label cuts and rejects like a process label" {
    try testing.expectEqualStrings("nvim", argv0Label("/usr/bin/nvim").?);
    try testing.expectEqualStrings("run.sh", argv0Label("./run.sh").?);
    try testing.expectEqualStrings("-sh", argv0Label("-sh").?);
    try testing.expectEqualStrings("sh", argv0Label("/bin/sh").?);
    try testing.expect(argv0Label("/") == null);
    try testing.expect(argv0Label("a/") == null);
    // A multi-byte code point straddling byte 255 is cut before it.
    var wide: [5 + 254 + 2 + 40]u8 = undefined;
    @memcpy(wide[0..5], "/dir/");
    @memset(wide[5..259], 'a');
    @memcpy(wide[259..261], "\u{e9}");
    @memset(wide[261..], 'b');
    const cut = argv0Label(&wide).?;
    try testing.expectEqual(@as(usize, 254), cut.len);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
    var plain: [300]u8 = undefined;
    @memset(&plain, 'x');
    try testing.expectEqual(@as(usize, 255), argv0Label(&plain).?.len);
}
