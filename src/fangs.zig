//! The fangs: two fangs as
//! heavy scanlines in `ansi-7`, the drop in the edition colour (`ember`).
//! They appear in `venomx --version`, the `doctor` header and the empty
//! state of a session with no panes, and nowhere else.
const std = @import("std");
const term = @import("venom-term");

/// The version `--version` and the fangs' caption print.
pub const version = @import("version.zig").version;
pub const tagline = "terminal multiplexer for humans and agents";

/// One line per row. The drop is the only `●`; every other glyph is a scanline.
pub const rows = [_][]const u8{
    "━━━━━━  ━━━━━━",
    " ━━━━━  ━━━━━",
    "  ━━━━  ━━━━",
    "   ━━━  ━━━",
    "    ━━  ━━",
    "      ●",
};
/// Columns the art takes, and where a caption starts (rows 1 and 2).
pub const art_width = 14;
pub const caption_col = 17;
pub const height: u16 = rows.len;
const drop = "●";

fn isDrop(glyph: []const u8) bool {
    return std.mem.eql(u8, glyph, drop);
}

/// `ansi-7` for the scanlines, the edition signal for the drop.
fn glyphStyle(chrome: term.theme.Chrome, glyph: []const u8) term.Style {
    return .{ .fg = if (isDrop(glyph)) chrome.signal() else chrome.ansi(7) };
}

fn writeSgr(w: *std.Io.Writer, c: term.Color) !void {
    switch (c) {
        .default => try w.writeAll("\x1b[39m"),
        .index => |i| if (i < 8) try w.print("\x1b[{d}m", .{30 + @as(u32, i)}) else if (i < 16) try w.print("\x1b[{d}m", .{90 + @as(u32, i) - 8}) else try w.print("\x1b[38;5;{d}m", .{i}),
        .rgb => |v| try w.print("\x1b[38;2;{d};{d};{d}m", .{ v[0], v[1], v[2] }),
    }
}

/// The fangs for a command line, with up to two caption lines beside them
/// (rows 1 and 2). `chrome` null prints plain text with no escapes (a pipe,
/// `NO_COLOR`); otherwise the scanlines and the drop are coloured.
pub fn write(w: *std.Io.Writer, chrome: ?term.theme.Chrome, captions: []const []const u8) !void {
    for (rows, 0..) |row, y| {
        var it = (try std.unicode.Utf8View.init(row)).iterator();
        while (it.nextCodepointSlice()) |glyph| {
            if (glyph[0] == ' ' or chrome == null) {
                try w.writeAll(glyph);
                continue;
            }
            try writeSgr(w, glyphStyle(chrome.?, glyph).fg);
            try w.writeAll(glyph);
            try w.writeAll("\x1b[39m");
        }
        if (y >= 1 and y - 1 < captions.len) {
            const used = std.unicode.utf8CountCodepoints(row) catch row.len;
            try w.splatByteAll(' ', caption_col - used);
            try w.writeAll(captions[y - 1]);
        }
        try w.writeByte('\n');
    }
}

/// Draws the fangs with their top-left at (`x`, `y`) on a surface, clipped to
/// `region`. Captions go in rows 1 and 2, as in `write`.
pub fn draw(surface: *term.Surface, region: term.Region, chrome: term.theme.Chrome, x: u16, y: u16, captions: []const []const u8) !void {
    for (rows, 0..) |row, dy| {
        const row_y = y +| @as(u16, @intCast(dy));
        if (row_y >= region.y +| region.height) break;
        var col: u16 = x;
        var it = (try std.unicode.Utf8View.init(row)).iterator();
        while (it.nextCodepointSlice()) |glyph| : (col +|= 1) {
            if (glyph[0] == ' ' or col >= region.x +| region.width) continue;
            try surface.text(.{ .x = col, .y = row_y, .width = 1, .height = 1 }, glyph, glyphStyle(chrome, glyph));
        }
        if (dy >= 1 and dy - 1 < captions.len and x +| caption_col < region.x +| region.width) {
            const style: term.Style = if (dy == 1) chrome.text(chrome.theme.bone) else chrome.mutedText();
            const left = x +| caption_col;
            try surface.text(.{ .x = left, .y = row_y, .width = region.x +| region.width -| left, .height = 1 }, captions[dy - 1], style);
        }
    }
}

/// The widest line the fangs and captions need, in columns.
pub fn width(captions: []const []const u8) u16 {
    var w: usize = art_width;
    for (captions) |c| w = @max(w, caption_col + (std.unicode.utf8CountCodepoints(c) catch c.len));
    return @intCast(@min(w, std.math.maxInt(u16)));
}

test "plain fangs match the brand drawing exactly" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, null, &.{ "venomx " ++ version, tagline });
    try std.testing.expectEqualStrings(
        "━━━━━━  ━━━━━━\n" ++
            " ━━━━━  ━━━━━    venomx " ++ version ++ "\n" ++
            "  ━━━━  ━━━━     " ++ tagline ++ "\n" ++
            "   ━━━  ━━━\n" ++
            "    ━━  ━━\n" ++
            "      ●\n",
        w.buffered(),
    );
}

test "coloured fangs: scanlines in ansi-7, the drop in the edition signal" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const theme = @import("chrome_theme.zig");
    try write(&w, theme.chrome(.trve, .truecolor), &.{});
    const t = theme.resolve(.trve);
    var want: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&want, "\x1b[38;2;{d};{d};{d}m━\x1b[39m", .{ t.ansi[7][0], t.ansi[7][1], t.ansi[7][2] });
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), line));
    const drop_line = try std.fmt.bufPrint(&want, "\x1b[38;2;{d};{d};{d}m●\x1b[39m", .{ t.ember.rgb[0], t.ember.rgb[1], t.ember.rgb[2] });
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), drop_line) != null);
    // ANSI 16: palette index 7 for the lines.
    var w2: std.Io.Writer = .fixed(&buf);
    try write(&w2, theme.chrome(.trve, .ansi16), &.{});
    try std.testing.expect(std.mem.startsWith(u8, w2.buffered(), "\x1b[37m━\x1b[39m"));
}
