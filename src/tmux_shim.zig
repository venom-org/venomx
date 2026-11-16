//! tmux compatibility shim: the subset of tmux that Claude Code's
//! agent teams use (`TmuxBackend` of Claude Code 2.1.319), mapped onto
//! venomx verbs and sent as the calling pane's own principal (the ordinary
//! `VENOMX_TOKEN` / `VENOMX_SOCKET` of the pane; no owner file, no
//! elevation). Reached as `venomx tmux ...` or by running the binary under
//! the name `tmux` (a symlink first on PATH).
//!
//! Policy: every supported command validates its flags against an explicit
//! list. A flag, command, key name, target form or format variable outside
//! that list fails with exit status 1 and a message naming it, before any
//! verb with an effect is sent. Nothing is ignored silently, with two
//! documented exceptions: the global `-L` / `-S` (venomx has one daemon per
//! socket, chosen by `VENOMX_SOCKET`) and `split-window -l`, which is
//! applied as a best-effort divider move after the split (warning on
//! stderr if it could not be applied).
//!
//! `respawn-pane`: venomx has no verb that replaces a live pane's process.
//! Claude Code parks each teammate pane on `cat` and then respawns it, so a
//! pane started with exactly the command `cat` is started as a parked
//! launcher (tag `tmux.state=parked`) that reads one command line and execs
//! it; `respawn-pane` on a parked pane sends that line. Respawning any
//! other pane fails clearly. See docs/site/tmux.md.
const std = @import("std");
const proto = @import("proto");
const standalone = @import("standalone.zig");
const Value = std.json.Value;
const eq = std.mem.eql;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Shown as `tmux -V`; Claude Code only checks the exit status.
pub const version_line = "tmux 3.4 (venomx tmux shim)";

pub const ApiError = struct { code: []const u8, message: []const u8 };
pub const Reply = union(enum) { ok: Value, err: ApiError };

/// The daemon as the shim sees it: one blocking verb call with JSON params.
pub const Backend = struct {
    ptr: *anyopaque,
    callFn: *const fn (ptr: *anyopaque, a: Allocator, verb: []const u8, params_json: []const u8) anyerror!Reply,
    pub fn call(self: Backend, a: Allocator, verb: []const u8, params_json: []const u8) anyerror!Reply {
        return self.callFn(self.ptr, a, verb, params_json);
    }
};

/// What the shim knows about its caller.
pub const Env = struct {
    /// `VENOMX_PANE` (the calling pane), if any.
    pane: ?[]const u8 = null,
    /// Absolute working directory of the shim process.
    cwd: []const u8 = "/",
    /// `$SHELL`, used when a pane is created with no command.
    shell: []const u8 = "/bin/sh",
    /// A file all respawn-pane calls of this daemon serialize on (flock), so
    /// two concurrent respawns of one pane cannot both pass the parked check.
    lock_path: ?[:0]const u8 = null,
    /// How long respawn-pane waits for that lock before failing.
    lock_wait_ms: u32 = 2000,
    stopped: ?*const std.atomic.Value(bool) = null,
};

// ------------------------------------------------------------ command table

const Command = struct {
    name: []const u8,
    alias: []const u8,
    /// getopt-style flags; a following `:` means the flag takes a value.
    spec: []const u8,
    run: *const fn (*Shim, *const Parsed) anyerror!void,
};

const commands = [_]Command{
    .{ .name = "has-session", .alias = "has", .spec = "t:", .run = hasSession },
    .{ .name = "new-session", .alias = "new", .spec = "dPs:n:c:F:", .run = newSession },
    .{ .name = "new-window", .alias = "neww", .spec = "dPn:t:c:F:", .run = newWindow },
    .{ .name = "split-window", .alias = "splitw", .spec = "dhvPl:t:F:c:", .run = splitWindow },
    .{ .name = "list-panes", .alias = "lsp", .spec = "t:F:", .run = listPanes },
    .{ .name = "list-windows", .alias = "lsw", .spec = "t:F:", .run = listWindows },
    .{ .name = "display-message", .alias = "display", .spec = "pt:", .run = displayMessage },
    .{ .name = "kill-pane", .alias = "killp", .spec = "t:", .run = killPane },
    .{ .name = "send-keys", .alias = "send", .spec = "lt:", .run = sendKeys },
    .{ .name = "capture-pane", .alias = "capturep", .spec = "pNS:t:", .run = capturePane },
    .{ .name = "select-pane", .alias = "selectp", .spec = "t:T:", .run = selectPane },
    .{ .name = "respawn-pane", .alias = "respawnp", .spec = "kt:", .run = respawnPane },
};

pub fn usage(w: *Writer) !void {
    try w.writeAll("venomx tmux: a tmux shim for the commands Claude Code's agent teams use.\n" ++
        "Run as `venomx tmux <command> ...`, or symlink the venomx binary as `tmux` first on PATH.\n" ++
        "It acts as the calling pane's own principal (VENOMX_TOKEN, VENOMX_SOCKET).\n" ++
        "Supported commands (anything else fails with exit status 1):\n");
    for (commands) |cmd| try w.print("  {s} ({s})  flags: {s}\n", .{ cmd.name, cmd.alias, cmd.spec });
    try w.writeAll("  -V\n  global -L <name> and -S <path> are accepted and ignored (VENOMX_SOCKET selects the daemon)\n");
}

// ------------------------------------------------------------ flag parsing

pub const Parsed = struct {
    present: [128]bool = @splat(false),
    values: [128]?[]const u8 = @splat(null),
    rest: []const []const u8 = &.{},
    fn has(self: *const Parsed, flag: u8) bool {
        return self.present[flag];
    }
    fn value(self: *const Parsed, flag: u8) ?[]const u8 {
        return self.values[flag];
    }
};

pub const ParseError = error{ UnknownFlag, MissingValue, DuplicateFlag };

/// getopt parsing: clustered short flags, a value flag takes the rest of its
/// cluster or the next argument (whatever it looks like, so `-S -50` works),
/// `--` ends options and options end at the first non-flag argument.
pub fn parseFlags(args: []const []const u8, spec: []const u8, bad: *u8) ParseError!Parsed {
    var out: Parsed = .{};
    var i: usize = 0;
    outer: while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (eq(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            const ch = arg[j];
            const at = if (ch < 128) std.mem.indexOfScalar(u8, spec, ch) else null;
            if (at == null or ch == ':') {
                bad.* = ch;
                return error.UnknownFlag;
            }
            if (out.present[ch]) {
                bad.* = ch;
                return error.DuplicateFlag;
            }
            out.present[ch] = true;
            if (at.? + 1 < spec.len and spec[at.? + 1] == ':') {
                if (j + 1 < arg.len) {
                    out.values[ch] = arg[j + 1 ..];
                } else if (i + 1 < args.len) {
                    i += 1;
                    out.values[ch] = args[i];
                } else {
                    bad.* = ch;
                    return error.MissingValue;
                }
                continue :outer;
            }
        }
    }
    out.rest = args[@min(i, args.len)..];
    return out;
}

// ------------------------------------------------------------ ids

/// venomx `p3` -> tmux `%3` (`w` -> `@`, `s` -> `$`).
fn tmuxId(a: Allocator, id: []const u8) ![]const u8 {
    if (id.len < 2) return a.dupe(u8, id);
    const sigil: u8 = switch (id[0]) {
        'p' => '%',
        'w' => '@',
        's' => '$',
        else => return a.dupe(u8, id),
    };
    return std.fmt.allocPrint(a, "{c}{s}", .{ sigil, id[1..] });
}
/// tmux `%3` -> venomx `p3`; null if `t` is not that form.
fn venomId(a: Allocator, t: []const u8, sigil: u8, prefix: u8) !?[]const u8 {
    if (t.len < 2 or t[0] != sigil) return null;
    for (t[1..]) |ch| if (!std.ascii.isDigit(ch)) return null;
    return try std.fmt.allocPrint(a, "{c}{s}", .{ prefix, t[1..] });
}

// ------------------------------------------------------------ keys

const named_keys = [_]struct { []const u8, []const u8 }{
    .{ "Enter", "\r" },       .{ "Escape", "\x1b" },  .{ "Space", " " },          .{ "Tab", "\t" },
    .{ "BTab", "\x1b[Z" },    .{ "BSpace", "\x7f" },  .{ "Up", "\x1b[A" },        .{ "Down", "\x1b[B" },
    .{ "Right", "\x1b[C" },   .{ "Left", "\x1b[D" },  .{ "Home", "\x1b[1~" },     .{ "End", "\x1b[4~" },
    .{ "PageUp", "\x1b[5~" }, .{ "PgUp", "\x1b[5~" }, .{ "PageDown", "\x1b[6~" }, .{ "PgDn", "\x1b[6~" },
    .{ "DC", "\x1b[3~" },     .{ "IC", "\x1b[2~" },   .{ "F1", "\x1bOP" },        .{ "F2", "\x1bOQ" },
    .{ "F3", "\x1bOR" },      .{ "F4", "\x1bOS" },    .{ "F5", "\x1b[15~" },      .{ "F6", "\x1b[17~" },
    .{ "F7", "\x1b[18~" },    .{ "F8", "\x1b[19~" },  .{ "F9", "\x1b[20~" },      .{ "F10", "\x1b[21~" },
    .{ "F11", "\x1b[23~" },   .{ "F12", "\x1b[24~" },
};

pub const KeyError = error{UnsupportedKey};

/// The bytes for one `send-keys` argument without `-l`: a key name, a
/// `C-x` / `M-x` chord, or (null) literal text. A chord or key-looking name
/// this table lacks is an error instead of being typed literally.
pub fn keyBytes(a: Allocator, arg: []const u8) KeyError!?[]const u8 {
    for (named_keys) |k| if (eq(u8, k[0], arg)) return k[1];
    if (arg.len >= 3 and arg[1] == '-' and (arg[0] == 'C' or arg[0] == 'M' or arg[0] == 'S')) {
        const rest = arg[2..];
        if (arg[0] == 'C' and rest.len == 1) {
            const ch = rest[0];
            const b: u8 = switch (ch) {
                'a'...'z' => ch - 'a' + 1,
                'A'...'Z' => ch - 'A' + 1,
                '@' => 0,
                '[' => 27,
                '\\' => 28,
                ']' => 29,
                '^' => 30,
                '_' => 31,
                '?' => 127,
                else => return error.UnsupportedKey,
            };
            return a.dupe(u8, &.{b}) catch return error.UnsupportedKey;
        }
        if (arg[0] == 'C' and eq(u8, rest, "Space")) return "\x00";
        if (arg[0] == 'M') {
            const inner = (try keyBytes(a, rest)) orelse if (rest.len == 1) rest else return error.UnsupportedKey;
            return std.fmt.allocPrint(a, "\x1b{s}", .{inner}) catch return error.UnsupportedKey;
        }
        return error.UnsupportedKey;
    }
    return null;
}

// ------------------------------------------------------------ sizes

/// `70%` -> 70; null for anything else (cells are not supported by -l).
pub fn percent(text: []const u8) ?u32 {
    if (text.len < 2 or text[text.len - 1] != '%') return null;
    const n = std.fmt.parseInt(u32, text[0 .. text.len - 1], 10) catch return null;
    return if (n >= 1 and n <= 99) n else null;
}

// ------------------------------------------------------------ the shim

const Shim = struct {
    a: Allocator,
    backend: Backend,
    env: Env,
    out: *Writer,
    err: *Writer,
    command: []const u8 = "",
    // Per-invocation caches, dropped by `refresh` after any mutation.
    pane_cache: ?[]const Value = null,
    session_cache: ?[]const Value = null,
    windows: std.StringHashMapUnmanaged(Value) = .empty,
    sessions: std.StringHashMapUnmanaged(Value) = .empty,

    fn fail(self: *Shim, comptime fmt: []const u8, args: anytype) anyerror {
        self.err.print("venomx tmux: " ++ fmt ++ "\n", args) catch {};
        return error.Failed;
    }

    /// An exclusive flock on env.lock_path (-1: no lock configured). Fails
    /// closed: if the lock cannot be opened or taken within lock_wait_ms, the
    /// command fails before any change.
    fn lockRespawns(self: *Shim) anyerror!std.c.fd_t {
        const path = self.env.lock_path orelse return -1;
        var fd: std.c.fd_t = -1;
        while (true) {
            fd = std.c.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0o600));
            if (fd >= 0) break;
            if (std.c.errno(fd) != .INTR) return self.fail("respawn-pane: cannot open the respawn lock {s}", .{path});
        }
        const step_ms: u32 = 20;
        var waited: u32 = 0;
        while (true) {
            const rc = std.c.flock(fd, std.c.LOCK.EX | std.c.LOCK.NB);
            if (rc == 0) return fd;
            const e = std.c.errno(rc);
            if (e != .INTR and e != .AGAIN) {
                _ = std.c.close(fd);
                return self.fail("respawn-pane: cannot lock {s}", .{path});
            }
            if (waited >= self.env.lock_wait_ms or (self.env.stopped != null and self.env.stopped.?.load(.monotonic))) {
                _ = std.c.close(fd);
                return self.fail("respawn-pane: another respawn-pane holds the lock; try again", .{});
            }
            const ts: std.c.timespec = .{ .sec = 0, .nsec = step_ms * 1_000_000 };
            _ = std.c.nanosleep(&ts, null);
            waited += step_ms;
        }
    }

    fn refresh(self: *Shim) void {
        self.pane_cache = null;
        self.session_cache = null;
        self.windows = .empty;
        self.sessions = .empty;
    }

    /// One verb call. A daemon error becomes a clear failure unless `soft`.
    fn call(self: *Shim, verb: []const u8, params: anytype) anyerror!Value {
        const reply = try self.callRaw(verb, params);
        switch (reply) {
            .ok => |v| return v,
            .err => |e| return self.fail("{s} failed: {s}: {s}", .{ verb, e.code, e.message }),
        }
    }
    fn callRaw(self: *Shim, verb: []const u8, params: anytype) anyerror!Reply {
        const object = if (@TypeOf(params) == @TypeOf(.{})) struct {}{} else params;
        const body = try std.fmt.allocPrint(self.a, "{f}", .{std.json.fmt(object, .{ .emit_null_optional_fields = false })});
        return self.backend.call(self.a, verb, body);
    }

    // ---- reads

    fn paneList(self: *Shim) ![]const Value {
        if (self.pane_cache) |p| return p;
        const v = try self.call("pane.list", .{});
        const items = (v.object.get("panes") orelse return self.fail("pane.list returned no panes", .{})).array.items;
        self.pane_cache = items;
        return items;
    }
    fn sessionList(self: *Shim) ![]const Value {
        if (self.session_cache) |p| return p;
        const v = try self.call("session.list", .{});
        const items = (v.object.get("sessions") orelse return self.fail("session.list returned no sessions", .{})).array.items;
        self.session_cache = items;
        return items;
    }
    fn windowGet(self: *Shim, id: []const u8) !Value {
        if (self.windows.get(id)) |w| return w;
        const v = try self.call("window.get", .{ .window = id });
        try self.windows.put(self.a, id, v);
        return v;
    }
    fn sessionGet(self: *Shim, id: []const u8) !Value {
        if (self.sessions.get(id)) |s| return s;
        const v = try self.call("session.get", .{ .session = id });
        try self.sessions.put(self.a, id, v);
        return v;
    }
    fn paneInfo(self: *Shim, id: []const u8) !Value {
        for (try self.paneList()) |p| if (eq(u8, jstr(p, "pane") orelse "", id)) return p;
        return self.fail("can't find pane: {s}", .{try tmuxId(self.a, id)});
    }
    /// Pane IDs of a window's tiled layout, in layout order.
    fn windowPanes(self: *Shim, window: []const u8) ![]const []const u8 {
        const w = try self.windowGet(window);
        var out: std.ArrayList([]const u8) = .empty;
        const nodes = (w.object.get("nodes") orelse return out.items).array.items;
        for (nodes) |n| if (jstr(n, "kind")) |k| if (eq(u8, k, "pane")) {
            if (jstr(n, "pane")) |id| try out.append(self.a, id);
        };
        return out.items;
    }

    // ---- targets

    fn currentPane(self: *Shim) ![]const u8 {
        return self.env.pane orelse self.fail("no current pane: pass -t (this process is not inside a venomx pane)", .{});
    }

    /// A pane target: `%N`, `@N` / `session:window` (the window's first pane),
    /// `session:window.N`, or the current pane when `t` is null.
    fn paneTarget(self: *Shim, t: ?[]const u8) ![]const u8 {
        const raw = t orelse return self.currentPane();
        const text = if (raw.len > 0 and raw[0] == '=') raw[1..] else raw;
        if (try venomId(self.a, text, '%', 'p')) |id| {
            _ = try self.paneInfo(id);
            return id;
        }
        var pane_part: ?[]const u8 = null;
        var win_text = text;
        if (std.mem.lastIndexOfScalar(u8, text, '.')) |dot| if (std.mem.indexOfScalar(u8, text, ':') != null or text[0] == '@') {
            win_text = text[0..dot];
            pane_part = text[dot + 1 ..];
        };
        const window = try self.windowTarget(win_text);
        const panes = try self.windowPanes(window);
        if (pane_part) |pp| {
            if (try venomId(self.a, pp, '%', 'p')) |id| for (panes) |p| if (eq(u8, p, id)) return id;
            const n = std.fmt.parseInt(usize, pp, 10) catch return self.fail("unsupported pane target: {s}", .{raw});
            if (n < panes.len) return panes[n];
            return self.fail("can't find pane: {s}", .{raw});
        }
        if (panes.len == 0) return self.fail("can't find pane: window {s} has no panes", .{text});
        return panes[0];
    }

    /// A window target: `@N`, `%N` (its window), `session:window` (window id,
    /// exact name or index), `session:` (the first window), or a bare session
    /// name (its first window).
    fn windowTarget(self: *Shim, t: ?[]const u8) ![]const u8 {
        const raw = t orelse return jstr(try self.paneInfo(try self.currentPane()), "window").?;
        const text = if (raw.len > 0 and raw[0] == '=') raw[1..] else raw;
        if (try venomId(self.a, text, '@', 'w')) |id| {
            _ = try self.windowGet(id);
            return id;
        }
        if (try venomId(self.a, text, '%', 'p')) |id| return jstr(try self.paneInfo(id), "window").?;
        var session_text: []const u8 = text;
        var win_text: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, text, ':')) |colon| {
            session_text = text[0..colon];
            win_text = text[colon + 1 ..];
        }
        const sid = if (session_text.len == 0) jstr(try self.paneInfo(try self.currentPane()), "session").? else try self.sessionTarget(session_text);
        const s = try self.sessionGet(sid);
        const wins = (s.object.get("windows") orelse return self.fail("session.get returned no windows", .{})).array.items;
        if (win_text == null or win_text.?.len == 0) {
            if (wins.len == 0) return self.fail("can't find window: session {s} has none", .{session_text});
            return jstr(wins[0], "window").?;
        }
        const wt = win_text.?;
        if (try venomId(self.a, wt, '@', 'w')) |id| for (wins) |w| if (eq(u8, jstr(w, "window").?, id)) return id;
        for (wins) |w| if (eq(u8, jstr(w, "name") orelse "", wt)) return jstr(w, "window").?;
        if (std.fmt.parseInt(usize, wt, 10)) |n| {
            if (n < wins.len) return jstr(wins[n], "window").?;
        } else |_| {}
        return self.fail("can't find window: {s}", .{wt});
    }

    /// A session target: `$N`, an exact session name, or (when null) the
    /// current pane's session. A pane or window target names its session.
    fn sessionTarget(self: *Shim, t: ?[]const u8) ![]const u8 {
        const raw = t orelse return jstr(try self.paneInfo(try self.currentPane()), "session").?;
        const text = if (raw.len > 0 and raw[0] == '=') raw[1..] else raw;
        if (try venomId(self.a, text, '$', 's')) |id| {
            for (try self.sessionList()) |s| if (eq(u8, jstr(s, "session").?, id)) return id;
            return self.fail("can't find session: {s}", .{raw});
        }
        if (try venomId(self.a, text, '%', 'p')) |id| return jstr(try self.paneInfo(id), "session").?;
        if (try venomId(self.a, text, '@', 'w')) |id| return jstr(try self.windowGet(id), "session").?;
        for (try self.sessionList()) |s| if (eq(u8, jstr(s, "name") orelse "", text)) return jstr(s, "session").?;
        return self.fail("can't find session: {s}", .{raw});
    }

    // ---- format strings

    const Ctx = struct {
        pane: ?Value = null,
        window: []const u8,
        window_name: []const u8,
        window_index: usize,
        session: []const u8,
        session_name: []const u8,
        pane_index: usize = 0,
    };

    fn windowCtx(self: *Shim, window: []const u8, pane: ?[]const u8) !Ctx {
        const w = try self.windowGet(window);
        const sid = jstr(w, "session").?;
        const s = try self.sessionGet(sid);
        var index: usize = 0;
        for ((s.object.get("windows") orelse return self.fail("session.get returned no windows", .{})).array.items, 0..) |x, i| {
            if (eq(u8, jstr(x, "window").?, window)) index = i;
        }
        var sname: []const u8 = "";
        for (try self.sessionList()) |x| if (eq(u8, jstr(x, "session").?, sid)) {
            sname = jstr(x, "name") orelse "";
        };
        var ctx: Ctx = .{ .window = window, .window_name = jstr(w, "name") orelse "", .window_index = index, .session = sid, .session_name = sname };
        const panes = try self.windowPanes(window);
        const chosen = pane orelse if (panes.len > 0) panes[0] else null;
        if (chosen) |id| {
            ctx.pane = try self.paneInfo(id);
            for (panes, 0..) |p, i| if (eq(u8, p, id)) {
                ctx.pane_index = i;
            };
        }
        return ctx;
    }
    fn paneCtx(self: *Shim, pane: []const u8) !Ctx {
        return self.windowCtx(jstr(try self.paneInfo(pane), "window").?, pane);
    }

    /// `#{name}` and `##` only; any other variable or `#` sequence fails.
    fn expand(self: *Shim, fmt: []const u8, ctx: *const Ctx) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < fmt.len) {
            if (fmt[i] != '#') {
                try out.append(self.a, fmt[i]);
                i += 1;
                continue;
            }
            if (i + 1 < fmt.len and fmt[i + 1] == '#') {
                try out.append(self.a, '#');
                i += 2;
                continue;
            }
            if (i + 1 >= fmt.len or fmt[i + 1] != '{') return self.fail("unsupported format sequence at '{s}' (only #{{variable}} is supported)", .{fmt[i..]});
            const close = std.mem.indexOfScalarPos(u8, fmt, i + 2, '}') orelse return self.fail("unterminated format sequence in '{s}'", .{fmt});
            const name = fmt[i + 2 .. close];
            try out.appendSlice(self.a, try self.variable(name, ctx));
            i = close + 1;
        }
        return out.items;
    }

    fn variable(self: *Shim, name: []const u8, ctx: *const Ctx) ![]const u8 {
        const a = self.a;
        if (eq(u8, name, "window_id")) return tmuxId(a, ctx.window);
        if (eq(u8, name, "window_name")) return ctx.window_name;
        if (eq(u8, name, "window_index")) return std.fmt.allocPrint(a, "{d}", .{ctx.window_index});
        if (eq(u8, name, "session_id")) return tmuxId(a, ctx.session);
        if (eq(u8, name, "session_name")) return ctx.session_name;
        const pane_vars = [_][]const u8{ "pane_id", "pane_index", "pane_title", "pane_pid", "pane_dead", "pane_width", "pane_height" };
        for (pane_vars) |v| if (eq(u8, v, name)) {
            const pane = ctx.pane orelse return "";
            if (eq(u8, name, "pane_id")) return tmuxId(a, jstr(pane, "pane").?);
            if (eq(u8, name, "pane_index")) return std.fmt.allocPrint(a, "{d}", .{ctx.pane_index});
            if (eq(u8, name, "pane_title")) return paneTitle(pane);
            if (eq(u8, name, "pane_pid")) return std.fmt.allocPrint(a, "{d}", .{jint(pane, "pid") orelse 0});
            if (eq(u8, name, "pane_dead")) return if (jbool(pane, "exited")) "1" else "0";
            const cap = try self.call("pane.capture", .{ .pane = jstr(pane, "pane").? });
            return std.fmt.allocPrint(a, "{d}", .{jint(cap, if (eq(u8, name, "pane_width")) "cols" else "rows") orelse 0});
        };
        return self.fail("unsupported format variable '{s}' (supported: {s})", .{ name, variable_list });
    }

    // ---- command line for a new pane

    const Launch = struct { argv: []const []const u8, program: ?[]const u8 = null, parked: bool = false };

    /// tmux semantics: no command is the default shell as a login shell, one
    /// argument is a shell command line (`/bin/sh -c`), several are an argv.
    /// The exact command `cat` is Claude Code's placeholder and becomes a
    /// parked launcher (see the file comment).
    fn launch(self: *Shim, rest: []const []const u8) !Launch {
        if (rest.len == 0) {
            const argv = try standalone.loginArgv(self.a, self.env.shell);
            return .{ .argv = argv, .program = self.env.shell };
        }
        if (rest.len == 1 and eq(u8, rest[0], "cat")) return .{ .argv = &parked_argv, .parked = true };
        if (rest.len == 1) {
            if (rest[0].len == 0) return self.fail("empty command", .{});
            const argv = try self.a.alloc([]const u8, 3);
            argv[0] = "/bin/sh";
            argv[1] = "-c";
            argv[2] = rest[0];
            return .{ .argv = argv };
        }
        return .{ .argv = rest };
    }

    fn startDir(self: *Shim, c: ?[]const u8) ![]const u8 {
        const dir = c orelse return self.env.cwd;
        if (dir.len == 0) return self.fail("empty -c directory", .{});
        if (std.fs.path.isAbsolute(dir)) return dir;
        return std.fs.path.join(self.a, &.{ self.env.cwd, dir });
    }

    const Tag = struct { key: []const u8, value: []const u8 };
    fn parkedTags(l: Launch) ?[]const Tag {
        return if (l.parked) &parked_tags else null;
    }

    /// Syntax and variable names of a format, checked without any daemon call,
    /// so a bad -F fails before a pane, window or session is created.
    fn checkFormat(self: *Shim, fmt: []const u8) !void {
        var i: usize = 0;
        while (i < fmt.len) {
            if (fmt[i] != '#') {
                i += 1;
                continue;
            }
            if (i + 1 < fmt.len and fmt[i + 1] == '#') {
                i += 2;
                continue;
            }
            if (i + 1 >= fmt.len or fmt[i + 1] != '{') return self.fail("unsupported format sequence at '{s}' (only #{{variable}} is supported)", .{fmt[i..]});
            const close = std.mem.indexOfScalarPos(u8, fmt, i + 2, '}') orelse return self.fail("unterminated format sequence in '{s}'", .{fmt});
            const name = fmt[i + 2 .. close];
            var known = false;
            for (known_variables) |v| {
                if (eq(u8, v, name)) known = true;
            }
            if (!known) return self.fail("unsupported format variable '{s}' (supported: {s})", .{ name, variable_list });
            i = close + 1;
        }
    }
    fn checkNew(self: *Shim, p: *const Parsed) !void {
        if (p.has('P')) try self.checkFormat(p.value('F') orelse default_new_format);
    }

    /// `-P` output: the format, or tmux's default.
    fn printNew(self: *Shim, p: *const Parsed, pane: []const u8) !void {
        if (!p.has('P')) return;
        self.refresh();
        const ctx = try self.paneCtx(pane);
        const text = try self.expand(p.value('F') orelse default_new_format, &ctx);
        try self.out.print("{s}\n", .{text});
    }

    fn noPositional(self: *Shim, p: *const Parsed) !void {
        if (p.rest.len > 0) return self.fail("{s}: unexpected argument '{s}'", .{ self.command, p.rest[0] });
    }
};

const max_history: i64 = 1_000_000;
const default_new_format = "#{session_name}:#{window_index}.#{pane_index}";
const known_variables = [_][]const u8{ "window_id", "window_name", "window_index", "session_id", "session_name", "pane_id", "pane_index", "pane_title", "pane_pid", "pane_dead", "pane_width", "pane_height" };
const variable_list = "window_id window_name window_index session_id session_name pane_id pane_index pane_title pane_pid pane_dead pane_width pane_height";
const parked_script = "stty -echo -icanon min 1 time 0 2>/dev/null; IFS= read -r c; stty sane 2>/dev/null; exec /bin/sh -c \"$c\"";
const parked_argv = [_][]const u8{ "/bin/sh", "-c", parked_script };
const parked_tags = [_]Shim.Tag{.{ .key = "tmux.state", .value = "parked" }};

fn jstr(v: Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .string) x.string else null;
}
fn jint(v: Value, key: []const u8) ?i64 {
    if (v != .object) return null;
    const x = v.object.get(key) orelse return null;
    return if (x == .integer) x.integer else null;
}
fn jbool(v: Value, key: []const u8) bool {
    if (v != .object) return false;
    const x = v.object.get(key) orelse return false;
    return x == .bool and x.bool;
}
/// A tag set by `select-pane -T`, else the program's own title.
fn paneTitle(pane: Value) []const u8 {
    if (pane.object.get("tags")) |tags| if (tags == .array) for (tags.array.items) |t| {
        if (eq(u8, jstr(t, "key") orelse "", "tmux.title")) return jstr(t, "value") orelse "";
    };
    return jstr(pane, "title") orelse "";
}
fn paneTag(pane: Value, key: []const u8) ?[]const u8 {
    if (pane.object.get("tags")) |tags| if (tags == .array) for (tags.array.items) |t| {
        if (eq(u8, jstr(t, "key") orelse "", key)) return jstr(t, "value");
    };
    return null;
}

// ------------------------------------------------------------ commands

fn hasSession(s: *Shim, p: *const Parsed) anyerror!void {
    try s.noPositional(p);
    const t = p.value('t') orelse return s.fail("has-session needs -t", .{});
    _ = try s.sessionTarget(t);
}

fn sessionNameFree(s: *Shim, name: []const u8) !bool {
    for (try s.sessionList()) |x| if (eq(u8, jstr(x, "name") orelse "", name)) return false;
    return true;
}

fn newSession(s: *Shim, p: *const Parsed) anyerror!void {
    try s.checkNew(p);
    if (!p.has('d')) return s.fail("new-session without -d would attach a terminal; use -d (or `venomx new` to attach)", .{});
    const l = try s.launch(p.rest);
    var name: []const u8 = undefined;
    if (p.value('s')) |given| {
        const copy = try s.a.dupe(u8, given);
        for (copy) |*ch| if (ch.* == ':' or ch.* == '.') {
            ch.* = '_';
        };
        name = copy;
        if (!try sessionNameFree(s, name)) return s.fail("duplicate session: {s}", .{name});
    } else {
        var n: usize = 0;
        while (true) : (n += 1) {
            name = try std.fmt.allocPrint(s.a, "{d}", .{n});
            if (try sessionNameFree(s, name)) break;
        }
    }
    const cwd = try s.startDir(p.value('c'));
    const made = try s.call("session.create", .{ .name = name });
    const sid = jstr(made, "session") orelse return s.fail("session.create returned no session", .{});
    const reply = s.callRaw("window.create", .{ .session = sid, .name = p.value('n') orelse "", .argv = l.argv, .program = l.program, .cwd = cwd, .tags = Shim.parkedTags(l) }) catch |e| {
        // The outcome is unknown, but the session was ours and is empty at best.
        _ = s.callRaw("session.remove", .{ .session = sid }) catch {};
        return e;
    };
    switch (reply) {
        .ok => |w| {
            try s.printNew(p, jstr(w, "pane") orelse return s.fail("window.create returned no pane", .{}));
        },
        .err => |e| {
            // Roll back the empty session so a failed new-session leaves nothing.
            _ = s.callRaw("session.remove", .{ .session = sid }) catch {};
            return s.fail("window.create failed: {s}: {s}", .{ e.code, e.message });
        },
    }
}

fn newWindow(s: *Shim, p: *const Parsed) anyerror!void {
    try s.checkNew(p);
    const l = try s.launch(p.rest);
    const sid = try s.sessionTarget(blk: {
        // `-t session` or `-t session:` names the session; a pane or window
        // target names its session too.
        const t = p.value('t') orelse break :blk null;
        break :blk if (std.mem.indexOfScalar(u8, t, ':')) |c| t[0..c] else t;
    });
    const cwd = try s.startDir(p.value('c'));
    const w = try s.call("window.create", .{ .session = sid, .name = p.value('n') orelse "", .argv = l.argv, .program = l.program, .cwd = cwd, .tags = Shim.parkedTags(l) });
    try s.printNew(p, jstr(w, "pane") orelse return s.fail("window.create returned no pane", .{}));
}

fn splitWindow(s: *Shim, p: *const Parsed) anyerror!void {
    try s.checkNew(p);
    if (p.has('h') and p.has('v')) return s.fail("split-window: -h and -v are mutually exclusive", .{});
    var size: ?u32 = null;
    if (p.value('l')) |l| size = percent(l) orelse return s.fail("split-window: -l supports a percentage such as 70% only, got '{s}'", .{l});
    const l = try s.launch(p.rest);
    const target = try s.paneTarget(p.value('t'));
    const axis: []const u8 = if (p.has('h')) "cols" else "rows";
    const cwd = try s.startDir(p.value('c'));
    const r = try s.call("pane.split", .{ .pane = target, .axis = axis, .argv = l.argv, .program = l.program, .cwd = cwd, .tags = Shim.parkedTags(l) });
    const pane = jstr(r, "pane") orelse return s.fail("pane.split returned no pane", .{});
    if (size) |pct| applySize(s, target, pane, axis, pct) catch |e| {
        if (e != error.Failed) return e;
        s.err.print("venomx tmux: warning: -l {d}% could not be applied; the new pane keeps the even split\n", .{pct}) catch {};
    };
    try s.printNew(p, pane);
}

/// The new pane is the second child of a fresh even split. Move the divider
/// so it gets `pct` percent, from the panes' current sizes.
fn applySize(s: *Shim, old: []const u8, new: []const u8, axis: []const u8, pct: u32) !void {
    if (pct == 50) return;
    const cols = eq(u8, axis, "cols");
    const field: []const u8 = if (cols) "cols" else "rows";
    const a_size = jint(try s.call("pane.capture", .{ .pane = old }), field) orelse return error.Failed;
    const b_size = jint(try s.call("pane.capture", .{ .pane = new }), field) orelse return error.Failed;
    const avail = a_size + b_size;
    const even = @divTrunc(avail + 1, 2);
    const first_wanted = @divTrunc(avail * @as(i64, 100 - @as(i64, pct)), 100);
    const delta = first_wanted - even; // negative: the first pane shrinks
    if (delta == 0) return;
    const direction: []const u8 = if (delta < 0) (if (cols) "left" else "up") else (if (cols) "right" else "down");
    const cells: i64 = if (delta < 0) -delta else delta;
    _ = try s.call("pane.resize", .{ .pane = new, .direction = direction, .cells = cells });
}

fn listPanes(s: *Shim, p: *const Parsed) anyerror!void {
    try s.noPositional(p);
    const fmt = p.value('F') orelse return s.fail("list-panes needs -F <format>", .{});
    // A pane target lists its window.
    const window = try s.windowTarget(p.value('t'));
    for (try s.windowPanes(window)) |id| {
        const ctx = try s.windowCtx(window, id);
        try s.out.print("{s}\n", .{try s.expand(fmt, &ctx)});
    }
}

fn listWindows(s: *Shim, p: *const Parsed) anyerror!void {
    try s.noPositional(p);
    const fmt = p.value('F') orelse return s.fail("list-windows needs -F <format>", .{});
    const sid = try s.sessionTarget(blk: {
        const t = p.value('t') orelse break :blk null;
        break :blk if (std.mem.indexOfScalar(u8, t, ':')) |c| t[0..c] else t;
    });
    const sess = try s.sessionGet(sid);
    for ((sess.object.get("windows") orelse return s.fail("session.get returned no windows", .{})).array.items) |w| {
        const ctx = try s.windowCtx(jstr(w, "window").?, null);
        try s.out.print("{s}\n", .{try s.expand(fmt, &ctx)});
    }
}

fn displayMessage(s: *Shim, p: *const Parsed) anyerror!void {
    if (!p.has('p')) return s.fail("display-message without -p would draw on a status line venomx does not have; use -p", .{});
    if (p.rest.len != 1) return s.fail("display-message -p needs exactly one format argument", .{});
    const pane = try s.paneTarget(p.value('t'));
    const ctx = try s.paneCtx(pane);
    try s.out.print("{s}\n", .{try s.expand(p.rest[0], &ctx)});
}

fn killPane(s: *Shim, p: *const Parsed) anyerror!void {
    try s.noPositional(p);
    const t = p.value('t') orelse return s.fail("kill-pane needs -t", .{});
    const pane = try s.paneTarget(t);
    const info = try s.paneInfo(pane);
    const window = jstr(info, "window").?;
    const session = jstr(info, "session").?;
    _ = try s.call("pane.kill", .{ .pane = pane, .remove = true });
    s.refresh();
    // tmux ends a window whose last pane died, and a session whose last
    // window ended; plain removal in venomx leaves them empty.
    if ((try s.windowPanes(window)).len > 0) return;
    _ = try s.call("window.remove", .{ .window = window });
    s.refresh();
    const sess = try s.sessionGet(session);
    if ((sess.object.get("windows") orelse return).array.items.len == 0) _ = try s.call("session.remove", .{ .session = session });
}

fn sendKeys(s: *Shim, p: *const Parsed) anyerror!void {
    const pane = try s.paneTarget(p.value('t'));
    var text: std.ArrayList(u8) = .empty;
    for (p.rest) |arg| {
        if (p.has('l')) {
            try text.appendSlice(s.a, arg);
            continue;
        }
        const bytes = keyBytes(s.a, arg) catch return s.fail("send-keys: unsupported key '{s}' (use -l to type it literally)", .{arg});
        try text.appendSlice(s.a, bytes orelse arg);
    }
    if (text.items.len == 0) return;
    _ = try s.call("pane.send", .{ .pane = pane, .text = text.items });
}

fn capturePane(s: *Shim, p: *const Parsed) anyerror!void {
    try s.noPositional(p);
    if (!p.has('p')) return s.fail("capture-pane without -p would fill a tmux paste buffer venomx does not have; use -p", .{});
    const pane = try s.paneTarget(p.value('t'));
    const keep = p.has('N');
    const screen = try s.call("pane.capture", .{ .pane = pane });
    const rows: i64 = jint(screen, "rows") orelse 0;
    var lines: std.ArrayList([]const u8) = .empty;
    if (p.value('S')) |start| {
        var history: ?i64 = null; // null: all retained history
        if (!eq(u8, start, "-")) {
            const n = std.fmt.parseInt(i64, start, 10) catch return s.fail("capture-pane: -S takes a line number or '-', got '{s}'", .{start});
            if (n > 0) return s.fail("capture-pane: -S {d} would start inside the screen; only 0, a negative line count or '-' are supported", .{n});
            if (n < -max_history) return s.fail("capture-pane: -S {d} is more than the {d} history lines this shim reads; use '-' for all retained history", .{ n, max_history });
            history = -n;
        }
        var first = try s.call("pane.capture_rows", .{ .pane = pane, .tail = if (history) |h| @as(?i64, std.math.add(i64, rows, h) catch return s.fail("capture-pane: -S is out of range", .{})) else null });
        while (true) {
            for ((first.object.get("lines") orelse return s.fail("pane.capture_rows returned no lines", .{})).array.items) |line| {
                if (line == .string) try lines.append(s.a, line.string);
            }
            if (first.object.get("done")) |d| if (d == .bool and d.bool) break;
            const next = jint(first, "next") orelse break;
            const epoch = jint(first, "epoch") orelse break;
            const end = jint(first, "end") orelse break;
            first = try s.call("pane.capture_rows", .{ .pane = pane, .epoch = epoch, .start = next, .end = end });
        }
    } else {
        const text = jstr(screen, "text") orelse return s.fail("pane.capture returned no text", .{});
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| try lines.append(s.a, line);
    }
    for (lines.items) |line| {
        const shown = if (keep) line else std.mem.trimEnd(u8, line, " ");
        try s.out.print("{s}\n", .{shown});
    }
}

fn selectPane(s: *Shim, p: *const Parsed) anyerror!void {
    try s.noPositional(p);
    const title = p.value('T') orelse return s.fail("select-pane only supports -T <title>: venomx has no way to move focus", .{});
    const pane = try s.paneTarget(p.value('t'));
    // The title is a pane tag (1-128 bytes of UTF-8, no controls); an empty
    // title clears it.
    if (title.len == 0) {
        _ = try s.call("pane.tag", .{ .pane = pane, .unset = [_][]const u8{"tmux.title"} });
        return;
    }
    var end = @min(title.len, 128);
    while (end > 0 and end < title.len and (title[end] & 0xc0) == 0x80) end -= 1;
    const clean = try s.a.dupe(u8, title[0..end]);
    for (clean) |*ch| if (ch.* < 0x20 or ch.* == 0x7f) {
        ch.* = ' ';
    };
    if (!std.unicode.utf8ValidateSlice(clean)) return s.fail("select-pane: the title is not valid UTF-8", .{});
    _ = try s.call("pane.tag", .{ .pane = pane, .set = [_]Shim.Tag{.{ .key = "tmux.title", .value = clean }} });
}

fn respawnPane(s: *Shim, p: *const Parsed) anyerror!void {
    if (!p.has('k')) return s.fail("respawn-pane needs -k (venomx cannot restart a pane that already exited)", .{});
    const t = p.value('t') orelse return s.fail("respawn-pane needs -t", .{});
    if (p.rest.len != 1) return s.fail("respawn-pane supports exactly one command argument (a shell command line)", .{});
    const line = p.rest[0];
    for (line) |ch| if ((ch < 0x20 and ch != '\t') or ch == 0x7f) return s.fail("respawn-pane: the command contains a control character", .{});
    if (line.len == 0) return s.fail("respawn-pane: empty command", .{});
    // A canonical-mode PTY truncates lines of 4096 bytes or more.
    if (line.len >= 4000) return s.fail("respawn-pane: the command is {d} bytes; at most 3999 fit one terminal line", .{line.len});
    const text = try std.fmt.allocPrint(s.a, "{s}\n", .{line});
    const lock = try s.lockRespawns();
    defer if (lock >= 0) {
        _ = std.c.flock(lock, std.c.LOCK.UN);
        _ = std.c.close(lock);
    };
    const pane = try s.paneTarget(t);
    s.refresh();
    const info = try s.paneInfo(pane);
    const state = paneTag(info, "tmux.state") orelse "";
    if (!eq(u8, state, "parked")) return s.fail("respawn-pane: venomx cannot replace the process of {s} ({s}); only a pane the shim created with the command `cat` and not yet respawned can be (kill-pane and split-window instead)", .{ t, if (state.len == 0) "not created by this shim" else "already respawned" });
    // Mark first (under the lock): a second respawn of the same pane fails
    // instead of typing its line into the running program. Only a definite
    // error reply from pane.send puts the pane back to parked; if the send
    // may have been accepted (the call itself failed) the state is unknown
    // and stays respawned.
    _ = try s.call("pane.tag", .{ .pane = pane, .set = [_]Shim.Tag{.{ .key = "tmux.state", .value = "respawned" }} });
    const sent = s.callRaw("pane.send", .{ .pane = pane, .text = text }) catch |e| {
        return s.fail("respawn-pane: sending to {s} failed ({s}); whether the command was delivered is unknown, so the pane stays marked respawned (inspect it with capture-pane)", .{ t, @errorName(e) });
    };
    switch (sent) {
        .ok => {},
        .err => |e| {
            _ = s.callRaw("pane.tag", .{ .pane = pane, .set = [_]Shim.Tag{.{ .key = "tmux.state", .value = "parked" }} }) catch {};
            return s.fail("pane.send failed: {s}: {s}", .{ e.code, e.message });
        },
    }
}

// ------------------------------------------------------------ entry

/// Run one tmux invocation (argv without the program name). Returns the
/// process exit status: 0, or 1 for every failure.
pub fn run(a: Allocator, backend: Backend, env: Env, args: []const []const u8, out: *Writer, err: *Writer) u8 {
    var s: Shim = .{ .a = a, .backend = backend, .env = env, .out = out, .err = err };
    dispatch(&s, args) catch |e| {
        if (e != error.Failed) err.print("venomx tmux: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };
    return 0;
}

fn dispatch(s: *Shim, args: []const []const u8) anyerror!void {
    var i: usize = 0;
    // Global options before the command.
    while (i < args.len and args[i].len >= 2 and args[i][0] == '-') : (i += 1) {
        const arg = args[i];
        if (eq(u8, arg, "-V")) return s.out.print("{s}\n", .{version_line});
        if (eq(u8, arg, "-L") or eq(u8, arg, "-S")) {
            if (i + 1 >= args.len) return s.fail("option {s} requires an argument", .{arg});
            i += 1;
            continue;
        }
        return s.fail("unsupported tmux option '{s}' (supported: -V, -L, -S)", .{arg});
    }
    if (i >= args.len) return s.fail("no command given (see `venomx tmux --help`)", .{});
    const name = args[i];
    for (commands) |cmd| if (eq(u8, name, cmd.name) or eq(u8, name, cmd.alias)) {
        s.command = cmd.name;
        var bad: u8 = 0;
        const parsed = parseFlags(args[i + 1 ..], cmd.spec, &bad) catch |e| return switch (e) {
            error.UnknownFlag => s.fail("{s}: unsupported flag -{c}", .{ cmd.name, bad }),
            error.MissingValue => s.fail("{s}: flag -{c} needs a value", .{ cmd.name, bad }),
            error.DuplicateFlag => s.fail("{s}: flag -{c} given twice", .{ cmd.name, bad }),
        };
        return cmd.run(s, &parsed);
    };
    return s.fail("unsupported command '{s}'; this shim implements only what Claude Code's agent teams use (see `venomx tmux --help`)", .{name});
}

/// `venomx tmux ...` or the binary run under the name `tmux`: the arguments
/// after the program word, or null when this is an ordinary venomx call.
pub fn invocation(argv: []const [:0]const u8) ?[]const [:0]const u8 {
    if (argv.len == 0) return null;
    if (eq(u8, std.fs.path.basename(argv[0]), "tmux")) return argv[1..];
    if (argv.len > 1 and eq(u8, argv[1], "tmux")) return argv[2..];
    return null;
}

// ------------------------------------------------------------ daemon backend

/// The real backend: an NDJSON connection with the caller's own credentials.
pub const Daemon = struct {
    client: proto.Client,
    stopped: *const std.atomic.Value(bool),
    next_id: i64 = 1,

    pub fn connect(gpa: Allocator, environ: std.process.Environ, stopped: *const std.atomic.Value(bool)) !Daemon {
        var client = try proto.Client.init(gpa, .{
            .tool = "venomx",
            .path = .{ .socket = null, .environ = environ },
            .protocol = .ndjson,
            .hello = .{ .identity = .{ .name = "venomx-tmux", .version = @import("version.zig").version }, .caps = &.{} },
        });
        errdefer client.deinit();
        while (!try client.pollHello(100)) if (stopped.load(.monotonic)) return error.Interrupted;
        return .{ .client = client, .stopped = stopped };
    }
    pub fn deinit(self: *Daemon) void {
        self.client.deinit();
    }
    pub fn backend(self: *Daemon) Backend {
        return .{ .ptr = self, .callFn = callImpl };
    }
    fn callImpl(ptr: *anyopaque, a: Allocator, verb: []const u8, params_json: []const u8) anyerror!Reply {
        const self: *Daemon = @ptrCast(@alignCast(ptr));
        const params = try std.json.parseFromSliceLeaky(Value, a, params_json, .{});
        const id = self.next_id;
        self.next_id += 1;
        const reply = try standalone.request(a, &self.client, id, verb, params, self.stopped);
        if (standalone.okValue(reply)) |ok| return .{ .ok = ok };
        const e = reply.object.get("error") orelse return error.InvalidResponse;
        return .{ .err = .{ .code = jstr(e, "code") orelse "internal", .message = jstr(e, "message") orelse "" } };
    }
};

// ------------------------------------------------------------ tests

/// A scripted daemon: replies by verb name from a fixed table and records
/// every call.
const Fake = struct {
    a: Allocator,
    replies: []const struct { []const u8, []const u8 },
    calls: std.ArrayList([]const u8) = .empty,
    fn backend(self: *Fake) Backend {
        return .{ .ptr = self, .callFn = call };
    }
    fn call(ptr: *anyopaque, a: Allocator, verb: []const u8, params_json: []const u8) anyerror!Reply {
        const self: *Fake = @ptrCast(@alignCast(ptr));
        try self.calls.append(self.a, try std.fmt.allocPrint(self.a, "{s} {s}", .{ verb, params_json }));
        for (self.replies) |r| if (eq(u8, r[0], verb)) {
            if (eq(u8, r[1], "THROW")) return error.Disconnected;
            if (std.mem.startsWith(u8, r[1], "ERR ")) return .{ .err = .{ .code = r[1][4..], .message = "scripted" } };
            return .{ .ok = try std.json.parseFromSliceLeaky(Value, a, r[1], .{}) };
        };
        return .{ .err = .{ .code = "not_found.verb", .message = verb } };
    }
};

const world = [_]struct { []const u8, []const u8 }{
    .{ "pane.list", "{\"panes\":[{\"pane\":\"p0\",\"window\":\"w0\",\"session\":\"s0\",\"title\":\"t\",\"exited\":false,\"tags\":[],\"pid\":7},{\"pane\":\"p1\",\"window\":\"w0\",\"session\":\"s0\",\"title\":\"\",\"exited\":false,\"tags\":[{\"key\":\"tmux.state\",\"value\":\"parked\"}],\"pid\":8},{\"pane\":\"p2\",\"window\":\"w0\",\"session\":\"s0\",\"title\":\"\",\"exited\":false,\"tags\":[],\"pid\":9}]}" },
    .{ "session.list", "{\"sessions\":[{\"session\":\"s0\",\"name\":\"main\"}]}" },
    .{ "session.get", "{\"session\":\"s0\",\"name\":\"main\",\"windows\":[{\"window\":\"w0\",\"name\":\"work\"}]}" },
    .{ "window.get", "{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"work\",\"nodes\":[{\"kind\":\"split\",\"axis\":\"cols\",\"first\":1,\"second\":2},{\"kind\":\"pane\",\"pane\":\"p0\"},{\"kind\":\"pane\",\"pane\":\"p1\"},{\"kind\":\"pane\",\"pane\":\"p2\"}]}" },
    .{ "pane.split", "{\"pane\":\"p2\",\"window\":\"w0\",\"session\":\"s0\"}" },
    .{ "pane.send", "{\"bytes\":1}" },
    .{ "pane.tag", "{}" },
};

fn exec(arena: Allocator, fake: *Fake, args: []const []const u8, out: *std.Io.Writer.Allocating, err: *std.Io.Writer.Allocating) u8 {
    return run(arena, fake.backend(), .{ .pane = "p0", .cwd = "/work" }, args, &out.writer, &err.writer);
}

test "tmux shim: flag parsing" {
    var bad: u8 = 0;
    const p = try parseFlags(&.{ "-dP", "-F", "#{pane_id}", "-l70%", "--", "cat" }, "dPF:l:", &bad);
    try std.testing.expect(p.has('d') and p.has('P'));
    try std.testing.expectEqualStrings("#{pane_id}", p.value('F').?);
    try std.testing.expectEqualStrings("70%", p.value('l').?);
    try std.testing.expectEqual(@as(usize, 1), p.rest.len);
    const neg = try parseFlags(&.{ "-S", "-50", "-p" }, "pS:", &bad);
    try std.testing.expectEqualStrings("-50", neg.value('S').?);
    try std.testing.expectError(error.UnknownFlag, parseFlags(&.{"-x"}, "p", &bad));
    try std.testing.expectEqual(@as(u8, 'x'), bad);
    try std.testing.expectError(error.MissingValue, parseFlags(&.{"-t"}, "t:", &bad));
    try std.testing.expectError(error.DuplicateFlag, parseFlags(&.{ "-p", "-p" }, "p", &bad));
}

test "tmux shim: keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("\r", (try keyBytes(a, "Enter")).?);
    try std.testing.expectEqualStrings("\x03", (try keyBytes(a, "C-c")).?);
    try std.testing.expectEqualStrings("\x1bx", (try keyBytes(a, "M-x")).?);
    try std.testing.expect((try keyBytes(a, "hello")) == null);
    try std.testing.expectError(error.UnsupportedKey, keyBytes(a, "C-Up"));
}

test "tmux shim: ids and sizes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("%12", try tmuxId(a, "p12"));
    try std.testing.expectEqualStrings("p12", (try venomId(a, "%12", '%', 'p')).?);
    try std.testing.expect((try venomId(a, "%x", '%', 'p')) == null);
    try std.testing.expectEqual(@as(?u32, 70), percent("70%"));
    try std.testing.expectEqual(@as(?u32, null), percent("70"));
    try std.testing.expectEqual(@as(?u32, null), percent("100%"));
}

test "tmux shim: display-message and list-panes formats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .a = a, .replies = &world };
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectEqual(@as(u8, 0), exec(a, &fake, &.{ "display-message", "-p", "#{pane_id} #{window_id} #{session_name}:#{window_name}.#{pane_index}" }, &out, &err));
    try std.testing.expectEqualStrings("%0 @0 main:work.0\n", out.written());
    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), exec(a, &fake, &.{ "list-panes", "-t", "main:work", "-F", "#{pane_id}" }, &out, &err));
    try std.testing.expectEqualStrings("%0\n%1\n%2\n", out.written());
    // Unknown variables and shorthand fail, with a message naming them.
    try std.testing.expectEqual(@as(u8, 1), exec(a, &fake, &.{ "display-message", "-p", "#{pane_flibble}" }, &out, &err));
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "pane_flibble") != null);
    try std.testing.expectEqual(@as(u8, 1), exec(a, &fake, &.{ "display-message", "-p", "#S" }, &out, &err));
}

test "tmux shim: split-window maps to pane.split and cat parks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .a = a, .replies = &world };
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectEqual(@as(u8, 0), exec(a, &fake, &.{ "split-window", "-d", "-t", "%0", "-h", "-P", "-F", "#{pane_id}", "--", "cat" }, &out, &err));
    var saw = false;
    for (fake.calls.items) |c| if (std.mem.startsWith(u8, c, "pane.split ")) {
        saw = true;
        try std.testing.expect(std.mem.indexOf(u8, c, "\"axis\":\"cols\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, c, "\"tmux.state\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, c, "\"cwd\":\"/work\"") != null);
    };
    try std.testing.expect(saw);
}

test "tmux shim: unsupported commands and flags fail before any effect" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .a = a, .replies = &world };
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    const cases = [_][]const []const u8{
        &.{"kill-server"},
        &.{ "split-window", "-b", "-t", "%0" },
        &.{ "select-pane", "-t", "%0" },
        &.{ "select-layout", "-t", "@0", "tiled" },
        &.{ "set-option", "-p", "-t", "%0", "remain-on-exit", "failed" },
        &.{ "send-keys", "-t", "%0", "C-Up" },
        &.{ "capture-pane", "-t", "%0" },
        &.{ "capture-pane", "-p", "-J", "-t", "%0" },
        &.{ "new-session", "-s", "x" },
        &.{ "respawn-pane", "-k", "-t", "%0", "echo hi" },
    };
    for (cases) |c| {
        const before = fake.calls.items.len;
        try std.testing.expectEqual(@as(u8, 1), exec(a, &fake, c, &out, &err));
        for (fake.calls.items[before..]) |call| {
            // Only reads may precede the refusal.
            try std.testing.expect(std.mem.startsWith(u8, call, "pane.list") or std.mem.startsWith(u8, call, "session.") or std.mem.startsWith(u8, call, "window.get"));
        }
    }
}

test "tmux shim: respawn-pane on a parked pane sends one line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .a = a, .replies = &world };
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectEqual(@as(u8, 0), exec(a, &fake, &.{ "respawn-pane", "-k", "-t", "%1", "--", "claude --x" }, &out, &err));
    try std.testing.expect(std.mem.indexOf(u8, fake.calls.items[fake.calls.items.len - 1], "\"text\":\"claude --x\\n\"") != null);
}

test "tmux shim: respawn send failure puts the pane back to parked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const broken = [_]struct { []const u8, []const u8 }{.{ "pane.send", "ERR denied.write" }} ++ world;
    var fake: Fake = .{ .a = a, .replies = &broken };
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectEqual(@as(u8, 1), exec(a, &fake, &.{ "respawn-pane", "-k", "-t", "%1", "--", "claude\t--x" }, &out, &err));
    const last = fake.calls.items[fake.calls.items.len - 1];
    try std.testing.expect(std.mem.startsWith(u8, last, "pane.tag "));
    try std.testing.expect(std.mem.indexOf(u8, last, "\"parked\"") != null);
}

test "tmux shim: no command passes the login program" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .a = a, .replies = &world };
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectEqual(@as(u8, 0), exec(a, &fake, &.{ "split-window", "-t", "%0" }, &out, &err));
    var saw = false;
    for (fake.calls.items) |c| if (std.mem.startsWith(u8, c, "pane.split ")) {
        saw = true;
        try std.testing.expect(std.mem.indexOf(u8, c, "\"argv\":[\"-sh\"]") != null);
        try std.testing.expect(std.mem.indexOf(u8, c, "\"program\":\"/bin/sh\"") != null);
    };
    try std.testing.expect(saw);
}

test "tmux shim: a bad -F creates nothing; capture -S is bounded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var fake: Fake = .{ .a = a, .replies = &world };
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    const bad = [_][]const []const u8{
        &.{ "split-window", "-P", "-F", "#{nope}", "-t", "%0" },
        &.{ "new-window", "-P", "-F", "#S", "-t", "main" },
        &.{ "new-session", "-d", "-s", "x", "-P", "-F", "#{nope}" },
        &.{ "capture-pane", "-p", "-S", "-9223372036854775808", "-t", "%0" },
        &.{ "capture-pane", "-p", "-S", "-9223372036854775807", "-t", "%0" },
        &.{ "capture-pane", "-p", "-S", "-99999999999999999999", "-t", "%0" },
    };
    for (bad) |c| {
        try std.testing.expectEqual(@as(u8, 1), exec(a, &fake, c, &out, &err));
    }
    for (fake.calls.items) |c| {
        try std.testing.expect(!std.mem.startsWith(u8, c, "pane.split") and !std.mem.startsWith(u8, c, "window.create") and !std.mem.startsWith(u8, c, "session.create") and !std.mem.startsWith(u8, c, "pane.capture_rows"));
    }
}

test "tmux shim: a thrown send keeps respawned; long lines are refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const broken = [_]struct { []const u8, []const u8 }{.{ "pane.send", "THROW" }} ++ world;
    var fake: Fake = .{ .a = a, .replies = &broken };
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectEqual(@as(u8, 1), exec(a, &fake, &.{ "respawn-pane", "-k", "-t", "%1", "--", "claude" }, &out, &err));
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "unknown") != null);
    for (fake.calls.items) |c| try std.testing.expect(std.mem.indexOf(u8, c, "\"parked\"") == null);
    const long = try a.alloc(u8, 4000);
    @memset(long, 'x');
    const before = fake.calls.items.len;
    try std.testing.expectEqual(@as(u8, 1), exec(a, &fake, &.{ "respawn-pane", "-k", "-t", "%1", "--", long }, &out, &err));
    try std.testing.expectEqual(before, fake.calls.items.len);
}

test "tmux shim: new-session removes its session when window.create throws" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const broken = [_]struct { []const u8, []const u8 }{ .{ "window.create", "THROW" }, .{ "session.create", "{\"session\":\"s9\",\"name\":\"x\"}" } } ++ world;
    var fake: Fake = .{ .a = a, .replies = &broken };
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    try std.testing.expectEqual(@as(u8, 1), exec(a, &fake, &.{ "new-session", "-d", "-s", "x" }, &out, &err));
    try std.testing.expect(std.mem.startsWith(u8, fake.calls.items[fake.calls.items.len - 1], "session.remove {\"session\":\"s9\"}"));
}

fn lockedExec(a: Allocator, fake: *Fake, path: [:0]const u8, out: *std.Io.Writer.Allocating, err: *std.Io.Writer.Allocating) u8 {
    return run(a, fake.backend(), .{ .pane = "p0", .cwd = "/work", .lock_path = path, .lock_wait_ms = 100 }, &.{ "respawn-pane", "-k", "-t", "%1", "--", "claude" }, &out.writer, &err.writer);
}

test "tmux shim: the respawn lock is 0600, released, and fails closed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrintSentinel(a, "/tmp/vx-tmux-lock-{d}", .{std.c.getpid()}, 0);
    defer _ = std.c.unlink(path);
    var out: std.Io.Writer.Allocating = .init(a);
    var err: std.Io.Writer.Allocating = .init(a);
    // Success: the lock file is private and free afterwards.
    var fake: Fake = .{ .a = a, .replies = &world };
    try std.testing.expectEqual(@as(u8, 0), lockedExec(a, &fake, path, &out, &err));
    const st = @import("os.zig").stat(path) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 0o600), st.mode & 0o777);
    const probe = std.c.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
    try std.testing.expect(probe >= 0);
    defer _ = std.c.close(probe);
    try std.testing.expectEqual(@as(c_int, 0), std.c.flock(probe, std.c.LOCK.EX | std.c.LOCK.NB));
    _ = std.c.flock(probe, std.c.LOCK.UN);
    // A failed send releases it too.
    const broken = [_]struct { []const u8, []const u8 }{.{ "pane.send", "ERR denied.write" }} ++ world;
    var bad: Fake = .{ .a = a, .replies = &broken };
    try std.testing.expectEqual(@as(u8, 1), lockedExec(a, &bad, path, &out, &err));
    try std.testing.expectEqual(@as(c_int, 0), std.c.flock(probe, std.c.LOCK.EX | std.c.LOCK.NB));
    // Held by someone else: fail before any tag change.
    var held: Fake = .{ .a = a, .replies = &world };
    try std.testing.expectEqual(@as(u8, 1), lockedExec(a, &held, path, &out, &err));
    for (held.calls.items) |c| try std.testing.expect(!std.mem.startsWith(u8, c, "pane.tag") and !std.mem.startsWith(u8, c, "pane.send"));
    try std.testing.expect(std.mem.indexOf(u8, err.written(), "holds the lock") != null);
    _ = std.c.flock(probe, std.c.LOCK.UN);
    // An unopenable lock path fails closed too.
    var none: Fake = .{ .a = a, .replies = &world };
    try std.testing.expectEqual(@as(u8, 1), lockedExec(a, &none, "/nonexistent-dir/lock", &out, &err));
    for (none.calls.items) |c| try std.testing.expect(!std.mem.startsWith(u8, c, "pane.tag"));
}

test "tmux shim: invocation" {
    const argv = [_][:0]const u8{ "/usr/bin/tmux", "ls" };
    try std.testing.expectEqual(@as(usize, 1), invocation(&argv).?.len);
    const v = [_][:0]const u8{ "venomx", "tmux", "-V" };
    try std.testing.expectEqual(@as(usize, 1), invocation(&v).?.len);
    const other = [_][:0]const u8{ "venomx", "ping" };
    try std.testing.expect(invocation(&other) == null);
}
