//! The Venom theme in venomx: which built-in theme the `theme` config
//! key names, venomx's edition signal (`ember`), the attach client's chrome
//! in that theme, and the host colours the daemon hands to panes. Roles come
//! from venom-term's `theme` module; nothing here hard-codes a colour.
const std = @import("std");
const term = @import("venom-term");
const Vt = @import("vt").Vt;
const theme = term.theme;

/// The `theme` config key. Default `trve` (dark); `bone` is the light one.
pub const Name = enum { trve, bone };

/// venomx's edition signal: ember.
pub const edition: theme.Edition = .venomx;

pub fn resolve(name: Name) *const theme.Theme {
    return theme.byName(@tagName(name)).?;
}

/// The attach client's chrome: the named theme in venomx's edition, in the
/// colour mode the host terminal supports.
pub fn chrome(name: Name, mode: theme.Mode) theme.Chrome {
    return .{ .theme = resolve(name), .edition = edition, .mode = mode };
}

/// The colour mode from `COLORTERM`, as `theme.Mode.detect` reads it.
pub fn modeFromColorterm(colorterm: ?[]const u8) theme.Mode {
    const value = colorterm orelse return .ansi16;
    if (std.mem.eql(u8, value, "truecolor") or std.mem.eql(u8, value, "24bit")) return .truecolor;
    return .ansi16;
}

/// What a program in a pane gets for OSC 10/11/12 queries: `bone` text on
/// the `void` ground with the brand's cursor (`blood`). The ANSI 16 palette
/// (OSC 4) is not carried: `Vt.QueryColors` has no palette yet.
pub fn hostColors(name: Name) Vt.QueryColors {
    const t = resolve(name);
    return .{ .fg = t.bone.rgb, .bg = t.void.rgb, .cursor = t.blood.rgb };
}

test "both themes hand panes their own ground, text and cursor" {
    const trve = hostColors(.trve);
    const bone = hostColors(.bone);
    try std.testing.expectEqual([3]u8{ 0xf1, 0xf1, 0xf1 }, trve.fg.?);
    try std.testing.expectEqual([3]u8{ 0x00, 0x00, 0x00 }, trve.bg.?);
    try std.testing.expectEqual([3]u8{ 0xfc, 0x30, 0x2e }, trve.cursor.?);
    try std.testing.expectEqual([3]u8{ 0x21, 0x12, 0x12 }, bone.fg.?);
    try std.testing.expectEqual([3]u8{ 0xf3, 0xf2, 0xf2 }, bone.bg.?);
    try std.testing.expectEqual([3]u8{ 0xae, 0x02, 0x00 }, bone.cursor.?);
}

test "the edition signal is ember in both themes" {
    for ([_]Name{ .trve, .bone }) |name| {
        const c = chrome(name, .truecolor);
        try std.testing.expectEqual(term.Color{ .rgb = resolve(name).ember.rgb }, c.signal());
    }
    try std.testing.expectEqual(term.Color{ .rgb = .{ 0xe7, 0x8a, 0x43 } }, chrome(.trve, .truecolor).signal());
    try std.testing.expectEqual(term.Color{ .rgb = .{ 0x8a, 0x3f, 0x0e } }, chrome(.bone, .truecolor).signal());
}

test "colour mode follows COLORTERM" {
    try std.testing.expect(modeFromColorterm(null) == .ansi16);
    try std.testing.expect(modeFromColorterm("truecolor") == .truecolor);
    try std.testing.expect(modeFromColorterm("24bit") == .truecolor);
    try std.testing.expect(modeFromColorterm("yes") == .ansi16);
}
