//! Status conformance cases: status rules, exec sources and the
//! owner-only exec config, against a real `Product` and dispatcher (the
//! harness of chrome_tests.zig). Exec sources run real processes.
const std = @import("std");
const proto = @import("proto");
const cfg = @import("cfg");
const g = proto.grants;
const manifest = @import("manifest.zig");
const chrome = @import("chrome.zig");
const rules = @import("status_rules.zig");
const exec = @import("status_exec.zig");
const harness = @import("chrome_tests.zig");
const Daemon = harness.Daemon;
const a = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const Value = std.json.Value;

test {
    _ = @import("status_exec.zig");
    _ = @import("status_rules.zig");
}

/// One reactor turn as the daemon runs it: reap, sources, expiry.
fn turn(d: *Daemon) !void {
    try d.product.supervise();
    try chrome.tickSources(&d.product);
    chrome.tick(&d.product);
}
/// Lets the next firing of `id` apply without waiting for coalescing.
fn uncoalesce(d: *Daemon, id: []const u8) void {
    d.product.chrome.rules.get(id).?.last_fire = std.math.minInt(i64);
}
fn finished(d: *Daemon, pane: []const u8, command: []const u8, exit_code: ?u8) !void {
    var buf: [32]u8 = undefined;
    try d.events.append(try std.fmt.bufPrint(&buf, "pane:{s}", .{pane}), "command.finished", .{ .pane = pane, .command = command, .reason = "exit", .exit_code = exit_code });
}
fn started(d: *Daemon, pane: []const u8, command: []const u8) !void {
    var buf: [32]u8 = undefined;
    try d.events.append(try std.fmt.bufPrint(&buf, "pane:{s}", .{pane}), "command.started", .{ .pane = pane, .command = command });
}
fn text(d: *Daemon, id: []const u8) ?[]const u8 {
    return if (d.product.chrome.segment(id)) |s| s.text else null;
}
fn lastEvent(d: *Daemon) []const u8 {
    return d.events.entries.items[d.events.entries.items.len - 1].bytes;
}
/// Whether any retained event of `kind` contains `needle`.
fn logged(d: *Daemon, kind: []const u8, needle: []const u8) bool {
    for (d.events.entries.items[d.events.head..]) |e| {
        if (std.mem.eql(u8, e.type, kind) and std.mem.indexOf(u8, e.bytes, needle) != null) return true;
    }
    return false;
}
fn sleepMs(ms: u32) void {
    const pause: std.c.timespec = .{ .sec = 0, .nsec = @as(isize, ms) * 1_000_000 };
    _ = std.c.nanosleep(&pause, null);
}
/// Runs turns until `cond(d)` holds, for at most five seconds.
fn until(d: *Daemon, comptime cond: fn (*Daemon) bool) !void {
    for (0..1000) |_| {
        try turn(d);
        if (cond(d)) return;
        sleepMs(5);
    }
    return error.Timeout;
}

test "a rule on command.finished with exit_code ne 0 fires on false, not on true; it clears on its clear_on event and when ttl_ms runs out" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    try d.ok(&d.owner, "status.rule.set",
        \\{"id":"user.failed","on":["command.finished"],"match":[{"key":"exit_code","op":"ne","value":"0"}],"clear_on":["command.started"],"format":"{event.command} {event.exit_code}","style":"error","ttl_ms":5000,"bind":"daemon"}
    );
    try expect(logged(d, "status.rule_changed", "\"id\":\"user.failed\""));
    try finished(d, "p0", "true", 0);
    try turn(d);
    try expect(text(d, "user.failed") == null);
    try finished(d, "p0", "false", 1);
    try turn(d);
    try expectEqualStrings("false 1", text(d, "user.failed").?);
    try expectEqual(chrome.Style.@"error", d.product.chrome.segment("user.failed").?.style);
    try expect(std.mem.indexOf(u8, lastEvent(d), "status.changed") != null);
    // A command starting in another pane is not the resource that fired it.
    try started(d, "p1", "ls");
    try turn(d);
    try expect(text(d, "user.failed") != null);
    try started(d, "p0", "make");
    try turn(d);
    try expect(text(d, "user.failed") == null);
    try expect(std.mem.indexOf(u8, lastEvent(d), "\"reason\":\"rule\"") != null);
    // Fired again, it goes when ttl_ms runs out; the rule stays.
    uncoalesce(d, "user.failed");
    try finished(d, "p2", "cargo", 101);
    try turn(d);
    try expectEqualStrings("cargo 101", text(d, "user.failed").?);
    d.product.chrome.segment("user.failed").?.expires = 0;
    chrome.tick(&d.product);
    try expect(text(d, "user.failed") == null);
    try expect(std.mem.indexOf(u8, lastEvent(d), "\"reason\":\"ttl\"") != null);
    try expect(d.product.chrome.rules.get("user.failed") != null);
    // A missing field equals no value: .ne holds.
    uncoalesce(d, "user.failed");
    try finished(d, "p1", "kill", null);
    try turn(d);
    try expectEqualStrings("kill ", text(d, "user.failed").?);
    // Firings are coalesced: a second one inside 100 ms waits its turn.
    try finished(d, "p1", "again", 2);
    try turn(d);
    try expectEqualStrings("kill ", text(d, "user.failed").?);
    try expect(d.product.chrome.rules.get("user.failed").?.pending != null);
    uncoalesce(d, "user.failed");
    try turn(d);
    try expectEqualStrings("again 2", text(d, "user.failed").?);
    // The rule's checks.
    try expectEqualStrings("invalid_params.rule", try code(d, &d.owner, "status.rule.set", "{\"id\":\"user.x\",\"on\":[\"command.finished\"],\"format\":\"x\"}"));
    try expectEqualStrings("invalid_params.rule", try code(d, &d.owner, "status.rule.set", "{\"id\":\"user.x\",\"on\":[],\"format\":\"x\",\"ttl_ms\":1000}"));
    try expectEqualStrings("invalid_params.template", try code(d, &d.owner, "status.rule.set", "{\"id\":\"user.x\",\"on\":[\"command.*\"],\"format\":\"{nope}\",\"ttl_ms\":1000}"));
    try expectEqualStrings("invalid_params.segment", try code(d, &d.owner, "status.rule.set", "{\"id\":\"user.x\",\"on\":[\"command.*\"],\"format\":\"x\",\"ttl_ms\":1000,\"icon\":\"too wide\"}"));
    try expectEqualStrings("not_found.rule", try code(d, &d.owner, "status.rule.clear", "{\"id\":\"user.x\"}"));
    // status.rule.list, then status.rule.clear removes the rule and its segment.
    var listed = try d.call(&d.owner, "status.rule.list", "{}");
    defer listed.deinit();
    try expectEqual(@as(usize, 1), listed.value.object.get("ok").?.object.get("rules").?.array.items.len);
    try d.ok(&d.owner, "status.rule.clear", "{\"id\":\"user.failed\"}");
    try expect(d.product.chrome.rules.get("user.failed") == null);
    try expect(text(d, "user.failed") == null);
    try expect(logged(d, "status.rule_cleared", "\"reason\":\"clear\""));
}

fn code(d: *Daemon, conn: *proto.Connection, verb: []const u8, params: []const u8) ![]const u8 {
    var r = try d.call(conn, verb, params);
    defer r.deinit();
    const e = r.value.object.get("error") orelse return "ok";
    const c = e.object.get("code").?.string;
    inline for (.{ "invalid_params.rule", "invalid_params.template", "invalid_params.segment", "conflict.rule_limit", "conflict.config_rule", "not_found.rule", "denied.namespace", "denied.write", "denied.owner" }) |known| if (std.mem.eql(u8, c, known)) return known;
    std.debug.print("unexpected {s}\n", .{c});
    return "other";
}

test "a rule set by a principal with read on session s0 only never fires on an event from session s1" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    try d.ok(&d.owner, "session.create", "{\"name\":\"other\"}");
    try d.ok(&d.owner, "window.create", "{\"session\":\"s1\",\"argv\":[\"true\"]}");
    try expect(d.product.pane("p3") != null);
    const s0_only = try d.principal(&.{ .{ .right = .read, .scope = "session:s0" }, .{ .right = .write, .scope = "session:s0" } }, "venom");
    var conn = d.connection(s0_only);
    defer conn.deinit();
    // scope=server needs write on server:root, which it doesn't hold.
    try expectEqualStrings("denied.write", try code(d, &conn, "status.rule.set", "{\"id\":\"venom.done\",\"on\":[\"command.finished\"],\"format\":\"{event.pane}\",\"ttl_ms\":60000}"));
    try d.ok(&conn, "status.rule.set", "{\"id\":\"venom.done\",\"on\":[\"command.finished\"],\"format\":\"{event.pane} {event.command}\",\"ttl_ms\":60000,\"scope\":\"s0\"}");
    try finished(d, "p3", "secret-build", 1);
    try turn(d);
    try expect(text(d, "venom.done") == null);
    const rule = d.product.chrome.rules.get("venom.done").?;
    try expectEqual(@as(u64, 1), rule.withheld);
    try expectEqual(@as(u64, 0), rule.fired);
    // The same event in s0 fires it, in session s0.
    try finished(d, "p0", "make", 0);
    try turn(d);
    try expectEqualStrings("p0 make", text(d, "venom.done").?);
    try expectEqualStrings("s0", d.product.chrome.segment("venom.done").?.scope);
    // scope=event puts the segment in the event's session.
    try d.ok(&d.owner, "status.rule.set", "{\"id\":\"user.where\",\"on\":[\"command.finished\"],\"format\":\"{event.pane}\",\"ttl_ms\":60000,\"scope\":\"event\",\"bind\":\"daemon\"}");
    try finished(d, "p3", "x", 0);
    try turn(d);
    try expectEqualStrings("s1", d.product.chrome.segment("user.where").?.scope);
}

test "a bind = connection rule and its segment go when the connection closes" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    const venom = try d.principal(&.{ .{ .right = .write, .scope = "server:root" }, .{ .right = .read, .scope = "*" } }, "venom");
    var conn = d.connection(venom);
    try d.ok(&conn, "status.rule.set", "{\"id\":\"venom.waiting\",\"on\":[\"command.finished\"],\"format\":\"▲ {event.command}\",\"ttl_ms\":60000}");
    try d.ok(&conn, "status.rule.set", "{\"id\":\"venom.kept\",\"on\":[\"command.finished\"],\"format\":\"kept\",\"ttl_ms\":60000,\"bind\":\"daemon\"}");
    // Only its own namespace, and never another product's.
    try expectEqualStrings("denied.namespace", try code(d, &conn, "status.rule.set", "{\"id\":\"user.x\",\"on\":[\"command.finished\"],\"format\":\"x\",\"ttl_ms\":1000}"));
    try finished(d, "p0", "agent", 0);
    try turn(d);
    try expectEqualStrings("▲ agent", text(d, "venom.waiting").?);
    try expectEqualStrings("kept", text(d, "venom.kept").?);
    d.server.closed(&conn);
    conn.deinit();
    try expect(d.product.chrome.rules.get("venom.waiting") == null);
    try expect(text(d, "venom.waiting") == null);
    try expect(logged(d, "status.rule_cleared", "\"reason\":\"disconnect\""));
    try expect(logged(d, "status.cleared", "\"reason\":\"disconnect\""));
    try expect(d.product.chrome.rules.get("venom.kept") != null);
    try expectEqualStrings("kept", text(d, "venom.kept").?);
    // Revoking its principal takes a daemon-bound rule with it.
    try d.registry.revoke(.{ .principal = g.owner }, venom, g.nowSeconds());
    try turn(d);
    try expect(d.product.chrome.rules.get("venom.kept") == null);
    try expect(logged(d, "status.rule_cleared", "\"reason\":\"revoked\""));
}

test "an interval exec source updates its text and keeps it after a failing run; a stream source updates line by line, restarts after it exits, and its child has no VENOMX_TOKEN" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(home);
    const home_var = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{home}, 0);
    defer a.free(home_var);
    const env = [_:null]?[*:0]const u8{ home_var, "PATH=/usr/bin:/bin", "VENOMX_TOKEN=vnt1.venomx.g7.abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ", "GITHUB_TOKEN=ghp_secret", "NOTE=keep" };
    const d = try Daemon.create();
    defer d.destroy();
    d.product.environ = .{ .block = .{ .slice = &env } };
    // Interval: run 2 fails. The cwd is $HOME, where the counter lives.
    const interval = "n=$(cat count 2>/dev/null || echo 0); n=$((n+1)); echo $n > count; echo noise; echo \"run $n\"; [ \"$n\" -ne 2 ]";
    // Stream: two lines 300 ms apart, then a clean exit.
    const stream = "echo \"${VENOMX_TOKEN:-none} ${GITHUB_TOKEN:-none} $VENOMX_SEGMENT $NOTE\"; sleep 0.3; echo '{\"text\":\"second\",\"style\":\"ok\"}'";
    const entries = [_]chrome.SegmentEntry{
        .{ .id = "user.iv", .exec = .{ .argv = &.{ "sh", "-c", interval }, .every_ms = 1000 } },
        .{ .id = "user.st", .exec = .{ .argv = &.{ "/bin/sh", "-c", stream } }, .group = "tray" },
    };
    try chrome.configure(&d.product, .{ .segments = &entries });
    try expectEqual(@as(usize, 2), d.product.chrome.exec.items.items.len);
    const iv = d.product.chrome.exec.items.items[0];
    const st = d.product.chrome.exec.items.items[1];
    const conds = struct {
        fn run1(x: *Daemon) bool {
            return if (text(x, "user.iv")) |t| std.mem.eql(u8, t, "run 1") else false;
        }
        fn run2done(x: *Daemon) bool {
            const s = x.product.chrome.exec.items.items[0];
            return s.runs == 2 and s.leader == null;
        }
        fn run3(x: *Daemon) bool {
            return if (text(x, "user.iv")) |t| std.mem.eql(u8, t, "run 3") else false;
        }
        fn first(x: *Daemon) bool {
            return text(x, "user.st") != null;
        }
        fn gone(x: *Daemon) bool {
            return text(x, "user.st") == null and x.product.chrome.exec.items.items[1].leader == null;
        }
        fn reslotted(x: *Daemon) bool {
            return x.product.chrome.segment("user.iv").?.priority == 90;
        }
        fn restarted(x: *Daemon) bool {
            const s = x.product.chrome.exec.items.items[1];
            return s.runs == 2 and text(x, "user.st") != null;
        }
    };
    try until(d, conds.run1);
    try until(d, conds.first);
    // The child's environment: no venomx token, no other token, its segment id.
    try expectEqualStrings("none none user.st keep", text(d, "user.st").?);
    try expectEqualStrings("tray", d.product.chrome.segment("user.st").?.group.?);
    // Stream mode: each line replaces the text (a JSON line sets the style
    // too); the exit clears the segment, and a restart is scheduled.
    try until(d, conds.gone);
    try expect(logged(d, "status.changed", "\"text\":\"second\",\"side\":\"right\",\"priority\":50,\"style\":\"ok\""));
    try expect(logged(d, "status.cleared", "\"reason\":\"exec\""));
    try expect(st.next_ms > chrome.nowMs());
    st.next_ms = 0;
    try until(d, conds.restarted);
    // Interval: the next run fails; the old text stays and doctor sees it.
    iv.next_ms = 0;
    try until(d, conds.run2done);
    try expectEqualStrings("run 1", text(d, "user.iv").?);
    try expectEqual(exec.Failure{ .exit = 1 }, iv.last_failure.?);
    try expectEqual(@as(usize, 1), exec.failing(&d.product));
    iv.next_ms = 0;
    try until(d, conds.run3);
    try expect(iv.last_failure == null);
    // A slot-only change keeps the run and republishes; a new argv restarts.
    const reslotted = [_]chrome.SegmentEntry{
        .{ .id = "user.iv", .exec = .{ .argv = &.{ "sh", "-c", interval }, .every_ms = 1000 }, .priority = 90 },
        entries[1],
    };
    const runs = iv.runs;
    try chrome.configure(&d.product, .{ .segments = &reslotted });
    try expect(d.product.chrome.exec.items.items[0] == iv);
    try expectEqual(runs, iv.runs);
    try until(d, conds.reslotted);
    try expectEqualStrings("run 3", text(d, "user.iv").?);
    // Removing an entry stops its source and clears its segment.
    try chrome.configure(&d.product, .{ .segments = entries[0..1] });
    try expectEqual(@as(usize, 1), d.product.chrome.exec.items.items.len);
    try expect(text(d, "user.st") == null);
    try chrome.configure(&d.product, .{});
    try expect(text(d, "user.iv") == null);
    // Let the stopped runs be reaped.
    for (0..400) |_| {
        try turn(d);
        if (d.product.discarded.items.len == 0) break;
        sleepMs(5);
    }
}

const StatusOnly = struct { status: chrome.StatusConfig = .{} };
const StatusStore = cfg.Store(StatusOnly, &.{});
fn validateStatus(c: StatusOnly) ?cfg.Validation {
    if (chrome.statusFailure(c.status)) |failure| return .{ .key = "status", .code = failure };
    if (c.status.segmentsFailure()) |failure| return .{ .key = "status.segments", .code = failure };
    return null;
}

test "config set of an exec entry by a non-owner principal is denied" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const user = try std.fs.path.join(a, &.{ base, "config.zon" });
    defer a.free(user);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data =
        \\.{ .status = .{ .segments = .{ .{ .id = "user.bat", .exec = .{ .argv = .{ "battery" }, .every_ms = 30000 }, .group = "tray" } } } }
    });
    var store = try StatusStore.init(a, .{ .io = std.testing.io, .path = user, .validate = validateStatus });
    defer store.deinit();
    const d = try Daemon.create();
    defer d.destroy();
    const Guard = exec.ExecGuard(StatusStore, StatusOnly);
    var guard: Guard = .{ .store = &store };
    var config_bindings = store.bindings();
    for (&config_bindings) |*b| if (std.mem.eql(u8, b.verb, "config.set")) {
        b.handler = proto.VerbHandler.init(&guard);
    };
    const schema = comptime cfg.mergeWith(manifest.core_model, .{ .errors = &chrome.config_errors });
    const bindings = d.product.bindings() ++ .{proto.Binding{ .verb = "events", .handler = proto.VerbHandler.init(&d.events) }} ++ config_bindings;
    var dispatcher = try proto.Dispatcher.init(a, &schema, &bindings, .{}, null);
    defer dispatcher.deinit();
    const set = struct {
        fn f(disp: *proto.Dispatcher, conn: *proto.Connection, key: []const u8, value: []const u8) ![]const u8 {
            conn.output.clearRetainingCapacity();
            conn.sent = 0;
            var line: std.ArrayList(u8) = .empty;
            defer line.deinit(a);
            try line.print(a, "{{\"id\":1,\"verb\":\"config.set\",\"params\":{f}}}", .{std.json.fmt(.{ .key = key, .value = value }, .{})});
            try disp.message(conn, .{ .ndjson = line.items });
            const r = try std.json.parseFromSlice(Value, a, std.mem.trimEnd(u8, conn.output.items, "\n"), .{});
            defer r.deinit();
            const e = r.value.object.get("error") orelse return "ok";
            const c = e.object.get("code").?.string;
            inline for (.{ "denied.owner", "denied.admin", "invalid_params.segment", "invalid_params.template" }) |known| if (std.mem.eql(u8, c, known)) return known;
            std.debug.print("unexpected {s}: {s}\n", .{ c, conn.output.items });
            return "other";
        }
    }.f;
    // A principal the owner granted admin, so it may use config.set at all.
    var admin = d.connection(try d.principal(&.{ .{ .right = .admin, .scope = "*" }, .{ .right = .read, .scope = "*" } }, null));
    defer admin.deinit();
    const changed = ".{ .{ .id = \"user.bat\", .exec = .{ .argv = .{ \"curl\", \"evil\" }, .every_ms = 30000 }, .group = \"tray\" } }";
    const same_plus_static = ".{ .{ .id = \"user.bat\", .exec = .{ .argv = .{ \"battery\" }, .every_ms = 30000 }, .group = \"tray\" }, .{ .id = \"user.host\", .text = \"devbox\" } }";
    try expectEqualStrings("denied.owner", try set(&dispatcher, &admin, "status.segments", changed));
    try expectEqualStrings("denied.owner", try set(&dispatcher, &admin, "status.segments", ".{}"));
    try expectEqualStrings("denied.owner", try set(&dispatcher, &admin, "status", ".{ .position = .bottom }"));
    try expectEqualStrings("denied.owner", try set(&dispatcher, &admin, "", ".{}"));
    // Changes that leave the exec entries alone are the store's to judge.
    try expectEqualStrings("ok", try set(&dispatcher, &admin, "status.position", ".bottom"));
    try expectEqualStrings("ok", try set(&dispatcher, &admin, "status.segments", same_plus_static));
    // The file is unchanged by the denied sets: the exec entry is the original.
    const persisted = try tmp.dir.readFileAlloc(std.testing.io, "config.zon", a, .limited(4096));
    defer a.free(persisted);
    try expect(std.mem.indexOf(u8, persisted, "evil") == null);
    try expect(std.mem.indexOf(u8, persisted, "battery") != null);
    // The owner may change it; an invalid exec entry fails the store's check.
    try expectEqualStrings("ok", try set(&dispatcher, &d.owner, "status.segments", changed));
    try expectEqualStrings("invalid_params.segment", try set(&dispatcher, &d.owner, "status.segments", ".{ .{ .id = \"venom.x\", .exec = .{ .argv = .{ \"x\" } } } }"));
    try expectEqualStrings("invalid_params.template", try set(&dispatcher, &d.owner, "status.segments", ".{ .{ .id = \"user.r\", .rule = .{ .on = .{ \"command.finished\" } }, .format = \"{nope}\", .ttl_ms = 1000 } }"));
}
