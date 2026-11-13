//! Product projections of validated authoritative Vt callbacks. OSC content
//! remains untrusted observation; it never creates grants or command results.
const std = @import("std");
const proto = @import("proto");
const Vt = @import("vt").Vt;
const foreground = @import("foreground.zig");
const Record = struct {
    id: []const u8,
    state: []const u8,
    kind: ?[]const u8 = null,
    app: ?[]const u8 = null,
    title: ?[]const u8 = null,
    msg: ?[]const u8 = null,
    progress: ?u8 = null,
    touched: u64 = 0,
    pub fn jsonStringify(self: Record, j: anytype) !void {
        try j.write(.{ .id = self.id, .state = self.state, .kind = self.kind, .app = self.app, .title = self.title, .msg = self.msg, .progress = self.progress });
    }
};
pub const Observation = struct {
    a: std.mem.Allocator,
    log: *proto.events.Log,
    pane: []const u8,
    storage: std.heap.ArenaAllocator,
    records: []const Record = &.{},
    command: ?[]const u8 = null,
    /// The active command's sanitized `cmdline`, if the shell sent one.
    cmdline: ?[]const u8 = null,
    /// Counts `command.started` and `command.finished`, so the product can
    /// clear `title_current` and sample the foreground.
    command_epoch: u64 = 0,
    next_command: u64 = 0,
    clock: u64 = 0,
    failed: bool = false,
    /// A record entered `blocked` since the product's last tick (a
    /// report may set `info` attention). Repeating a blocked report
    /// for the same record does not set it again.
    blocked_pending: bool = false,
    pub fn init(a: std.mem.Allocator, log: *proto.events.Log, pane: []const u8) Observation {
        return .{ .a = a, .log = log, .pane = pane, .storage = .init(a) };
    }
    pub fn deinit(self: *Observation) void {
        self.storage.deinit();
        if (self.command) |cmd| self.a.free(cmd);
        if (self.cmdline) |x| self.a.free(x);
    }
    pub fn callbacks(self: *Observation) Vt.Callbacks {
        return .{ .context = self, .program_status = statusCallback, .semantic_prompt = promptCallback };
    }
    fn statusCallback(ctx: ?*anyopaque, report: Vt.ProgramStatus) void {
        const self: *Observation = @ptrCast(@alignCast(ctx.?));
        self.status(report) catch {
            self.failed = true;
        };
    }
    fn promptCallback(ctx: ?*anyopaque, report: Vt.SemanticPrompt) void {
        const self: *Observation = @ptrCast(@alignCast(ctx.?));
        self.prompt(report) catch {
            self.failed = true;
        };
    }
    fn resource(self: *Observation, a: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(a, "pane:{s}", .{self.pane});
    }
    fn optional(text: []const u8) ?[]const u8 {
        return if (text.len == 0) null else text;
    }
    fn descendant(id: []const u8, parent: []const u8) bool {
        return parent.len == 0 or std.mem.eql(u8, id, parent) or (std.mem.startsWith(u8, id, parent) and id.len > parent.len and id[parent.len] == '/');
    }
    fn order(_: void, left: Record, right: Record) bool {
        return std.mem.lessThan(u8, left.id, right.id);
    }
    fn same(left: Record, right: Record) bool {
        if (!std.mem.eql(u8, left.id, right.id) or !std.mem.eql(u8, left.state, right.state) or left.progress != right.progress) return false;
        inline for (.{ "kind", "app", "title", "msg" }) |key| {
            const l = @field(left, key);
            const r = @field(right, key);
            if ((l == null) != (r == null)) return false;
            if (l != null and !std.mem.eql(u8, l.?, r.?)) return false;
        }
        return true;
    }
    pub fn reset(ctx: ?*anyopaque) void {
        const self: *Observation = @ptrCast(@alignCast(ctx.?));
        self.finish("reset", null) catch {
            self.failed = true;
        };
        self.cleanup("reset", true) catch {
            self.failed = true;
        };
    }
    fn publish(self: *Observation, records: []Record, reason: []const u8) !void {
        std.mem.sort(Record, records, {}, order);
        var equal = records.len == self.records.len;
        if (equal) for (records, self.records) |l, r| {
            if (!same(l, r)) {
                equal = false;
                break;
            }
        };
        // Arena replacement bounds retained data across any number of updates.
        var storage = std.heap.ArenaAllocator.init(self.a);
        errdefer storage.deinit();
        const a = storage.allocator();
        const owned = try a.dupe(Record, records);
        for (owned) |*record| {
            record.id = try a.dupe(u8, record.id);
            record.state = try a.dupe(u8, record.state);
            inline for (.{ "kind", "app", "title", "msg" }) |key| if (@field(record, key)) |v| {
                @field(record, key) = try a.dupe(u8, v);
            };
        }
        if (!equal) {
            const r = try self.resource(a);
            try self.log.append(r, "program.status_changed", .{ .pane = self.pane, .reason = reason, .records = owned });
        }
        self.storage.deinit();
        self.storage = storage;
        self.records = owned;
    }
    fn status(self: *Observation, report: Vt.ProgramStatus) !void {
        var scratch = std.heap.ArenaAllocator.init(self.a);
        defer scratch.deinit();
        const a = scratch.allocator();
        var next: std.ArrayList(Record) = .empty;
        var found = false;
        var was_blocked = false;
        self.clock += 1;
        for (self.records) |record| {
            if (report.state == .clear and descendant(record.id, report.id)) continue;
            if (std.mem.eql(u8, record.id, report.id)) {
                found = true;
                was_blocked = std.mem.eql(u8, record.state, "blocked");
                continue;
            }
            try next.append(a, record);
        }
        var reason: []const u8 = if (report.state == .clear) "clear" else "report";
        if (report.state != .clear) {
            // Support the protocol minimum of 64 records, with LRU eviction.
            if (!found and next.items.len >= 64) {
                var oldest: usize = 0;
                for (next.items, 0..) |record, i| if (record.touched < next.items[oldest].touched) {
                    oldest = i;
                };
                _ = next.orderedRemove(oldest);
                reason = "evicted";
            }
            try next.append(a, .{ .id = report.id, .state = if (report.state == .failed) "error" else @tagName(report.state), .kind = if (report.kind == .none) null else @tagName(report.kind), .app = optional(report.app), .title = optional(report.title), .msg = optional(report.message), .progress = report.progress, .touched = self.clock });
        }
        try self.publish(next.items, reason);
        if (report.state == .blocked and !was_blocked) self.blocked_pending = true;
    }
    pub fn cleanup(self: *Observation, reason: []const u8, all: bool) !void {
        var scratch = std.heap.ArenaAllocator.init(self.a);
        defer scratch.deinit();
        var next: std.ArrayList(Record) = .empty;
        if (!all) for (self.records) |record| {
            if (std.mem.eql(u8, record.state, "idle") or std.mem.eql(u8, record.state, "done") or std.mem.eql(u8, record.state, "error")) try next.append(scratch.allocator(), record);
        };
        try self.publish(next.items, reason);
    }
    pub fn finish(self: *Observation, reason: []const u8, code: ?i32) !void {
        const cmd = self.command orelse return;
        var scratch = std.heap.ArenaAllocator.init(self.a);
        defer scratch.deinit();
        try self.log.append(try self.resource(scratch.allocator()), "command.finished", .{ .pane = self.pane, .command = cmd, .reason = reason, .exit_code = if (code != null and code.? >= 0 and code.? <= 255) code else null });
        self.a.free(cmd);
        self.command = null;
        if (self.cmdline) |x| self.a.free(x);
        self.cmdline = null;
        self.command_epoch += 1;
    }
    fn prompt(self: *Observation, report: Vt.SemanticPrompt) !void {
        switch (report.kind) {
            .prompt_start => {
                try self.finish("prompt", null);
                try self.cleanup("prompt", false);
            },
            .input_start => {},
            .output_start => if (self.command == null) {
                if (self.next_command == proto.events.max_seq) return error.Overflow;
                const cmd = try std.fmt.allocPrint(self.a, "{s}/c{d}", .{ self.pane, self.next_command });
                errdefer self.a.free(cmd);
                // libghostty-vt decodes `cmdline_url` (and kitty's raw `cmdline`).
                const line = try foreground.cmdline(self.a, report.command);
                errdefer if (line) |x| self.a.free(x);
                self.next_command += 1;
                var scratch = std.heap.ArenaAllocator.init(self.a);
                defer scratch.deinit();
                try self.log.append(try self.resource(scratch.allocator()), "command.started", .{ .pane = self.pane, .command = cmd, .cmdline = line });
                self.command = cmd;
                self.cmdline = line;
                self.command_epoch += 1;
            },
            .command_end => try self.finish("osc133", report.exit_code),
        }
    }
    pub fn appendSnapshot(self: *Observation, a: std.mem.Allocator, out: *std.ArrayList(proto.events.Entity)) !void {
        if (self.records.len > 0) try out.append(a, .{ .resource = try self.resource(a), .entity_type = "program_status", .content = try std.json.Stringify.valueAlloc(a, .{ .pane = self.pane, .records = self.records }, .{ .emit_null_optional_fields = false }), .event_types = &.{"program.status_changed"} });
        if (self.command) |cmd| try out.append(a, .{ .resource = try self.resource(a), .entity_type = "command", .content = try std.json.Stringify.valueAlloc(a, .{ .pane = self.pane, .command = cmd, .cmdline = self.cmdline }, .{ .emit_null_optional_fields = false }), .event_types = &.{ "command.started", "command.finished" } });
    }
};

test "authoritative OSC projections: fragments, identical reports, subtree clear, lifecycle and reset" {
    const a = std.testing.allocator;
    var events = try proto.events.Log.init(a, "venomx", .{}, null);
    defer events.deinit();
    const pane = try @import("stream.zig").Pane.create(a, "p0", .{ .cols = 20, .rows = 3 }, .{});
    defer pane.destroy();
    var obs = Observation.init(a, &events, "p0");
    defer obs.deinit();
    pane.observers = obs.callbacks();
    pane.reset_observer = Observation.reset;
    const blocked = "\x1b]7501;state=blocked:kind=permission:id=build/test:msg=QXBwcm92ZT8=\x07";
    for (blocked) |byte| try pane.feed(&.{byte});
    try std.testing.expectEqual(@as(usize, 1), obs.records.len);
    try std.testing.expectEqualStrings("Approve?", obs.records[0].msg.?);
    const high = events.high;
    try pane.feed(blocked);
    try std.testing.expectEqual(high, events.high);
    try pane.feed("\x1b]7501;?\x07");
    try std.testing.expect(std.mem.startsWith(u8, pane.input.items, "\x1b]7501;?"));
    try std.testing.expect(std.mem.endsWith(u8, pane.input.items, "\x07"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, pane.input.items, "\x1b]7501;"));
    try std.testing.expectEqual(high, events.high);
    try pane.feed("\x1b]7501;state=clear:id=build\x1b\\");
    try std.testing.expectEqual(@as(usize, 0), obs.records.len);
    try pane.feed("\x1b]7501;state=done\x07\x1b]133;C\x07\x1b]133;C\x07");
    try std.testing.expect(obs.command != null);
    const command_high = events.high;
    try pane.feed("\x1b[!p"); // DECSTR is not RIS.
    try std.testing.expectEqual(command_high, events.high);
    try pane.feed("\x1b]133;A\x07");
    try std.testing.expect(obs.command == null);
    try std.testing.expectEqual(@as(usize, 1), obs.records.len); // done survives prompt
    try pane.feed("\x1b]133;C\x07\x1bc");
    try std.testing.expect(obs.command == null);
    try std.testing.expectEqual(@as(usize, 0), obs.records.len);
    // Text batching must keep reset cleanup between callbacks in one read,
    // and recognize a RIS split across reads.
    try pane.feed("before\x1b]7501;state=working:id=old\x07\x1bc\x1b]7501;state=done:id=new\x07after");
    try std.testing.expectEqual(@as(usize, 1), obs.records.len);
    try std.testing.expectEqualStrings("new", obs.records[0].id);
    try pane.feed("\x1b");
    try pane.feed("c");
    try std.testing.expectEqual(@as(usize, 0), obs.records.len);
    try std.testing.expect(!obs.failed);
}

test "OSC 133 C's cmdline_url is the active command's sanitized cmdline, cleared at D" {
    const a = std.testing.allocator;
    var events = try proto.events.Log.init(a, "venomx", .{}, null);
    defer events.deinit();
    // venomx's catalog adds `cmdline` to `command.started`.
    events.catalog = &@import("manifest.zig").catalog;
    const pane = try @import("stream.zig").Pane.create(a, "p0", .{ .cols = 20, .rows = 3 }, .{});
    defer pane.destroy();
    var obs = Observation.init(a, &events, "p0");
    defer obs.deinit();
    pane.observers = obs.callbacks();
    try pane.feed("\x1b]133;C;cmdline_url=ping%20x%1b\x07");
    try std.testing.expectEqualStrings("ping x\u{fffd}", obs.cmdline.?);
    try std.testing.expectEqual(@as(u64, 1), obs.command_epoch);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var out: std.ArrayList(proto.events.Entity) = .empty;
    try obs.appendSnapshot(arena.allocator(), &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items[0].content, "\"cmdline\":\"ping x\u{fffd}\"") != null);
    try pane.feed("\x1b]133;D;0\x07");
    try std.testing.expect(obs.cmdline == null and obs.command == null);
    try std.testing.expectEqual(@as(u64, 2), obs.command_epoch);
    // A malformed escape still starts the command, with no cmdline.
    try pane.feed("\x1b]133;C;cmdline_url=bad%zz\x07");
    try std.testing.expect(obs.command != null and obs.cmdline == null);
    try std.testing.expect(!obs.failed);
}
