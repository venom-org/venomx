//! Vim-style copy mode, the keyboard counterpart of the mouse
//! selection. Client state only: a cursor over the
//! pane's rows, an optional char or line selection, and the motions that move
//! the cursor. The attach client owns the view; this module only moves points
//! over a `Grid` and says what the client should do next.
const std = @import("std");

pub const Point = struct { row: u64, col: u16 };
pub const Visual = enum { none, char, line };

/// The rows the cursor may visit, and how to read a cell's character.
pub const Grid = struct {
    ctx: *const anyopaque,
    cols: u16,
    /// First and last row the cursor may visit, inclusive.
    low: u64,
    high: u64,
    /// The rows shown, for `H`, `M`, `L` and the page motions.
    top: u64,
    height: u16,
    /// The first codepoint of a cell; ' ' for a blank cell. A wide
    /// character's spacer cell reads as a word character.
    charAt: *const fn (ctx: *const anyopaque, row: u64, col: u16) u21,
    fn at(g: Grid, p: Point) u21 {
        return g.charAt(g.ctx, p.row, p.col);
    }
    pub fn clamp(g: Grid, p: Point) Point {
        return .{ .row = std.math.clamp(p.row, g.low, @max(g.low, g.high)), .col = @min(p.col, g.cols -| 1) };
    }
    fn next(g: Grid, p: Point) ?Point {
        if (p.col + 1 < g.cols) return .{ .row = p.row, .col = p.col + 1 };
        if (p.row < g.high) return .{ .row = p.row + 1, .col = 0 };
        return null;
    }
    fn prev(g: Grid, p: Point) ?Point {
        if (p.col > 0) return .{ .row = p.row, .col = p.col - 1 };
        if (p.row > g.low) return .{ .row = p.row - 1, .col = g.cols -| 1 };
        return null;
    }
};

/// A key as copy mode reads it: the character it types (after Shift), or a
/// named key. `ctrl` is the Ctrl modifier on a character.
pub const Key = union(enum) {
    char: u21,
    ctrl: u21,
    left,
    right,
    up,
    down,
    page_up,
    page_down,
    home,
    end,
    escape,
    enter,
    backspace,
};

/// A search pattern, as codepoints.
pub const Pattern = struct {
    pub const max = 128;
    buf: [max]u21 = undefined,
    len: u8 = 0,
    pub fn slice(self: *const Pattern) []const u21 {
        return self.buf[0..self.len];
    }
    fn push(self: *Pattern, cp: u21) void {
        if (self.len == max) return;
        self.buf[self.len] = cp;
        self.len += 1;
    }
};
pub const Dir = enum {
    forward,
    backward,
    fn flip(d: Dir) Dir {
        return if (d == .forward) .backward else .forward;
    }
};

/// What the client does after a key.
pub const Action = enum {
    /// Redraw: the cursor or the selection may have moved.
    moved,
    /// Copy the selection to the clipboard and leave copy mode.
    yank,
    /// Leave copy mode without copying.
    exit,
    /// `{` / `}`: move to the previous / next OSC 133 prompt row.
    prompt_prev,
    prompt_next,
    /// A search found nothing; the cursor stays.
    not_found,
    /// Nothing happened.
    none,
};

pub const State = struct {
    /// The stream epoch the points belong to; a new epoch ends copy mode.
    epoch: u64,
    cursor: Point,
    visual: Visual = .none,
    anchor: Point = .{ .row = 0, .col = 0 },
    /// A typed count prefix (`5j`); 0 when none.
    count: u32 = 0,
    /// `g` was typed and waits for the second `g`.
    pending_g: bool = false,
    /// `/` or `?` was typed and the search line is being edited.
    editing: ?Dir = null,
    line: Pattern = .{},
    /// The last search, which `n` / `N` repeat and the client highlights.
    last: Pattern = .{},
    last_dir: Dir = .forward,

    /// The search line while it is edited, for the status row.
    pub fn searchLine(self: *const State) ?struct { Dir, []const u21 } {
        const dir = self.editing orelse return null;
        return .{ dir, self.line.slice() };
    }
    fn editKey(self: *State, g: Grid, dir: Dir, k: Key) Action {
        switch (k) {
            .escape => self.editing = null,
            .enter => {
                self.editing = null;
                // An empty line searches for the last pattern again, as vi does.
                if (self.line.len > 0) self.last = self.line;
                self.last_dir = dir;
                return self.search(g, dir, 1);
            },
            .backspace => if (self.line.len == 0) {
                self.editing = null;
            } else {
                self.line.len -= 1;
            },
            .ctrl => |ch| switch (ch) {
                'c' => self.editing = null,
                'u' => self.line.len = 0,
                else => return .none,
            },
            .char => |ch| self.line.push(ch),
            else => return .none,
        }
        return .moved;
    }
    fn search(self: *State, g: Grid, dir: Dir, n: u64) Action {
        if (self.last.len == 0) return .none;
        var at = self.cursor;
        for (0..n) |_| at = find(g, at, self.last.slice(), dir) orelse return .not_found;
        self.cursor = at;
        return .moved;
    }

    /// The selection the client draws and copies, as ordered points.
    pub fn selection(self: State, cols: u16) ?struct { Point, Point } {
        const a, const b = if (before(self.anchor, self.cursor)) .{ self.anchor, self.cursor } else .{ self.cursor, self.anchor };
        return switch (self.visual) {
            .none => null,
            .char => .{ a, b },
            .line => .{ .{ .row = a.row, .col = 0 }, .{ .row = b.row, .col = cols -| 1 } },
        };
    }

    pub fn key(self: *State, g: Grid, k: Key) Action {
        if (self.editing) |dir| return self.editKey(g, dir, k);
        const g_was = self.pending_g;
        self.pending_g = false;
        // Digits build a count; a leading `0` is the line-start motion.
        if (k == .char) if (k.char >= '0' and k.char <= '9') if (k.char != '0' or self.count > 0) {
            self.count = @min(self.count *| 10 +| (k.char - '0'), 100_000);
            return .none;
        };
        const counted = self.count > 0;
        const n: u64 = @max(self.count, 1);
        self.count = 0;
        const half: u64 = @max(g.height / 2, 1);
        const page: u64 = @max(g.height, 2) - 1;
        const c = self.cursor;
        switch (k) {
            .escape => {
                if (self.visual == .none) return .exit;
                self.visual = .none;
            },
            .enter => return if (self.visual != .none) .yank else .none,
            .backspace => return self.key(g, .left),
            .left => self.cursor.col = c.col -| @as(u16, @intCast(@min(n, c.col))),
            .right => self.cursor = g.clamp(.{ .row = c.row, .col = c.col +| @as(u16, @intCast(@min(n, g.cols))) }),
            .up => self.cursor = g.clamp(.{ .row = c.row -| n, .col = c.col }),
            .down => self.cursor = g.clamp(.{ .row = c.row +| n, .col = c.col }),
            .page_up => self.cursor = g.clamp(.{ .row = c.row -| page * n, .col = c.col }),
            .page_down => self.cursor = g.clamp(.{ .row = c.row +| page * n, .col = c.col }),
            .home => self.cursor.col = 0,
            .end => self.cursor.col = lastNonBlank(g, c.row),
            .ctrl => |ch| switch (ch) {
                'u' => self.cursor = g.clamp(.{ .row = c.row -| half * n, .col = c.col }),
                'd' => self.cursor = g.clamp(.{ .row = c.row +| half * n, .col = c.col }),
                'b' => self.cursor = g.clamp(.{ .row = c.row -| page * n, .col = c.col }),
                'f' => self.cursor = g.clamp(.{ .row = c.row +| page * n, .col = c.col }),
                'c' => return .exit,
                else => return .none,
            },
            .char => |ch| switch (ch) {
                // The vi letters are the arrows, count included.
                'h', 'l', ' ', 'k', 'j' => {
                    self.count = if (counted) @intCast(n) else 0;
                    return self.key(g, switch (ch) {
                        'h' => .left,
                        'k' => .up,
                        'j' => .down,
                        else => .right,
                    });
                },
                '0' => self.cursor.col = 0,
                '^' => self.cursor.col = firstNonBlank(g, c.row),
                '$' => self.cursor = g.clamp(.{ .row = c.row +| (n - 1), .col = 0 }),
                'w', 'W' => for (0..n) |_| {
                    self.cursor = wordForward(g, self.cursor, ch == 'W');
                },
                'b', 'B' => for (0..n) |_| {
                    self.cursor = wordBack(g, self.cursor, ch == 'B');
                },
                'e', 'E' => for (0..n) |_| {
                    self.cursor = wordEnd(g, self.cursor, ch == 'E');
                },
                'g' => {
                    if (!g_was) {
                        self.pending_g = true;
                        return .none;
                    }
                    self.cursor = g.clamp(.{ .row = if (counted) g.low + n - 1 else g.low, .col = 0 });
                },
                'G' => self.cursor = g.clamp(.{ .row = if (counted) g.low + n - 1 else g.high, .col = 0 }),
                'H' => self.cursor = g.clamp(.{ .row = g.top + (n - 1), .col = c.col }),
                'M' => self.cursor = g.clamp(.{ .row = g.top + g.height / 2, .col = c.col }),
                'L' => self.cursor = g.clamp(.{ .row = (g.top + g.height -| 1) -| (n - 1), .col = c.col }),
                '/', '?' => {
                    self.editing = if (ch == '/') .forward else .backward;
                    self.line.len = 0;
                },
                'n' => return self.search(g, self.last_dir, n),
                'N' => return self.search(g, self.last_dir.flip(), n),
                '{' => return .prompt_prev,
                '}' => return .prompt_next,
                'v', 'V' => {
                    const want: Visual = if (ch == 'v') .char else .line;
                    if (self.visual == want) {
                        self.visual = .none;
                    } else {
                        if (self.visual == .none) self.anchor = self.cursor;
                        self.visual = want;
                    }
                },
                'o' => if (self.visual != .none) std.mem.swap(Point, &self.anchor, &self.cursor),
                'y' => {
                    // `y` with nothing selected copies the cursor's line (`yy`).
                    if (self.visual == .none) {
                        self.anchor = self.cursor;
                        self.visual = .line;
                    }
                    return .yank;
                },
                'Y' => {
                    self.anchor = self.cursor;
                    self.visual = .line;
                    return .yank;
                },
                'q' => return .exit,
                else => return .none,
            },
        }
        // `$` ends on the last character of the line it lands on.
        if (k == .char and k.char == '$') self.cursor.col = lastNonBlank(g, self.cursor.row);
        return .moved;
    }
};

/// Smart case: a pattern with an uppercase letter matches case exactly.
fn exact(pat: []const u21) bool {
    for (pat) |cp| if (cp < 0x80 and std.ascii.isUpper(@intCast(cp))) return true;
    return false;
}
fn fold(cp: u21) u21 {
    return if (cp < 0x80) std.ascii.toLower(@intCast(cp)) else cp;
}
/// Whether `pat` starts at (`row`, `col`), within the row.
pub fn matchAt(g: Grid, pat: []const u21, row: u64, col: u16) bool {
    if (pat.len == 0 or @as(usize, col) + pat.len > g.cols) return false;
    const sensitive = exact(pat);
    for (pat, 0..) |want, i| {
        const got = g.at(.{ .row = row, .col = col + @as(u16, @intCast(i)) });
        if (if (sensitive) got != want else fold(got) != fold(want)) return false;
    }
    return true;
}
/// The next match start after `from` (`forward`) or before it, wrapping
/// around the grid's rows once; `from` itself is found last.
pub fn find(g: Grid, from: Point, pat: []const u21, dir: Dir) ?Point {
    if (pat.len == 0 or g.cols == 0 or g.high < g.low) return null;
    const total = g.high - g.low + 1;
    const start = std.math.clamp(from.row, g.low, g.high) - g.low;
    var i: u64 = 0;
    while (i <= total) : (i += 1) {
        const row = g.low + switch (dir) {
            .forward => (start + i) % total,
            .backward => (start + total - (i % total)) % total,
        };
        // The first row searches only past `from`; the wrapped-to last row
        // only up to and including it.
        switch (dir) {
            .forward => {
                var col: u32 = if (i == 0) @as(u32, from.col) + 1 else 0;
                const stop: u32 = if (i == total) from.col else g.cols - 1;
                while (col <= stop and col < g.cols) : (col += 1) if (matchAt(g, pat, row, @intCast(col))) return .{ .row = row, .col = @intCast(col) };
            },
            .backward => {
                if (i == 0 and from.col == 0) continue;
                var col: i32 = if (i == 0) @as(i32, from.col) - 1 else g.cols - 1;
                const stop: i32 = if (i == total) from.col else 0;
                while (col >= stop) : (col -= 1) if (matchAt(g, pat, row, @intCast(col))) return .{ .row = row, .col = @intCast(col) };
            },
        }
    }
    return null;
}

fn before(a: Point, b: Point) bool {
    return a.row < b.row or (a.row == b.row and a.col <= b.col);
}

/// vim's character classes: blank, word (letters, digits, `_`, non-ASCII)
/// and punctuation. With `big` (`W B E`) only blank and non-blank.
fn class(cp: u21, big: bool) u2 {
    if (cp == ' ' or cp == '\t' or cp == 0) return 0;
    if (big) return 1;
    if (cp >= 0x80 or cp == '_' or std.ascii.isAlphanumeric(@intCast(cp))) return 1;
    return 2;
}

fn wordForward(g: Grid, from: Point, big: bool) Point {
    var p = from;
    const start = class(g.at(p), big);
    if (start != 0) while (g.next(p)) |q| {
        p = q;
        if (class(g.at(p), big) != start) break;
    } else return p;
    while (class(g.at(p), big) == 0) p = g.next(p) orelse return p;
    return p;
}

fn wordEnd(g: Grid, from: Point, big: bool) Point {
    var p = g.next(from) orelse return from;
    while (class(g.at(p), big) == 0) p = g.next(p) orelse return p;
    const c = class(g.at(p), big);
    while (g.next(p)) |q| {
        if (class(g.at(q), big) != c) break;
        p = q;
    }
    return p;
}

fn wordBack(g: Grid, from: Point, big: bool) Point {
    var p = g.prev(from) orelse return from;
    while (class(g.at(p), big) == 0) p = g.prev(p) orelse return p;
    const c = class(g.at(p), big);
    while (g.prev(p)) |q| {
        if (class(g.at(q), big) != c) break;
        p = q;
    }
    return p;
}

fn firstNonBlank(g: Grid, row: u64) u16 {
    var col: u16 = 0;
    while (col < g.cols) : (col += 1) if (class(g.at(.{ .row = row, .col = col }), true) != 0) return col;
    return 0;
}

fn lastNonBlank(g: Grid, row: u64) u16 {
    var col: u16 = g.cols;
    while (col > 0) {
        col -= 1;
        if (class(g.at(.{ .row = row, .col = col }), true) != 0) return col;
    }
    return 0;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

const TextGrid = struct {
    lines: []const []const u8,
    fn charAt(ctx: *const anyopaque, row: u64, col: u16) u21 {
        const self: *const TextGrid = @ptrCast(@alignCast(ctx));
        if (row >= self.lines.len) return ' ';
        const line = self.lines[@intCast(row)];
        return if (col < line.len) line[col] else ' ';
    }
    fn grid(self: *const TextGrid, cols: u16, height: u16) Grid {
        return .{ .ctx = self, .cols = cols, .low = 0, .high = self.lines.len - 1, .top = 0, .height = height, .charAt = charAt };
    }
};

fn feed(s: *State, g: Grid, keys: []const u8) Action {
    var last: Action = .none;
    for (keys) |ch| last = s.key(g, .{ .char = ch });
    return last;
}

test "copy mode: h j k l, counts and clamping to the grid" {
    const t: TextGrid = .{ .lines = &.{ "one two", "three", "four" } };
    const g = t.grid(10, 3);
    var s: State = .{ .epoch = 1, .cursor = .{ .row = 0, .col = 0 } };
    _ = feed(&s, g, "3l");
    try testing.expectEqual(Point{ .row = 0, .col = 3 }, s.cursor);
    _ = feed(&s, g, "jj");
    try testing.expectEqual(Point{ .row = 2, .col = 3 }, s.cursor);
    _ = feed(&s, g, "9j");
    try testing.expectEqual(@as(u64, 2), s.cursor.row);
    _ = feed(&s, g, "20l");
    try testing.expectEqual(@as(u16, 9), s.cursor.col);
    _ = feed(&s, g, "20h");
    try testing.expectEqual(@as(u16, 0), s.cursor.col);
    _ = feed(&s, g, "kk");
    try testing.expectEqual(@as(u64, 0), s.cursor.row);
    _ = s.key(g, .down);
    try testing.expectEqual(@as(u64, 1), s.cursor.row);
}

test "copy mode: line motions 0 ^ $ and gg G H M L" {
    const t: TextGrid = .{ .lines = &.{ "  indented line  ", "x", "", "last" } };
    const g = t.grid(20, 4);
    var s: State = .{ .epoch = 1, .cursor = .{ .row = 0, .col = 5 } };
    _ = feed(&s, g, "^");
    try testing.expectEqual(@as(u16, 2), s.cursor.col);
    _ = feed(&s, g, "$");
    try testing.expectEqual(@as(u16, 14), s.cursor.col);
    _ = feed(&s, g, "0");
    try testing.expectEqual(@as(u16, 0), s.cursor.col);
    _ = feed(&s, g, "G");
    try testing.expectEqual(Point{ .row = 3, .col = 0 }, s.cursor);
    _ = feed(&s, g, "gg");
    try testing.expectEqual(Point{ .row = 0, .col = 0 }, s.cursor);
    _ = feed(&s, g, "2G");
    try testing.expectEqual(@as(u64, 1), s.cursor.row);
    _ = feed(&s, g, "L");
    try testing.expectEqual(@as(u64, 3), s.cursor.row);
    _ = feed(&s, g, "H");
    try testing.expectEqual(@as(u64, 0), s.cursor.row);
    _ = feed(&s, g, "M");
    try testing.expectEqual(@as(u64, 2), s.cursor.row);
    // A lone `g` waits; another key drops it.
    try testing.expectEqual(Action.none, feed(&s, g, "g"));
    _ = feed(&s, g, "j");
    try testing.expectEqual(@as(u64, 3), s.cursor.row);
}

test "copy mode: w b e and W B E cross punctuation and lines" {
    const t: TextGrid = .{ .lines = &.{ "foo.bar baz", "qux" } };
    const g = t.grid(12, 2);
    var s: State = .{ .epoch = 1, .cursor = .{ .row = 0, .col = 0 } };
    _ = feed(&s, g, "w");
    try testing.expectEqual(@as(u16, 3), s.cursor.col); // .
    _ = feed(&s, g, "w");
    try testing.expectEqual(@as(u16, 4), s.cursor.col); // bar
    _ = feed(&s, g, "w");
    try testing.expectEqual(@as(u16, 8), s.cursor.col); // baz
    _ = feed(&s, g, "w");
    try testing.expectEqual(Point{ .row = 1, .col = 0 }, s.cursor); // qux
    _ = feed(&s, g, "b");
    try testing.expectEqual(Point{ .row = 0, .col = 8 }, s.cursor);
    _ = feed(&s, g, "B");
    try testing.expectEqual(@as(u16, 0), s.cursor.col);
    _ = feed(&s, g, "E");
    try testing.expectEqual(@as(u16, 6), s.cursor.col);
    _ = feed(&s, g, "0e");
    try testing.expectEqual(@as(u16, 2), s.cursor.col);
    _ = feed(&s, g, "0W");
    try testing.expectEqual(@as(u16, 8), s.cursor.col);
}

test "copy mode: v and V select, o swaps ends, y yanks, esc clears then exits" {
    const t: TextGrid = .{ .lines = &.{ "hello world", "second" } };
    const g = t.grid(12, 2);
    var s: State = .{ .epoch = 1, .cursor = .{ .row = 0, .col = 0 } };
    try testing.expect(s.selection(12) == null);
    _ = feed(&s, g, "vw");
    const sel = s.selection(12).?;
    try testing.expectEqual(Point{ .row = 0, .col = 0 }, sel[0]);
    try testing.expectEqual(Point{ .row = 0, .col = 6 }, sel[1]);
    _ = feed(&s, g, "o");
    try testing.expectEqual(@as(u16, 0), s.cursor.col);
    _ = feed(&s, g, "Vj");
    const lines = s.selection(12).?;
    try testing.expectEqual(Point{ .row = 0, .col = 0 }, lines[0]);
    try testing.expectEqual(Point{ .row = 1, .col = 11 }, lines[1]);
    try testing.expectEqual(Action.yank, feed(&s, g, "y"));
    // Esc drops the selection first, then leaves.
    var e: State = .{ .epoch = 1, .cursor = .{ .row = 0, .col = 0 } };
    _ = feed(&e, g, "v");
    try testing.expectEqual(Action.moved, e.key(g, .escape));
    try testing.expectEqual(Visual.none, e.visual);
    try testing.expectEqual(Action.exit, e.key(g, .escape));
    try testing.expectEqual(Action.exit, feed(&e, g, "q"));
    // `y` with nothing selected yanks the cursor's line; enter needs a selection.
    var y: State = .{ .epoch = 1, .cursor = .{ .row = 1, .col = 3 } };
    try testing.expectEqual(Action.none, y.key(g, .enter));
    try testing.expectEqual(Action.yank, feed(&y, g, "y"));
    try testing.expectEqual(Point{ .row = 1, .col = 0 }, y.selection(12).?[0]);
}

fn typeLine(s: *State, g: Grid, text: []const u8) Action {
    for (text) |ch| _ = s.key(g, .{ .char = ch });
    return s.key(g, .enter);
}

test "/ and ? search with smart case, wrap around, n and N repeat" {
    const t: TextGrid = .{ .lines = &.{ "foo bar", "Bar baz", "x bar" } };
    const g = t.grid(10, 3);
    var s: State = .{ .epoch = 1, .cursor = .{ .row = 0, .col = 0 } };
    try testing.expectEqual(Action.moved, s.key(g, .{ .char = '/' }));
    try testing.expect(s.searchLine() != null);
    // Lowercase matches any case.
    try testing.expectEqual(Action.moved, typeLine(&s, g, "bar"));
    try testing.expect(s.searchLine() == null);
    try testing.expectEqual(Point{ .row = 0, .col = 4 }, s.cursor);
    _ = feed(&s, g, "n");
    try testing.expectEqual(Point{ .row = 1, .col = 0 }, s.cursor);
    _ = feed(&s, g, "2n");
    // Past "x bar" it wraps to the first row.
    try testing.expectEqual(Point{ .row = 0, .col = 4 }, s.cursor);
    _ = feed(&s, g, "N");
    try testing.expectEqual(Point{ .row = 2, .col = 2 }, s.cursor);
    // An uppercase letter makes it exact; ? searches backward.
    _ = s.key(g, .{ .char = '?' });
    try testing.expectEqual(Action.moved, typeLine(&s, g, "Bar"));
    try testing.expectEqual(Point{ .row = 1, .col = 0 }, s.cursor);
    _ = feed(&s, g, "n");
    try testing.expectEqual(Point{ .row = 1, .col = 0 }, s.cursor); // the only one
    _ = s.key(g, .{ .char = '/' });
    try testing.expectEqual(Action.not_found, typeLine(&s, g, "zzz"));
    try testing.expectEqual(Point{ .row = 1, .col = 0 }, s.cursor);
    // Editing: backspace, esc cancels, backspace on an empty line leaves it.
    _ = s.key(g, .{ .char = '/' });
    _ = feed(&s, g, "bq");
    _ = s.key(g, .backspace);
    try testing.expectEqual(@as(u8, 1), s.searchLine().?[1].len);
    _ = s.key(g, .escape);
    try testing.expect(s.searchLine() == null);
    _ = s.key(g, .{ .char = '/' });
    _ = s.key(g, .backspace);
    try testing.expect(s.searchLine() == null);
    // Keys typed into the line are not motions; `q` is text there.
    _ = s.key(g, .{ .char = '/' });
    try testing.expectEqual(Action.moved, s.key(g, .{ .char = 'q' }));
    _ = s.key(g, .escape);
    // An empty line repeats the last search.
    _ = s.key(g, .{ .char = '/' });
    _ = typeLine(&s, g, "Bar");
    s.cursor = .{ .row = 0, .col = 0 };
    _ = s.key(g, .{ .char = '/' });
    _ = s.key(g, .enter);
    try testing.expectEqual(Point{ .row = 1, .col = 0 }, s.cursor);
}
