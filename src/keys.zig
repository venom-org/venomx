//! Key tables, shared by the daemon (registration, `keys.list`,
//! `config check`, `doctor`) and the presentation client (key routing). The
//! syntax, precedence, JSON form and leader state machine are venom-term's
//! `chrome.keys` (one implementation for every venomx client);
//! this file adds venomx's commands, built-in table and config layers.
//!
//! The client intercepts only the leader (and, in lock mode, the unlock key).
//! Everything bound lives in tables under the leader. Layers, highest first:
//! user config, the defaults file, registered product tables, built-in.
const std = @import("std");
const ck = @import("term_chrome").keys;
const manifest = @import("manifest.zig");
const eq = std.mem.eql;

// ------------------------------------------------------------------ chords

pub const Mods = ck.Mods;
pub const Chord = ck.Chord;
pub const named_base = ck.named_base;
pub const parseChord = ck.parseChord;
pub const fromKey = ck.fromKey;
pub const formatChord = ck.formatChord;
pub const chordText = ck.chordText;
pub const max_sequence = ck.max_sequence;
pub const Sequence = ck.Sequence;
pub const parseSequence = ck.parseSequence;
pub const legacyDeliverable = ck.legacyDeliverable;
pub const legacyByte = ck.legacyByte;

// ---------------------------------------------------------------- commands

/// Local viewport and presentation actions of the client.
pub const Local = enum {
    detach,
    /// `h j k l` and the arrows move by direction.
    focus_left,
    focus_down,
    focus_up,
    focus_right,
    focus_next,
    focus_prev,
    window_next,
    window_prev,
    /// The n-th window of the session, in ID order.
    window_1,
    window_2,
    window_3,
    window_4,
    window_5,
    window_6,
    window_7,
    window_8,
    window_9,
    scroll_line_up,
    scroll_line_down,
    scroll_page_up,
    scroll_page_down,
    scroll_bottom,
    /// `{` / `}` put the previous / next OSC 133 A prompt row at the top.
    scroll_prev_command,
    scroll_next_command,
    /// Send the leader key itself to the focused pane.
    send_leader,
    command_prompt,
    /// Pick a window of the attached session; this client only.
    window_picker,
    /// Pick a session to attach to; this client only.
    session_picker,
    /// List the keys, by opening the leader popup now.
    all_keys,
    clear_selection,
    /// vim-style keyboard selection over the focused pane's rows.
    copy_mode,
    /// This client only; never resizes anyone's panes.
    zoom,
    /// Focus the next pane that needs attention.
    focus_attention,
    /// Pass every key to the pane until the unlock key.
    lock,
    /// Show or hide the float layer on this client only.
    toggle_floats,
    /// Cycle focus among the visible floats and popups.
    focus_float,
    /// Close the focused popup.
    dismiss_popup,
};
/// Built-in product mutations. Each names a schema verb, checked at compile
/// time, and is sent with the client's own authorization.
pub const Verb = enum {
    split_right,
    split_down,
    new_window,
    close_pane,
    /// `pane.resize` moves a shared split divider one cell.
    resize_left,
    resize_down,
    resize_up,
    resize_right,
    /// `pane.place` floats the focused tiled pane, or tiles
    /// the focused float back into its window.
    toggle_pane_float,
    pub fn wire(self: Verb) []const u8 {
        return switch (self) {
            .split_right, .split_down => "pane.split",
            .new_window => "window.create",
            .close_pane => "pane.kill",
            .resize_left, .resize_down, .resize_up, .resize_right => "pane.resize",
            .toggle_pane_float => "pane.place",
        };
    }
};
comptime {
    for (std.enums.values(Verb)) |v| {
        if (!knownVerb(v.wire())) @compileError("binding names an undeclared verb: " ++ v.wire());
    }
}
pub const Command = union(enum) { local: Local, verb: Verb };
/// One name per command, shared by bindings, `.local` targets and the `:`
/// command prompt.
pub fn commandName(c: Command) []const u8 {
    return switch (c) {
        .local => |l| switch (l) {
            inline else => |t| kebab(@tagName(t)),
        },
        .verb => |v| switch (v) {
            inline else => |t| kebab(@tagName(t)),
        },
    };
}
fn kebab(comptime tag: []const u8) []const u8 {
    const name = comptime blk: {
        var out: [tag.len]u8 = undefined;
        for (tag, 0..) |ch, i| out[i] = if (ch == '_') '-' else ch;
        break :blk out;
    };
    return &name;
}
pub fn parseCommand(name: []const u8) ?Command {
    inline for (comptime std.enums.values(Local)) |v| if (eq(u8, name, commandName(.{ .local = v }))) return .{ .local = v };
    inline for (comptime std.enums.values(Verb)) |v| if (eq(u8, name, commandName(.{ .verb = v }))) return .{ .verb = v };
    return null;
}
/// A schema verb of venomx a `.verb` target may name.
pub fn knownVerb(name: []const u8) bool {
    @setEvalBranchQuota(100_000);
    for (manifest.model.verbs) |v| if (eq(u8, v.name, name) and !eq(u8, name, "events")) return true;
    return false;
}

// ----------------------------------------------------------------- tables

/// Tables over venomx's commands; `.verb` targets name venomx schema verbs.
pub const K = ck.Tables(Command, .{ .parseLocal = parseCommand, .localName = commandName, .knownVerb = knownVerb });
pub const placeholders = ck.placeholders;
pub const placeholder = ck.placeholder;
pub const Target = K.Target;
pub const Binding = K.Binding;
pub const Layer = ck.Layer;
pub const Table = K.Table;
pub const BindingConfig = ck.BindingConfig;
pub const GroupConfig = ck.GroupConfig;
pub const TableConfig = ck.TableConfig;
pub const PrefixConfig = ck.PrefixConfig;
pub const parsePrefixes = ck.parsePrefixes;
pub const effectivePrefix = ck.effectivePrefix;
pub const Settings = ck.Settings;
pub const esc_key = parseChord("escape").?;
pub const Failure = ck.Failure;
pub const ParseResult = ck.ParseResult;
pub const validName = ck.validName;
pub const max_bindings = ck.max_bindings;
pub const parseBinding = K.parseBinding;
pub const parseTable = K.parseTable;
pub const Entry = K.Entry;
pub const Conflict = K.Conflict;
pub const Shadow = K.Shadow;
pub const Resolved = K.Resolved;
pub const Active = ck.Active;
pub const resolve = K.resolve;
pub const Router = K.Router;
pub const tableJson = K.tableJson;
pub const tableFromJson = K.tableFromJson;
pub const tagsFromJson = ck.tagsFromJson;
pub const bindingConfigFromJson = ck.bindingConfigFromJson;
pub const groupConfigsFromJson = ck.groupConfigsFromJson;

/// The `keys` config.
pub const Config = struct {
    leader: []const u8 = "ctrl+b",
    unlock: []const u8 = "ctrl+alt+b",
    /// How long after a key the leader popup appears; 0 shows it at once.
    popup_delay_ms: u32 = 200,
    /// How long leader mode waits for a key; 0 waits until the next key.
    timeout_ms: u32 = 0,
    tables: []const TableConfig = &.{},
    /// Moves a table to another sub-prefix without restating its bindings.
    prefixes: []const PrefixConfig = &.{},
    pub const max_ms = 60000;
    pub fn check(self: Config) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const leader = parseChord(self.leader) orelse return error.InvalidConfig;
        const unlock = parseChord(self.unlock) orelse return error.InvalidConfig;
        if (leader.eql(unlock)) return error.InvalidConfig;
        if (self.timeout_ms != 0 and (self.timeout_ms < 100 or self.timeout_ms > max_ms)) return error.InvalidConfig;
        if (self.popup_delay_ms > max_ms) return error.InvalidConfig;
        if (try parsePrefixes(arena.allocator(), self.prefixes) == .failed) return error.InvalidConfig;
        for (self.tables) |t| {
            switch (try parseTable(arena.allocator(), t, .user)) {
                .ok => {},
                .failed => return error.InvalidConfig,
            }
        }
        // A conflict inside one table is a same-layer conflict.
        for (self.tables) |t| {
            const one = switch (try parseTable(arena.allocator(), t, .user)) {
                .ok => |x| x,
                .failed => unreachable,
            };
            const r = try resolve(arena.allocator(), &.{one}, null);
            if (r.conflicts.len > 0) return error.InvalidConfig;
        }
    }
};

/// The `keys` config defaults, for a client that has not heard from the daemon yet.
/// venom-term's `Settings{}` keeps older defaults on purpose, so set them all.
pub const default_settings: Settings = .{
    .leader = parseChord((Config{}).leader).?,
    .unlock = parseChord((Config{}).unlock).?,
    .popup_delay_ms = (Config{}).popup_delay_ms,
    .timeout_ms = (Config{}).timeout_ms,
};
/// `tables` with the merged `keys.prefixes` applied. Bad entries move nothing
/// (`config check` reports them). The moves are config, not table state, so
/// they survive a registrar replacing a table. Allocates into `a`.
pub fn effectiveTables(a: std.mem.Allocator, tables: []const Table, prefixes: []const PrefixConfig) ![]Table {
    return K.applyPrefixes(a, tables, switch (try parsePrefixes(a, prefixes)) {
        .ok => |moves| moves,
        .failed => &.{},
    });
}

// ----------------------------------------------------------------- builtin

fn builtinBinding(comptime key: []const u8, comptime c: Command) Binding {
    return K.binding(key, .{ .local = c });
}
/// The built-in `venomx` table: frequent actions right after the leader.
/// Without labels the popup shows the command names, which `:` also takes.
pub const builtin_bindings = blk: {
    @setEvalBranchQuota(100_000);
    break :blk [_]Binding{
        builtinBinding("h", .{ .local = .focus_left }),
        builtinBinding("left", .{ .local = .focus_left }),
        builtinBinding("j", .{ .local = .focus_down }),
        builtinBinding("down", .{ .local = .focus_down }),
        builtinBinding("k", .{ .local = .focus_up }),
        builtinBinding("up", .{ .local = .focus_up }),
        builtinBinding("l", .{ .local = .focus_right }),
        builtinBinding("right", .{ .local = .focus_right }),
        builtinBinding("tab", .{ .local = .focus_next }),
        builtinBinding("shift+tab", .{ .local = .focus_prev }),
        builtinBinding("\\", .{ .verb = .split_right }),
        builtinBinding("-", .{ .verb = .split_down }),
        builtinBinding("c", .{ .verb = .new_window }),
        builtinBinding("n", .{ .local = .window_next }),
        builtinBinding("p", .{ .local = .window_prev }),
        builtinBinding("w", .{ .local = .window_picker }),
        builtinBinding("s", .{ .local = .session_picker }),
        builtinBinding("1", .{ .local = .window_1 }),
        builtinBinding("2", .{ .local = .window_2 }),
        builtinBinding("3", .{ .local = .window_3 }),
        builtinBinding("4", .{ .local = .window_4 }),
        builtinBinding("5", .{ .local = .window_5 }),
        builtinBinding("6", .{ .local = .window_6 }),
        builtinBinding("7", .{ .local = .window_7 }),
        builtinBinding("8", .{ .local = .window_8 }),
        builtinBinding("9", .{ .local = .window_9 }),
        builtinBinding("r h", .{ .verb = .resize_left }),
        builtinBinding("r left", .{ .verb = .resize_left }),
        builtinBinding("r j", .{ .verb = .resize_down }),
        builtinBinding("r down", .{ .verb = .resize_down }),
        builtinBinding("r k", .{ .verb = .resize_up }),
        builtinBinding("r up", .{ .verb = .resize_up }),
        builtinBinding("r l", .{ .verb = .resize_right }),
        builtinBinding("r right", .{ .verb = .resize_right }),
        builtinBinding("[ j", .{ .local = .scroll_line_down }),
        builtinBinding("[ down", .{ .local = .scroll_line_down }),
        builtinBinding("[ k", .{ .local = .scroll_line_up }),
        builtinBinding("[ up", .{ .local = .scroll_line_up }),
        builtinBinding("[ page_up", .{ .local = .scroll_page_up }),
        builtinBinding("[ page_down", .{ .local = .scroll_page_down }),
        builtinBinding("[ {", .{ .local = .scroll_prev_command }),
        builtinBinding("[ }", .{ .local = .scroll_next_command }),
        builtinBinding("[ v", .{ .local = .copy_mode }),
        builtinBinding("page_up", .{ .local = .scroll_page_up }),
        builtinBinding("page_down", .{ .local = .scroll_page_down }),
        builtinBinding("]", .{ .local = .scroll_bottom }),
        builtinBinding("z", .{ .local = .zoom }),
        builtinBinding("!", .{ .local = .focus_attention }),
        builtinBinding("d", .{ .local = .detach }),
        builtinBinding("X", .{ .verb = .close_pane }),
        builtinBinding("f", .{ .local = .toggle_floats }),
        builtinBinding("F", .{ .local = .focus_float }),
        builtinBinding("x", .{ .local = .dismiss_popup }),
        builtinBinding("e", .{ .verb = .toggle_pane_float }),
        builtinBinding(":", .{ .local = .command_prompt }),
        builtinBinding("?", .{ .local = .all_keys }),
        builtinBinding("L", .{ .local = .lock }),
        // `esc` also clears this client's selection, here at the root.
        // From a lower level the router only cancels; see `App.keyOutcome`.
        builtinBinding("escape", .{ .local = .clear_selection }),
    };
};
const builtin_groups = [_]ck.Group{ ck.group("r", "resize", true), ck.group("[", "scroll", true) };
pub const builtin_table: Table = .{ .name = "venomx", .layer = .builtin, .groups = &builtin_groups, .bindings = &builtin_bindings };
/// sub-prefixes a built-in never takes.
pub const reserved_prefixes = [_][]const u8{ "v", "o", "m" };
comptime {
    @setEvalBranchQuota(100_000);
    for (reserved_prefixes) |key| {
        if (builtinKey(parseChord(key).?)) @compileError("a built-in binding takes the reserved sub-prefix: " ++ key);
    }
}
/// A key the built-in table binds directly after the leader. Products may
/// not take it as a sub-prefix (they never shadow a built-in).
pub fn builtinKey(c: Chord) bool {
    for (builtin_bindings) |b| if (b.seq.keys[0].eql(c)) return true;
    return false;
}

// -------------------------------------------------------------- config file

/// The `keys.tables` of one config file, parsed alone so the daemon knows
/// each table's layer (the effective config merges them per name). Null
/// when the file does not exist.
pub fn readLayer(a: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const TableConfig {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        error.OutOfMemory => return err,
        else => return error.Unreadable,
    };
    return try parseLayer(a, bytes);
}
pub fn parseLayer(a: std.mem.Allocator, bytes: []const u8) ![]const TableConfig {
    const File = struct { keys: struct { tables: []const TableConfig = &.{} } = .{} };
    const src = try a.dupeSentinel(u8, bytes, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const parsed = std.zon.parse.fromSlice(File, .{ .gpa = a, .arena = a, .source = src, .diagnostics = &diagnostics, .ignore_unknown_fields = true }) catch |err| return if (err == error.OutOfMemory) err else error.Unreadable;
    return parsed.keys.tables;
}

/// The `keys` value of a config, as ZON text.
pub fn parseConfig(a: std.mem.Allocator, bytes: []const u8) !Config {
    const src = try a.dupeSentinel(u8, bytes, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(Config, .{ .gpa = a, .arena = a, .source = src, .diagnostics = &diagnostics, .ignore_unknown_fields = true }) catch |err| if (err == error.OutOfMemory) err else error.Unreadable;
}

/// The two config layers of `keys.tables` plus the effective scalars.
pub const ConfigLayers = struct {
    config: Config = .{},
    defaults: []const TableConfig = &.{},
    user: []const TableConfig = &.{},
};
/// Where the daemon reads the config layers from (the cfg store in `serve`,
/// fixed values in tests).
pub const ConfigSource = struct {
    ptr: *anyopaque,
    f: *const fn (*anyopaque, std.mem.Allocator) anyerror!ConfigLayers,
    pub fn layers(self: ConfigSource, a: std.mem.Allocator) !ConfigLayers {
        return self.f(self.ptr, a);
    }
};
/// Config tables as `Table`s; invalid ones are skipped (config check reports
/// them).
pub fn configTables(a: std.mem.Allocator, layers: ConfigLayers, out: *std.ArrayList(Table)) !void {
    for ([_]struct { []const TableConfig, Layer }{ .{ layers.defaults, .defaults }, .{ layers.user, .user } }) |pair| {
        for (pair[0]) |t| switch (try parseTable(a, t, pair[1])) {
            .ok => |x| try out.append(a, x),
            .failed => {},
        };
    }
}

// ------------------------------------------------------------------- tests

const testing = std.testing;
test "key syntax: chords, sequences, normalization" {
    try testing.expect(parseChord("ctrl+space").?.eql(.{ .cp = ' ', .mods = .{ .ctrl = true } }));
    try testing.expect(parseChord("ctrl+@").?.eql(parseChord("ctrl+space").?));
    try testing.expect(parseChord("alt+shift+left").?.eql(.{ .cp = named_base + 2, .mods = .{ .alt = true, .shift = true } }));
    try testing.expect(parseChord("%").?.eql(.{ .cp = '%' }));
    try testing.expect(parseChord("shift+o").?.eql(parseChord("O").?));
    try testing.expect(parseChord("ctrl++").?.eql(.{ .cp = '+', .mods = .{ .ctrl = true } }));
    try testing.expect(parseChord("+").?.eql(.{ .cp = '+' }));
    try testing.expect(parseChord("PageUp").?.eql(parseChord("page_up").?));
    try testing.expect(parseChord("") == null and parseChord("ctrl+") == null and parseChord("ctrl+ctrl+a") == null and parseChord("hyper+a") == null and parseChord("ab") == null);
    const s = parseSequence("a  ctrl+b %").?;
    try testing.expectEqual(@as(u8, 3), s.len);
    try testing.expect(parseSequence("a b c d e") == null and parseSequence("  ") == null);
    const text = try s.text(testing.allocator);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("a ctrl+b %", text);
    // Legacy and Kitty input of one key compare equal.
    try testing.expect(fromKey('@', .{ .ctrl = true }, null, null).eql(parseChord("ctrl+space").?));
    try testing.expect(fromKey('5', .{ .shift = true }, '%', "%").eql(parseChord("%").?));
    try testing.expect(fromKey('o', .{ .shift = true }, null, null).eql(parseChord("O").?));
    try testing.expect(fromKey(9, .{ .shift = true }, null, null).eql(parseChord("shift+tab").?));
    try testing.expect(legacyDeliverable(parseChord("ctrl+space").?) and legacyDeliverable(parseChord("ctrl+b").?) and legacyDeliverable(parseChord("alt+x").?));
    try testing.expect(!legacyDeliverable(parseChord("ctrl+shift+a").?) and !legacyDeliverable(parseChord("super+a").?) and !legacyDeliverable(parseChord("ctrl+1").?));
    try testing.expectEqual(@as(?u8, 0), legacyByte(parseChord("ctrl+space").?));
    try testing.expectEqual(@as(?u8, 2), legacyByte(parseChord("ctrl+b").?));
}

test "bindings: one target, known locals and verbs, whole-element placeholders" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const ok = try parseBinding(x, .{ .key = "a", .exec = &.{ "venom", "approve", "--pane", "{pane}" } }, "b");
    try testing.expect(ok == .ok);
    try testing.expect((try parseBinding(x, .{ .key = "a", .exec = &.{ "venom", "--pane={pane}" } }, "b")) == .failed);
    try testing.expectEqualStrings("placeholder", (try parseBinding(x, .{ .key = "a", .exec = &.{ "venom", "x{session}" } }, "b")).failed.reason);
    try testing.expect((try parseBinding(x, .{ .key = "a", .exec = &.{"{pane}"} }, "b")) == .failed);
    try testing.expect((try parseBinding(x, .{ .key = "a", .exec = &.{} }, "b")) == .failed);
    try testing.expect((try parseBinding(x, .{ .key = "a", .local = "zoom" }, "b")) == .ok);
    try testing.expect((try parseBinding(x, .{ .key = "a", .local = "rm-rf" }, "b")) == .failed);
    // A client's own pane.popup binding mints its ticket implicitly.
    try testing.expect((try parseBinding(x, .{ .key = "a", .verb = "pane.popup", .args = "{\"argv\":[\"fzf\"],\"preset\":\"user.picker\"}" }, "b")) == .ok);
    try testing.expect((try parseBinding(x, .{ .key = "a", .verb = "pane.nope" }, "b")) == .failed);
    try testing.expect((try parseBinding(x, .{ .key = "a", .verb = "pane.attention", .args = "{\"pane\":\"{pane}\",\"clear\":true}" }, "b")) == .ok);
    try testing.expect((try parseBinding(x, .{ .key = "a", .verb = "pane.attention", .args = "{\"pane\":\"p{pane}\"}" }, "b")) == .failed);
    try testing.expect((try parseBinding(x, .{ .key = "a", .verb = "pane.attention", .args = "[1]" }, "b")) == .failed);
    try testing.expect((try parseBinding(x, .{ .key = "a", .local = "zoom", .exec = &.{"x"} }, "b")) == .failed);
    try testing.expect((try parseBinding(x, .{ .key = "a", .local = "zoom", .args = "{}" }, "b")) == .failed);
    try testing.expect((try parseBinding(x, .{ .key = "", .local = "zoom" }, "b")) == .failed);
}

test "precedence: user > defaults > product > builtin; same-layer overlaps conflict" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const venom = (try parseTable(x, .{ .name = "venom", .prefix = "a", .bind = &.{ .{ .key = "a", .exec = &.{ "venom", "approve" } }, .{ .key = "n", .local = "zoom" } } }, .product)).ok;
    const user_root = (try parseTable(x, .{ .name = "mine", .bind = &.{.{ .key = "d", .local = "zoom" }} }, .user)).ok;
    const defaults_sub = (try parseTable(x, .{ .name = "distro", .prefix = "a", .bind = &.{.{ .key = "x", .local = "zoom" }} }, .defaults)).ok;
    var r = try resolve(x, &.{ builtin_table, venom, user_root }, null);
    try testing.expectEqual(@as(usize, 0), r.conflicts.len);
    // User `d` shadows built-in detach; venom's sub-table is reachable.
    try testing.expect(r.lookup(&.{parseChord("d").?}).exact.binding.target.local.local == .zoom);
    try testing.expect(r.lookup(&.{parseChord("a").?}) == .partial);
    try testing.expect(r.lookup(&.{ parseChord("a").?, parseChord("a").? }) == .exact);
    try testing.expectEqual(@as(usize, 1), r.shadowed.len);
    try testing.expectEqualStrings("venomx", r.shadowed[0].table);
    // A defaults table on the same sub-prefix hides the whole product table.
    r = try resolve(x, &.{ builtin_table, venom, defaults_sub }, null);
    try testing.expect(r.lookup(&.{ parseChord("a").?, parseChord("a").? }) == .none);
    try testing.expectEqual(@as(usize, 2), r.shadowed.len);
    try testing.expectEqualStrings("distro", r.shadowed[0].by);
    // Same layer: overlapping sequences and equal sub-prefixes conflict.
    const one_t = (try parseTable(x, .{ .name = "one", .bind = &.{ .{ .key = "g", .local = "zoom" }, .{ .key = "g g", .local = "zoom" } } }, .user)).ok;
    r = try resolve(x, &.{one_t}, null);
    try testing.expectEqual(@as(usize, 1), r.conflicts.len);
    try testing.expectEqualStrings("g g", r.conflicts[0].key);
    const two_t = (try parseTable(x, .{ .name = "two", .prefix = "a", .bind = &.{.{ .key = "q", .local = "zoom" }} }, .user)).ok;
    const three_t = (try parseTable(x, .{ .name = "three", .prefix = "a", .bind = &.{.{ .key = "r", .local = "zoom" }} }, .user)).ok;
    r = try resolve(x, &.{ two_t, three_t }, null);
    try testing.expectEqual(@as(usize, 1), r.conflicts.len);
    try testing.expectEqual(Layer.user, r.conflicts[0].layer);
    // The same table name in a higher layer replaces the lower one.
    const over = (try parseTable(x, .{ .name = "venom", .prefix = "v", .bind = &.{.{ .key = "a", .local = "zoom" }} }, .user)).ok;
    r = try resolve(x, &.{ venom, over }, null);
    try testing.expect(r.lookup(&.{ parseChord("a").?, parseChord("a").? }) == .none);
    try testing.expect(r.lookup(&.{ parseChord("v").?, parseChord("a").? }) == .exact);
}

test "config: check, ZON layer parse and JSON round trip" {
    try (Config{}).check();
    try testing.expectError(error.InvalidConfig, (Config{ .leader = "ctrl+alt+b" }).check());
    // 0 means no timeout and no delay; small timeouts stay refused.
    try (Config{ .timeout_ms = 0, .popup_delay_ms = 0 }).check();
    try (Config{ .timeout_ms = 100 }).check();
    try testing.expectError(error.InvalidConfig, (Config{ .timeout_ms = 99 }).check());
    try testing.expectError(error.InvalidConfig, (Config{ .popup_delay_ms = 60001 }).check());
    // `keys.prefixes` entries are checked, and one name moves once.
    try (Config{ .prefixes = &.{.{ .name = "venom", .prefix = "a" }} }).check();
    try testing.expectError(error.InvalidConfig, (Config{ .prefixes = &.{.{ .name = "venom", .prefix = "escape" }} }).check());
    try testing.expectError(error.InvalidConfig, (Config{ .prefixes = &.{ .{ .name = "venom", .prefix = "a" }, .{ .name = "venom", .prefix = "b" } } }).check());
    try testing.expectError(error.InvalidConfig, (Config{ .leader = "nope+x" }).check());
    try testing.expectError(error.InvalidConfig, (Config{ .tables = &.{.{ .name = "u", .bind = &.{ .{ .key = "x", .local = "zoom" }, .{ .key = "x", .local = "detach" } } }} }).check());
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const x = arena.allocator();
    const tables = try parseLayer(x,
        \\.{ .status = .{ .position = "top" }, .keys = .{ .leader = "ctrl+b", .tables = .{
        \\    .{ .name = "venom", .prefix = "a", .when = .{ .{ .key = "owner", .value = "venom" } }, .bind = .{
        \\        .{ .key = "a", .exec = .{ "venom", "approve", "--pane", "{pane}" } },
        \\        .{ .key = "s", .verb = "pane.attention", .args = "{\"pane\":\"{pane}\",\"clear\":true}" },
        \\    } },
        \\} } }
    );
    try testing.expectEqual(@as(usize, 1), tables.len);
    const table = (try parseTable(x, tables[0], .user)).ok;
    const json = try tableJson(x, &table);
    const back = (try tableFromJson(x, json)).?;
    try testing.expectEqualStrings("venom", back.name);
    try testing.expect(back.prefix.?.eql(parseChord("a").?));
    try testing.expectEqualStrings("{pane}", back.bindings[0].target.exec[3]);
    try testing.expectEqualStrings("pane.attention", back.bindings[1].target.verb.name);
    try testing.expectEqualStrings("owner", back.when[0].key);
}
