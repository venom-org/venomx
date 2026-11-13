//! On-demand daemon lifecycle: restart-only startup settings, the
//! daemon's latched lifetime state machine, and the CLI's cooperative
//! missing-daemon launcher registered with the shared runtime.
const std = @import("std");
const c = std.c;
const cfg = @import("cfg");
const proto = @import("proto");
const Ctx = @import("cli").runtime.Startup.Context;

/// `daemon` config section; every key is restart-only startup policy,
/// read by clients only after a missing daemon.
pub const Settings = struct {
    startup: []const u8 = "explicit",
    startup_timeout_ms: u32 = 5000,
    /// Whether `venomx` / `venomx new` may start a daemon.
    interactive_start: bool = true,
    pub fn check(self: Settings) error{Invalid}!void {
        if (!std.mem.eql(u8, self.startup, "explicit") and !std.mem.eql(u8, self.startup, "on-demand")) return error.Invalid;
        if (self.startup_timeout_ms < 100 or self.startup_timeout_ms > 60_000) return error.Invalid;
    }
    pub fn onDemand(self: Settings) bool {
        return std.mem.eql(u8, self.startup, "on-demand");
    }
};
pub const policies = [_]cfg.FieldPolicy{
    .{ .key = "daemon.startup", .restart = true },
    .{ .key = "daemon.startup_timeout_ms", .restart = true },
    .{ .key = "daemon.interactive_start", .restart = true },
};
/// The `attach` config section, read by the attach client.
pub const AttachSettings = struct {
    /// "exit" (default) or "next": what a client does when its session ends.
    on_session_end: []const u8 = "exit",
    pub fn check(self: AttachSettings) error{Invalid}!void {
        if (!std.mem.eql(u8, self.on_session_end, "exit") and !std.mem.eql(u8, self.on_session_end, "next")) return error.Invalid;
    }
};
/// `serve --origin`: recorded for doctor only; grants nothing.
pub const Origin = enum {
    serve,
    interactive,
    session_create,
    pub fn parse(value: []const u8) Origin {
        return std.meta.stringToEnum(Origin, value) orelse .serve;
    }
};

/// Fixed first-session grace; not configurable.
pub const first_session_grace_ms = 5000;
pub const Lifetime = enum { persistent, on_demand };
pub const Phase = enum { initializing, awaiting_first_session, active, stopping };

/// Latched at serve and serialized with mutations in the reactor. A
/// persistent daemon never leaves `active` because of resource counts.
pub const State = struct {
    lifetime: Lifetime = .persistent,
    origin: Origin = .serve,
    phase: Phase = .initializing,
    grace_deadline_ms: i64 = 0,
    pub fn parse(value: []const u8) Lifetime {
        return if (std.mem.eql(u8, value, "on-demand")) .on_demand else .persistent;
    }
    /// Readiness: the reactor is about to dispatch its first request.
    pub fn ready(self: *State, now_ms: i64) void {
        if (self.phase != .initializing) return;
        if (self.lifetime == .persistent) {
            self.phase = .active;
            return;
        }
        self.phase = .awaiting_first_session;
        self.grace_deadline_ms = now_ms + first_session_grace_ms;
    }
    pub fn stopping(self: *const State) bool {
        return self.phase == .stopping;
    }
    /// A session creation committed in this reactor turn.
    pub fn created(self: *State) void {
        if (self.phase == .awaiting_first_session) self.phase = .active;
    }
    /// A session removal committed; `sessions` is the remaining live count.
    /// The final removal latches `stopping` in the same turn (irreversible).
    pub fn removed(self: *State, sessions: usize) void {
        if (self.lifetime == .on_demand and self.phase == .active and sessions == 0) self.phase = .stopping;
    }
    /// Grace expiry with zero sessions stops even with clients connected;
    /// probes and failed calls never extend it.
    pub fn tick(self: *State, now_ms: i64, sessions: usize) void {
        if (self.phase == .awaiting_first_session and now_ms >= self.grace_deadline_ms and sessions == 0) self.phase = .stopping;
    }
    pub fn graceRemainingMs(self: *const State, now_ms: i64) i64 {
        return if (self.phase == .awaiting_first_session) @max(0, self.grace_deadline_ms - now_ms) else 0;
    }
    /// Doctor: the state is consistent with the live session count.
    pub fn consistent(self: *const State, sessions: usize) bool {
        return switch (self.phase) {
            .initializing => false,
            .awaiting_first_session => self.lifetime == .on_demand and sessions == 0,
            .active => self.lifetime == .persistent or sessions > 0,
            .stopping => self.lifetime == .on_demand,
        };
    }
};

/// Config locations must be absent or regular files: a FIFO or device would
/// make the bounded read block.
pub fn regularOrMissing(a: std.mem.Allocator, path: []const u8) !void {
    const z = try a.dupeSentinel(u8, path, 0);
    defer a.free(z);
    const st = proto.os.statAt(c.AT.FDCWD, z, 0) catch |err| return if (err == error.FileNotFound) {} else error.NotRegular;
    if (st.mode & c.S.IFMT != c.S.IFREG) return error.NotRegular;
}

/// The path of a manager's marker that matches a
/// process above this one, in the directory of `socket`, or null. A daemon there
/// would refuse this caller its owner token and stay a child of that manager.
/// A missing directory holds no marker and is not created. An unusable one fails
/// closed with the shared path error.
pub fn managerMarker(a: std.mem.Allocator, socket: []const u8) !?[]const u8 {
    const dir = proto.os.runtimeDir(a, socket, false) catch |err| return if (err == error.NotRunning) null else err;
    defer proto.os.close(dir);
    const chain = proto.process.walk(c.getpid(), 0);
    if (chain.len < 2) return null;
    for (chain.refs[1..chain.len]) |ref| {
        // One process at a time, so that the denial can name the match.
        var one: proto.process.Chain = .{ .len = 2 };
        one.refs[0] = chain.refs[0];
        one.refs[1] = ref;
        if (!proto.managers.below(dir, one)) continue;
        return try std.fmt.allocPrint(a, "{s}/manager-{d}-{d}", .{ std.fs.path.dirname(socket) orelse ".", ref.pid, ref.start });
    }
    return null;
}
/// With no daemon running, `doctor` can't report the marker, so the denial does.
pub fn managerDenial(a: std.mem.Allocator, marker: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "no daemon started: a manager's marker matches a process above this caller ({s}), so the owner token would be refused here. Expected below a manager such as venom; in a plain terminal the marker was forged, and deleting the file ends this", .{marker});
}

/// Shared-runtime startup hook (cli.runtime.Startup). Only reached for an
/// ordinary CLI `session create` after validation and an initial NotRunning.
/// `params_valid` repeats the product handler's own `--name` predicate so a
/// malformed creation fails `invalid_params.name` (exit 2) with
/// the daemon's own error, and never launches a daemon.
pub fn Launcher(comptime Store: type, comptime validate: anytype, comptime validate_layer: anytype, comptime params_valid: fn (std.json.Value) bool) type {
    return struct {
        const Self = @This();
        gpa: std.mem.Allocator,
        io: std.Io,
        environ: std.process.Environ,
        stderr: *std.Io.Writer,
        pid: c.pid_t = 0,
        /// Read end of the candidate's stdout: serve's single termination
        /// record (`{}` or the error wrapper). Its stderr is the null device.
        record: c.fd_t = -1,
        buf: [4096]u8 = undefined,
        len: usize = 0,
        outcome: enum { running, lost_race, failed, exited } = .running,
        /// Who starts the candidate (`--origin`).
        origin: Origin = .session_create,

        pub fn deinit(self: *Self) void {
            if (self.record >= 0) _ = c.close(self.record);
            self.record = -1;
        }
        fn env(self: *Self, ctx: Ctx) std.process.Environ {
            return ctx.path.environ orelse self.environ;
        }
        pub fn prepare(self: *Self, ctx: Ctx) anyerror!?u32 {
            const e = self.env(ctx);
            // Product-level validation the schema cannot express: the same
            // error the daemon's handler returns, before any launch.
            if (!params_valid(ctx.call.params)) {
                var data: std.json.Value = .{ .object = .empty };
                try data.object.put(ctx.allocator, "param", .{ .string = "name" });
                return ctx.reject("invalid_params.name", "invalid display name", data);
            }
            // No token, or an ordinary (epoch-bound) token: never launch and
            // never read the owner file.
            const token = e.getPosix("VENOMX_TOKEN") orelse return null;
            if (!std.mem.eql(u8, token, "@owner")) return null;
            const path = cfg.configPath(ctx.allocator, "venomx", e) catch |err| return if (err == error.OutOfMemory) err else error.StartupConfig;
            regularOrMissing(ctx.allocator, path) catch |err| return if (err == error.OutOfMemory) err else error.StartupConfig;
            // The same parser, defaults and validation as the daemon.
            const defaults = try cfg.defaultsPaths(ctx.allocator, "venomx", e);
            var store = Store.init(self.gpa, .{ .io = self.io, .path = path, .defaults = defaults, .validate = validate, .validate_layer = validate_layer }) catch |err| return if (err == error.OutOfMemory) err else error.StartupConfig;
            defer store.deinit();
            const settings = store.current().daemon;
            if (!settings.onDemand()) return null;
            // Conservative accident prevention, not an identity boundary.
            if (e.getPosix("VENOMX_PRINCIPAL") != null or e.getPosix("VENOMX_PANE") != null) return error.StartupContext;
            // The runtime's reject takes only invalid_params codes, so the
            // denial's detail goes to stderr, as `report` does.
            if (try managerMarker(ctx.allocator, ctx.path.socket.?)) |marker| {
                self.stderr.print("venomx: {s}\n", .{try managerDenial(ctx.allocator, marker)}) catch {};
                self.stderr.flush() catch {};
                return error.StartupContext;
            }
            return settings.startup_timeout_ms;
        }
        pub fn launch(self: *Self, ctx: Ctx) anyerror!void {
            const a = ctx.allocator;
            const socket = try std.fmt.allocPrintSentinel(a, "--socket={s}", .{ctx.path.socket.?}, 0);
            const origin = try std.fmt.allocPrintSentinel(a, "--origin={s}", .{@tagName(self.origin)}, 0);
            const argv = [_:null]?[*:0]const u8{ "venomx", "serve", "--lifetime=on-demand", origin.ptr, socket.ptr, "--json" };
            var envs: std.ArrayList(?[*:0]const u8) = .empty;
            for (self.env(ctx).block.slice) |entry| {
                const bytes = std.mem.span(entry.?);
                const key = bytes[0 .. std.mem.indexOfScalar(u8, bytes, '=') orelse continue];
                // Credentials and caller context never reach the daemon.
                if (std.mem.eql(u8, key, "VENOMX_TOKEN") or std.mem.eql(u8, key, "VENOMX_PRINCIPAL") or std.mem.eql(u8, key, "VENOMX_PANE") or std.mem.eql(u8, key, "VENOMX_SOCKET")) continue;
                try envs.append(a, entry);
            }
            const envp = try a.allocSentinel(?[*:0]const u8, envs.items.len, null);
            @memcpy(envp, envs.items);
            var fds: [2]c.fd_t = undefined;
            if (@import("os.zig").pipe2(&fds, .{ .CLOEXEC = true, .NONBLOCK = true }) != 0) return error.StartupFailed;
            errdefer _ = c.close(fds[0]);
            defer _ = c.close(fds[1]);
            const devnull = c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
            if (devnull < 0) return error.StartupFailed;
            defer _ = c.close(devnull);
            // Every allocation precedes fork. The child execs this very binary
            // (never a PATH lookup or shell) in its own session, so a terminal
            // or the launcher's exit cannot signal it.
            const pid = c.fork();
            if (pid < 0) return error.StartupFailed;
            if (pid == 0) {
                _ = c.setsid();
                if (c.dup2(devnull, 0) < 0 or c.dup2(fds[1], 1) < 0 or c.dup2(devnull, 2) < 0) c._exit(127);
                // The record pipe is blocking for the daemon's single final write.
                _ = c.fcntl(1, c.F.SETFL, @as(c_int, 0));
                _ = execve("/proc/self/exe", &argv, envp.ptr);
                c._exit(127);
            }
            self.pid = pid;
            self.record = fds[0];
        }
        pub fn poll(self: *Self, _: Ctx) anyerror!@import("cli").runtime.Startup.Status {
            if (self.outcome == .failed) return .failed;
            if (self.outcome != .running) return .pending;
            self.drain();
            var status: c_int = 0;
            const n = c.waitpid(self.pid, &status, c.W.NOHANG);
            if (n != self.pid) return .pending;
            self.drain();
            const s: u32 = @bitCast(status);
            const code = if (c.W.IFEXITED(s)) c.W.EXITSTATUS(s) else 128;
            const record = self.buf[0..self.len];
            // A losing candidate's conflict is absorbed: the winner is used.
            if (std.mem.indexOf(u8, record, "\"conflict.already_running\"") != null) {
                self.outcome = .lost_race;
                return .pending;
            }
            // Path errors fail closed with the shared error, no fallback.
            if (std.mem.indexOf(u8, record, "\"conflict.not_a_socket\"") != null) return error.NotASocket;
            if (std.mem.indexOf(u8, record, "\"denied.insecure_path\"") != null) return error.InsecurePath;
            if (std.mem.indexOf(u8, record, "\"unavailable.path_too_long\"") != null) return error.PathTooLong;
            if (code == 0) {
                self.outcome = .exited;
                return .pending;
            }
            self.outcome = .failed;
            self.report(code, record);
            return .failed;
        }
        /// Bounded human diagnostic on stderr: the candidate's error code
        /// only, never its environment or a credential.
        fn report(self: *Self, code: u32, record: []const u8) void {
            var name: []const u8 = "no termination record";
            const parsed = std.json.parseFromSlice(std.json.Value, self.gpa, std.mem.trim(u8, record, " \n"), .{}) catch null;
            defer if (parsed) |p| p.deinit();
            if (parsed) |p| if (p.value == .object) if (p.value.object.get("error")) |err| if (err == .object) if (err.object.get("code")) |v| {
                if (v == .string and v.string.len <= 128 and proto.errors.knownCode(v.string)) name = v.string;
            };
            self.stderr.print("venomx: daemon candidate failed during startup (exit {d}, {s})\n", .{ code, name }) catch {};
            self.stderr.flush() catch {};
        }
        fn drain(self: *Self) void {
            if (self.record < 0) return;
            while (true) {
                var scratch: [512]u8 = undefined;
                const n = c.read(self.record, &scratch, scratch.len);
                if (n <= 0) return;
                const take = @min(@as(usize, @intCast(n)), self.buf.len - self.len);
                @memcpy(self.buf[self.len..][0..take], scratch[0..take]);
                self.len += take;
            }
        }
    };
}
extern "c" fn execve([*:0]const u8, [*:null]const ?[*:0]const u8, [*:null]const ?[*:0]const u8) c_int;

test "lifecycle: a missing marker directory holds no marker and is not created" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const missing = try std.fmt.allocPrintSentinel(a, ".zig-cache/tmp/{s}/venom", .{tmp.sub_path}, 0);
    defer a.free(missing);
    const socket = try std.fmt.allocPrint(a, "{s}/venomx.sock", .{missing});
    defer a.free(socket);
    try std.testing.expectEqual(@as(?[]const u8, null), try managerMarker(a, socket));
    try std.testing.expectError(error.FileNotFound, proto.os.statAt(c.AT.FDCWD, missing, 0));
}
test "lifecycle: on-demand phases follow commit order" {
    var s: State = .{ .lifetime = .on_demand };
    s.ready(1000);
    try std.testing.expectEqual(Phase.awaiting_first_session, s.phase);
    try std.testing.expectEqual(@as(i64, 5000), s.graceRemainingMs(1000));
    s.tick(5999, 0);
    try std.testing.expect(!s.stopping());
    s.created();
    s.tick(7000, 1);
    try std.testing.expectEqual(Phase.active, s.phase);
    s.removed(1);
    try std.testing.expect(!s.stopping());
    s.removed(0);
    try std.testing.expect(s.stopping());
    // Stopping is irreversible.
    s.created();
    try std.testing.expect(s.stopping());
    var grace: State = .{ .lifetime = .on_demand };
    grace.ready(0);
    grace.tick(first_session_grace_ms, 0);
    try std.testing.expect(grace.stopping());
}
test "lifecycle: persistent never stops on counts" {
    var s: State = .{};
    s.ready(0);
    s.tick(1_000_000, 0);
    s.removed(0);
    try std.testing.expectEqual(Phase.active, s.phase);
    try std.testing.expect(s.consistent(0));
}
test "lifecycle: settings validation" {
    try (Settings{}).check();
    try (Settings{ .startup = "on-demand", .startup_timeout_ms = 100 }).check();
    try std.testing.expectError(error.Invalid, (Settings{ .startup = "always" }).check());
    try std.testing.expectError(error.Invalid, (Settings{ .startup_timeout_ms = 99 }).check());
    try std.testing.expectError(error.Invalid, (Settings{ .startup_timeout_ms = 60_001 }).check());
    try (AttachSettings{ .on_session_end = "next" }).check();
    try std.testing.expectError(error.Invalid, (AttachSettings{ .on_session_end = "detach" }).check());
    try std.testing.expectEqual(Origin.interactive, Origin.parse("interactive"));
    try std.testing.expectEqual(Origin.serve, Origin.parse("bogus"));
}

test "lifecycle: final removal stops in the same turn; denial precedes unavailable.shutdown" {
    const testing = std.testing;
    const a = testing.allocator;
    const g = proto.grants;
    const Product = @import("product.zig").Product;
    const streams = @import("server.zig");
    var events = try proto.events.Log.init(a, "venomx", .{}, null);
    defer events.deinit();
    events.catalog = &@import("manifest.zig").catalog;
    var registry = try g.Registry.init(a, "venomx", .{});
    defer registry.deinit();
    var server = streams.Server.init(a, events.source);
    defer server.deinit();
    var leaders = @import("supervisor").Leaders.init(a, .{});
    defer leaders.deinit();
    var product: Product = .{ .a = a, .streams = &server, .registry = &registry, .events = &events, .environ = .empty, .leaders = &leaders, .lifecycle = .{ .lifetime = .on_demand } };
    defer product.deinit();
    registry.containment = g.Containment.init(&product);
    product.lifecycle.ready(0);
    const bindings = product.bindings() ++ .{proto.Binding{ .verb = "events", .handler = proto.VerbHandler.init(&events) }};
    var dispatcher = try proto.Dispatcher.init(a, &@import("manifest.zig").core_model, &bindings, .{}, null);
    defer dispatcher.deinit();
    var owner = proto.Connection.init(a, -1);
    defer owner.deinit();
    var unknown = proto.Connection.init(a, -1);
    defer unknown.deinit();
    for ([_]*proto.Connection{ &owner, &unknown }) |conn| {
        conn.protocol = .ndjson;
        conn.ready = true;
        conn.version = 1;
        conn.registry = &registry;
    }
    owner.identity = .{ .principal = g.owner };
    try dispatcher.message(&owner, .{ .ndjson = "{\"id\":0,\"verb\":\"session.create\"}" });
    try testing.expectEqual(Phase.active, product.lifecycle.phase);
    try dispatcher.message(&owner, .{ .ndjson = "{\"id\":1,\"verb\":\"session.remove\",\"params\":{\"session\":\"s0\"}}" });
    try testing.expect(product.lifecycle.stopping());
    const high = events.high;
    owner.output.clearRetainingCapacity();
    try dispatcher.message(&unknown, .{ .ndjson = "{\"id\":2,\"verb\":\"session.create\"}" });
    try testing.expect(std.mem.indexOf(u8, unknown.output.items, "\"denied.write\"") != null);
    try dispatcher.message(&owner, .{ .ndjson = "{\"id\":3,\"verb\":\"session.create\"}" });
    try testing.expect(std.mem.indexOf(u8, owner.output.items, "\"unavailable.shutdown\"") != null);
    // No effects: no session, no event; reads still answer.
    try testing.expectEqual(high, events.high);
    try testing.expectEqual(@as(usize, 0), product.liveSessions());
    owner.output.clearRetainingCapacity();
    try dispatcher.message(&owner, .{ .ndjson = "{\"id\":4,\"verb\":\"session.list\"}" });
    try testing.expect(std.mem.indexOf(u8, owner.output.items, "\"sessions\":[]") != null);
}
test "lifecycle: grace expiry and a creation race resolve by commit order" {
    var s: State = .{ .lifetime = .on_demand };
    s.ready(0);
    s.created(); // creation committed first: the expiry tick is moot
    s.tick(first_session_grace_ms + 1, 1);
    try std.testing.expectEqual(Phase.active, s.phase);
    var t: State = .{ .lifetime = .on_demand };
    t.ready(0);
    t.tick(first_session_grace_ms, 0); // expiry committed first
    t.created();
    try std.testing.expect(t.stopping());
}
