//! Status line conformance cases: the status line's layout
//! lists, built-in templates, the tray, clicks, removed keys and the
//! centre, drawn by real attach clients (the harness of
//! chrome_tests.zig).
const std = @import("std");
const proto = @import("proto");
const cfg = @import("cfg");
const g = proto.grants;
const chrome = @import("chrome.zig");
const ac = @import("attach_chrome.zig");
const App = @import("attach_app.zig").App;
const harness = @import("chrome_tests.zig");
const Daemon = harness.Daemon;
const Client = harness.Client;
const a = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const lone_window = "{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w0\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p0\"}]}}}";

/// A `status.changed` event for a pushed segment, as the daemon sends it.
fn segmentEvent(buf: []u8, id: []const u8, text: []const u8, extra: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"id\":2,\"item\":{{\"type\":\"status.changed\",\"data\":{{\"id\":\"{s}\",\"revision\":1,\"segment\":{{\"id\":\"{s}\",\"text\":\"{s}\",\"side\":\"right\",\"priority\":50,\"style\":\"normal\",\"when\":[],\"scope\":\"server\",\"bind\":\"connection\",\"revision\":1{s}}}}}}}}}", .{ id, id, text, extra });
}
fn clearedEvent(buf: []u8, id: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{{\"id\":2,\"item\":{{\"type\":\"status.cleared\",\"data\":{{\"id\":\"{s}\",\"reason\":\"clear\"}}}}}}", .{id});
}
fn has(line: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, line, needle) != null;
}
/// Applies `content` as the client's `status` config, as `config.get` does.
fn configure(c: *Client, content: []const u8) !void {
    try c.app.shared.applyConfig("status", content);
    c.app.dirty = true;
}
/// The client's placed status items, for positions.
fn placed(c: *Client, arena: std.mem.Allocator) ![]const ac.Placed {
    const items = try c.app.statusItems(arena);
    return ac.layout(arena, items, c.app.cols);
}
fn find(list: []const ac.Placed, id: []const u8) ?ac.Placed {
    for (list) |p| if (std.mem.eql(u8, p.id, id)) return p;
    return null;
}

test "with the default config the line is the default status line" {
    var c = try Client.init(80, 6);
    defer c.deinit();
    try c.app.control(lone_window);
    const before = try c.status();
    defer a.free(before);
    try expect(std.mem.startsWith(u8, before, " s0 ◤  ▸1"));
    // The built-in defaults spelled out change nothing.
    try configure(&c, ".{ .position = .top, .left = .{ \"venomx.session\", \"venomx.nested\", \"venomx.mode\", \"venomx.windows\", \"venomx.panes\", \"venomx.pane\" }, .right = .{ \"venomx.message\", \"venomx.notify\", \"venomx.tray\", \"venomx.attention\", \"venomx.clock\" } }");
    const after = try c.status();
    defer a.free(after);
    try expectEqualStrings(before, after);
    try expect(has(after, "14:02"));
}

test ".left without venomx.windows and .unlisted = .hide hides the windows; a new .left moves segments live" {
    var c = try Client.init(80, 6);
    defer c.deinit();
    try c.app.control(lone_window);
    var buf: [512]u8 = undefined;
    try c.app.control(try segmentEvent(&buf, "venom.agents", "agents", ""));
    try configure(&c, ".{ .left = .{ \"venomx.session\" }, .right = .{ \"venomx.clock\" }, .unlisted = .hide }");
    {
        const line = try c.status();
        defer a.free(line);
        try expect(has(line, " s0 "));
        try expect(!has(line, "▸1"));
        try expect(!has(line, "agents"));
        try expect(has(line, "14:02"));
    }
    // A config change (what `config set` and the reload send) moves the
    // windows first and shows them, with no restart.
    try configure(&c, ".{ .left = .{ \"venomx.windows\", \"venomx.session\" }, .right = .{ \"venom.agents\" }, .unlisted = .hide }");
    {
        const line = try c.status();
        defer a.free(line);
        const windows = std.mem.indexOf(u8, line, "▸1").?;
        const session = std.mem.indexOf(u8, line, " s0 ").?;
        try expect(windows < session);
        try expect(has(line, "agents"));
        try expect(!has(line, "14:02"));
    }
}

test "venomx.panes with .panes = .focused and {pane.id} shows the focused pane's ID on that client only" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var one = try Client.init(80, 24);
    defer one.deinit();
    var two = try Client.init(80, 24);
    defer two.deinit();
    try one.sync(d);
    try two.sync(d);
    const config = ".{ .segments = .{ .{ .id = \"venomx.panes\", .panes = .focused, .format = \"<{pane.id}>\" } } }";
    try configure(&one, config);
    try configure(&two, config);
    const focus = one.app.focus.?;
    const want = try std.fmt.allocPrint(a, "<{s}>", .{focus});
    defer a.free(want);
    {
        const line = try one.status();
        defer a.free(line);
        try expect(has(line, want));
        // Only the focused pane is listed.
        try expect(!has(line, "<p1>") or std.mem.eql(u8, focus, "p1"));
    }
    try one.app.run(.{ .local = .focus_next });
    const moved = try std.fmt.allocPrint(a, "<{s}>", .{one.app.focus.?});
    defer a.free(moved);
    try expect(!std.mem.eql(u8, moved, want));
    const l1 = try one.status();
    defer a.free(l1);
    try expect(has(l1, moved));
    try expect(!has(l1, want));
    const l2 = try two.status();
    defer a.free(l2);
    try expect(has(l2, want));
}

test "{pane.tag.branch|-} shows - and then main after pane.tag sets it" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var c = try Client.init(80, 24);
    defer c.deinit();
    try c.sync(d);
    try configure(&c, ".{ .segments = .{ .{ .id = \"venomx.pane\", .format = \"branch:{pane.tag.branch|-}\" } } }");
    {
        const line = try c.status();
        defer a.free(line);
        try expect(has(line, "branch:-"));
    }
    var buf: [128]u8 = undefined;
    try d.ok(&d.owner, "pane.tag", try std.fmt.bufPrint(&buf, "{{\"pane\":\"{s}\",\"set\":[{{\"key\":\"branch\",\"value\":\"main\"}}]}}", .{c.app.focus.?}));
    try c.sync(d);
    const line = try c.status();
    defer a.free(line);
    try expect(has(line, "branch:main"));
    // An empty template means the fixed notes again.
    try configure(&c, ".{ .segments = .{ .{ .id = \"venomx.pane\", .format = \"\" } } }");
    const plain = try c.status();
    defer a.free(plain);
    try expect(!has(plain, "branch:"));
}

test "[ › {pane.process}] drops the whole bracket when the process is empty" {
    var c = try Client.init(80, 6);
    defer c.deinit();
    try c.app.control(lone_window);
    try configure(&c, ".{ .segments = .{ .{ .id = \"user.where\", .format = \"at[ › {pane.process}][ #{pane.id}]\", .side = .left } } }");
    const line = try c.status();
    defer a.free(line);
    try expect(has(line, "at #p0"));
    try expect(!has(line, "›  "));
    try expect(!has(line, "at ›"));
}

test "an unknown variable fails config check with invalid_params.template; layout and source errors too" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const x = arena.allocator();
    const parse = struct {
        fn f(al: std.mem.Allocator, text: [:0]const u8) !chrome.StatusConfig {
            var diagnostics: std.zon.parse.Diagnostics = undefined;
            return std.zon.parse.fromSlice(chrome.StatusConfig, .{ .gpa = al, .arena = al, .source = text, .diagnostics = &diagnostics });
        }
    }.f;
    try expectEqualStrings("invalid_params.template", chrome.statusFailure(try parse(x, ".{ .segments = .{ .{ .id = \"user.x\", .format = \"{nope}\" } } }")).?);
    try expectEqualStrings("invalid_params.status_layout", chrome.statusFailure(try parse(x, ".{ .left = .{ \"venomx.clock\" }, .right = .{ \"venomx.clock\" } }")).?);
    try expectEqualStrings("invalid_params.segment", chrome.statusFailure(try parse(x, ".{ .segments = .{ .{ .id = \"user.x\" } } }")).?);
    try expectEqualStrings("invalid_params.segment", chrome.statusFailure(try parse(x, ".{ .segments = .{ .{ .id = \"user.x\", .text = \"a\", .format = \"b\" } } }")).?);
    try expect(chrome.statusFailure(try parse(x, ".{ .segments = .{ .{ .id = \"venomx.clock\", .format = \"{clock:%a %H:%M}\" }, .{ .id = \"user.host\", .text = \"devbox\" } } }")) == null);
}

test "two pushed segments in group tray show as icons inside venomx.tray; no tray when both are cleared" {
    var c = try Client.init(80, 6);
    defer c.deinit();
    try c.app.control(lone_window);
    var buf: [512]u8 = undefined;
    try c.app.control(try segmentEvent(&buf, "venom-os.wifi", "wifi", ",\"group\":\"tray\",\"icon\":\"W\""));
    try c.app.control(try segmentEvent(&buf, "venom-os.bat", "81%", ",\"group\":\"tray\""));
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const list = try placed(&c, arena.allocator());
        const tray = find(list, "venomx.tray").?;
        // Same priority: by id. The one without an icon draws its text.
        try expectEqualStrings("81% W", tray.text);
        try expect(find(list, "venom-os.wifi") == null);
        try expectEqual(@as(usize, 2), tray.members.len);
    }
    try c.app.control(try clearedEvent(&buf, "venom-os.wifi"));
    try c.app.control(try clearedEvent(&buf, "venom-os.bat"));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try expect(find(try placed(&c, arena.allocator()), "venomx.tray") == null);
    const line = try c.status();
    defer a.free(line);
    try expect(!has(line, "81%"));
}

test "a click runs a .verb target with the clicking client's identity; a pushed click can't do more than that client" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var c = try Client.init(100, 24);
    defer c.deinit();
    try c.sync(d);
    var buf: [512]u8 = undefined;
    const click = ",\"click\":{\"verb\":\"pane.split\",\"args\":\"{\\\"pane\\\":\\\"{pane}\\\",\\\"axis\\\":\\\"cols\\\",\\\"argv\\\":[\\\"true\\\"]}\"}";
    try c.app.control(try segmentEvent(&buf, "venom.split", "split", click));
    try c.app.control(try segmentEvent(&buf, "venom.plain", "plain", ""));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const list = try placed(&c, arena.allocator());
    const target = find(list, "venom.split").?;
    const plain = find(list, "venom.plain").?;
    c.app.requests.clearRetainingCapacity();
    // A click on a segment without a target does nothing.
    var seq: [32]u8 = undefined;
    _ = try c.app.feedInput(try std.fmt.bufPrint(&seq, "\x1b[<0;{d};1M\x1b[<0;{d};1m", .{ plain.x + 1, plain.x + 1 }));
    try expectEqual(@as(usize, 0), c.app.requests.items.len);
    _ = try c.app.feedInput(try std.fmt.bufPrint(&seq, "\x1b[<0;{d};1M\x1b[<0;{d};1m", .{ target.x + 1, target.x + 1 }));
    try expectEqual(@as(usize, 1), c.app.requests.items.len);
    try expectEqualStrings("pane.split", c.app.requests.items[0].verb);
    try expect(has(c.app.requests.items[0].params, c.app.focus.?));
    // Sent as a read-only client, the daemon refuses it: the target held
    // no authority of its own.
    var reader = d.connection(try d.principal(&.{.{ .right = .read, .scope = "*" }}, "venom"));
    defer reader.deinit();
    const r = c.app.requests.items[0];
    var refused = try d.call(&reader, r.verb, r.params);
    defer refused.deinit();
    try expect(std.mem.startsWith(u8, refused.value.object.get("error").?.object.get("code").?.string, "denied."));
    const panes = d.product.panes.items.len;
    try d.ok(&d.owner, r.verb, r.params);
    try expectEqual(panes + 1, d.product.panes.items.len);
    for (c.app.requests.items) |q| a.free(q.params);
    c.app.requests.clearRetainingCapacity();
    // A config slot override's click wins over the product's.
    try configure(&c, ".{ .segments = .{ .{ .id = \"venom.split\", .click = .{ .local = \"zoom\" } } } }");
    _ = try c.app.feedInput(try std.fmt.bufPrint(&seq, "\x1b[<0;{d};1M\x1b[<0;{d};1m", .{ target.x + 1, target.x + 1 }));
    try expectEqual(@as(usize, 0), c.app.requests.items.len);
    try expect(c.app.zoomed() != null);
}

const StatusOnly = struct { status: chrome.StatusConfig = .{} };
const StatusStore = cfg.Store(StatusOnly, &.{});
fn validateStatus(c: StatusOnly) ?cfg.Validation {
    if (chrome.statusFailure(c.status)) |code| return .{ .key = "status", .code = code };
    return null;
}

test "status.hide in config fails config check with invalid_params.config_key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const user = try std.fs.path.join(a, &.{ base, "config.zon" });
    defer a.free(user);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = ".{ .status = .{ .position = .top } }" });
    var store = try StatusStore.init(a, .{ .io = std.testing.io, .path = user, .validate = validateStatus });
    defer store.deinit();
    for ([_][]const u8{ ".{ .status = .{ .hide = .{ \"venomx.clock\" } } }", ".{ .status = .{ .priority = .{ .{ .id = \"venom.agents\", .priority = 99 } } } }" }) |text| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = text });
        try std.testing.expectError(error.InvalidConfig, store.check());
        try expectEqualStrings("invalid_params.config_key", store.failure.code);
    }
    // And config set of the removed key.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = ".{}" });
    try std.testing.expectError(error.InvalidConfig, store.set("status.hide", ".{ \"venomx.clock\" }"));
    try expectEqualStrings("invalid_params.config_key", store.failure.code);
}

test "at 80 columns centre, left and right drop together by priority, and the centre never overlaps a side" {
    var c = try Client.init(80, 6);
    defer c.deinit();
    try c.app.control(lone_window);
    var buf: [512]u8 = undefined;
    try c.app.control(try std.fmt.bufPrint(&buf, "{{\"id\":2,\"item\":{{\"type\":\"status.changed\",\"data\":{{\"id\":\"venom.centre\",\"revision\":1,\"segment\":{{\"id\":\"venom.centre\",\"text\":\"centre centre centre\",\"side\":\"center\",\"priority\":70,\"style\":\"normal\",\"when\":[],\"scope\":\"server\",\"bind\":\"connection\",\"revision\":1}}}}}}}}", .{}));
    try c.app.control(try std.fmt.bufPrint(&buf, "{{\"id\":2,\"item\":{{\"type\":\"status.changed\",\"data\":{{\"id\":\"venom.low\",\"revision\":1,\"segment\":{{\"id\":\"venom.low\",\"text\":\"low low low low low low low low\",\"side\":\"center\",\"priority\":5,\"style\":\"normal\",\"when\":[],\"scope\":\"server\",\"bind\":\"connection\",\"revision\":1}}}}}}}}", .{}));
    try c.app.control(try segmentEvent(&buf, "venom.wide", "a fairly wide right-hand segment", ""));
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const list = try placed(&c, arena.allocator());
    const centre = find(list, "venom.centre").?;
    // The lowest priority goes first, whatever its side: it is dropped, or
    // kept cut with `…` as the last one placed.
    if (find(list, "venom.low")) |low| try expect(std.mem.endsWith(u8, low.text, "…"));
    try expect(find(list, "venom.wide") != null);
    var left_end: usize = 0;
    var right_start: usize = 80;
    for (list) |p| switch (p.side) {
        .left => left_end = @max(left_end, p.x + ac.width(p.text)),
        .right => right_start = @min(right_start, p.x),
        .center => {},
    };
    try expect(centre.x >= left_end + 1);
    try expect(centre.x + ac.width(centre.text) + 1 <= right_start);
    const line = try c.status();
    defer a.free(line);
    try expect(has(line, "centre centre centre"));
}

test "toggle-segment hides a segment on this client only, and shows it again" {
    var c = try Client.init(80, 6);
    defer c.deinit();
    try c.app.control(lone_window);
    try c.app.toggleSegment("venomx.clock");
    {
        const line = try c.status();
        defer a.free(line);
        try expect(!has(line, "14:02"));
    }
    // Through the command prompt, as a human types it.
    try c.app.run(.{ .local = .command_prompt });
    _ = try c.app.feedInput("toggle-segment venomx.clock\r");
    const line = try c.status();
    defer a.free(line);
    try expect(has(line, "14:02"));
}

test "a config .when shows a segment only while the focused pane has its tags, and replaces a pushed segment's own when" {
    const d = try Daemon.create();
    defer d.destroy();
    try harness.topology(d);
    var c = try Client.init(160, 24);
    defer c.deinit();
    try c.sync(d);
    // venom.flag pushes its own when (env=prod); the config replaces it with role=ops.
    try c.app.control("{\"id\":2,\"item\":{\"type\":\"status.changed\",\"data\":{\"id\":\"venom.flag\",\"revision\":1,\"segment\":{\"id\":\"venom.flag\",\"text\":\"FLAG\",\"side\":\"right\",\"priority\":50,\"style\":\"normal\",\"when\":[{\"key\":\"env\",\"value\":\"prod\"}],\"scope\":\"server\",\"bind\":\"connection\",\"revision\":1}}}}");
    try configure(&c, ".{ .segments = .{ .{ .id = \"user.prod\", .text = \"PROD\", .when = .{.{ .key = \"env\", .value = \"prod\" }} }, .{ .id = \"venom.flag\", .when = .{.{ .key = \"role\", .value = \"ops\" }} } } }");
    const focus = c.app.focus.?;
    var buf: [256]u8 = undefined;
    {
        const line = try c.status();
        defer a.free(line);
        try expect(!has(line, "PROD"));
        try expect(!has(line, "FLAG"));
    }
    try d.ok(&d.owner, "pane.tag", try std.fmt.bufPrint(&buf, "{{\"pane\":\"{s}\",\"set\":[{{\"key\":\"env\",\"value\":\"prod\"}}]}}", .{focus}));
    try c.sync(d);
    {
        const line = try c.status();
        defer a.free(line);
        try expect(has(line, "PROD"));
        // The pushed when (env=prod) holds, but the config's role=ops replaces it.
        try expect(!has(line, "FLAG"));
    }
    try d.ok(&d.owner, "pane.tag", try std.fmt.bufPrint(&buf, "{{\"pane\":\"{s}\",\"set\":[{{\"key\":\"role\",\"value\":\"ops\"}}],\"unset\":[\"env\"]}}", .{focus}));
    try c.sync(d);
    const line = try c.status();
    defer a.free(line);
    try expect(!has(line, "PROD"));
    try expect(has(line, "FLAG"));
}
