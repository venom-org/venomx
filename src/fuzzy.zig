//! Fuzzy matching for the `all-keys` list: a query matches a text
//! when each of its space-separated terms is a case-insensitive subsequence
//! of the text. Higher scores rank first: consecutive characters, word starts
//! and an early first match count for a term, gaps against it.
const std = @import("std");

const per_char = 16;
const consecutive = 24;
const word_start = 32;
const gap = 3;
const max_lead = 15;

/// Null when `query` does not match `text`; 0 for an empty query.
pub fn score(text: []const u8, query: []const u8) ?i32 {
    return scoreFields(&.{text}, query);
}
/// Like `score`, but each term may match in any one of `fields`; it counts
/// where it scores best.
pub fn scoreFields(fields: []const []const u8, query: []const u8) ?i32 {
    var total: i32 = 0;
    var terms = std.mem.tokenizeScalar(u8, query, ' ');
    while (terms.next()) |term| {
        var best: ?i32 = null;
        for (fields) |f| if (termScore(f, term)) |s| {
            best = if (best) |b| @max(b, s) else s;
        };
        total += best orelse return null;
    }
    return total;
}

fn lower(c: u8) u8 {
    return std.ascii.toLower(c);
}
fn boundary(text: []const u8, i: usize) bool {
    if (i == 0) return true;
    const prev = text[i - 1];
    return !std.ascii.isAlphanumeric(prev) and prev < 0x80;
}

/// The leftmost end of a match, then the latest start that still reaches it
/// (the tightest window), scored over its positions.
fn termScore(text: []const u8, term: []const u8) ?i32 {
    if (term.len == 0) return 0;
    var t: usize = 0;
    var end: usize = 0;
    for (text, 0..) |c, i| {
        if (lower(c) == lower(term[t])) {
            t += 1;
            if (t == term.len) {
                end = i;
                break;
            }
        }
    } else return null;
    var start = end;
    var q = term.len;
    var i = end + 1;
    while (i > 0) {
        i -= 1;
        if (lower(text[i]) == lower(term[q - 1])) {
            q -= 1;
            if (q == 0) {
                start = i;
                break;
            }
        }
    }
    // Score the window left to right, matching greedily from `start`.
    var s: i32 = 0;
    var k: usize = 0;
    var last: ?usize = null;
    for (start..end + 1) |j| {
        if (k == term.len) break;
        if (lower(text[j]) != lower(term[k])) continue;
        s += per_char;
        if (boundary(text, j)) s += word_start;
        if (last) |l| {
            if (j == l + 1) s += consecutive else s -= gap * @as(i32, @intCast(@min(j - l - 1, 10)));
        }
        last = j;
        k += 1;
    }
    s -= @intCast(@min(start, max_lead));
    return s;
}

const testing = std.testing;

test "empty query matches everything with 0" {
    try testing.expectEqual(@as(?i32, 0), score("anything", ""));
    try testing.expectEqual(@as(?i32, 0), score("", "  "));
}
test "a term must be a subsequence, ignoring ASCII case" {
    try testing.expect(score("resize left", "rzl") != null);
    try testing.expect(score("Resize Left", "RESIZE") != null);
    try testing.expect(score("resize left", "lr") == null);
    try testing.expect(score("", "a") == null);
}
test "every space-separated term must match" {
    try testing.expect(score("r h  resize › resize-left", "r left") != null);
    try testing.expect(score("r h  resize › resize-left", "r qq") == null);
}
test "terms may match in different fields, a term within one field" {
    try testing.expect(scoreFields(&.{ "r h", "resize › resize-left" }, "rh left") != null);
    try testing.expect(scoreFields(&.{ "r h", "left" }, "hl") == null);
}
test "consecutive and word-start matches rank first" {
    const tight = score("split-right", "split").?;
    const loose = score("send-pane-list-input-text", "split").?;
    try testing.expect(tight > loose);
    const start = score("focus left", "le").?;
    const inside = score("toggle", "le").?;
    try testing.expect(start > inside);
}
test "the tightest window is scored" {
    // `d` alone at the end beats the scattered `d…e…t` reading.
    try testing.expect(score("d  detach", "det").? > score("dxxexxt", "det").?);
}
