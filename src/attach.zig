//! `venomx attach --session <id> | --pane <id>`: the emulating presentation
//! client. One negotiated binary
//! connection carries CONTROL (verbs, the window event subscription) and one
//! odd-ID stream per displayed pane. It is a local presentation entry in the
//! same binary, not a daemon verb.
const std = @import("std");
const proto = @import("proto");
const cli = @import("cli");
const term = @import("venom-term");
const app_mod = @import("attach_app.zig");
const App = app_mod.App;
const posix = std.posix;
const exec = @import("attach_exec.zig");
const host_probe = @import("host_probe.zig");
const chrome_theme = @import("chrome_theme.zig");
const raw_filter = @import("raw_filter.zig");
const pane_stream = @import("pane_stream");

pub const description =
    "After the leader (default ctrl+b, see keys.leader) a popup lists the next " ++
    "keys of your active tables; ? shows it at once. The default keys: " ++
    "h j k l or the arrows move focus, Tab and Shift-Tab next and previous pane, " ++
    "\\ and - split, c new window, n and p next and previous window, 1-9 a window, " ++
    "[ scroll (then j k, the arrows, PgUp, PgDn, { } for the previous or next command, until Esc), PgUp, PgDn and ] scroll, " ++
    "z zoom (this client only), ! next pane needing attention, d detach, " ++
    "X close pane, f show or hide floats (this client only), F next float, " ++
    "x close popup, : command, L lock (every key goes to the pane until the " ++
    "unlock key, default ctrl+alt+b, see keys.unlock). Esc cancels and clears " ++
    "the selection (at the first level it can also close a focused popup), " ++
    "Backspace goes up one level, and the leader again sends it to the pane. " ++
    "Every other key reaches the focused pane unchanged. Products add tables " ++
    "under their own sub-prefix (keys register). Mouse wheel scrolls; " ++
    "left drag selects and copies with OSC 52. Presentation clients use the " ++
    "owner file by default; VENOMX_TOKEN overrides it. Inside a venomx pane " ++
    "the pane's own rights apply. The daemon must already be running. " ++
    "With --raw=true and --pane, use host scrollback and forward host input " ++
    "unchanged (leader d detaches; leader leader sends the leader). A size " ++
    "mismatch switches to single-pane emulation.";

const Args = struct { target: app_mod.Target, path: proto.SocketOptions, history: u64, raw: bool, notice: ?[]const u8 = null };

pub const Context = struct {
    pub const commands = .{ "attach", "new", "shell.init" };
    pub fn call(self: *Context, local: cli.Local.Context) anyerror!cli.Local.Outcome {
        if (std.mem.eql(u8, local.name, "shell.init")) return @import("shell_init.zig").call(local);
        var ctx = self.*;
        ctx.environ = local.path.environ orelse self.environ;
        ctx.stopped = local.interrupted orelse self.stopped;
        ctx.stderr = local.stderr;
        if (std.mem.eql(u8, local.name, "new")) return newSession(ctx, local);
        const session = local.params.object.get("session");
        const pane = local.params.object.get("pane");
        if (session != null and pane != null) return failure("invalid_params.selector", "give at most one of --session or --pane");
        const raw = local.params.object.get("raw").?.bool;
        if (raw and pane == null) return failure("invalid_params.selector", "--raw requires --pane");
        const history: u64 = @intCast(local.params.object.get("history").?.integer);
        if (pane) |v| return run(ctx, .{ .target = .{ .pane = v.string }, .path = local.path, .raw = raw, .history = history });
        // No selector attaches to the last-used session, else
        // the most recently created one. It never starts or creates anything.
        const id = if (session) |v| v.string else switch (try pick(ctx, local.allocator, local.path, null)) {
            .session => |x| x,
            .failure => |f| return .{ .failure = f },
        };
        return present(ctx, local.allocator, .{ .target = .{ .session = id }, .path = local.path, .raw = false, .history = history });
    }

    gpa: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    environ_map: *std.process.Environ.Map,
    stopped: *const std.atomic.Value(bool),
    /// Config and the daemon launcher, for `new` and `attach.on_session_end`.
    host: ?standalone.Host = null,
    stderr: ?*std.Io.Writer = null,
};
const standalone = @import("standalone.zig");

fn failure(code: []const u8, message: []const u8) cli.Local.Outcome {
    return .{ .failure = .{ .code = code, .message = message } };
}
fn note(ctx: Context, comptime fmt: []const u8, args: anytype) void {
    const w = ctx.stderr orelse return;
    w.print(fmt ++ "\n", args) catch {};
    w.flush() catch {};
}
fn settings(ctx: Context, a: std.mem.Allocator) !standalone.Settings {
    const h = ctx.host orelse return .{};
    return h.vtable.settings(h.ptr, a, ctx.environ);
}

/// A ready NDJSON client for the setup verbs, with the same credentials as
/// the presentation connection (owner file unless VENOMX_TOKEN is set; the
/// caller's own rights inside a managed tree).
fn setupClient(ctx: Context, path: proto.SocketOptions, owner: ?std.process.Environ) !proto.Client {
    return connectWith(ctx, path, owner, .ndjson);
}

const Pick = union(enum) { session: []const u8, failure: cli.Local.Failure };
/// Selector-less choice of a session against the running daemon.
fn pick(ctx: Context, a: std.mem.Allocator, path: proto.SocketOptions, exclude: ?[]const u8) !Pick {
    const owner = try ownerEnviron(a, ctx.environ);
    var client = setupClient(ctx, path, owner) catch |err| return .{ .failure = connectFailure(err) };
    defer client.deinit();
    const listed = try standalone.request(a, &client, 1, "session.list", struct {}{}, ctx.stopped);
    if (standalone.errorCode(listed)) |code| return .{ .failure = .{ .code = if (std.mem.startsWith(u8, code, "denied")) "denied.read" else "not_found.session", .message = "cannot list sessions" } };
    const sessions = standalone.okValue(listed).?.object.get("sessions").?.array.items;
    const epoch = try daemonEpoch(a, &client, ctx.stopped);
    const last = try standalone.readLast(a, ctx.environ);
    const id = standalone.choose(sessions, last, epoch, exclude) orelse return .{ .failure = .{ .code = "not_found.session", .message = "no session to attach to (start one with `venomx`)" } };
    return .{ .session = try a.dupe(u8, id) };
}
/// The daemon's event source identifies its lifetime (the last-session
/// file's epoch). `run.list` is the cheapest read that reports it.
fn daemonEpoch(a: std.mem.Allocator, client: *proto.Client, stopped: *const std.atomic.Value(bool)) ![]const u8 {
    const r = try standalone.request(a, client, 2, "run.list", .{ .limit = 1 }, stopped);
    const ok = standalone.okValue(r) orelse return "";
    const source = ok.object.get("source") orelse return "";
    return if (source == .string) source.string else "";
}
fn connectFailure(err: anyerror) cli.Local.Failure {
    return switch (err) {
        error.NotRunning, error.ConnectFailed, error.Timeout => .{ .code = "unavailable", .message = "no venomx daemon is listening (start one with `venomx`)" },
        error.DeniedToken => .{ .code = "denied", .message = "authentication failed" },
        error.Interrupted => .{ .code = "cancelled", .message = "interrupted" },
        else => .{ .code = "unavailable", .message = @errorName(err) },
    };
}

/// The failure a `session.get` error code maps to.
fn sessionGetFailure(code: []const u8) cli.Local.Outcome {
    if (std.mem.startsWith(u8, code, "not_found")) return failure("not_found.session", "no such session");
    if (std.mem.startsWith(u8, code, "denied")) return failure("denied.read", "cannot read session");
    return failure("failed", "session.get failed");
}
/// A notice carried over from the previous attach (a vanished pick) is shown.
fn showNotice(app: *App, args: Args) void {
    if (args.notice) |n| app.say("{s}", .{n});
}
fn isGone(outcome: cli.Local.Outcome) bool {
    return switch (outcome) {
        .failure => |f| std.mem.eql(u8, f.code, "not_found.session"),
        else => false,
    };
}
/// Attach to a session, then handle its end: attach to the
/// next session with `attach.on_session_end = "next"`, else exit 0 with a
/// one-line message.
fn present(ctx: Context, a: std.mem.Allocator, first: Args) !cli.Local.Outcome {
    return presentWith(ctx, a, first, runSession);
}
/// `present` over an injectable session runner (tests drive it with scripted
/// sessions). A picked session that vanished before the attach leaves the
/// client on the session it came from, with a notice, instead of exiting.
fn presentWith(ctx: Context, a: std.mem.Allocator, first: Args, comptime runner: fn (Context, Args, ?std.mem.Allocator) anyerror!Ended) !cli.Local.Outcome {
    var args = first;
    var from: ?[]const u8 = null;
    while (true) {
        const ended = try runner(ctx, args, a);
        if (from) |back| {
            from = null;
            if (isGone(ended.outcome)) {
                const gone = args.target.session;
                args.target = .{ .session = back };
                args.notice = try std.fmt.allocPrint(a, "session {s} is gone", .{gone});
                continue;
            }
        }
        args.notice = null;
        if (ended.switch_to) |next| {
            from = args.target.session;
            args.target = .{ .session = next };
            continue;
        }
        if (!ended.session_ended) {
            if (ended.detached) note(ctx, "[venomx: detached from {s}{s}{s}{s}]", .{ args.target.session, if (ended.name.len > 0) " (" else "", ended.name, if (ended.name.len > 0) ")" else "" });
            return ended.outcome;
        }
        const policy = settings(ctx, a) catch standalone.Settings{};
        if (std.mem.eql(u8, policy.on_session_end, "next")) {
            switch (pick(ctx, a, args.path, args.target.session) catch Pick{ .failure = .{ .code = "unavailable", .message = "" } }) {
                .session => |next| {
                    args.target = .{ .session = next };
                    continue;
                },
                .failure => {},
            }
        }
        note(ctx, "[venomx: session {s} ended{s}]", .{ args.target.session, if (serverGone(ctx, args.path)) "; server stopped" else "" });
        return .{ .status = 0 };
    }
}
/// After an on-demand daemon's last session it exits promptly; give it a
/// short bounded moment so the message can say so.
fn serverGone(ctx: Context, path: proto.SocketOptions) bool {
    const deadline = nowMs() + 500;
    while (nowMs() < deadline) {
        var client = proto.Client.init(ctx.gpa, .{ .tool = "venomx", .path = .{ .socket = path.socket, .environ = ctx.environ }, .hello = .{ .identity = .{ .name = "venomx-attach", .version = @import("version.zig").version }, .caps = &.{} } }) catch |err| return err == error.NotRunning;
        client.deinit();
        var none = [_]posix.pollfd{};
        _ = posix.poll(&none, 20) catch {};
    }
    return false;
}

// ------------------------------------------------------------ new

/// The daemon error to report: its own code when `new` declares it, else
/// its class (both are valid local failures).
fn relay(a: std.mem.Allocator, v: Value) !cli.Local.Outcome {
    const e = v.object.get("error").?;
    const code = standalone.errorCode(v).?;
    const message = if (e.object.get("message")) |m| (if (m == .string) m.string else code) else code;
    const declared = comptime blk: {
        var names: [new_errors.len][]const u8 = undefined;
        for (new_errors, 0..) |d, i| names[i] = d.code;
        break :blk names;
    };
    for (declared) |d| if (std.mem.eql(u8, d, code)) {
        const data = if (e.object.get("data")) |x| (if (x == .object) x else Value{ .object = .empty }) else Value{ .object = .empty };
        return .{ .failure = .{ .code = try a.dupe(u8, code), .message = try a.dupe(u8, message), .data = data } };
    };
    const class = code[0 .. std.mem.indexOfScalar(u8, code, '.') orelse code.len];
    return .{ .failure = .{ .code = if (proto.errors.knownCode(class)) try a.dupe(u8, class) else "internal", .message = try a.dupe(u8, message) } };
}
const lifecycle = @import("lifecycle.zig");
const new_errors = @import("manifest.zig").local[1].errors;
const Value = std.json.Value;

/// Ensure a daemon, create a session and its shell window
/// with ordinary verbs, then attach unless detached.
fn newSession(ctx: Context, local: cli.Local.Context) !cli.Local.Outcome {
    const a = local.allocator;
    const params = local.params.object;
    const env = ctx.environ;
    const nested = params.get("nested").?.bool;
    // Before connecting: managed-context markers refuse, even when empty.
    const managed = env.getPosix("VENOMX_PRINCIPAL") != null or env.getPosix("VENOMX_PANE") != null;
    if (managed and !nested) return failure("denied.startup_context", "venomx new refuses to run inside a venomx pane; use --nested=true with the pane's own token");
    const own_token = env.getPosix("VENOMX_TOKEN");
    if (nested and (own_token == null or std.mem.eql(u8, own_token.?, "@owner"))) return failure("denied.startup_context", "--nested=true needs the caller's own VENOMX_TOKEN and never reads the owner file");
    // Owner intent is implicit outside a pane.
    const owner: ?std.process.Environ = if (nested) null else try ownerEnviron(a, env);
    var client = setupClient(ctx, local.path, owner) catch |err| blk: {
        if (err != error.NotRunning) return .{ .failure = connectFailure(err) };
        if (nested) return failure("unavailable.not_running", "no venomx daemon is running; --nested never starts one");
        var denial: []const u8 = "";
        break :blk startDaemon(ctx, a, local.path, owner, &denial) catch |e| return if (e == error.StartupContext) failure("denied.startup_context", denial) else startFailure(e);
    };
    var open = true;
    defer if (open) client.deinit();

    const cwd = if (params.get("cwd")) |v| v.string else try standalone.currentDir(a);
    const name = if (params.get("name")) |v| v.string else try standalone.defaultName(a, cwd);
    if (params.get("attach_existing").?.bool) {
        const listed = try standalone.request(a, &client, 10, "session.list", struct {}{}, ctx.stopped);
        if (standalone.errorCode(listed) != null) return relay(a, listed);
        var matches: std.ArrayList([]const u8) = .empty;
        for (standalone.okValue(listed).?.object.get("sessions").?.array.items) |s| if (std.mem.eql(u8, s.object.get("name").?.string, name)) try matches.append(a, s.object.get("session").?.string);
        if (matches.items.len > 1) {
            const data = try std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, .{ .sessions = matches.items }, .{}), .{});
            return .{ .failure = .{ .code = "conflict.ambiguous_name", .message = "several sessions have that name; attach with --session", .data = data } };
        }
        if (matches.items.len == 1) {
            const id = matches.items[0];
            if (params.get("detached").?.bool) return localResult(a, .{ .session = id, .attached = true });
            client.deinit();
            open = false;
            return present(ctx, a, .{ .target = .{ .session = id }, .path = local.path, .raw = false, .history = @intCast(params.get("history").?.integer) });
        }
    }
    const created = try standalone.request(a, &client, 11, "session.create", .{ .name = name, .on_empty = "remove" }, ctx.stopped);
    if (standalone.errorCode(created) != null) return relay(a, created);
    const sid = standalone.okValue(created).?.object.get("session").?.string;
    const size = hostSize();
    const window = if (params.get("argv")) |v| blk: {
        const items = try a.alloc([]const u8, v.array.items.len);
        for (v.array.items, items) |x, *o| o.* = x.string;
        break :blk try standalone.request(a, &client, 12, "window.create", .{ .session = sid, .argv = items, .cwd = cwd, .cols = size.cols, .rows = size.rows, .on_exit = "remove" }, ctx.stopped);
    } else blk: {
        const shell = try standalone.defaultShell(a, env);
        break :blk try standalone.request(a, &client, 12, "window.create", .{ .session = sid, .program = shell, .argv = try standalone.loginArgv(a, shell), .cwd = cwd, .cols = size.cols, .rows = size.rows, .on_exit = "remove" }, ctx.stopped);
    };
    if (standalone.errorCode(window) != null) {
        // Best effort: never leave the empty session behind.
        _ = standalone.request(a, &client, 13, "session.remove", .{ .session = sid }, ctx.stopped) catch {};
        return relay(a, window);
    }
    const w = standalone.okValue(window).?.object;
    if (params.get("detached").?.bool) return localResult(a, .{ .session = sid, .window = w.get("window").?.string, .pane = w.get("pane").?.string });
    client.deinit();
    open = false;
    return present(ctx, a, .{ .target = .{ .session = sid }, .path = local.path, .raw = false, .history = @intCast(params.get("history").?.integer) });
}
fn localResult(a: std.mem.Allocator, value: anytype) !cli.Local.Outcome {
    return .{ .result = try std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, value, .{}), .{}) };
}
fn startFailure(err: anyerror) cli.Local.Outcome {
    return switch (err) {
        error.NotAllowed => failure("unavailable.not_running", "no venomx daemon is running and daemon.interactive_start is false"),
        error.StartupConfig => failure("invalid_params.startup_config", "the startup configuration could not be read"),
        error.StartupDeadline => failure("unavailable.startup_deadline", "the daemon did not become ready within daemon.startup_timeout_ms"),
        error.Interrupted, error.Cancelled => failure("cancelled", "interrupted"),
        error.DeniedToken => failure("denied.token", "owner authentication failed"),
        else => failure("unavailable.startup_failed", "the daemon candidate failed during startup"),
    };
}
/// Launch `serve --lifetime on-demand
/// --origin interactive` on the selected socket and wait for readiness
/// within daemon.startup_timeout_ms. A daemon that wins the race (on-demand
/// or persistent) is used as-is. Below a manager's marker it launches nothing
/// and fails error.StartupContext, with the failure's message in `denial`.
fn startDaemon(ctx: Context, a: std.mem.Allocator, path: proto.SocketOptions, owner: ?std.process.Environ, denial: *[]const u8) !proto.Client {
    const started = nowMs();
    const host = ctx.host orelse return error.NotAllowed;
    const policy = host.vtable.settings(host.ptr, a, ctx.environ) catch |err| return if (err == error.OutOfMemory) err else error.StartupConfig;
    if (!policy.interactive_start) return error.NotAllowed;
    const deadline = started + policy.startup_timeout_ms;
    const socket = try selectedSocket(a, .{ .socket = path.socket, .environ = ctx.environ });
    if (try lifecycle.managerMarker(a, socket)) |marker| {
        denial.* = try lifecycle.managerDenial(a, marker);
        return error.StartupContext;
    }
    var failed = false;
    host.vtable.launch(host.ptr, a, socket, ctx.environ) catch |err| {
        if (err == error.OutOfMemory) return err;
        failed = true;
    };
    var delay: i32 = 5;
    while (true) {
        if (ctx.stopped.load(.monotonic)) return error.Interrupted;
        failed = (host.vtable.failed(host.ptr) catch true) or failed;
        if (connectWith(ctx, .{ .socket = socket, .environ = path.environ }, owner, .ndjson)) |client| {
            return client;
        } else |err| switch (err) {
            error.OutOfMemory, error.Interrupted => return err,
            // Not listening yet, or the owner file is not written yet.
            else => {},
        }
        if (nowMs() >= deadline) return if (failed) error.StartupFailed else error.StartupDeadline;
        var none = [_]posix.pollfd{};
        _ = posix.poll(&none, @intCast(@max(1, @min(delay, deadline - nowMs())))) catch {};
        delay = @min(delay * 2, 100);
    }
}
fn selectedSocket(a: std.mem.Allocator, path: proto.SocketOptions) ![]const u8 {
    const selected = try proto.os.socketPath(a, "venomx", path);
    if (std.fs.path.isAbsolute(selected)) return selected;
    return std.fs.path.join(a, &.{ try standalone.currentDir(a), selected });
}

/// Presentation clients read the owner file unless the user
/// chose a token. The shared credential loader does the secure read.
fn ownerEnviron(a: std.mem.Allocator, environ: std.process.Environ) !?std.process.Environ {
    if (environ.getPosix("VENOMX_TOKEN") != null) return null;
    const old = environ.block.view().slice;
    const slice = try a.allocSentinel(?[*:0]const u8, old.len + 1, null);
    for (old, 0..) |entry, i| slice[i] = entry;
    slice[old.len] = "VENOMX_TOKEN=@owner";
    return .{ .block = .{ .slice = slice } };
}

const Link = struct {
    client: proto.Client,
    fn conn(self: *Link) *proto.Connection {
        return &self.client.connection;
    }
};

fn connect(ctx: Context, args: Args, owner: ?std.process.Environ) !proto.Client {
    if (@import("builtin").is_test) if (TestReconnect.enabled) return TestReconnect.client(ctx.gpa);
    return connectWith(ctx, args.path, owner, .binary);
}
fn connectWith(ctx: Context, path: proto.SocketOptions, owner: ?std.process.Environ, protocol: @import("proto").Protocol) !proto.Client {
    const caps = [_][]const u8{ "cancel", @import("stream.zig").capability };
    var tries: [2]?std.process.Environ = .{ owner, null };
    const attempts: []const ?std.process.Environ = if (owner != null) &tries else tries[1..];
    var last: anyerror = error.ConnectFailed;
    for (attempts) |env| {
        var client = try proto.Client.init(ctx.gpa, .{
            .tool = "venomx",
            .path = .{ .socket = path.socket, .environ = env orelse ctx.environ },
            .protocol = protocol,
            .hello = .{ .identity = .{ .name = "venomx-attach", .version = @import("version.zig").version }, .caps = &caps },
        });
        const ok = blk: {
            while (true) {
                const done = client.pollHello(100) catch |err| {
                    // Inside a managed tree the owner token is refused; the
                    // pane's own rights apply instead.
                    if (err == error.DeniedToken and env != null and client.token_failure == .owner_context) break :blk false;
                    client.deinit();
                    return err;
                };
                if (done) break :blk true;
                if (ctx.stopped.load(.monotonic)) {
                    client.deinit();
                    return error.Interrupted;
                }
            }
        };
        if (ok) return client;
        client.deinit();
        last = error.DeniedToken;
    }
    return last;
}

/// Blocking verb call on the fresh connection, before the presentation loop.
fn call(client: *proto.Client, verb: []const u8, params: anytype) !?[]const u8 {
    try client.request(@as(i64, 1), verb, params);
    while (true) {
        const msg = try client.receive(100) orelse continue;
        if (msg != .frame or msg.frame.kind != proto.Kind.control) continue;
        var parsed = try std.json.parseFromSlice(std.json.Value, client.connection.gpa, msg.frame.payload, .{});
        defer parsed.deinit();
        const v = parsed.value;
        const id = v.object.get("id") orelse continue;
        if (id != .integer or id.integer != 1) continue;
        const e = v.object.get("error") orelse return null;
        const code = e.object.get("code") orelse return "error";
        return if (code == .string and std.mem.startsWith(u8, code.string, "not_found")) "not_found" else if (code == .string and std.mem.startsWith(u8, code.string, "denied")) "denied" else "error";
    }
}

/// Like `call`, returning the `ok` value (in `a`) or the error code.
fn callValue(a: std.mem.Allocator, client: *proto.Client, id: i64, verb: []const u8, params: anytype) !union(enum) { ok: std.json.Value, err: []const u8 } {
    try client.request(id, verb, params);
    while (true) {
        const msg = try client.receive(100) orelse continue;
        if (msg != .frame or msg.frame.kind != proto.Kind.control) continue;
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, msg.frame.payload, .{ .allocate = .alloc_always });
        const got = v.object.get("id") orelse continue;
        if (got != .integer or got.integer != id) continue;
        if (v.object.get("ok")) |ok| return .{ .ok = ok };
        return .{ .err = standalone.errorCode(v) orelse "internal" };
    }
}

fn subscribe(client: *proto.Client, target: app_mod.Target, raw: bool) !void {
    // The authorized `window.*` projection, staged through its
    // checkpoint, so new windows are not raced by a list-then-listen.
    // `pane.*` brings pane snapshot entities, whose `recovery`
    // object marks restored archives in the status line.
    switch (target) {
        // `session.*` reports the session's end.
        // `status.*` segments, `notify.*` and `config.*` (the
        // client's status/attention settings) feed the status line.
        // `keys.*`: registered key tables reload on `keys.changed`.
        .session => try client.request(@as(i64, 2), "events", .{ .types = [_][]const u8{ "window.*", "pane.*", "session.*", "status.*", "notify.*", "config.*", "keys.*", "principal.*", "program.*", "command.*" } }),
        // Raw passthrough has no status line to show it in.
        .pane => if (!raw) try client.request(@as(i64, 2), "events", .{ .types = [_][]const u8{ "pane.*", "status.*", "notify.*", "config.*", "principal.*", "program.*", "command.*" } }),
    }
}

fn run(ctx: Context, args: Args) !cli.Local.Outcome {
    return (try runSession(ctx, args, null)).outcome;
}
const Ended = struct { outcome: cli.Local.Outcome, session_ended: bool = false, detached: bool = false, name: []const u8 = "", switch_to: ?[]const u8 = null };
/// `keep` owns the returned session name.
fn runSession(ctx: Context, args: Args, keep: ?std.mem.Allocator) !Ended {
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    const owner = try ownerEnviron(arena_state.allocator(), ctx.environ);
    var link: Link = .{ .client = connect(ctx, args, owner) catch |err| return .{ .outcome = .{ .failure = connectFailure(err) } } };
    defer link.client.deinit();
    if (!link.conn().hasCap(@import("stream.zig").capability)) return .{ .outcome = failure("unsupported", "the daemon does not offer venomx.pane_stream") };
    var name: []const u8 = "";
    if (args.target == .session) {
        const a = arena_state.allocator();
        switch (try callValue(a, &link.client, 1, "session.get", .{ .session = args.target.session })) {
            .err => |code| {
                return .{ .outcome = sessionGetFailure(code) };
            },
            .ok => |v| if (v.object.get("name")) |n| if (n == .string) if (keep) |k| {
                name = try k.dupe(u8, n.string);
            },
        }
        // Remember this daemon's epoch and the session.
        switch (try callValue(a, &link.client, 3, "run.list", .{ .limit = 1 })) {
            .ok => |v| if (v.object.get("source")) |src| if (src == .string) standalone.writeLast(a, ctx.environ, src.string, args.target.session),
            .err => {},
        }
    }
    // Principals made before this attach, so a denial names their
    // pane. The owner sees the whole tree; any failure leaves IDs as names.
    var principals: ?std.json.Value = null;
    if (!args.raw) {
        switch (try callValue(arena_state.allocator(), &link.client, 4, "grant.list", .{})) {
            .ok => |v| if (v == .object) {
                principals = v.object.get("principals");
            },
            .err => {},
        }
    }
    try subscribe(&link.client, args.target, args.raw);

    const shell = ctx.environ.getPosix("SHELL") orelse "/bin/sh";
    const size = hostSize();
    var app = try App.init(ctx.gpa, args.target, .{ .cols = size.cols, .rows = size.rows }, .{ .history = args.history, .shell = shell });
    defer app.deinit();
    app.raw = args.raw;
    app.home = ctx.environ.getPosix("HOME") orelse "";
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    app.local_host = std.posix.gethostname(&host_buf) catch "";
    if (principals) |ps| try app.seedPrincipals(ps);
    showNotice(&app, args);
    app.nested = ctx.environ.getPosix("VENOMX_PANE") != null;
    app.support = hostSupport(ctx.environ);
    if (!args.raw) try app.requestConfig() else try app.requestKeys();
    // The chrome's theme is read once per attach, in the host's colour mode.
    if (!args.raw) {
        app.chrome = chrome_theme.chrome(.trve, chrome_theme.modeFromColorterm(ctx.environ.getPosix("COLORTERM")));
        try app.requestTheme();
    }
    app.input_frame_limit = link.conn().max_frame;
    try app.setHostGeometry(.{ .cell_width = size.cell_width, .cell_height = size.cell_height });
    app.host_input_enabled = !args.raw;
    if (args.raw) {
        const stream = &app.panes.items[0].stream;
        stream.mode = .raw;
        stream.formats = &.{.vt};
    }
    try app.resize(size.cols, size.rows);

    var probe: host_probe.Probe = .{};
    const result = blk: {
        var tty = try Tty.enter();
        defer tty.leave();
        var surface = try term.Surface.init(ctx.gpa, app.cols, app.rows);
        var out_buf: [64 * 1024]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(ctx.io, &out_buf);
        const out = &stdout.interface;
        // A raw stream's output filter, between the pane and this terminal.
        var host: raw_filter.Host = .{ .out = out };
        defer {
            settleProbe(&probe);
            surface.deinit(out);
            raw_filter.restoreHost(out, app.host_input_enabled, if (args.raw) &host.filter else null) catch {};
            out.flush() catch {};
        }
        if (args.raw) {
            app.panes.items[0].stream.passthrough = host.passthrough();
            // Before any pane output, so the answers describe the host
            // from before the pane could change it. Attach doesn't wait.
            if (std.c.isatty(posix.STDOUT_FILENO) != 0) {
                try out.writeAll(host_probe.queries);
                probe.start(nowMs());
                host.filter.snapshot = &probe.snapshot;
            }
        } else try out.writeAll(Tty.enter_sequence);
        try out.flush();
        break :blk try loop(ctx, args, owner, &link, &app, &surface, out, &probe);
    };
    // Reasons are printed after the host terminal is restored.
    if (result.message) |m| return .{ .outcome = failure(switch (result.status) {
        3 => "not_found.pane",
        4 => "denied.read",
        6 => "unavailable",
        else => "failed",
    }, m) };
    const detached = if (app.quit) |q| std.mem.eql(u8, q, "detached") else false;
    // The session-picker's choice: the session to attach to next.
    const switch_to = if (app.switch_to) |id| (if (keep) |k| try k.dupe(u8, id) else null) else null;
    return .{ .outcome = .{ .status = result.status }, .session_ended = app.session_ended, .detached = detached, .name = name, .switch_to = switch_to };
}
const Outcome = struct { status: u8, message: ?[]const u8 = null };

fn loop(ctx: Context, args: Args, owner: ?std.process.Environ, link: *Link, app: *App, surface: *term.Surface, out: *std.Io.Writer, probe: *host_probe.Probe) !Outcome {
    var in_buf: [4096]u8 = undefined;
    var in_len: usize = 0;
    var escape_deadline: ?i64 = null;
    var frame: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer frame.deinit();
    var next_frame: i64 = 0;
    var emulating_started = !args.raw;
    var children: exec.Children = .{};
    defer children.deinit(ctx.gpa);
    while (true) {
        if (ctx.stopped.load(.monotonic)) {
            for (app.panes.items) |p| try p.stream.detach();
            try drain(link, app);
            return .{ .status = 0 };
        }
        try app.recoverBackfill();
        try drain(link, app);
        if (app.quit) |reason| {
            // Hand queued CLOSE frames to the socket before leaving.
            const deadline = nowMs() + 200;
            while (link.conn().output.items.len > 0 and nowMs() < deadline) {
                _ = link.client.receive(10) catch break;
            }
            return .{ .status = app.exit_status, .message = if (app.exit_status != 0) reason else null };
        }
        const now = nowMs();
        app.tick();
        try runExecs(ctx, app, &children);
        const passthrough = args.raw and (app.panes.items[0].stream.vt == null);
        if (passthrough) {
            try out.flush();
            app.dirty = false;
            app.pane_damage = false;
        }
        if (!passthrough and app.needsRender() and now >= next_frame) {
            if (!emulating_started) {
                // The raw program may have left modes or margins active.
                // Start the presentation renderer on a clean alternate screen.
                try out.writeAll("\x1b[!p\x1b[r");
                try out.writeAll(Tty.enter_sequence);
                app.host_input_enabled = true;
                emulating_started = true;
            }
            try app.render(surface);
            frame.clearRetainingCapacity();
            try surface.present(ctx.io, ctx.environ_map, &frame.writer);
            try out.writeAll(frame.written());
            if (app.host.items.len > 0) {
                try out.writeAll(app.host.items);
                app.host.clearRetainingCapacity();
            }
            try out.flush();
            next_frame = now + 8;
        }
        const conn = link.conn();
        var fds = [_]posix.pollfd{
            // A negative fd is skipped: held input waits in the tty queue.
            .{ .fd = if (app.holdInput()) -1 else posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = conn.fd, .events = posix.POLL.IN | (if (conn.output.items.len > 0) posix.POLL.OUT else @as(i16, 0)), .revents = 0 },
            .{ .fd = winch_pipe[0], .events = posix.POLL.IN, .revents = 0 },
        };
        var timeout: i32 = if (app.needsRender()) @intCast(@max(1, next_frame - now)) else 250;
        if (escape_deadline) |deadline| timeout = @intCast(@min(timeout, @max(0, deadline - now)));
        // The popup's delay and `keys.timeout_ms`; neither wakes an idle client.
        if (app.nextWake()) |wake| timeout = @intCast(@min(timeout, @max(0, wake - now)));
        // Held input stays in the tty, so the probe has nothing to give back.
        if (!app.holdInput()) if (probe.nextWake()) |wake| {
            timeout = @intCast(@min(timeout, @max(0, wake - now)));
        };
        _ = posix.poll(&fds, timeout) catch |err| if (err != error.Interrupted) return err;
        if (fds[2].revents != 0) {
            var drop: [64]u8 = undefined;
            while (std.c.read(winch_pipe[0], &drop, drop.len) > 0) {}
            const size = hostSize();
            try app.setHostGeometry(.{ .cell_width = size.cell_width, .cell_height = size.cell_height });
            try app.resize(size.cols, size.rows);
        }
        // The daemon first. Both can be queued, in either order; after a stall this
        // lets a key see a focus move that came first (a popup's removal), and a key typed before a lost link is read before the reconnect.
        if (fds[1].revents != 0) {
            const ok = service(link, app, fds[1].revents) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => false,
            };
            // A stopping on-demand daemon closes the connection right after
            // the final session.removed: that is the end.
            if (!ok and app.session_ended) return .{ .status = 0 };
            if (!ok) {
                app.say("connection lost; reconnecting", .{});
                if (!try reconnect(ctx, args, owner, link, app)) return .{ .status = 6, .message = "unavailable: lost the connection to the daemon" };
            }
        }
        // Serving it can start a hold (a reconnect): the bytes then stay in the tty.
        if (!app.holdInput()) {
            // Room for what the probe may give back, as an incomplete
            // sequence that fills the buffer never completes.
            if (!probe.done and in_buf.len - in_len < 3 * host_probe.Probe.max_held) in_len = 0;
            var fresh = probe.tick(in_buf[in_len..], nowMs());
            if (fds[0].revents != 0) {
                const n = readHost(probe, in_buf[in_len + fresh ..]);
                if (n == 0) return .{ .status = 0 };
                if (n > 0) fresh += @intCast(n);
            }
            if (fresh > 0) {
                in_len += fresh;
                // Raw input retains host keyboard, mouse and paste encodings.
                // Leader d detaches; leader leader sends a literal leader.
                const used = if (args.raw and !emulating_started) try rawInput(app, in_buf[0..in_len]) else try app.feedInput(in_buf[0..in_len]);
                if (used > 0) escape_deadline = null;
                std.mem.copyForwards(u8, in_buf[0 .. in_len - used], in_buf[used..in_len]);
                in_len -= used;
                // An incomplete sequence filling the buffer never completes.
                if (in_len == in_buf.len) in_len = 0;
            }
        }
        if (in_len == 1 and in_buf[0] == 0x1b and app.paste == null) {
            if (escape_deadline) |deadline| {
                if (nowMs() >= deadline) {
                    try app.flushEscape();
                    in_len = 0;
                    escape_deadline = null;
                }
            } else escape_deadline = nowMs() + 25;
        } else escape_deadline = null;
    }
}

/// One read of host input into `dest`. 0 is end of file. While the probe runs,
/// its replies are left out, so a read of nothing but replies returns -1.
fn readHost(probe: *host_probe.Probe, dest: []u8) isize {
    if (probe.done) return std.c.read(posix.STDIN_FILENO, dest.ptr, dest.len);
    var wire: [1024]u8 = undefined;
    const want = @min(wire.len, dest.len - host_probe.Probe.max_held);
    const n = std.c.read(posix.STDIN_FILENO, &wire, want);
    if (n <= 0) return n;
    const kept = probe.feed(wire[0..@intCast(n)], dest, nowMs());
    return if (kept == 0) -1 else @intCast(kept);
}

/// On the way out: replies still on their way would be typed at the shell,
/// and the restore wants them. Bounded, so a mute terminal costs `settle_ms`
/// once, and only when leaving within the probe's window. Other bytes read
/// here would be discarded by `Tty.leave` anyway.
fn settleProbe(probe: *host_probe.Probe) void {
    const deadline = nowMs() + host_probe.settle_ms;
    while (!probe.done) {
        const left = deadline - nowMs();
        if (left <= 0) break;
        var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&fds, @intCast(left)) catch break;
        if (ready == 0 or fds[0].revents & posix.POLL.IN == 0) break;
        var dest: [1024 + host_probe.Probe.max_held]u8 = undefined;
        if (readHost(probe, &dest) == 0) break;
    }
    probe.giveUp();
}

/// Queue every pane's C→S frames and verb requests on the connection.
fn drain(link: *Link, app: *App) !void {
    const conn = link.conn();
    for (app.panes.items) |p| try p.stream.flush(conn, sendFrame);
    try app.flushRequests(conn, sendLine);
    app.collect();
}

fn sendLine(conn: *proto.Connection, line: []const u8) anyerror!void {
    try conn.sendMessage(.{ .ndjson = line });
}

fn sendFrame(conn: *proto.Connection, stream: u32, o: pane_stream.Out) anyerror!void {
    try conn.sendMessage(.{ .frame = .{ .kind = o.kind, .stream = stream, .payload = o.payload } });
}

/// One socket turn. Returns false when the connection is gone.
/// Socket reads (of at most 8 KiB each) one wakeup may take: 256 KiB, one
/// full PTY frame.
const read_burst = 32;

fn service(link: *Link, app: *App, revents: i16) !bool {
    const conn = link.conn();
    if (revents & (posix.POLL.ERR | posix.POLL.NVAL) != 0) return false;
    if (revents & posix.POLL.OUT != 0) try conn.flush();
    if (revents & posix.POLL.IN != 0) {
        // Drain a bounded burst per wakeup: one 8 KiB read per poll lets a
        // flood outrun this client into an overflow resync, while
        // the bound still leaves host input and rendering a turn.
        for (0..read_burst) |_| {
            const more = conn.read() catch |err| return if (err == error.EndOfStream) false else err;
            while (try conn.next()) |msg| {
                if (msg != .frame) continue;
                const f = msg.frame;
                if (f.stream == 0) {
                    if (f.kind == proto.Kind.control) app.control(f.payload) catch |err| if (err == error.OutOfMemory) return err;
                    if (f.kind == proto.Kind.err or f.kind == proto.Kind.close) return false;
                    continue;
                }
                try app.frame(f.stream, f.kind, f.payload);
            }
            if (!more) break;
        }
    } else if (revents & posix.POLL.HUP != 0) return false;
    return true;
}

/// A lost connection restores each stream independently. With
/// the same daemon source each stream resumes at its applied offset;
/// otherwise the server sends a fresh snapshot.
fn reconnect(ctx: Context, args: Args, owner: ?std.process.Environ, link: *Link, app: *App) !bool {
    const deadline = nowMs() + 5000;
    while (nowMs() < deadline) {
        if (ctx.stopped.load(.monotonic)) return false;
        var fresh = connect(ctx, args, owner) catch {
            var none = [_]posix.pollfd{};
            _ = posix.poll(&none, 100) catch {};
            continue;
        };
        link.client.deinit();
        link.client = fresh;
        fresh = undefined;
        app.cancelPaste();
        app.input_frame_limit = link.conn().max_frame;
        try app.reattachStreams();
        app.pending.clearRetainingCapacity();
        app.clearPresses();
        if (args.target == .session) {
            app.topology_ready = false;
            try subscribe(&link.client, args.target, args.raw);
        }
        if (!args.raw) try app.requestConfig() else try app.requestKeys();
        app.say("reconnected", .{});
        return true;
    }
    return false;
}

var winch_pipe: [2]posix.fd_t = .{ -1, -1 };
fn onWinch(_: posix.SIG) callconv(.c) void {
    const byte = [_]u8{1};
    _ = std.c.write(winch_pipe[1], &byte, 1);
}

const Tty = struct {
    saved: posix.termios,
    // Request normalized host input independently of each pane's modes.
    // Unsupported Kitty keyboard requests are ignored by legacy hosts.
    const enter_sequence = "\x1b[?1049h\x1b[?1003h\x1b[?1006h\x1b[?2004h\x1b[>31u";
    fn enter() !Tty {
        if (@import("os.zig").pipe2(&winch_pipe, .{ .NONBLOCK = true, .CLOEXEC = true }) != 0) return error.PipeFailed;
        var act: posix.Sigaction = .{ .handler = .{ .handler = onWinch }, .mask = posix.sigemptyset(), .flags = posix.SA.RESTART };
        posix.sigaction(.WINCH, &act, null);
        const saved = try posix.tcgetattr(posix.STDIN_FILENO);
        var raw = saved;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;
        raw.cc[@backingInt(posix.V.MIN)] = 1;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        // NOW, not FLUSH: keystrokes typed while the client was starting
        // (typeahead) stay queued and reach the pane once attached. FLUSH
        // discarded them, so `venomx` followed at once by `exit` lost the
        // exit.
        try posix.tcsetattr(posix.STDIN_FILENO, .NOW, raw);
        return .{ .saved = saved };
    }
    fn leave(self: *Tty) void {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, self.saved) catch {};
        var act: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
        posix.sigaction(.WINCH, &act, null);
        for (winch_pipe) |fd| if (fd >= 0) {
            _ = std.c.close(fd);
        };
        winch_pipe = .{ -1, -1 };
    }
};

fn ioctlRequest(comptime value: anytype) c_int {
    return @bitCast(@as(u32, @intCast(value)));
}
fn hostSize() struct { cols: u16, rows: u16, cell_width: ?u16 = null, cell_height: ?u16 = null } {
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(posix.STDOUT_FILENO, ioctlRequest(posix.T.IOCGWINSZ), @intFromPtr(&ws)) != 0 or ws.col == 0 or ws.row == 0) return .{ .cols = 80, .rows = 24 };
    return .{ .cols = ws.col, .rows = ws.row, .cell_width = if (ws.xpixel >= ws.col) ws.xpixel / ws.col else null, .cell_height = if (ws.ypixel >= ws.row) ws.ypixel / ws.row else null };
}
/// Raw input sees host bytes: only the leader's legacy byte (0x02 for the
/// default `ctrl+b`) is intercepted.
fn rawInput(app: *App, bytes: []const u8) !usize {
    const stream = &app.panes.items[0].stream;
    const leader = @import("keys.zig").legacyByte(app.keymap.settings.leader) orelse 0;
    var start: usize = 0;
    for (bytes, 0..) |byte, i| {
        if (app.raw_leader) {
            app.raw_leader = false;
            if (byte == 'd') {
                try app.run(.{ .local = .detach });
                return bytes.len;
            }
            if (byte != leader) try stream.input(&.{leader});
            try stream.input(bytes[i..][0..1]);
            start = i + 1;
        } else if (byte == leader) {
            try stream.input(bytes[start..i]);
            start = i + 1;
            app.raw_leader = true;
        }
    }
    try stream.input(bytes[start..]);
    return bytes.len;
}

/// Run queued `exec` bindings and report failed ones.
fn runExecs(ctx: Context, app: *App, children: *exec.Children) !void {
    if (children.reap()) |failed| app.say("exec binding {s} {d}", .{ if (failed.signaled) "killed by signal" else "exited", failed.status });
    if (app.execs.items.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena.deinit();
    const env = try exec.childEnviron(arena.allocator(), ctx.environ);
    for (app.execs.items) |x| {
        defer x.deinit(app.a);
        const pid = exec.spawn(ctx.gpa, x.argv, env) catch {
            app.say("exec binding {s} could not start", .{x.argv[0]});
            continue;
        };
        try children.pids.append(ctx.gpa, pid);
    }
    app.execs.clearRetainingCapacity();
}

fn nowMs() i64 {
    return @import("server.zig").nowMs();
}

/// Test-only transport seam: exercise the real reconnect lifecycle without a
/// socket/hello server. Production builds have neither the hook nor its state.
pub const TestReconnect = if (@import("builtin").is_test) struct {
    var enabled = false;
    fn client(allocator: std.mem.Allocator) proto.Client {
        var conn = proto.Connection.init(allocator, -1);
        conn.protocol = .binary;
        conn.ready = true;
        return .{ .connection = conn, .options = .{ .tool = "venomx", .hello = .{ .identity = .{ .name = "test", .version = "0" } } } };
    }
    pub fn run(app: *App) !bool {
        enabled = true;
        defer enabled = false;
        var link: Link = .{ .client = client(app.a) };
        defer link.client.deinit();
        var stopped: std.atomic.Value(bool) = .init(false);
        var env: std.process.Environ.Map = .init(app.a);
        defer env.deinit();
        return reconnect(.{ .gpa = app.a, .io = std.testing.io, .environ = .empty, .environ_map = &env, .stopped = &stopped }, .{ .target = app.target, .path = .{}, .history = 0, .raw = false }, null, &link, app);
    }
} else struct {};

/// Test seam for `present`'s re-attach loop: scripted sessions, no daemon.
pub const TestPresent = if (@import("builtin").is_test) struct {
    var calls: std.ArrayList([]const u8) = .empty;
    var notices: std.ArrayList(?[]const u8) = .empty;
    var broken = false;
    /// s0 (the start) switches to s1 (vanished); s0 then ends on its own.
    fn script(_: Context, args: Args, keep: ?std.mem.Allocator) anyerror!Ended {
        const gpa = std.testing.allocator;
        try calls.append(gpa, args.target.session);
        try notices.append(gpa, args.notice);
        const id = args.target.session;
        if (std.mem.eql(u8, id, "s1")) return .{ .outcome = failure(if (broken) "unavailable" else "not_found.session", "no such session") };
        if (std.mem.eql(u8, id, "s2")) return .{ .outcome = .{ .status = 0 }, .detached = true };
        const next: []const u8 = if (calls.items.len == 1) "s1" else if (calls.items.len == 3) "s2" else return .{ .outcome = .{ .status = 0 }, .detached = true };
        return .{ .outcome = .{ .status = 0 }, .switch_to = try keep.?.dupe(u8, next) };
    }
    /// A non-`not_found.session` failure after a switch is returned as is.
    pub fn runBroken() !void {
        broken = true;
        defer broken = false;
        const gpa = std.testing.allocator;
        calls = .empty;
        notices = .empty;
        defer calls.deinit(gpa);
        defer notices.deinit(gpa);
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        var stopped: std.atomic.Value(bool) = .init(false);
        var env: std.process.Environ.Map = .init(gpa);
        defer env.deinit();
        const ctx: Context = .{ .gpa = gpa, .io = std.testing.io, .environ = .empty, .environ_map = &env, .stopped = &stopped };
        const out = try presentWith(ctx, arena_state.allocator(), .{ .target = .{ .session = "s0" }, .path = .{}, .history = 0, .raw = false }, script);
        try std.testing.expectEqualStrings("unavailable", out.failure.code);
        try std.testing.expectEqual(@as(usize, 2), calls.items.len);
    }
    pub fn mapping() !void {
        const eq = std.testing.expectEqualStrings;
        try eq("not_found.session", sessionGetFailure("not_found.session").failure.code);
        try eq("denied.read", sessionGetFailure("denied.x").failure.code);
        try eq("failed", sessionGetFailure("internal").failure.code);
        var app = try App.init(std.testing.allocator, .{ .session = "s0" }, .{ .cols = 80, .rows = 24 }, .{});
        defer app.deinit();
        showNotice(&app, .{ .target = .{ .session = "s0" }, .path = .{}, .history = 0, .raw = false });
        try eq("", app.message.items);
        showNotice(&app, .{ .target = .{ .session = "s0" }, .path = .{}, .history = 0, .raw = false, .notice = "session s1 is gone" });
        try eq("session s1 is gone", app.message.items);
    }
    pub fn run() !void {
        const gpa = std.testing.allocator;
        calls = .empty;
        notices = .empty;
        defer calls.deinit(gpa);
        defer notices.deinit(gpa);
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        var stopped: std.atomic.Value(bool) = .init(false);
        var env: std.process.Environ.Map = .init(gpa);
        defer env.deinit();
        const ctx: Context = .{ .gpa = gpa, .io = std.testing.io, .environ = .empty, .environ_map = &env, .stopped = &stopped };
        const out = try presentWith(ctx, arena_state.allocator(), .{ .target = .{ .session = "s0" }, .path = .{}, .history = 0, .raw = false }, script);
        try std.testing.expectEqual(@as(u8, 0), out.status);
        // s0 -> s1 (gone) -> back on s0 with a notice -> s2 (alive), no notice.
        const want = [_][]const u8{ "s0", "s1", "s0", "s2" };
        try std.testing.expectEqual(want.len, calls.items.len);
        for (want, calls.items) |w, got| try std.testing.expectEqualStrings(w, got);
        try std.testing.expect(notices.items[0] == null and notices.items[1] == null and notices.items[3] == null);
        try std.testing.expectEqualStrings("session s1 is gone", notices.items[2].?);
    }
} else struct {};
/// What the host terminal can draw, from `TERM` and the locale.
pub fn hostSupport(environ: std.process.Environ) @import("attach_border.zig").Support {
    return @import("attach_border.zig").Support.detect(environ.getPosix("TERM"), environ.getPosix("LC_ALL"), environ.getPosix("LC_CTYPE"), environ.getPosix("LANG"));
}
