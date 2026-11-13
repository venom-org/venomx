//! An allocator that zeroes memory before giving it back. The daemon routes
//! every heap allocation through it, so request
//! frames, call arenas, the built child environment and child tokens never
//! survive in freed heap memory, whichever module held them.
const std = @import("std");
const Alignment = std.mem.Alignment;
const Allocator = std.mem.Allocator;

pub const Scrub = struct {
    child: Allocator,
    pub fn allocator(self: *Scrub) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
        const self: *Scrub = @ptrCast(@alignCast(ctx));
        return self.child.rawAlloc(len, alignment, ret);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret: usize) bool {
        const self: *Scrub = @ptrCast(@alignCast(ctx));
        // A shrink never needs the tail again, even if the resize fails.
        if (new_len < memory.len) std.crypto.secureZero(u8, memory[new_len..]);
        return self.child.rawResize(memory, alignment, new_len, ret);
    }
    /// Never moves in place: callers fall back to alloc, copy and `free`,
    /// which zeroes the old block.
    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ret)) memory.ptr else null;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret: usize) void {
        const self: *Scrub = @ptrCast(@alignCast(ctx));
        std.crypto.secureZero(u8, memory);
        self.child.rawFree(memory, alignment, ret);
    }
};

test "freed, shrunk and moved memory is zeroed" {
    const t = std.testing;
    var backing: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    var scrub: Scrub = .{ .child = fixed.allocator() };
    const a = scrub.allocator();
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(a, "canary-one");
    for (0..8) |_| try list.appendSlice(a, "canary-two");
    list.deinit(a);
    const s = try a.dupe(u8, "canary-three");
    a.free(s);
    try t.expect(std.mem.indexOf(u8, &backing, "canary") == null);
}
