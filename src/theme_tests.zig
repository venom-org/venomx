//! The attach chrome in the Venom theme (ember edition), for both
//! built-in themes and both colour modes.
const std = @import("std");
const term = @import("venom-term");
const app_mod = @import("attach_app.zig");
const chrome_theme = @import("chrome_theme.zig");
const App = app_mod.App;
const a = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const topology = "{\"id\":2,\"item\":{\"type\":\"state.snapshot\",\"data\":{\"entities\":[{\"resource\":\"window:w0\",\"entity_type\":\"window\",\"content\":\"{\\\"window\\\":\\\"w0\\\",\\\"session\\\":\\\"s0\\\",\\\"name\\\":\\\"\\\",\\\"revision\\\":1,\\\"nodes\\\":[{\\\"kind\\\":\\\"split\\\",\\\"axis\\\":\\\"cols\\\",\\\"first\\\":1,\\\"second\\\":2},{\\\"kind\\\":\\\"pane\\\",\\\"pane\\\":\\\"p0\\\"},{\\\"kind\\\":\\\"pane\\\",\\\"pane\\\":\\\"p1\\\"}]}\",\"event_types\":[]}," ++
    "{\"resource\":\"window:w1\",\"entity_type\":\"window\",\"content\":\"{\\\"window\\\":\\\"w1\\\",\\\"session\\\":\\\"s0\\\",\\\"name\\\":\\\"\\\",\\\"revision\\\":1,\\\"nodes\\\":[{\\\"kind\\\":\\\"pane\\\",\\\"pane\\\":\\\"p2\\\"}]}\",\"event_types\":[]}]}}}";

fn themedApp(name: chrome_theme.Name, mode: term.theme.Mode) !App {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 60, .rows = 10 }, .{});
    errdefer app.deinit();
    app.chrome = chrome_theme.chrome(name, mode);
    try app.control(topology);
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    return app;
}

fn draw(app: *App) !term.Surface {
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try term.Surface.init(a, app.cols, app.rows);
    errdefer surface.deinit(&out.writer);
    try app.render(&surface);
    return surface;
}

fn find(surface: *const term.Surface, text: []const u8, y_from: u16) ?term.Cell {
    var y: u16 = y_from;
    while (y < surface.height) : (y += 1) {
        var x: u16 = 0;
        while (x < surface.width) : (x += 1) {
            const cell = surface.get(x, y) orelse continue;
            if (std.mem.eql(u8, cell.text, text)) return cell;
        }
    }
    return null;
}

test "the status line and borders are drawn in the theme, ember edition, in both themes" {
    for ([_]chrome_theme.Name{ .trve, .bone }) |name| {
        var app = try themedApp(name, .truecolor);
        defer app.deinit();
        var devnull: std.Io.Writer.Allocating = .init(a);
        defer devnull.deinit();
        var surface = try draw(&app);
        defer surface.deinit(&devnull.writer);
        const c = app.chrome;
        const t = c.theme;
        // The session block is a fill of the ember signal with its on- text.
        const block = surface.get(0, 0).?;
        try std.testing.expectEqualStrings(" ", block.text);
        try expectEqual(c.sessionBlock(), block.style);
        try expectEqual(term.Color{ .rgb = t.ember.rgb }, block.style.bg);
        try expectEqual(term.Color{ .rgb = t.on_ember.rgb }, block.style.fg);
        try expect(block.style.bold);
        // The rest of the bar is bone-dim on grave.
        const last = surface.get(surface.width - 1, 0).?;
        try expectEqual(c.statusBar().bg, last.style.bg);
        try expectEqual(term.Color{ .rgb = t.grave.rgb }, last.style.bg);
        // The active window is bone and bold; the other is muted.
        const w0 = surface.get(row0(&surface, "▸", 0).?.x + 1, 0).?;
        try expectEqual(term.Color{ .rgb = t.bone.rgb }, w0.style.fg);
        try expect(w0.style.bold);
        // The unfocused pane's title line is `rule`; the focused pane's line and
        // the separator beside it are heavy, in the signal.
        const rule = find(&surface, "─", 1).?;
        try expectEqual(c.inactiveBorder(), rule.style);
        try expectEqual(c.focusedBorder(), find(&surface, "┃", 1).?.style);
        try expectEqual(c.focusedBorder(), find(&surface, "━", 1).?.style);
        // Nothing is drawn in a raw palette index or bare reverse video.
        for (0..surface.height) |y| for (0..surface.width) |x| {
            const style = surface.get(@intCast(x), @intCast(y)).?.style;
            try expect(!style.reverse);
            try expect(style.fg != .index and style.bg != .index);
        };
    }
}

test "the two themes differ, and a plain terminal gets the ANSI fallbacks" {
    var dark = try themedApp(.trve, .truecolor);
    defer dark.deinit();
    var light = try themedApp(.bone, .truecolor);
    defer light.deinit();
    try expect(!std.meta.eql(dark.chrome.sessionBlock(), light.chrome.sessionBlock()));
    var plain = try themedApp(.trve, .ansi16);
    defer plain.deinit();
    var devnull: std.Io.Writer.Allocating = .init(a);
    defer devnull.deinit();
    var surface = try draw(&plain);
    defer surface.deinit(&devnull.writer);
    // ANSI 16: the signal is `ember`'s fallback, drawn as a reverse fill.
    const block = surface.get(0, 0).?;
    try expectEqual(plain.chrome.sessionBlock(), block.style);
    try expectEqual(term.Color{ .index = 11 }, block.style.fg);
    try expect(block.style.reverse);
}

test "the theme config key is read once per attach and a reload leaves the chrome" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 60, .rows = 10 }, .{});
    defer app.deinit();
    try expectEqualStrings("trve", app.chrome.theme.name);
    try app.requestTheme();
    try answerTheme(&app, ".bone");
    try expectEqualStrings("bone", app.chrome.theme.name);
    try expect(app.chrome.edition == .venomx);
    // An unreadable value keeps what the chrome had.
    try app.requestTheme();
    try answerTheme(&app, ".solarized");
    try expectEqualStrings("bone", app.chrome.theme.name);
    // A reload re-reads status and attention, not the theme.
    for (app.requests.items) |r| a.free(r.params);
    app.requests.clearRetainingCapacity();
    try app.control("{\"id\":2,\"item\":{\"type\":\"config.reloaded\",\"data\":{}}}");
    for (app.requests.items) |r| try expect(std.mem.indexOf(u8, r.params, "theme") == null);
}

fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
    try std.testing.expectEqualStrings(expected, actual);
}

fn answerTheme(app: *App, content: []const u8) !void {
    const r = app.requests.orderedRemove(app.requests.items.len - 1);
    defer a.free(r.params);
    const reply = try std.json.Stringify.valueAlloc(a, .{ .id = r.id, .ok = .{ .key = "theme", .content = content } }, .{});
    defer a.free(reply);
    try app.control(reply);
}

/// The cells of row 0 as (x, cell) for every cell whose text is `text`.
fn row0(surface: *const term.Surface, text: []const u8, nth: usize) ?struct { x: u16, cell: term.Cell } {
    var seen: usize = 0;
    var x: u16 = 0;
    while (x < surface.width) : (x += 1) {
        const cell = surface.get(x, 0).?;
        if (!std.mem.eql(u8, cell.text, text)) continue;
        if (seen == nth) return .{ .x = x, .cell = cell };
        seen += 1;
    }
    return null;
}

test "the fang cut follows the session block and the active window has a signal marker" {
    for ([_]chrome_theme.Name{ .trve, .bone }) |name| {
        var app = try themedApp(name, .truecolor);
        defer app.deinit();
        var devnull: std.Io.Writer.Allocating = .init(a);
        defer devnull.deinit();
        var surface = try draw(&app);
        defer surface.deinit(&devnull.writer);
        const c = app.chrome;
        const signal = term.Color{ .rgb = c.theme.ember.rgb };
        const grave = term.Color{ .rgb = c.theme.grave.rgb };
        // " s0 " is the block; the cut is in the signal on grave right after it.
        const fang = row0(&surface, "◤", 0).?;
        try expectEqual(@as(u16, 4), fang.x);
        try expectEqual(signal, fang.cell.style.fg);
        try expectEqual(grave, fang.cell.style.bg);
        try expect(row0(&surface, "│", 0) == null or row0(&surface, "│", 0).?.x > fang.x);
        // The active window: `▸` in the signal, then its id in bone bold.
        const mark = row0(&surface, "▸", 0).?;
        try expect(mark.x > fang.x);
        try expectEqual(signal, mark.cell.style.fg);
        const id = surface.get(mark.x + 1, 0).?;
        try std.testing.expectEqualStrings("1", id.text);
        try expect(id.style.bold);
        try expectEqual(term.Color{ .rgb = c.theme.bone.rgb }, id.style.fg);
        // The other window is muted and not bold.
        const other = surface.get(mark.x + 3, 0).?;
        try std.testing.expectEqualStrings("2", other.text);
        try expectEqual(c.mutedText().fg, other.style.fg);
        try expect(!other.style.bold);
    }
}

test "a mode label is bone bold on ash, with no glyph and never the signal" {
    for ([_]chrome_theme.Name{ .trve, .bone }) |name| {
        var app = try themedApp(name, .truecolor);
        defer app.deinit();
        _ = try app.feedInput("\x02");
        var devnull: std.Io.Writer.Allocating = .init(a);
        defer devnull.deinit();
        var surface = try draw(&app);
        defer surface.deinit(&devnull.writer);
        const t = app.chrome.theme;
        const l = row0(&surface, "L", 0).?;
        try std.testing.expectEqualStrings("E", surface.get(l.x + 1, 0).?.text);
        try expectEqual(term.Color{ .rgb = t.ash.rgb }, l.cell.style.bg);
        try expectEqual(term.Color{ .rgb = t.bone.rgb }, l.cell.style.fg);
        try expect(l.cell.style.bold);
        try expect(!std.meta.eql(l.cell.style.bg, term.Color{ .rgb = t.ember.rgb }));
        // No `◆` precedes the label.
        try expect(row0(&surface, "◆", 0) == null);
    }
}

test "info attention keeps a rule border; focus wins; urgent shows warn" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    const c = app.chrome;
    try app.control("{\"id\":2,\"item\":{\"type\":\"pane.attention_changed\",\"data\":{\"pane\":\"p1\",\"level\":\"info\",\"reason\":\"\",\"revision\":1}}}");
    var devnull: std.Io.Writer.Allocating = .init(a);
    defer devnull.deinit();
    {
        var surface = try draw(&app);
        defer surface.deinit(&devnull.writer);
        // p1 has `info`: its title line stays `rule`, and only the mark shows it.
        const line = find(&surface, "─", 1).?;
        try expectEqual(c.inactiveBorder(), line.style);
        try expect(!std.meta.eql(line.style.fg, term.Color{ .rgb = c.theme.ember.rgb }));
        try expect(find(&surface, "◆", 1) != null);
        // Focus wins on the shared separator.
        try expectEqual(c.focusedBorder(), find(&surface, "┃", 1).?.style);
    }
    try app.control("{\"id\":2,\"item\":{\"type\":\"pane.attention_changed\",\"data\":{\"pane\":\"p1\",\"level\":\"urgent\",\"reason\":\"\",\"revision\":2}}}");
    var surface = try draw(&app);
    defer surface.deinit(&devnull.writer);
    try expectEqual(c.text(c.theme.warn), find(&surface, "─", 1).?.style);
    try expectEqual(c.focusedBorder(), find(&surface, "┃", 1).?.style);
    try expect(find(&surface, "▲", 1) != null);
}

fn send(app: *App, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(a, "{{\"id\":2,\"item\":{{\"type\":" ++ fmt ++ "}}}}", args);
    defer a.free(msg);
    try app.control(msg);
}

fn markOf(app: *App, id: []const u8) []const u8 {
    return app.paneMark(app.pane(id).?).glyph;
}

fn programRecords(app: *App, records: []const u8) !void {
    try send(app, "\"program.status_changed\",\"data\":{{\"pane\":\"p1\",\"reason\":\"report\",\"records\":{s}}}", .{records});
}

fn exitCode(app: *App, code: []const u8) !void {
    try send(app, "\"command.finished\",\"data\":{{\"pane\":\"p1\",\"command\":\"c\",\"reason\":\"osc133\"{s}}}", .{code});
}

test "OSC 7501 record states map by summary priority, and no report is idle" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    try setPane(&app, "{\"pane\":\"p1\",\"session\":\"s0\"}");
    try expectEqualStrings("○", markOf(&app, "p1"));
    try programRecords(&app, "[{\"id\":\"x\",\"state\":\"working\"}]");
    try expectEqualStrings("◆", markOf(&app, "p1"));
    try programRecords(&app, "[{\"id\":\"x\",\"state\":\"working\"},{\"id\":\"y\",\"state\":\"error\"}]");
    try expectEqualStrings("✕", markOf(&app, "p1"));
    try programRecords(&app, "[{\"id\":\"x\",\"state\":\"working\"},{\"id\":\"y\",\"state\":\"done\"}]");
    try expectEqualStrings("●", markOf(&app, "p1"));
    try programRecords(&app, "[{\"id\":\"x\",\"state\":\"idle\"}]");
    try expectEqualStrings("○", markOf(&app, "p1"));
    try programRecords(&app, "[{\"id\":\"x\",\"state\":\"error\"},{\"id\":\"y\",\"state\":\"blocked\"},{\"id\":\"z\",\"state\":\"working\"}]");
    try expectEqualStrings("▲", markOf(&app, "p1"));
    try programRecords(&app, "[]");
    try expectEqualStrings("○", markOf(&app, "p1"));
    // The mark is drawn on the title line.
    var devnull: std.Io.Writer.Allocating = .init(a);
    defer devnull.deinit();
    var surface = try draw(&app);
    defer surface.deinit(&devnull.writer);
    try expect(find(&surface, "○", 1) != null);
}

test "the last OSC 133 exit, its precedence, and unknown exits" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    try setPane(&app, "{\"pane\":\"p1\",\"session\":\"s0\"}");
    try exitCode(&app, ",\"exit_code\":0");
    try expectEqualStrings("●", markOf(&app, "p1"));
    try exitCode(&app, ",\"exit_code\":2");
    try expectEqualStrings("✕", markOf(&app, "p1"));
    try send(&app, "\"command.started\",\"data\":{{\"pane\":\"p1\",\"command\":\"c2\"}}", .{});
    try expectEqualStrings("○", markOf(&app, "p1"));
    // No exit_code: the status is unknown.
    try exitCode(&app, ",\"exit_code\":2");
    try exitCode(&app, "");
    try expectEqualStrings("○", markOf(&app, "p1"));
    // An OSC 7501 report outranks the last command.
    try exitCode(&app, ",\"exit_code\":1");
    try programRecords(&app, "[{\"id\":\"x\",\"state\":\"working\"}]");
    try expectEqualStrings("◆", markOf(&app, "p1"));
    // The process exit outranks both, and attention outranks the exit.
    try programRecords(&app, "[{\"id\":\"x\",\"state\":\"blocked\"}]");
    app.pane("p1").?.stream.exit = .{ .code = 0 };
    try expectEqualStrings("●", markOf(&app, "p1"));
    try send(&app, "\"pane.attention_changed\",\"data\":{{\"pane\":\"p1\",\"level\":\"info\",\"reason\":\"\",\"revision\":1}}", .{});
    try expectEqualStrings("◆", markOf(&app, "p1"));
    app.pane("p1").?.stream.exit = null;
}

test "malformed reports keep the old state and create no pane; pane.removed clears it" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    try setPane(&app, "{\"pane\":\"p1\",\"session\":\"s0\"}");
    try programRecords(&app, "[{\"id\":\"x\",\"state\":\"working\"}]");
    try exitCode(&app, ",\"exit_code\":1");
    try std.testing.expectError(error.BadEvent, programRecords(&app, "[{\"id\":\"x\",\"state\":\"working\"},{\"id\":\"y\",\"state\":\"bogus\"}]"));
    try std.testing.expectError(error.BadEvent, programRecords(&app, "[{\"id\":\"x\"}]"));
    try std.testing.expectError(error.BadEvent, programRecords(&app, "\"nope\""));
    try expectEqualStrings("◆", markOf(&app, "p1"));
    try programRecords(&app, "[]");
    for ([_][]const u8{ ",\"exit_code\":256", ",\"exit_code\":-1", ",\"exit_code\":\"0\"", ",\"exit_code\":1.5" }) |bad| {
        try std.testing.expectError(error.BadEvent, exitCode(&app, bad));
        try expectEqualStrings("✕", markOf(&app, "p1"));
    }
    try std.testing.expectError(error.BadEvent, send(&app, "\"program.status_changed\",\"data\":{{\"pane\":\"p9\",\"records\":5}}", .{}));
    try std.testing.expectError(error.BadEvent, send(&app, "\"command.finished\",\"data\":{{\"pane\":\"p9\",\"exit_code\":999}}", .{}));
    try std.testing.expect(app.shared.pane("p9") == null);
    // A removed pane's state goes with it.
    try programRecords(&app, "[{\"id\":\"x\",\"state\":\"blocked\"}]");
    try std.testing.expect(app.shared.pane("p1").?.program == .blocked);
    try send(&app, "\"pane.removed\",\"data\":{{\"pane\":\"p1\"}}", .{});
    try std.testing.expect(app.shared.pane("p1") == null);
}

test "the program_status snapshot entity seeds the mark, and the lone pane's status entry shows it" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    const panes = ",{\"resource\":\"pane:p1\",\"entity_type\":\"pane\",\"content\":\"{\\\"pane\\\":\\\"p1\\\",\\\"session\\\":\\\"s0\\\"}\",\"event_types\":[]}" ++
        ",{\"resource\":\"pane:p2\",\"entity_type\":\"pane\",\"content\":\"{\\\"pane\\\":\\\"p2\\\",\\\"session\\\":\\\"s0\\\"}\",\"event_types\":[]}";
    const snap = topology[0 .. topology.len - 4] ++ panes ++ ",{\"resource\":\"pane:p1\",\"entity_type\":\"program_status\",\"content\":\"{\\\"pane\\\":\\\"p1\\\",\\\"records\\\":[{\\\"id\\\":\\\"x\\\",\\\"state\\\":\\\"blocked\\\"}]}\",\"event_types\":[]}" ++
        ",{\"resource\":\"pane:p2\",\"entity_type\":\"program_status\",\"content\":\"{\\\"pane\\\":\\\"p2\\\",\\\"records\\\":[{\\\"id\\\":\\\"x\\\",\\\"state\\\":\\\"working\\\"}]}\",\"event_types\":[]}]}}}";
    try app.control(snap);
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    try expectEqualStrings("▲", markOf(&app, "p1"));
    // p0 has no report.
    try expectEqualStrings("○", markOf(&app, "p0"));
    try app.run(.{ .local = .window_next });
    var devnull: std.Io.Writer.Allocating = .init(a);
    defer devnull.deinit();
    var surface = try draw(&app);
    defer surface.deinit(&devnull.writer);
    const status = try rowString(&surface, 0);
    defer a.free(status);
    try expect(std.mem.indexOf(u8, status, "p2 ◆") != null);
}

test "one bad program_status entity is skipped, the rest of the snapshot applies" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    const bad = ",{\"resource\":\"pane:p1\",\"entity_type\":\"program_status\",\"content\":\"{\\\"pane\\\":\\\"p1\\\",\\\"records\\\":[{\\\"id\\\":\\\"x\\\",\\\"state\\\":\\\"future\\\"}]}\",\"event_types\":[]}" ++
        ",{\"resource\":\"pane:p1\",\"entity_type\":\"program_status\",\"content\":\"not json\",\"event_types\":[]}" ++
        ",{\"resource\":\"pane:p1\",\"entity_type\":\"program_status\",\"event_types\":[]}";
    const good = ",{\"resource\":\"pane:p2\",\"entity_type\":\"program_status\",\"content\":\"{\\\"pane\\\":\\\"p2\\\",\\\"records\\\":[{\\\"id\\\":\\\"x\\\",\\\"state\\\":\\\"working\\\"}]}\",\"event_types\":[]}" ++
        ",{\"resource\":\"pane:p0\",\"entity_type\":\"pane\",\"content\":\"{\\\"pane\\\":\\\"p0\\\",\\\"session\\\":\\\"s0\\\"}\",\"event_types\":[]}";
    const panes = ",{\"resource\":\"pane:p1\",\"entity_type\":\"pane\",\"content\":\"{\\\"pane\\\":\\\"p1\\\",\\\"session\\\":\\\"s0\\\"}\",\"event_types\":[]}" ++
        ",{\"resource\":\"pane:p2\",\"entity_type\":\"pane\",\"content\":\"{\\\"pane\\\":\\\"p2\\\",\\\"session\\\":\\\"s0\\\"}\",\"event_types\":[]}";
    // A bad pane, a bad status and a bad window entity, each followed by a good one.
    const more = ",{\"entity_type\":\"pane\",\"content\":\"{\\\"pane\\\":\\\"p7\\\",\\\"attention\\\":{\\\"level\\\":\\\"bogus\\\"}}\"}" ++
        ",{\"entity_type\":\"pane\",\"content\":\"{\\\"pane\\\":\\\"p3\\\",\\\"session\\\":\\\"s0\\\"}\"}" ++
        ",{\"entity_type\":\"status\",\"content\":\"{\\\"id\\\":\\\"bad\\\"}\"}" ++
        ",{\"entity_type\":\"status\"}" ++
        ",{\"entity_type\":\"status\",\"content\":\"{\\\"id\\\":\\\"ok\\\",\\\"text\\\":\\\"fine\\\"}\"}" ++
        ",{\"entity_type\":\"window\",\"content\":\"nope\"}";
    try app.control(topology[0 .. topology.len - 4] ++ panes ++ bad ++ more ++ good ++ "]}}}");
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    try expectEqualStrings("○", markOf(&app, "p1"));
    try expect(app.shared.pane("p2").?.program == .working);
    try expect(app.shared.pane("p0") != null);
    try expect(app.shared.pane("p7") == null);
    try expect(app.shared.pane("p3") != null);
    try expectEqual(@as(usize, 1), app.shared.segments.items.len);
    try expectEqualStrings("ok", app.shared.segments.items[0].id);
}

test "observation events and snapshot entities for unknown panes create no pane" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    try setPane(&app, "{\"pane\":\"p1\",\"session\":\"s0\"}");
    const before = app.shared.panes.items.len;
    // A late event for a closed pane.
    try send(&app, "\"program.status_changed\",\"data\":{{\"pane\":\"p9\",\"records\":[{{\"id\":\"x\",\"state\":\"working\"}}]}}", .{});
    try send(&app, "\"command.started\",\"data\":{{\"pane\":\"p9\",\"command\":\"c\"}}", .{});
    try send(&app, "\"command.finished\",\"data\":{{\"pane\":\"p9\",\"exit_code\":1}}", .{});
    try expect(app.shared.pane("p9") == null);
    // Rejected events create no pane either.
    try std.testing.expectError(error.BadEvent, send(&app, "\"pane.tags_changed\",\"data\":{{\"pane\":\"p9\"}}", .{}));
    try std.testing.expectError(error.BadEvent, send(&app, "\"pane.attention_changed\",\"data\":{{\"pane\":\"p9\",\"level\":\"bogus\"}}", .{}));
    try std.testing.expectError(error.BadEvent, send(&app, "\"program.status_changed\",\"data\":{{\"pane\":\"p9\",\"records\":5}}", .{}));
    try std.testing.expectError(error.BadEvent, send(&app, "\"command.finished\",\"data\":{{\"pane\":\"p9\",\"exit_code\":999}}", .{}));
    try std.testing.expectError(error.BadEvent, send(&app, "\"pane.created\",\"data\":{{\"pane\":\"p9\",\"tags\":5}}", .{}));
    {
        var bad = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"pane\":\"p9\",\"attention\":{\"level\":\"bogus\"}}", .{});
        defer bad.deinit();
        try std.testing.expectError(error.BadEvent, app.shared.paneEntity(bad.value));
    }
    try expect(app.shared.pane("p9") == null);
    try expectEqual(before, app.shared.panes.items.len);
    // A pane removed, then a late event for it.
    try send(&app, "\"pane.removed\",\"data\":{{\"pane\":\"p1\"}}", .{});
    try programRecords(&app, "[{\"id\":\"x\",\"state\":\"working\"}]");
    try expect(app.shared.pane("p1") == null);
}

test "info is frost, not the signal" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    const info = app.roleStyle(.accent);
    try expectEqual(term.Color{ .rgb = app.chrome.theme.frost.rgb }, info.fg);
    try expect(!std.meta.eql(info.fg, app.chrome.signal()));
}

test "a picker is on crypt with a rule_strong edge; its selected row is grave with a signal mark" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w2\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[{\"kind\":\"pane\",\"pane\":\"p9\"}]}}}");
    try app.run(.{ .local = .window_picker });
    var devnull: std.Io.Writer.Allocating = .init(a);
    defer devnull.deinit();
    var surface = try draw(&app);
    defer surface.deinit(&devnull.writer);
    const t = app.chrome.theme;
    const corner = find(&surface, "╭", 0).?;
    try expectEqual(term.Color{ .rgb = t.rule_strong.rgb }, corner.style.fg);
    try expectEqual(term.Color{ .rgb = t.crypt.rgb }, corner.style.bg);
    const mark = find(&surface, "▌", 0).?;
    try expectEqual(app.chrome.signal(), mark.style.fg);
    try expectEqual(term.Color{ .rgb = t.grave.rgb }, mark.style.bg);
}

test "pane default cells are painted in the theme ground the daemon reports" {
    for ([_]chrome_theme.Name{ .trve, .bone }) |name| {
        var app = try themedApp(name, .truecolor);
        defer app.deinit();
        var devnull: std.Io.Writer.Allocating = .init(a);
        defer devnull.deinit();
        var surface = try draw(&app);
        defer surface.deinit(&devnull.writer);
        const reported = chrome_theme.hostColors(name);
        try expectEqual(term.Color{ .rgb = reported.bg.? }, surface.defaults.bg);
        try expectEqual(term.Color{ .rgb = reported.fg.? }, surface.defaults.fg);
    }
}

test "on a 16-colour terminal the surface keeps the terminal's ground and no cell is RGB" {
    for ([_]chrome_theme.Name{ .trve, .bone }) |name| {
        var app = try themedApp(name, .ansi16);
        defer app.deinit();
        var devnull: std.Io.Writer.Allocating = .init(a);
        defer devnull.deinit();
        var surface = try draw(&app);
        defer surface.deinit(&devnull.writer);
        try expectEqual(term.Color.default, surface.defaults.fg);
        try expectEqual(term.Color.default, surface.defaults.bg);
        for (0..surface.height) |y| for (0..surface.width) |x| {
            const style = surface.get(@intCast(x), @intCast(y)).?.style;
            try expect(style.fg != .rgb and style.bg != .rgb);
        };
    }
}

test "a pane's corner label ends at its last column, measured in cells" {
    var devnull: std.Io.Writer.Allocating = .init(a);
    defer devnull.deinit();
    var surface = try term.Surface.init(a, 30, 3);
    defer surface.deinit(&devnull.writer);
    const rect: @import("attach_layout.zig").Rect = .{ .x = 5, .y = 1, .width = 20, .height = 2 };
    const style: term.Style = .{ .bold = true };
    // " ✕ exited 3 " is 12 cells but 14 bytes.
    try app_mod.cornerLabel(&surface, rect, " ✕ exited 3 ", style);
    try std.testing.expectEqualStrings(" ", surface.get(24, 1).?.text);
    try expect(surface.get(24, 1).?.style.bold and !surface.get(25, 1).?.style.bold);
    try std.testing.expectEqualStrings("✕", surface.get(24 - 10, 1).?.text);
    try expect(!surface.get(24 - 12, 1).?.style.bold);
    // A label wider than the pane is cut at its first column.
    try app_mod.cornerLabel(&surface, .{ .x = 0, .y = 0, .width = 4, .height = 1 }, " ✕ exited 3 ", style);
    try expect(!surface.get(4, 0).?.style.bold);
}

test "the fang cut is drawn once after the block, with or without a status message" {
    for ([_]bool{ false, true }) |with_message| {
        var app = try themedApp(.trve, .truecolor);
        defer app.deinit();
        if (with_message) app.say("hello", .{});
        var devnull: std.Io.Writer.Allocating = .init(a);
        defer devnull.deinit();
        var surface = try draw(&app);
        defer surface.deinit(&devnull.writer);
        const fang = row0(&surface, "◤", 0).?;
        try expectEqual(@as(u16, 4), fang.x);
        try expect(row0(&surface, "◤", 1) == null);
        // No separator right after the cut, and the windows follow it.
        try std.testing.expect(!std.mem.eql(u8, surface.get(fang.x + 1, 0).?.text, "│"));
        try std.testing.expect(!std.mem.eql(u8, surface.get(fang.x + 2, 0).?.text, "│"));
        try expect(row0(&surface, "▸", 0).?.x > fang.x);
        if (with_message) try expect(row0(&surface, "h", 0) != null);
    }
}

fn rowString(surface: *const term.Surface, y: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..surface.width) |x| {
        const t = surface.get(@intCast(x), y).?.text;
        try out.appendSlice(a, if (t.len == 0) " " else t);
    }
    return out.toOwnedSlice(a);
}

test "a split window has a title row, and the panes are laid out below it" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    var devnull: std.Io.Writer.Allocating = .init(a);
    defer devnull.deinit();
    var surface = try draw(&app);
    defer surface.deinit(&devnull.writer);
    // Row 0 is the status line, row 1 the title row, the panes start on row 2.
    try expectEqual(@as(u16, 2), app.pane("p0").?.rect.y);
    try expectEqual(@as(u16, 8), app.pane("p0").?.rect.height);
    const title_row = try rowString(&surface, 1);
    defer a.free(title_row);
    // No pane IDs: each untitled pane shows its mark.
    // p0 is focused: its title line is heavy; p1's is light.
    try expect(std.mem.startsWith(u8, title_row, "━ ○ ━"));
    // The junction turns into p0 only: no arm into p1's light line.
    try expect(std.mem.indexOf(u8, title_row, "┓") != null);
    try expect(std.mem.indexOf(u8, title_row, "┓─ ○ ─") != null);
    // No bottom or outer side border: the last row and the first column are pane cells.
    try std.testing.expect(find(&surface, "┗", 0) == null and find(&surface, "└", 0) == null);
}

test "a lone pane has no title line, and its ID and mark are on the window's status entry; zoom keeps the title row" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    try app.run(.{ .local = .window_next });
    try expectEqualStrings("w1", app.active.?);
    try app.control("{\"id\":2,\"item\":{\"type\":\"pane.attention_changed\",\"data\":{\"pane\":\"p2\",\"level\":\"warn\",\"reason\":\"\",\"revision\":1}}}");
    var devnull: std.Io.Writer.Allocating = .init(a);
    defer devnull.deinit();
    {
        var surface = try draw(&app);
        defer surface.deinit(&devnull.writer);
        // The pane gets the whole area under the status line.
        try expectEqual(@as(u16, 1), app.pane("p2").?.rect.y);
        try expectEqual(@as(u16, 9), app.pane("p2").?.rect.height);
        const status = try rowString(&surface, 0);
        defer a.free(status);
        try expect(std.mem.indexOf(u8, status, "▸2") != null);
        try expect(std.mem.indexOf(u8, status, "p2 ▲") != null);
        const below = try rowString(&surface, 1);
        defer a.free(below);
        try expect(std.mem.indexOf(u8, below, "p2") == null);
    }
    // Back in the split window, zoom keeps the title row and its other panes' titles are hidden.
    try app.run(.{ .local = .window_next });
    try app.run(.{ .local = .zoom });
    try expect(app.zoomed() != null);
    var surface = try draw(&app);
    defer surface.deinit(&devnull.writer);
    try expectEqual(@as(u16, 2), app.pane("p0").?.rect.y);
    const title_row = try rowString(&surface, 1);
    defer a.free(title_row);
    try expect(std.mem.startsWith(u8, title_row, "━ ○ ━"));
    try expect(std.mem.count(u8, title_row, "○") == 1);
}

test "16-colour mode draws the same lines, and the minimum pane sizes hold on a tiny terminal" {
    var app = try themedApp(.trve, .ansi16);
    defer app.deinit();
    var devnull: std.Io.Writer.Allocating = .init(a);
    defer devnull.deinit();
    var surface = try draw(&app);
    defer surface.deinit(&devnull.writer);
    const c = app.chrome;
    try expectEqual(c.focusedBorder(), find(&surface, "┃", 1).?.style);
    try expectEqual(c.inactiveBorder(), find(&surface, "─", 1).?.style);
    // A 3-wide, 4-high terminal: the status line, the title row, and one row for each pane
    // and one column for each pane and the separator.
    try app.resize(3, 4);
    try expectEqual(@as(u16, 1), app.pane("p0").?.rect.width);
    try expectEqual(@as(u16, 1), app.pane("p1").?.rect.width);
    try expect(app.pane("p0").?.rect.height >= 1);
    var tiny = try draw(&app);
    defer tiny.deinit(&devnull.writer);
}

fn goLive(p: *app_mod.PaneView, cols: u16, rows: u16) !void {
    p.stream.vt = try @import("vt").Vt.init(a, .{ .cols = cols, .rows = rows });
    p.stream.phase = .live;
    p.stream.writer = true;
}

test "a lone pane's changed title reaches the status line's middle on the next render" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    try app.run(.{ .local = .window_next });
    const p = app.pane("p2").?;
    try goLive(p, 60, 9);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try term.Surface.init(a, app.cols, app.rows);
    defer surface.deinit(&out.writer);
    try p.stream.vt.?.feed("\x1b]2;first\x07");
    try app.render(&surface);
    {
        const status = try rowString(&surface, 0);
        defer a.free(status);
        try expect(std.mem.indexOf(u8, status, " first ") != null);
    }
    try p.stream.vt.?.feed("\x1b]2;second\x07");
    p.damaged = true;
    app.pane_damage = true;
    try app.render(&surface);
    const status = try rowString(&surface, 0);
    defer a.free(status);
    try expect(std.mem.indexOf(u8, status, " second ") != null);
    try expect(std.mem.indexOf(u8, status, "first") == null);
}

test "a long lone-pane title is capped and gives way to attention and the clock" {
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 50, .rows = 10 }, .{});
    defer app.deinit();
    app.fixed_clock = "12:34";
    try app.control(topology);
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    try app.run(.{ .local = .window_next });
    try app.control("{\"id\":2,\"item\":{\"type\":\"pane.attention_changed\",\"data\":{\"pane\":\"p2\",\"level\":\"warn\",\"reason\":\"\",\"revision\":1}}}");
    const p = app.pane("p2").?;
    try goLive(p, 50, 9);
    try p.stream.vt.?.feed("\x1b]2;a very long title that would push everything else off the bar\x07");
    var devnull: std.Io.Writer.Allocating = .init(a);
    defer devnull.deinit();
    var surface = try draw(&app);
    defer surface.deinit(&devnull.writer);
    const status = try rowString(&surface, 0);
    defer a.free(status);
    try expect(std.mem.indexOf(u8, status, "1 attention") != null);
    try expect(std.mem.indexOf(u8, status, "12:34") != null);
    try expect(std.mem.indexOf(u8, status, "would push everything") == null);
}

test "a float in a split window stays on the damage-only render" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    try app.control("{\"id\":2,\"item\":{\"type\":\"pane.created\",\"data\":{\"pane\":\"p9\",\"session\":\"s0\",\"window\":\"w0\",\"layer\":\"float\",\"float\":{\"width\":\"20\",\"height\":\"4\",\"anchor\":\"center\",\"border\":\"single\",\"x\":0,\"y\":0,\"min_cols\":1,\"min_rows\":1,\"z\":1}}}}");
    try expect(app.overlay("p9") != null);
    try goLive(app.pane("p0").?, 29, 8);
    try goLive(app.pane("p1").?, 30, 8);
    const float = app.pane("p9").?;
    try goLive(float, 18, 2);
    // The float has a pane block, so its title is set before the
    // first render; a new one redraws the bar.
    try float.stream.vt.?.feed("\x1b]2;float title\x07");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var surface = try term.Surface.init(a, app.cols, app.rows);
    defer surface.deinit(&out.writer);
    try app.render(&surface);
    try expect(app.pane("p0").?.has_title_line and !float.has_title_line);
    // The float's own output is patched in place, not a full redraw.
    try float.stream.vt.?.feed("hi");
    float.damaged = true;
    app.pane_damage = true;
    surface.damage = null;
    try app.render(&surface);
    const d = surface.damage.?;
    try expect(@as(u32, d.width) * d.height < @as(u32, app.cols) * app.rows);
    // A tiled pane's new title is on the border, which only a full render draws.
    try app.pane("p0").?.stream.vt.?.feed("\x1b]2;changed\x07");
    app.pane("p0").?.damaged = true;
    app.pane_damage = true;
    surface.damage = null;
    try app.render(&surface);
    const row = try rowString(&surface, 1);
    defer a.free(row);
    try expect(std.mem.indexOf(u8, row, "━ changed ○") != null);
}

test "a rows split keeps one row for each pane under the title row, and tiny terminals do not fail" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    try app.control("{\"id\":2,\"item\":{\"type\":\"window.created\",\"data\":{\"window\":\"w2\",\"session\":\"s0\",\"name\":\"\",\"revision\":1,\"nodes\":[{\"kind\":\"split\",\"axis\":\"rows\",\"first\":1,\"second\":2},{\"kind\":\"pane\",\"pane\":\"p7\"},{\"kind\":\"pane\",\"pane\":\"p8\"}]}}}");
    try app.run(.{ .local = .window_next });
    try app.run(.{ .local = .window_next });
    try expectEqualStrings("w2", app.active.?);
    var devnull: std.Io.Writer.Allocating = .init(a);
    defer devnull.deinit();
    // Status line, title row, a pane row, a separator (p8's title line), a pane row.
    try app.resize(10, 5);
    try expectEqual(@as(u16, 1), app.pane("p7").?.rect.height);
    try expectEqual(@as(u16, 1), app.pane("p8").?.rect.height);
    // One to three rows: the lines never draw outside the window and never fail.
    for ([_]u16{ 1, 2, 3, 4 }) |rows| {
        try app.resize(10, rows);
        var surface = try draw(&app);
        surface.deinit(&devnull.writer);
    }
}

test "a wide-character title is cut by cells, and a lone-cell pane shows a line" {
    const border = @import("attach_border.zig");
    try expectEqual(@as(usize, 4), border.cells("日本"));
    try expectEqualStrings("日", border.cutCells("日本", 3));
    // Cut by graphemes, measured in cells: a ZWJ family and a flag are one cell group each.
    try expectEqual(@as(usize, 2), border.cells("👨‍👩‍👧"));
    try expectEqualStrings("👨‍👩‍👧", border.cutCells("👨‍👩‍👧x", 2));
    try expectEqualStrings("e\u{301}", border.cutCells("e\u{301}x", 1));
    try expectEqualStrings("", border.cutCells("😀", 1));
    var buf: [32]u8 = undefined;
    try expectEqualStrings("ab", border.clean(&buf, "a\xc2\x85b\xc2\xa0"));
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    for (0..5) |w| {
        var s = try term.Surface.init(a, 12, 3);
        defer s.deinit(&out.writer);
        const lines = [_]border.Line{.{ .rect = .{ .x = 0, .y = 1, .width = @intCast(w), .height = 2 }, .title = "日本語のタイトル", .tag = "grp", .mark = if (w % 2 == 0) .{ .glyph = "▲", .style = .{} } else null }};
        try border.draw(&s, .{ .lines = &lines, .title_row = .{ .x = 0, .y = 0, .width = 12, .height = 1 }, .styles = .{ .rule = .{}, .urgent = .{}, .focus = .{}, .title = .{}, .title_focus = .{}, .tag = .{} } });
        // A one-column pane with no state shows its line cell, not the title.
        if (w == 1) try expectEqualStrings("─", s.get(0, 0).?.text);
    }
    var s = try term.Surface.init(a, 12, 3);
    defer s.deinit(&out.writer);
    const lines = [_]border.Line{.{ .rect = .{ .x = 0, .y = 1, .width = 12, .height = 2 }, .title = "日本語のタイトル" }};
    try border.draw(&s, .{ .lines = &lines, .title_row = .{ .x = 0, .y = 0, .width = 12, .height = 1 }, .styles = .{ .rule = .{}, .urgent = .{}, .focus = .{}, .title = .{}, .title_focus = .{}, .tag = .{} } });
    // "─ " then 9 cells for the title: 4 wide characters and the ellipsis.
    try expectEqualStrings("日", s.get(2, 0).?.text);
    try expectEqualStrings("…", s.get(10, 0).?.text);
}

fn scrolledPane(app: *App, id: []const u8) !struct { pv: *app_mod.PaneView, first: u64, second: u64, vt: term.Vt } {
    const pv = app.pane(id).?;
    pv.stream.vt = try term.Vt.init(a, .{ .cols = 20, .rows = 6 });
    pv.stream.phase = .live;
    const vt = pv.stream.vt.?;
    for (0..2) |_| try vt.feed("\x1b]133;A\x07$ \x1b]133;B\x07cmd\r\n\x1b]133;C\x07out1\r\nout2\r\n\x1b]133;D;0\x07");
    for (0..10) |_| try vt.feed("tail\r\n");
    const e = vt.rows().epoch;
    const first = vt.rows().oldest;
    try expectEqual(term.Vt.RowPrompt.start, try vt.rowPrompt(e, first));
    const second = (try vt.nextPromptRow(e, first)).?;
    pv.scroll = first;
    pv.scroll_epoch = e;
    app.dirty = true;
    return .{ .pv = pv, .first = first, .second = second, .vt = vt };
}

test "the held block is on grave; a pane at column 0 keeps its content and gets no mark" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    {
        var s = try draw(&app);
        defer s.deinit(&out.writer);
        for (0..s.height) |y| for (0..s.width) |x| try expect(!std.mem.eql(u8, s.get(@intCast(x), @intCast(y)).?.text, "▌"));
    }
    const sc = try scrolledPane(&app, "p0");
    var s = try draw(&app);
    defer s.deinit(&out.writer);
    const grave = term.Color{ .rgb = app.chrome.theme.grave.rgb };
    const r = sc.pv.rect;
    try expectEqual(@as(u16, 0), r.x);
    const block_rows: u16 = @intCast(@min(sc.second - sc.first, r.height));
    try expect(block_rows >= 2);
    for (0..r.height) |y| {
        const cell = s.get(r.x + 1, r.y + @as(u16, @intCast(y))).?;
        if (y < block_rows) try expectEqual(grave, cell.style.bg) else try expect(!std.meta.eql(grave, cell.style.bg));
    }
    // The first column still holds the program's `$`.
    try std.testing.expectEqualStrings("$", s.get(r.x, r.y).?.text);
    for (0..s.height) |y| for (0..s.width) |x| try expect(!std.mem.eql(u8, s.get(@intCast(x), @intCast(y)).?.text, "▌"));
}

test "beside a separator the signal marks the prompt row only" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    const sc = try scrolledPane(&app, "p1");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var s = try draw(&app);
    defer s.deinit(&out.writer);
    const r = sc.pv.rect;
    try expect(r.x > 0);
    const signal = term.Color{ .rgb = app.chrome.theme.ember.rgb };
    const grave = term.Color{ .rgb = app.chrome.theme.grave.rgb };
    for (0..r.height) |y| {
        const edge = s.get(r.x - 1, r.y + @as(u16, @intCast(y))).?;
        const cell = s.get(r.x, r.y + @as(u16, @intCast(y))).?;
        if (y == 0) {
            try std.testing.expectEqualStrings("▌", edge.text);
            try expectEqual(signal, edge.style.fg);
            try expectEqual(grave, edge.style.bg);
            try std.testing.expectEqualStrings("$", cell.text);
        } else {
            try expect(!std.mem.eql(u8, edge.text, "▌"));
        }
    }
}

test "the signal shows beside the focused pane's heavy separator" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    const sc = try scrolledPane(&app, "p1");
    if (app.focus) |f| a.free(f);
    app.focus = try a.dupe(u8, "p1");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const r = sc.pv.rect;
    {
        // Unscrolled, the separator beside the focused pane is heavy.
        sc.pv.scroll = null;
        var s = try draw(&app);
        defer s.deinit(&out.writer);
        try std.testing.expectEqualStrings("┃", s.get(r.x - 1, r.y + 1).?.text);
    }
    sc.pv.scroll = sc.first;
    app.dirty = true;
    var s = try draw(&app);
    defer s.deinit(&out.writer);
    try std.testing.expectEqualStrings("▌", s.get(r.x - 1, r.y).?.text);
    try expectEqual(term.Color{ .rgb = app.chrome.theme.ember.rgb }, s.get(r.x - 1, r.y).?.style.fg);
    try std.testing.expectEqualStrings("┃", s.get(r.x - 1, r.y + 1).?.text);
}

test "the signal replaces a junction on the separator" {
    // p0 above p2 on the left, p1 on the right: the left split meets the
    // separator beside p1 on one of p1's rows.
    const three = "{\"id\":2,\"item\":{\"type\":\"state.snapshot\",\"data\":{\"entities\":[{\"resource\":\"window:w0\",\"entity_type\":\"window\",\"content\":\"{\\\"window\\\":\\\"w0\\\",\\\"session\\\":\\\"s0\\\",\\\"name\\\":\\\"\\\",\\\"revision\\\":1,\\\"nodes\\\":[{\\\"kind\\\":\\\"split\\\",\\\"axis\\\":\\\"cols\\\",\\\"first\\\":1,\\\"second\\\":4},{\\\"kind\\\":\\\"split\\\",\\\"axis\\\":\\\"rows\\\",\\\"first\\\":2,\\\"second\\\":3},{\\\"kind\\\":\\\"pane\\\",\\\"pane\\\":\\\"p0\\\"},{\\\"kind\\\":\\\"pane\\\",\\\"pane\\\":\\\"p2\\\"},{\\\"kind\\\":\\\"pane\\\",\\\"pane\\\":\\\"p1\\\"}]}\",\"event_types\":[]}]}}}";
    var app = try App.init(a, .{ .session = "s0" }, .{ .cols = 60, .rows = 14 }, .{});
    defer app.deinit();
    app.chrome = chrome_theme.chrome(.trve, .truecolor);
    try app.control(three);
    try app.control("{\"id\":2,\"item\":{\"type\":\"stream.checkpoint\",\"data\":{}}}");
    const pv = app.pane("p1").?;
    const r = pv.rect;
    try expect(r.x > 0);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    // Find the junction row beside p1.
    app.dirty = true;
    const junction: u16 = blk: {
        var s = try draw(&app);
        defer s.deinit(&out.writer);
        for (0..r.height) |y| {
            const t = s.get(r.x - 1, r.y + @as(u16, @intCast(y))).?.text;
            if (!std.mem.eql(u8, t, "│") and !std.mem.eql(u8, t, "┃")) break :blk @intCast(y);
        }
        return error.TestUnexpectedResult;
    };
    try expect(junction > 0);
    pv.stream.vt = try term.Vt.init(a, .{ .cols = r.width, .rows = r.height });
    pv.stream.phase = .live;
    const vt = pv.stream.vt.?;
    // One command whose prompt runs over continuation lines (OSC 133 A
    // `k=c`) down past the junction row, then more history.
    try vt.feed("\x1b]133;A\x07$ \\\r\n");
    for (0..junction) |_| try vt.feed("\x1b]133;A;k=c\x07> \\\r\n");
    try vt.feed("\x1b]133;A;k=c\x07> \x1b]133;B\x07cmd\r\n\x1b]133;C\x07out\r\n\x1b]133;D;0\x07");
    for (0..2 * r.height) |_| try vt.feed("tail\r\n");
    const e = vt.rows().epoch;
    const start = vt.rows().oldest;
    try expectEqual(term.Vt.RowPrompt.start, try vt.rowPrompt(e, start));
    try expectEqual(term.Vt.RowPrompt.continuation, try vt.rowPrompt(e, start + junction));
    pv.scroll = start;
    pv.scroll_epoch = e;
    app.dirty = true;
    var s = try draw(&app);
    defer s.deinit(&out.writer);
    try std.testing.expectEqualStrings("▌", s.get(r.x - 1, r.y + junction).?.text);
    // The output row below the prompt keeps its separator.
    try expect(!std.mem.eql(u8, s.get(r.x - 1, r.y + junction + 2).?.text, "▌"));
}

test "a stale epoch draws no block; a top that is not a start row holds the block above" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    const sc = try scrolledPane(&app, "p1");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const grave = term.Color{ .rgb = app.chrome.theme.grave.rgb };
    // Top one row below the start: still in the block.
    sc.pv.scroll = sc.first + 1;
    {
        var s = try draw(&app);
        defer s.deinit(&out.writer);
        try expectEqual(grave, s.get(sc.pv.rect.x + 1, sc.pv.rect.y).?.style.bg);
        try expect(!std.mem.eql(u8, s.get(sc.pv.rect.x - 1, sc.pv.rect.y).?.text, "▌"));
    }
    // A reset starts a new epoch: the old scroll row is void.
    try sc.vt.feed("\x1bc");
    var s = try draw(&app);
    defer s.deinit(&out.writer);
    try expect(sc.pv.scroll == null);
    for (0..s.height) |y| for (0..s.width) |x| try expect(!std.mem.eql(u8, s.get(@intCast(x), @intCast(y)).?.text, "▌"));
}

test "the held block is searched again when a cropped active row is rewritten" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    const pv = app.pane("p1").?;
    const r = pv.rect;
    // A terminal taller than the pane, so the live view is cropped.
    pv.stream.vt = try term.Vt.init(a, .{ .cols = r.width, .rows = r.height + 6 });
    pv.stream.phase = .live;
    const vt = pv.stream.vt.?;
    try vt.feed("\x1b]133;A\x07$ \x1b]133;B\x07cmd\r\n\x1b]133;C\x07");
    for (0..r.height + 4) |_| try vt.feed("out\r\n");
    const e = vt.rows().epoch;
    const start = vt.rows().active;
    try expectEqual(term.Vt.RowPrompt.start, try vt.rowPrompt(e, start));
    try expect(app.topRow(pv) > start);
    pv.scroll = start;
    pv.scroll_epoch = e;
    app.dirty = true;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    const grave = term.Color{ .rgb = app.chrome.theme.grave.rgb };
    {
        var s = try draw(&app);
        defer s.deinit(&out.writer);
        try expectEqual(grave, s.get(r.x + 1, r.y).?.style.bg);
    }
    // The program repaints the screen in place: the row is no prompt now.
    try vt.feed("\x1b[H\x1b[2J");
    for (0..r.height + 5) |_| try vt.feed("new\r\n");
    try expectEqual(e, vt.rows().epoch);
    try expect(try vt.rowPrompt(e, start) != .start);
    try expect(try vt.prevPromptRow(e, start) == null);
    app.dirty = true;
    var s = try draw(&app);
    defer s.deinit(&out.writer);
    for (0..r.height) |y| try expect(!std.meta.eql(grave, s.get(r.x + 1, r.y + @as(u16, @intCast(y))).?.style.bg));
}

test "trimming history keeps the held block's cached start" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    const pv = app.pane("p1").?;
    // A wide terminal keeps libghostty's pages short, so history is trimmed
    // a page at a time well before the block's start goes.
    pv.stream.vt = try term.Vt.init(a, .{ .cols = 500, .rows = 6, .scrollback_lines = 100 });
    pv.stream.phase = .live;
    const vt = pv.stream.vt.?;
    while (vt.rows().oldest == 0) try vt.feed("old\r\n");
    const page = vt.rows().oldest;
    // The prompt goes on the second page, which the next trim keeps.
    while (vt.rows().active + vt.cursor().y < 2 * page + 2) try vt.feed("old\r\n");
    try expectEqual(page, vt.rows().oldest);
    try vt.feed("\x1b]133;A\x07$ \x1b]133;B\x07cmd\r\n\x1b]133;C\x07");
    for (0..8) |_| try vt.feed("out\r\n");
    const e = vt.rows().epoch;
    const start = (try vt.prevPromptRow(e, vt.rows().active)).?;
    try expect(start >= 2 * page);
    pv.scroll = start + 2;
    pv.scroll_epoch = e;
    app.dirty = true;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    {
        var s = try draw(&app);
        defer s.deinit(&out.writer);
    }
    const searched = pv.block_cache.?;
    try expectEqual(@as(?u64, start), searched.first);
    // Output trims history from the top, short of the block's start.
    const before = vt.rows().oldest;
    while (vt.rows().oldest == before) try vt.feed("more\r\n");
    try expect(vt.rows().oldest <= start and start + 2 < vt.rows().active);
    app.dirty = true;
    {
        var s = try draw(&app);
        defer s.deinit(&out.writer);
        try expectEqual(term.Color{ .rgb = app.chrome.theme.grave.rgb }, s.get(pv.rect.x + 1, pv.rect.y).?.style.bg);
    }
    // Not searched again: the entry still holds the oldest row of its search.
    try expectEqual(searched, pv.block_cache.?);
}

fn setPane(app: *App, json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    try app.shared.paneEntity(parsed.value);
}

fn titleRow(app: *App) ![]u8 {
    var devnull: std.Io.Writer.Allocating = .init(a);
    defer devnull.deinit();
    var surface = try draw(app);
    defer surface.deinit(&devnull.writer);
    return rowString(&surface, 1);
}

test "the title is the OSC 2 title, else argv0, else empty" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    try goLive(app.pane("p0").?, 29, 8);
    try goLive(app.pane("p1").?, 30, 8);
    {
        const row = try titleRow(&app);
        defer a.free(row);
        try expect(std.mem.startsWith(u8, row, "━ ○ ━"));
        try expect(std.mem.indexOf(u8, row, "nvim") == null);
    }
    try setPane(&app, "{\"pane\":\"p0\",\"session\":\"s0\",\"argv0\":\"nvim\"}");
    {
        const row = try titleRow(&app);
        defer a.free(row);
        try expect(std.mem.indexOf(u8, row, "━ nvim") != null);
    }
    // A set OSC 2 title wins; an emptied one falls back to argv0 again.
    try app.pane("p0").?.stream.vt.?.feed("\x1b]2;zsh\x07");
    app.pane("p0").?.damaged = true;
    app.pane_damage = true;
    {
        const row = try titleRow(&app);
        defer a.free(row);
        try expect(std.mem.indexOf(u8, row, "━ zsh") != null);
        try expect(std.mem.indexOf(u8, row, "nvim") == null);
    }
    try app.pane("p0").?.stream.vt.?.feed("\x1b]2;\x07");
    {
        const row = try titleRow(&app);
        defer a.free(row);
        try expect(std.mem.indexOf(u8, row, "━ nvim") != null);
    }
}

test "the right part is the group tag, else the OSC 7 cwd, else empty" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    app.home = "/home/u";
    app.local_host = "box";
    try goLive(app.pane("p0").?, 29, 8);
    try goLive(app.pane("p1").?, 30, 8);
    const vt = app.pane("p0").?.stream.vt.?;
    {
        const row = try titleRow(&app);
        defer a.free(row);
        try expect(std.mem.indexOf(u8, row, "/srv") == null and std.mem.indexOf(u8, row, "~") == null);
    }
    try vt.feed("\x1b]7;file://other/srv/a%20b\x1b\\");
    app.pane("p0").?.damaged = true;
    app.pane_damage = true;
    {
        const row = try titleRow(&app);
        defer a.free(row);
        try expect(std.mem.indexOf(u8, row, "/srv/a b") != null);
    }
    // A local host and a path under $HOME is shortened with ~.
    try vt.feed("\x1b]7;file://box/home/u/src\x1b\\");
    {
        const row = try titleRow(&app);
        defer a.free(row);
        try expect(std.mem.indexOf(u8, row, "~/src") != null);
    }
    try vt.feed("\x1b]7;file:///home/user/src\x1b\\");
    {
        const row = try titleRow(&app);
        defer a.free(row);
        try expect(std.mem.indexOf(u8, row, "/home/user/src") != null);
    }
    // The group tag wins over the cwd.
    try setPane(&app, "{\"pane\":\"p0\",\"session\":\"s0\",\"tags\":[{\"key\":\"group\",\"value\":\"thread-7\"}]}");
    {
        const row = try titleRow(&app);
        defer a.free(row);
        try expect(std.mem.indexOf(u8, row, "thread-7") != null);
        try expect(std.mem.indexOf(u8, row, "/home/user") == null);
    }
}

test "control and bidi characters never reach the title line" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    try goLive(app.pane("p0").?, 29, 8);
    try goLive(app.pane("p1").?, 30, 8);
    try setPane(&app, "{\"pane\":\"p0\",\"session\":\"s0\",\"argv0\":\"a\\u001bb\\u202ec\\u0085d\"}");
    try app.pane("p0").?.stream.vt.?.feed("\x1b]7;file:///t%1b%5b31m%e2%80%aex\x1b\\");
    var devnull: std.Io.Writer.Allocating = .init(a);
    defer devnull.deinit();
    var surface = try draw(&app);
    defer surface.deinit(&devnull.writer);
    const row = try rowString(&surface, 1);
    defer a.free(row);
    try expect(std.mem.indexOf(u8, row, "━ abcd") != null);
    try expect(std.mem.indexOf(u8, row, "/t[31mx") != null);
    for (0..surface.width) |x| for (surface.get(@intCast(x), 1).?.text) |byte| try expect(byte >= 0x20 and byte != 0x7f);
    try expect(std.mem.indexOf(u8, row, "\u{202e}") == null);
}

test "one invalid byte or an invisible character does not blank the cwd" {
    var app = try themedApp(.trve, .truecolor);
    defer app.deinit();
    try goLive(app.pane("p0").?, 29, 8);
    try goLive(app.pane("p1").?, 30, 8);
    try app.pane("p0").?.stream.vt.?.feed("\x1b]7;file:///d%e9%ffx%e2%80%8by\x1b\\");
    const row = try titleRow(&app);
    defer a.free(row);
    try expect(std.mem.indexOf(u8, row, "/dxy") != null);
}
