//! `shell.init`: the opt-in OSC 133 snippets for zsh, bash and fish.
//! They send the OSC 133 C mark with `cmdline_url`, so the status
//! line can name `ping google.com` instead of the shell.
const std = @import("std");
const cli = @import("cli");

pub const scripts = .{
    .{ "zsh", @embedFile("shell/venomx.zsh") },
    .{ "bash", @embedFile("shell/venomx.bash") },
    .{ "fish", @embedFile("shell/venomx.fish") },
};

/// The snippet for `shell`, or null for a shell without one.
pub fn script(shell: []const u8) ?[]const u8 {
    inline for (scripts) |s| if (std.mem.eql(u8, shell, s[0])) return s[1];
    return null;
}

pub fn call(local: cli.Local.Context) !cli.Local.Outcome {
    // The schema's `choices` already restricts the shell.
    const shell = local.params.object.get("shell").?.string;
    var out: std.json.ObjectMap = .empty;
    try out.put(local.allocator, "shell", .{ .string = shell });
    try out.put(local.allocator, "script", .{ .string = script(shell).? });
    return .{ .result = .{ .object = out } };
}

test "every choice has a script that only acts in a venomx pane and loads once" {
    inline for (scripts) |s| {
        try std.testing.expect(std.mem.indexOf(u8, s[1], "VENOMX_PANE") != null);
        try std.testing.expect(std.mem.indexOf(u8, s[1], "_venomx_shell_init") != null);
        try std.testing.expect(std.mem.indexOf(u8, s[1], "133;C;cmdline_url=") != null);
    }
    try std.testing.expect(script("tcsh") == null);
}
