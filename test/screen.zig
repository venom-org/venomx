//! Test helper: replay a host terminal's output bytes (stdin) into a fresh
//! venom-term Vt of `cols rows` and print its visible screen as text.
const std = @import("std");
const Vt = @import("vt").Vt;
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    if (argv.len != 3) return error.Usage;
    const cols = try std.fmt.parseInt(u16, argv[1], 10);
    const rows = try std.fmt.parseInt(u16, argv[2], 10);
    var vt = try Vt.init(a, .{ .cols = cols, .rows = rows });
    defer vt.deinit();
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try vt.feed(buf[0..@intCast(n)]);
    }
    const r = vt.rows();
    const text = try vt.exportRows(a, r.epoch, r.active, r.end);
    defer a.free(text);
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    try out.interface.writeAll(text);
    try out.interface.flush();
}
