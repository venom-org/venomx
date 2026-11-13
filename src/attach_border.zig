//! Pane borders in tmux's `pane-border-status
//! top` model. A pane has no box: its title sits on the line above it, which
//! is the separator between it and the pane above, or the window's title row
//! for a top-row pane. Vertical separators are one cell and carry no title.
//! Free of App state so it can be tested on a bare surface.
const std = @import("std");
const term = @import("venom-term");
const text_width = term.widgets.text;
const geometry = @import("attach_layout.zig");
const Surface = term.Surface;
const Style = term.Style;
const Rect = geometry.Rect;

/// What the host terminal can draw (heavy lines are
/// optional, the fang `◤` has a fallback). `doctor` reports the same answer.
pub const Support = struct {
    heavy: bool = true,
    fang: bool = true,

    pub const heavy_fallback = "light lines in the signal colour";
    pub const fang_fallback = "/";

    /// A Linux console, a dumb terminal or an explicit non-UTF-8 locale
    /// cannot draw box lines beyond ASCII or the triangle. An unset locale
    /// is assumed to be fine.
    pub fn detect(term_name: ?[]const u8, lc_all: ?[]const u8, lc_ctype: ?[]const u8, lang: ?[]const u8) Support {
        var ok = true;
        if (term_name) |t| {
            const vt_digit = t.len > 2 and std.mem.startsWith(u8, t, "vt") and std.ascii.isDigit(t[2]);
            if (std.mem.eql(u8, t, "linux") or std.mem.eql(u8, t, "dumb") or vt_digit) ok = false;
        }
        const locale = for ([_]?[]const u8{ lc_all, lc_ctype, lang }) |v| {
            if (v) |s| if (s.len > 0) break s;
        } else null;
        if (locale) |l| if (!utf8Locale(l)) {
            ok = false;
        };
        return .{ .heavy = ok, .fang = ok };
    }
    pub fn fangCut(self: Support) []const u8 {
        return if (self.fang) "◤" else fang_fallback;
    }
};
fn utf8Locale(l: []const u8) bool {
    var buf: [64]u8 = undefined;
    const n = @min(l.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], l[0..n]);
    return std.mem.indexOf(u8, lower, "utf-8") != null or std.mem.indexOf(u8, lower, "utf8") != null;
}

/// How a border is drawn, weakest first: the highest of the panes sharing a
/// cell wins (focused, else `urgent`, else `rule`).
pub const Look = enum { rule, urgent, focus };

pub const Mark = struct { glyph: []const u8, style: Style };

/// One pane's title line.
pub const Line = struct {
    /// The pane's rectangle; its title line is the row above.
    rect: Rect,
    title: []const u8 = "",
    /// The `group` tag, or the cwd.
    tag: []const u8 = "",
    mark: ?Mark = null,
    look: Look = .rule,
};

pub const Styles = struct {
    rule: Style,
    urgent: Style,
    focus: Style,
    title: Style,
    title_focus: Style,
    tag: Style,
};

pub const Input = struct {
    lines: []const Line,
    separators: []const geometry.Separator = &.{},
    /// The window's title row (a full-width rectangle of height 1), null for
    /// a lone pane.
    title_row: ?Rect = null,
    styles: Styles,
    support: Support = .{},
};

fn contains(r: Rect, x: i32, y: i32) bool {
    return x >= r.x and y >= r.y and x < @as(i32, r.x) + r.width and y < @as(i32, r.y) + r.height;
}
fn isV(in: Input, x: i32, y: i32) bool {
    for (in.separators) |s| if (s.vertical and contains(s.rect, x, y)) return true;
    return false;
}
fn isH(in: Input, x: i32, y: i32) bool {
    if (in.title_row) |t| if (contains(t, x, y)) return true;
    for (in.separators) |s| if (!s.vertical and contains(s.rect, x, y)) return true;
    return false;
}
fn lookAt(in: Input, x: i32, y: i32) Look {
    for (in.lines) |l| if (contains(l.rect, x, y)) return l.look;
    return .rule;
}
fn maxLook(a: Look, b: Look) Look {
    return if (@backingInt(a) >= @backingInt(b)) a else b;
}
/// A border cell belongs to the pane it is the title line of; a vertical
/// cell is shared by the panes on either side.
fn cellLook(in: Input, x: i32, y: i32) Look {
    if (isV(in, x, y)) return maxLook(lookAt(in, x - 1, y), lookAt(in, x + 1, y));
    if (isV(in, x, y + 1)) return maxLook(lookAt(in, x - 1, y + 1), lookAt(in, x + 1, y + 1));
    return lookAt(in, x, y + 1);
}

const light = [16][]const u8{ " ", "│", "│", "│", "─", "┘", "┐", "┤", "─", "└", "┌", "├", "─", "┴", "┬", "┼" };
const heavy = [16][]const u8{ " ", "┃", "┃", "┃", "━", "┛", "┓", "┫", "━", "┗", "┏", "┣", "━", "┻", "┳", "╋" };

fn styleOf(in: Input, look: Look) Style {
    return switch (look) {
        .rule => in.styles.rule,
        .urgent => in.styles.urgent,
        .focus => in.styles.focus,
    };
}
fn lineCell(in: Input, surface: *Surface, x: i32, y: i32, vertical: bool) !void {
    const look = cellLook(in, x, y);
    var mask: u4 = 0;
    if (vertical) {
        if (isV(in, x, y - 1) or isH(in, x, y - 1)) mask |= 1;
        if (isV(in, x, y + 1) or isH(in, x, y + 1)) mask |= 2;
        // A vertical cell with no vertical neighbours is still a vertical line.
        if (mask == 0) mask = 3;
    } else {
        if (isV(in, x, y - 1)) mask |= 1;
        if (isV(in, x, y + 1)) mask |= 2;
        if (isH(in, x - 1, y)) mask |= 4;
        if (isH(in, x + 1, y)) mask |= 8;
        if (mask & 12 == 0) mask |= 12;
    }
    if (vertical) {
        if (isH(in, x - 1, y)) mask |= 4;
        if (isH(in, x + 1, y)) mask |= 8;
    }
    // A junction takes the strongest look of the panes it touches, and a
    // cell has one colour: an arm toward a weaker line would carry that look
    // half a cell into it. Drop such an arm: `┳` becomes `┓`.
    if (mask & 3 != 0 and mask & 12 != 0) {
        const Arm = struct { bit: u4, dx: i32, dy: i32 };
        const arms = [_]Arm{ .{ .bit = 1, .dx = 0, .dy = -1 }, .{ .bit = 2, .dx = 0, .dy = 1 }, .{ .bit = 4, .dx = -1, .dy = 0 }, .{ .bit = 8, .dx = 1, .dy = 0 } };
        for (arms) |a| {
            const nx = x + a.dx;
            const ny = y + a.dy;
            if (mask & a.bit == 0 or !(isV(in, nx, ny) or isH(in, nx, ny))) continue;
            if (@backingInt(cellLook(in, nx, ny)) < @backingInt(look)) mask &= ~a.bit;
        }
    }
    const set = if (look == .focus and in.support.heavy) &heavy else &light;
    try surface.put(@intCast(x), @intCast(y), .{ .text = set[mask], .style = styleOf(in, look) });
}

/// Draws separators, junctions, the title row and every title line. Panes
/// are drawn by the caller.
pub fn draw(surface: *Surface, in: Input) !void {
    if (in.title_row) |t| for (0..t.width) |dx| try lineCell(in, surface, t.x + @as(i32, @intCast(dx)), t.y, false);
    for (in.separators) |s| {
        const r = s.rect;
        for (0..r.height) |dy| for (0..r.width) |dx| try lineCell(in, surface, r.x + @as(i32, @intCast(dx)), r.y + @as(i32, @intCast(dy)), s.vertical);
        // Where the line above or below a vertical separator is a horizontal
        // line, the cell there is a junction.
        if (s.vertical and r.width > 0 and r.height > 0) {
            for ([_]i32{ @as(i32, r.y) - 1, @as(i32, r.y) + r.height }) |y| {
                if (isH(in, r.x, y) and !isV(in, r.x, y)) try lineCell(in, surface, r.x, y, false);
            }
        }
    }
    for (in.lines) |l| try title(surface, in, l);
}

/// The display width of `s` in cells, by grapheme (venom-term's text widths).
pub fn cells(s: []const u8) usize {
    return text_width.width(s);
}
/// The longest prefix of `s` that fits in `limit` cells, cut between graphemes.
pub fn cutCells(s: []const u8, limit: usize) []const u8 {
    var n: usize = 0;
    var end: usize = 0;
    while (end < s.len) {
        const next = text_width.nextGrapheme(s, end);
        const w = text_width.graphemeWidth(s[end..next]);
        if (n + w > limit) break;
        n += w;
        end = next;
    }
    return s[0..end];
}
/// Bidi marks, embeddings, overrides and isolates, and the other invisible
/// format characters (zero-width space, line and paragraph separators, word
/// joiner and invisible operators, deprecated format characters, soft hyphen,
/// combining grapheme joiner, Mongolian vowel separator, Hangul fillers, BOM,
/// interlinear annotations, tags and variation selectors supplement). U+200C
/// and U+200D stay: Persian and Indic scripts and emoji ZWJ sequences need them.
fn isInvisible(c: u21) bool {
    return c == 0x00ad or c == 0x034f or c == 0x061c or c == 0x115f or c == 0x1160 or c == 0x17b4 or c == 0x17b5 or c == 0x180e or c == 0x2800 or c == 0xffa0 or (c >= 0x1d173 and c <= 0x1d17a) or c == 0x200b or c == 0x200e or c == 0x200f or
        (c >= 0x2028 and c <= 0x202e) or (c >= 0x2060 and c <= 0x2064) or (c >= 0x2066 and c <= 0x206f) or c == 0x3164 or c == 0xfeff or
        (c >= 0xfff9 and c <= 0xfffb) or (c >= 0xe0000 and c <= 0xe007f) or (c >= 0xe0100 and c <= 0xe01ef);
}
/// Drops control characters (C0, DEL and C1), U+00A0, the invisible and bidi
/// characters of `isInvisible` and each byte that is not
/// valid UTF-8: a title is program-controlled, and one bad byte must not blank
/// the rest.
pub fn clean(buf: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > s.len) {
            i += 1;
            continue;
        }
        const cp = s[i..][0..len];
        const c = std.unicode.utf8Decode(cp) catch {
            i += 1;
            continue;
        };
        i += len;
        if (c < 0x20 or c == 0x7f or (c >= 0x80 and c <= 0x9f) or c == 0xa0 or isInvisible(c)) continue;
        if (n + cp.len > buf.len) break;
        @memcpy(buf[n..][0..cp.len], cp);
        n += cp.len;
    }
    return buf[0..n];
}

/// What of a title line fits in `width` cells, in this
/// drop order: the right part, then the title (cut with `…`, then dropped),
/// then the leading line cell and its space. The mark always stays. A line
/// shows no pane ID.
pub const Fit = struct { lead: bool, title: usize, ellipsis: bool, tag: bool, mark: bool };
pub fn fit(width: usize, title_w: usize, tag_w: usize, has_mark: bool) Fit {
    var f: Fit = .{ .lead = title_w > 0 or has_mark, .title = 0, .ellipsis = false, .tag = false, .mark = has_mark };
    if (!f.lead) return f;
    const lead_w: usize = 2;
    // " ▲" after the title takes two cells, the mark alone one.
    const mark_w: usize = if (!has_mark) 0 else if (title_w > 0) 2 else 1;
    if (lead_w + title_w + mark_w <= width) {
        f.title = title_w;
        const left = lead_w + title_w + mark_w;
        // " tag ─": a space, the tag, a space and a line cell.
        if (tag_w > 0 and left + 1 + tag_w + 2 <= width) f.tag = true;
        return f;
    }
    if (title_w > 0) {
        // Room for at least one character plus `…`, then " ▲".
        const after: usize = if (has_mark) 2 else 0;
        if (width >= lead_w + after + 2) {
            f.title = width - lead_w - after - 1;
            f.ellipsis = true;
            return f;
        }
    }
    if (lead_w + @as(usize, @intFromBool(has_mark)) <= width) return f;
    f.lead = false;
    return f;
}

fn title(surface: *Surface, in: Input, l: Line) !void {
    if (l.rect.width == 0 or l.rect.height == 0 or l.rect.y == 0) return;
    const y = l.rect.y - 1;
    const w: usize = l.rect.width;
    var tbuf: [256]u8 = undefined;
    const t = clean(&tbuf, l.title);
    var gbuf: [1024]u8 = undefined;
    const tag = clean(&gbuf, l.tag);
    const f = fit(w, cells(t), cells(tag), l.mark != null);
    const focus = l.look == .focus;
    const line = styleOf(in, l.look);
    var x: u16 = l.rect.x;
    const right = l.rect.x + l.rect.width;
    if (f.lead) {
        try surface.text(.{ .x = l.rect.x + 1, .y = y, .width = 1, .height = 1 }, " ", line);
        x +|= 2;
    }
    const start = x;
    if (f.title > 0 or f.ellipsis) {
        const shown = cutCells(t, f.title);
        const ts = if (focus) in.styles.title_focus else in.styles.title;
        try surface.text(.{ .x = x, .y = y, .width = right - x, .height = 1 }, shown, ts);
        x +|= @intCast(cells(shown));
        if (f.ellipsis) {
            try surface.text(.{ .x = x, .y = y, .width = right - x, .height = 1 }, "…", ts);
            x +|= 1;
        }
    }
    if (l.mark) |m| if (x < right) {
        if (x > start) {
            try surface.text(.{ .x = x, .y = y, .width = right - x, .height = 1 }, " ", line);
            x +|= 1;
        }
        try surface.text(.{ .x = x, .y = y, .width = right - x, .height = 1 }, m.glyph, m.style);
        x +|= 1;
    };
    // A drawn piece is followed by one space in the line's style.
    if (x > start and x < right) {
        try surface.text(.{ .x = x, .y = y, .width = right - x, .height = 1 }, " ", line);
        x +|= 1;
    }
    if (f.tag) {
        const tw: u16 = @intCast(cells(tag));
        // The tag sits at the right with one line cell after it.
        const at = right - 1 - 1 - tw;
        if (at > x) {
            try surface.text(.{ .x = at - 1, .y = y, .width = 1, .height = 1 }, " ", line);
            try surface.text(.{ .x = at, .y = y, .width = tw, .height = 1 }, tag, in.styles.tag);
            try surface.text(.{ .x = at + tw, .y = y, .width = 1, .height = 1 }, " ", line);
        }
    }
}

fn testStyles() Styles {
    return .{
        .rule = .{ .fg = .{ .index = 8 } },
        .urgent = .{ .fg = .{ .index = 3 } },
        .focus = .{ .fg = .{ .index = 11 } },
        .title = .{},
        .title_focus = .{ .bold = true },
        .tag = .{},
    };
}
fn rowText(a: std.mem.Allocator, s: *const Surface, y: u16) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (0..s.width) |x| {
        const t = s.get(@intCast(x), y).?.text;
        try out.appendSlice(a, if (t.len == 0) " " else t);
    }
    return out.toOwnedSlice(a);
}

test "fit drops the right part, the title, then the lead cell; the mark stays" {
    const t = std.testing;
    // Everything: "─ codex ▲ " + " git ─"
    var f = fit(40, 5, 3, true);
    try t.expect(f.lead and f.tag and f.title == 5 and !f.ellipsis);
    // No room for the tag.
    f = fit(11, 5, 3, true);
    try t.expect(f.lead and !f.tag and f.title == 5);
    // The title is cut with an ellipsis.
    f = fit(8, 9, 0, true);
    try t.expect(f.lead and f.ellipsis and f.title == 3);
    // The title is dropped.
    f = fit(5, 9, 0, true);
    try t.expect(f.lead and f.title == 0 and !f.ellipsis);
    // The lead cell is dropped; the mark stays.
    f = fit(2, 9, 0, true);
    try t.expect(!f.lead and f.title == 0 and f.mark);
    f = fit(1, 3, 0, true);
    try t.expect(!f.lead and f.mark);
    // Nothing to show: no lead either.
    f = fit(10, 0, 0, false);
    try t.expect(!f.lead);
}

test "support detection" {
    const t = std.testing;
    try t.expect(Support.detect("xterm-256color", null, null, "en_US.UTF-8").heavy);
    try t.expect(Support.detect("xterm", null, null, null).heavy);
    try t.expect(!Support.detect("linux", null, null, "en_US.UTF-8").heavy);
    try t.expect(!Support.detect("xterm", null, null, "C").fang);
    try t.expect(!Support.detect("xterm", "POSIX", null, "en_US.UTF-8").heavy);
    try t.expect(Support.detect("xterm", "", null, "en_US.utf8").heavy);
}

test "two panes: titles on the title row, one separator, junction on top" {
    const a = std.testing.allocator;
    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();
    var s = try Surface.init(a, 21, 5);
    defer s.deinit(&sink.writer);
    const lines = [_]Line{
        .{ .rect = .{ .x = 0, .y = 1, .width = 10, .height = 4 }, .title = "zsh", .look = .focus, .mark = .{ .glyph = "●", .style = .{} } },
        .{ .rect = .{ .x = 11, .y = 1, .width = 10, .height = 4 }, .title = "vim", .look = .rule },
    };
    const seps = [_]geometry.Separator{.{ .rect = .{ .x = 10, .y = 1, .width = 1, .height = 4 }, .vertical = true }};
    try draw(&s, .{ .lines = &lines, .separators = &seps, .title_row = .{ .x = 0, .y = 0, .width = 21, .height = 1 }, .styles = testStyles() });
    const top = try rowText(a, &s, 0);
    defer a.free(top);
    // The junction has no arm into p1's weaker line.
    try std.testing.expectEqualStrings("━ zsh ● ━━┓─ vim ────", top);
    const mid = try rowText(a, &s, 2);
    defer a.free(mid);
    try std.testing.expectEqualStrings("          ┃          ", mid);
    // The focused pane's separator is heavy and in the signal.
    try std.testing.expectEqual(Style{ .fg = .{ .index = 11 } }, s.get(10, 2).?.style);
}

test "a nested split: junctions on the separators between panes" {
    const a = std.testing.allocator;
    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();
    var s = try Surface.init(a, 21, 8);
    defer s.deinit(&sink.writer);
    // p0 left; p1 top right; p2 bottom right (title on the horizontal separator).
    const lines = [_]Line{
        .{ .rect = .{ .x = 0, .y = 1, .width = 10, .height = 7 }, .title = "zsh" },
        .{ .rect = .{ .x = 11, .y = 1, .width = 10, .height = 3 }, .title = "vim" },
        .{ .rect = .{ .x = 11, .y = 5, .width = 10, .height = 3 }, .title = "git", .look = .urgent },
    };
    const seps = [_]geometry.Separator{
        .{ .rect = .{ .x = 10, .y = 1, .width = 1, .height = 7 }, .vertical = true },
        .{ .rect = .{ .x = 11, .y = 4, .width = 10, .height = 1 }, .vertical = false },
    };
    try draw(&s, .{ .lines = &lines, .separators = &seps, .title_row = .{ .x = 0, .y = 0, .width = 21, .height = 1 }, .styles = testStyles(), .support = .{ .heavy = false } });
    const top = try rowText(a, &s, 0);
    defer a.free(top);
    try std.testing.expectEqualStrings("─ zsh ────┬─ vim ────", top);
    const sep = try rowText(a, &s, 4);
    defer a.free(sep);
    try std.testing.expectEqualStrings("          ├─ git ────", sep);
    // The urgent pane's title line is in warn.
    try std.testing.expectEqual(Style{ .fg = .{ .index = 3 } }, s.get(17, 4).?.style);
}

test "a focused junction has no arm into a weaker line" {
    const a = std.testing.allocator;
    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();
    var s = try Surface.init(a, 21, 8);
    defer s.deinit(&sink.writer);
    // p0 left, focused; p1 top right; p2 bottom right.
    var lines = [_]Line{
        .{ .rect = .{ .x = 0, .y = 1, .width = 10, .height = 7 }, .title = "zsh", .look = .focus },
        .{ .rect = .{ .x = 11, .y = 1, .width = 10, .height = 3 }, .title = "vim" },
        .{ .rect = .{ .x = 11, .y = 5, .width = 10, .height = 3 }, .title = "git" },
    };
    const seps = [_]geometry.Separator{
        .{ .rect = .{ .x = 10, .y = 1, .width = 1, .height = 7 }, .vertical = true },
        .{ .rect = .{ .x = 11, .y = 4, .width = 10, .height = 1 }, .vertical = false },
    };
    try draw(&s, .{ .lines = &lines, .separators = &seps, .title_row = .{ .x = 0, .y = 0, .width = 21, .height = 1 }, .styles = testStyles() });
    try std.testing.expectEqualStrings("┓", s.get(10, 0).?.text);
    // The vertical stays whole where p2's line meets it.
    try std.testing.expectEqualStrings("┃", s.get(10, 4).?.text);

    // Focus on the right: the junction turns the other way.
    lines[0].look = .rule;
    lines[1].look = .focus;
    try draw(&s, .{ .lines = &lines, .separators = &seps, .title_row = .{ .x = 0, .y = 0, .width = 21, .height = 1 }, .styles = testStyles() });
    try std.testing.expectEqualStrings("┏", s.get(10, 0).?.text);
    try std.testing.expectEqual(Style{ .fg = .{ .index = 11 } }, s.get(10, 0).?.style);
    // Equal looks keep the full junction.
    lines[1].look = .rule;
    try draw(&s, .{ .lines = &lines, .separators = &seps, .title_row = .{ .x = 0, .y = 0, .width = 21, .height = 1 }, .styles = testStyles() });
    try std.testing.expectEqualStrings("┬", s.get(10, 0).?.text);
    try std.testing.expectEqualStrings("├", s.get(10, 4).?.text);
}

test "a one-column pane shows only its mark" {
    const a = std.testing.allocator;
    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();
    var s = try Surface.init(a, 5, 3);
    defer s.deinit(&sink.writer);
    const lines = [_]Line{.{ .rect = .{ .x = 0, .y = 1, .width = 1, .height = 2 }, .title = "zsh", .mark = .{ .glyph = "▲", .style = .{} } }};
    try draw(&s, .{ .lines = &lines, .title_row = .{ .x = 0, .y = 0, .width = 5, .height = 1 }, .styles = testStyles() });
    try std.testing.expectEqualStrings("▲", s.get(0, 0).?.text);
}

test "clean drops only the bad bytes and the invisible characters" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("ab", clean(&buf, "a\xe9b"));
    try t.expectEqualStrings("ab", clean(&buf, "a\xffb"));
    try t.expectEqualStrings("ab", clean(&buf, "ab\xe2\x82"));
    try t.expectEqualStrings("ab", clean(&buf, "a\u{200b}\u{2028}\u{2029}\u{2060}\u{2064}\u{feff}\u{fff9}\u{e0041}b"));
    try t.expectEqualStrings("ab", clean(&buf, "a\u{202e}\u{2066}\u{61c}b"));
    try t.expectEqualStrings("ab", clean(&buf, "a\u{206a}\u{206f}\u{ad}\u{34f}\u{180e}\u{115f}\u{1160}\u{3164}\u{e0100}\u{e01ef}b"));
    // ZWNJ and ZWJ stay, for Persian, Indic scripts and emoji sequences.
    try t.expectEqualStrings("a\u{200c}b\u{200d}c", clean(&buf, "a\u{200c}b\u{200d}c"));
    try t.expectEqualStrings("é€λ", clean(&buf, "é€λ"));
}
