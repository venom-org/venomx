//! Registered key tables: daemon state, so every presentation
//! client sees them. `keys.register|unregister|list`, `keys.changed`, and the
//! layered report (`shadowed`, conflicts) that `doctor` shares.
const std = @import("std");
const proto = @import("proto");
const g = proto.grants;
const keys = @import("keys.zig");
const chrome = @import("chrome.zig");
const product_mod = @import("product.zig");
const Product = product_mod.Product;
const Batch = product_mod.Batch;
const cli = @import("cli");
const cfg = @import("cfg");
const Value = std.json.Value;
const eq = std.mem.eql;

pub const max_tables = 32;

pub const Registered = struct {
    arena: std.heap.ArenaAllocator,
    table: keys.Table,
    bind: chrome.Bind,
    /// The registering connection for `bind = connection`.
    conn: ?*proto.Connection,
    principal: g.Id,
    fn destroy(self: *Registered, a: std.mem.Allocator) void {
        self.arena.deinit();
        a.destroy(self);
    }
};

pub const Registry = struct {
    tables: std.ArrayList(*Registered) = .empty,
    revision: u64 = 0,
    /// The user and defaults layers (the cfg store in `serve`).
    source: ?keys.ConfigSource = null,
    pub fn deinit(self: *Registry, a: std.mem.Allocator) void {
        for (self.tables.items) |r| r.destroy(a);
        self.tables.deinit(a);
    }
    pub fn find(self: *const Registry, name: []const u8) ?*Registered {
        for (self.tables.items) |r| if (eq(u8, r.table.name, name)) return r;
        return null;
    }
    fn remove(self: *Registry, r: *Registered) void {
        for (self.tables.items, 0..) |x, i| if (x == r) {
            _ = self.tables.orderedRemove(i);
            return;
        };
    }
};

/// Every layer, highest-precedence data last is irrelevant: `resolve` orders
/// by layer. Allocates into `a`.
pub const Report = struct {
    config: keys.Config,
    tables: []const keys.Table,
    resolved: keys.Resolved,
};
pub fn report(p: *Product, a: std.mem.Allocator) !Report {
    const layers: keys.ConfigLayers = if (p.keytables.source) |s| try s.layers(a) else .{};
    var all: std.ArrayList(keys.Table) = .empty;
    try all.append(a, keys.builtin_table);
    for (p.keytables.tables.items) |r| try all.append(a, r.table);
    try keys.configTables(a, layers, &all);
    const effective = try keys.effectiveTables(a, all.items, layers.config.prefixes);
    return .{ .config = layers.config, .tables = effective, .resolved = try keys.resolve(a, effective, null) };
}

fn result(c: *proto.Call, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(c.arena(), value, .{ .emit_null_optional_fields = false });
    if (bytes.len + c.id_json.len + 16 > c.conn.max_frame) return c.fail("unsupported.result_size", "unsupported.result_size", struct {}{});
    try c.ok(try std.json.parseFromSliceLeaky(Value, c.arena(), bytes, .{}));
}
fn invalid(c: *proto.Call, f: keys.Failure) !void {
    return c.fail("invalid_params.bindings", "invalid key table", .{ .param = f.param, .reason = f.reason });
}
fn arg(c: *proto.Call, key: []const u8) ?[]const u8 {
    return if (c.params.object.get(key)) |v| (if (v == .string) v.string else null) else null;
}
const root: g.Resource = .{ .kind = "server", .id = "root" };
fn nameDenied(c: *proto.Call, name: []const u8) !void {
    return c.fail("denied.namespace", "the table name must be the caller's namespace (the owner may use any but venomx)", .{ .id = name, .namespace = c.namespace() });
}

pub fn call(p: *Product, c: *proto.Call) !void {
    const verb = c.verb.name;
    if (eq(u8, verb, "keys.register")) return register(p, c);
    if (eq(u8, verb, "keys.unregister")) return unregister(p, c);
    if (eq(u8, verb, "keys.list")) return list(p, c);
    unreachable;
}

fn shadowJson(s: keys.Shadow) @TypeOf(.{ .key = s.key, .table = s.table, .layer = @tagName(s.layer), .by = s.by, .by_layer = @tagName(s.by_layer) }) {
    return .{ .key = s.key, .table = s.table, .layer = @tagName(s.layer), .by = s.by, .by_layer = @tagName(s.by_layer) };
}

fn register(p: *Product, c: *proto.Call) !void {
    const a = c.arena();
    const o = c.params.object;
    if (!try p.admit(c, .write, root)) return;
    const name = arg(c, "name").?;
    if (!keys.validName(name)) return invalid(c, .{ .param = "name", .reason = "name" });
    if (!chrome.mayRegister(c.conn.identity.principal, c.namespace(), name, chrome.isolated(c))) return nameDenied(c, name);
    const prefix_text = arg(c, "prefix").?;
    const prefix = keys.parseChord(prefix_text) orelse return invalid(c, .{ .param = "prefix", .reason = "key" });
    // Product tables never shadow a built-in.
    if (keys.builtinKey(prefix)) return c.fail("conflict.key_prefix", "the prefix is taken", .{ .prefix = prefix_text, .table = "venomx" });
    const layers: keys.ConfigLayers = if (p.keytables.source) |s| try s.layers(a) else .{};
    // Precedence and conflicts apply to the prefix after `keys.prefixes`.
    const moves = switch (try keys.parsePrefixes(a, layers.config.prefixes)) {
        .ok => |x| x,
        .failed => &.{},
    };
    const effective = keys.effectivePrefix(moves, name, prefix).?;
    for (p.keytables.tables.items) |r| if (!eq(u8, r.table.name, name) and keys.effectivePrefix(moves, r.table.name, r.table.prefix).?.eql(effective)) {
        return c.fail("conflict.key_prefix", "the prefix is taken", .{ .prefix = try keys.chordText(a, effective), .table = r.table.name });
    };
    var config: keys.TableConfig = .{ .name = name, .prefix = prefix_text, .label = arg(c, "label") };
    if (o.get("groups")) |v| config.groups = (try keys.groupConfigsFromJson(a, v)) orelse return invalid(c, .{ .param = "groups", .reason = "group" });
    if (o.get("when")) |v| config.when = (try keys.tagsFromJson(a, v)) orelse return invalid(c, .{ .param = "when", .reason = "tag" });
    const items = o.get("bindings").?.array.items;
    const bind = try a.alloc(keys.BindingConfig, items.len);
    for (items, bind) |item, *dst| dst.* = (try keys.bindingConfigFromJson(a, item)) orelse return invalid(c, .{ .param = "bindings", .reason = "target" });
    config.bind = bind;
    const existing = p.keytables.find(name);
    if (existing == null and p.keytables.tables.items.len >= max_tables) return c.fail("conflict.key_prefix", "too many key tables", .{ .prefix = prefix_text, .table = "" });
    // Validate into scratch first; the stored copy lives in its own arena.
    switch (try keys.parseTable(a, config, .product)) {
        .failed => |f| return invalid(c, f),
        .ok => {},
    }
    const pa = p.a;
    const r = try pa.create(Registered);
    var committed = false;
    defer if (!committed) pa.destroy(r);
    r.arena = .init(pa);
    defer if (!committed) r.arena.deinit();
    const ra = r.arena.allocator();
    r.table = (try keys.parseTable(ra, config, .product)).ok;
    var source_buf: [24]u8 = undefined;
    r.table.source = try ra.dupe(u8, g.name(c.conn.identity.principal, &source_buf));
    const bind_mode = std.meta.stringToEnum(chrome.Bind, arg(c, "bind").?).?;
    r.bind = bind_mode;
    r.conn = if (bind_mode == .connection) c.conn else null;
    r.principal = c.conn.identity.principal;
    // `shadowed`: this table's bindings hidden by a higher layer.
    var all: std.ArrayList(keys.Table) = .empty;
    try all.append(a, keys.builtin_table);
    for (p.keytables.tables.items) |x| if (x != existing) try all.append(a, x.table);
    try all.append(a, r.table);
    try keys.configTables(a, layers, &all);
    const resolved = try keys.resolve(a, try keys.effectiveTables(a, all.items, layers.config.prefixes), null);
    var shadowed: std.ArrayList(@TypeOf(shadowJson(undefined))) = .empty;
    for (resolved.shadowed) |s| if (eq(u8, s.table, name) and s.layer == .product) try shadowed.append(a, shadowJson(s));
    if (existing == null) try p.keytables.tables.ensureUnusedCapacity(pa, 1);
    var batch = try Batch.init(p.events);
    defer batch.deinit();
    try batch.append("server:root", "keys.changed", .{ .layer = "product", .table = name, .revision = p.keytables.revision + 1 });
    try batch.reserve();
    try result(c, .{ .name = name, .prefix = try keys.chordText(a, effective), .layer = "product", .shadowed = shadowed.items });
    p.keytables.revision += 1;
    if (existing) |old| {
        for (p.keytables.tables.items) |*slot| if (slot.* == old) {
            slot.* = r;
        };
        old.destroy(pa);
    } else p.keytables.tables.appendAssumeCapacity(r);
    batch.commit();
    committed = true;
}

fn unregister(p: *Product, c: *proto.Call) !void {
    if (!try p.admit(c, .write, root)) return;
    const name = arg(c, "name").?;
    if (!chrome.mayRegister(c.conn.identity.principal, c.namespace(), name, chrome.isolated(c))) return nameDenied(c, name);
    const r = p.keytables.find(name) orelse return c.fail("not_found.key_table", "no such key table", .{ .name = name });
    var batch = try Batch.init(p.events);
    defer batch.deinit();
    try batch.append("server:root", "keys.changed", .{ .layer = "product", .table = name, .revision = p.keytables.revision + 1 });
    try batch.reserve();
    try result(c, struct {}{});
    p.keytables.revision += 1;
    p.keytables.remove(r);
    r.destroy(p.a);
    batch.commit();
}

fn list(p: *Product, c: *proto.Call) !void {
    const a = c.arena();
    if (!try c.authorize(.read, root)) return;
    const rep = try report(p, a);
    var tables: std.ArrayList(Value) = .empty;
    for (rep.tables) |*t| try tables.append(a, try keys.tableJson(a, t));
    var shadowed: std.ArrayList(@TypeOf(shadowJson(undefined))) = .empty;
    for (rep.resolved.shadowed) |s| try shadowed.append(a, shadowJson(s));
    const Conflict = struct { layer: []const u8, key: []const u8, tables: [2][]const u8 };
    var conflicts: std.ArrayList(Conflict) = .empty;
    for (rep.resolved.conflicts) |x| try conflicts.append(a, .{ .layer = @tagName(x.layer), .key = x.key, .tables = x.tables });
    return result(c, .{ .leader = rep.config.leader, .unlock = rep.config.unlock, .popup_delay_ms = rep.config.popup_delay_ms, .timeout_ms = rep.config.timeout_ms, .revision = p.keytables.revision, .tables = tables.items, .shadowed = shadowed.items, .conflicts = conflicts.items });
}

fn drop(p: *Product, r: *Registered) void {
    p.keytables.revision += 1;
    p.events.append("server:root", "keys.changed", .{ .layer = "product", .table = r.table.name, .revision = p.keytables.revision }) catch {};
    p.keytables.remove(r);
    r.destroy(p.a);
}
/// `bind = connection` tables go with their connection (as segments do).
pub fn closed(p: *Product, conn: *proto.Connection) void {
    var i: usize = 0;
    while (i < p.keytables.tables.items.len) {
        const r = p.keytables.tables.items[i];
        if (r.conn == conn) drop(p, r) else i += 1;
    }
}
/// Tables of a revoked principal are dropped.
pub fn tick(p: *Product) void {
    var i: usize = 0;
    while (i < p.keytables.tables.items.len) {
        const r = p.keytables.tables.items[i];
        if (r.principal != g.owner) if (p.registry.get(r.principal)) |entry| if (entry.revoked) {
            drop(p, r);
            continue;
        };
        i += 1;
    }
}

/// same-layer conflicts fail, cross-layer shadowing warns, and
/// a leader the terminal may not deliver warns.
pub fn doctor(r: *cli.doctor.Report, p: *Product) !void {
    const fix = try r.command("{s} keys list --json", r.tool);
    const rep = try report(p, r.arena);
    if (rep.resolved.conflicts.len > 0) {
        const x = rep.resolved.conflicts[0];
        try r.add("keys.conflicts", .fail, try r.print("{d} same-layer key conflict(s); first: {s} layer, key \"{s}\" in tables {s} and {s}", .{ rep.resolved.conflicts.len, @tagName(x.layer), x.key, x.tables[0], x.tables[1] }), try r.command("{s} config check --json", r.tool));
    } else try r.add("keys.conflicts", .ok, "no same-layer key conflicts", fix);
    if (rep.resolved.shadowed.len > 0) {
        var text: std.ArrayList(u8) = .empty;
        for (rep.resolved.shadowed[0..@min(rep.resolved.shadowed.len, 4)], 0..) |x, i| try text.print(r.arena, "{s}{s} \"{s}\" ({s}) by {s} ({s})", .{ if (i > 0) "; " else "", x.table, x.key, @tagName(x.layer), x.by, @tagName(x.by_layer) });
        try r.add("keys.shadowed", .warn, try r.print("{d} binding(s) shadowed by a higher layer: {s}", .{ rep.resolved.shadowed.len, text.items }), fix);
    } else try r.add("keys.shadowed", .ok, "no binding is shadowed", fix);
    const leader = keys.parseChord(rep.config.leader).?;
    const unlock = keys.parseChord(rep.config.unlock).?;
    const config_fix = try r.command("{s} config set --key keys.leader --value '\"ctrl+b\"'", r.tool);
    if (leader.plain()) {
        try r.add("keys.leader", .warn, try r.print("leader {s} is an ordinary key: typing it in a pane opens the leader", .{rep.config.leader}), config_fix);
    } else if (!keys.legacyDeliverable(leader) or !keys.legacyDeliverable(unlock)) {
        try r.add("keys.leader", .warn, try r.print("leader {s} / unlock {s}: {s} needs the Kitty keyboard protocol; a terminal without it cannot send it", .{ rep.config.leader, rep.config.unlock, if (!keys.legacyDeliverable(leader)) rep.config.leader else rep.config.unlock }), config_fix);
    } else try r.add("keys.leader", .ok, try r.print("leader {s}, unlock {s}", .{ rep.config.leader, rep.config.unlock }), config_fix);
}
/// Each config file's `keys.tables` with its layer (the
/// effective config merges them per name), for keys.list, doctor and check.
pub fn KeyLayers(comptime Store: type) type {
    return struct {
        store: *Store,
        fn layers(ptr: *anyopaque, a: std.mem.Allocator) anyerror!keys.ConfigLayers {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            // `config set` writes the file and leaves the store's active value
            // alone, and every `keys` setting applies at once: read what is on disk.
            // When the files do not load, the active value stands.
            const current = effective(self.store, a) catch |err| if (err == error.OutOfMemory) return err else self.store.current().keys;
            const io = self.store.options.io;
            // An unreadable file: report the effective tables as user tables.
            const fallback: keys.ConfigLayers = .{ .config = current, .user = current.tables };
            var out: keys.ConfigLayers = .{ .config = current };
            out.user = (keys.readLayer(a, io, self.store.path) catch |err| return if (err == error.OutOfMemory) err else fallback) orelse &.{};
            for (self.store.options.defaults) |path| if (keys.readLayer(a, io, path) catch |err| return if (err == error.OutOfMemory) err else fallback) |tables| {
                out.defaults = tables;
                break;
            };
            return out;
        }
        fn effective(store: *Store, a: std.mem.Allocator) !keys.Config {
            return keys.parseConfig(a, try store.get(a, "keys"));
        }
        pub fn source(self: *@This()) keys.ConfigSource {
            return .{ .ptr = self, .f = layers };
        }
    };
}
/// The same-layer key conflict code, declared on the shared config
/// verbs with `cfg.mergeWith`.
pub const config_errors = [_]cfg.ErrorCode{.{ .code = "invalid_params.key_conflict", .summary = "Two key tables of one config file bind the same key or sub-prefix; data.source names the file" }};
/// `cfg.Store`'s `validate_layer` for `keys.tables`: one config file's own
/// tables, resolved alone, must not conflict. The store
/// runs it per file wherever layers merge (init, get, set, check, reload,
/// watch) and reports the file as `source`. Cross-layer shadowing is not a
/// conflict; `doctor` reports it.
pub fn layerConflict(config: keys.Config, source: cfg.Source) ?cfg.Validation {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    // One file names a table once; the merge would hide a repeat.
    const prefixes = keys.parsePrefixes(arena.allocator(), config.prefixes) catch return null;
    if (prefixes == .failed) return .{ .key = "keys.prefixes" };
    // Out of memory: no verdict here; `keys.Config.check` still runs.
    const conflict = tablesConflict(arena.allocator(), config.tables, if (source == .defaults) .defaults else .user) catch return null;
    return if (conflict) .{ .key = "keys.tables", .code = "invalid_params.key_conflict" } else null;
}
fn tablesConflict(a: std.mem.Allocator, tables: []const keys.TableConfig, layer: keys.Layer) !bool {
    var parsed: std.ArrayList(keys.Table) = .empty;
    try keys.configTables(a, if (layer == .defaults) .{ .defaults = tables } else .{ .user = tables }, &parsed);
    return (try keys.resolve(a, parsed.items, null)).conflicts.len > 0;
}
