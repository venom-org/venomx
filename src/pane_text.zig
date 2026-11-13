//! The pane title line's right part when a pane has no `group` tag: the
//! working directory its program reports. The client
//! reads it from the pane's own output (`Vt.pwd`, the raw OSC 7 URI or a bare
//! path), so it is untrusted text; control and bidi characters are removed
//! where the line is drawn (`attach_border.clean`).
const std = @import("std");
const border = @import("attach_border.zig");

/// A reported working directory: the URI host (empty for a bare path) and the
/// percent-decoded path.
pub const Cwd = struct { host: []const u8, path: []const u8 };

/// `raw` as `Vt.pwd` returns it. A `file://host/path` URI is split and its path percent-decoded into `buf`
/// (at least `raw.len` bytes); a `kitty-shell-cwd://` path is taken verbatim
/// (kitty sends it unencoded, so no percent-decoding and no `?`/`#` cut). A string that starts with `/` is a bare path,
/// used as is. Anything else (another scheme, a relative path) has no cwd.
pub fn parseCwd(raw: []const u8, buf: []u8) ?Cwd {
    const schemes = [_][]const u8{ "file://", "kitty-shell-cwd://" };
    const scheme = for (schemes) |sc| {
        if (std.ascii.startsWithIgnoreCase(raw, sc)) break sc;
    } else return if (raw.len > 0 and raw[0] == '/') .{ .host = "", .path = raw } else null;
    const rest = raw[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    var encoded = rest[slash..];
    if (std.mem.eql(u8, scheme, "kitty-shell-cwd://")) {
        const n = @min(encoded.len, buf.len);
        @memcpy(buf[0..n], encoded[0..n]);
        return .{ .host = rest[0..slash], .path = buf[0..n] };
    }
    if (std.mem.indexOfAny(u8, encoded, "?#")) |end| encoded = encoded[0..end];
    var n: usize = 0;
    var i: usize = 0;
    while (i < encoded.len and n < buf.len) : (n += 1) {
        if (encoded[i] == '%' and i + 2 < encoded.len and hex(encoded[i + 1]) != null and hex(encoded[i + 2]) != null) {
            buf[n] = hex(encoded[i + 1]).? << 4 | hex(encoded[i + 2]).?;
            i += 3;
        } else {
            buf[n] = encoded[i];
            i += 1;
        }
    }
    return .{ .host = rest[0..slash], .path = buf[0..n] };
}

fn hex(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

/// `~` shortening, only for a local host (empty, `localhost` or the local
/// hostname) and a path equal to `home` or under `home` followed by `/`.
pub fn display(a: std.mem.Allocator, cwd: Cwd, home: []const u8, local_host: []const u8) ![]u8 {
    const local = cwd.host.len == 0 or std.ascii.eqlIgnoreCase(cwd.host, "localhost") or (local_host.len > 0 and std.ascii.eqlIgnoreCase(cwd.host, local_host));
    // One trailing slash of $HOME is not part of the boundary.
    const base = if (home.len > 1 and home[home.len - 1] == '/') home[0 .. home.len - 1] else home;
    if (local and base.len > 1 and std.mem.startsWith(u8, cwd.path, base)) {
        // The border drops invisible characters, so `.<ZWSP>.` would draw as
        // `..`: look for dot segments in what is drawn.
        const drawn = try a.alloc(u8, cwd.path.len);
        defer a.free(drawn);
        if (!dotSegment(border.clean(drawn, cwd.path))) {
            const tail = cwd.path[base.len..];
            if (tail.len == 0 or tail[0] == '/') return std.fmt.allocPrint(a, "~{s}", .{tail});
        }
    }
    return a.dupe(u8, cwd.path);
}

/// A `.` or `..` segment would make `~/..` name something outside $HOME. Zero
/// width code points (ZWNJ, ZWJ, variation selectors, combining marks) draw as
/// nothing, so a segment of dots and those counts too.
fn dotSegment(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        var dots: usize = 0;
        var cps = std.unicode.Utf8View.initUnchecked(seg).iterator();
        const only_dots = while (cps.nextCodepoint()) |cp| {
            if (cp == '.') dots += 1 else if (!zeroWidth(cp)) break false;
        } else true;
        if (only_dots and (dots == 1 or dots == 2)) return true;
    }
    return false;
}

fn zeroWidth(cp: u21) bool {
    return cp == 0x200c or cp == 0x200d or (cp >= 0xfe00 and cp <= 0xfe0f) or (cp >= 0x300 and cp <= 0x36f);
}

/// The right part for `raw` (`Vt.pwd`'s result), allocated from `a`; empty when
/// unset. The caller owns the result, which no longer borrows from the Vt.
pub fn rightPart(a: std.mem.Allocator, raw: ?[]const u8, home: []const u8, local_host: []const u8) ![]u8 {
    const r = raw orelse return a.alloc(u8, 0);
    const buf = try a.alloc(u8, r.len);
    defer a.free(buf);
    const cwd = parseCwd(r, buf) orelse return a.alloc(u8, 0);
    return display(a, cwd, home, local_host);
}

const t = std.testing;

fn shown(raw: ?[]const u8, home: []const u8, host: []const u8) ![]u8 {
    return rightPart(t.allocator, raw, home, host);
}

test "OSC 7 URIs lose scheme and host and are percent-decoded; bare paths stay" {
    const cases = [_][2][]const u8{
        .{ "file://host/tmp/x", "/tmp/x" },
        .{ "file:///srv/app", "/srv/app" },
        .{ "file://host/tmp/a%20b%2Fc", "/tmp/a b/c" },
        .{ "file://host/bad%zz%4", "/bad%zz%4" },
        .{ "FILE://h/x", "/x" },
        .{ "/home/u/proj", "/home/u/proj" },
        .{ "kitty-shell-cwd://h/srv/a%20b", "/srv/a%20b" },
        .{ "kitty-shell-cwd://h/srv/a b?x#y", "/srv/a b?x#y" },
        .{ "https://evil/x", "" },
        .{ "relative/dir", "" },
        .{ "C:\\x", "" },
        .{ "file://host", "" },
        .{ "", "" },
    };
    for (cases) |c| {
        const got = try shown(c[0], "", "");
        defer t.allocator.free(got);
        try t.expectEqualStrings(c[1], got);
    }
    const none = try shown(null, "/home/u", "");
    defer t.allocator.free(none);
    try t.expectEqualStrings("", none);
}

test "~ only for a local host and a $HOME boundary" {
    const cases = [_]struct { raw: []const u8, home: []const u8, host: []const u8, want: []const u8 }{
        .{ .raw = "file:///home/u", .home = "/home/u", .host = "box", .want = "~" },
        .{ .raw = "file:///home/u/src", .home = "/home/u", .host = "box", .want = "~/src" },
        .{ .raw = "file://box/home/u/src", .home = "/home/u", .host = "box", .want = "~/src" },
        .{ .raw = "file://localhost/home/u/src", .home = "/home/u", .host = "box", .want = "~/src" },
        .{ .raw = "file://other/home/u/src", .home = "/home/u", .host = "box", .want = "/home/u/src" },
        .{ .raw = "file:///home/user/src", .home = "/home/u", .host = "box", .want = "/home/user/src" },
        .{ .raw = "/home/u/x", .home = "/home/u", .host = "box", .want = "~/x" },
        .{ .raw = "file:///home/u/x", .home = "", .host = "box", .want = "/home/u/x" },
        .{ .raw = "file:///x", .home = "/", .host = "box", .want = "/x" },
        .{ .raw = "file:///home/u/%2e%2e", .home = "/home/u", .host = "box", .want = "/home/u/.." },
        .{ .raw = "file:///home/u/a/../b", .home = "/home/u", .host = "box", .want = "/home/u/a/../b" },
        .{ .raw = "file:///home/u/.%e2%80%8b.", .home = "/home/u", .host = "box", .want = "/home/u/.\u{200b}." },
        .{ .raw = "file:///home/u/.%ef%bb%bf./x", .home = "/home/u", .host = "box", .want = "/home/u/.\u{feff}./x" },
        .{ .raw = "file:///home/u/.%e2%80%8d.", .home = "/home/u", .host = "box", .want = "/home/u/.\u{200d}." },
        .{ .raw = "file:///home/u/.%ef%b8%8f.", .home = "/home/u", .host = "box", .want = "/home/u/.\u{fe0f}." },
        .{ .raw = "file:///home/u/.%e2%80%8c", .home = "/home/u", .host = "box", .want = "/home/u/.\u{200c}" },
        .{ .raw = "file:///home/u/./b", .home = "/home/u", .host = "box", .want = "/home/u/./b" },
        .{ .raw = "file:///home/u/a..b", .home = "/home/u", .host = "box", .want = "~/a..b" },
        .{ .raw = "file:///home/u/src", .home = "/home/u/", .host = "box", .want = "~/src" },
        .{ .raw = "file:///home/u", .home = "/home/u/", .host = "box", .want = "~" },
        .{ .raw = "kitty-shell-cwd://box/home/u/src", .home = "/home/u", .host = "box", .want = "~/src" },
    };
    for (cases) |c| {
        const got = try shown(c.raw, c.home, c.host);
        defer t.allocator.free(got);
        try t.expectEqualStrings(c.want, got);
    }
}
