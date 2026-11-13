//! Status rules: the daemon turns events into a segment. A rule
//! is data (event types, string comparisons and a template), never code.
//! Rules come from config (`user.*`, owned by the owner) and from the
//! `status.rule.*` verbs, in the caller's namespace.
//!
//! Each reactor turn reads the event log entries appended since the last
//! turn. A rule only sees an event its principal could read through the
//! `events` verb with its current grants. Decisions are
//! collected first and applied after the scan, because setting a segment
//! appends to the log being read; firings are coalesced to at most one per
//! `coalesce_ms` per rule.
const std = @import("std");
const proto = @import("proto");
const g = proto.grants;
const chrome = @import("chrome.zig");
const ct = @import("term_chrome");
const template = ct.status.template;
const product_mod = @import("product.zig");
const Product = product_mod.Product;
const Batch = product_mod.Batch;
const Value = std.json.Value;
const eq = std.mem.eql;

pub const max_rules_per_namespace = 32;
pub const max_rules = 128;
pub const max_selectors = 8;
/// At most 10 firings per second per rule.
pub const coalesce_ms = 100;

/// `.rule` of a config segment entry (venom-term's `chrome.status.Rule`).
pub const RuleConfig = ct.status.Rule;
pub const Op = RuleConfig.Op;
pub const Match = RuleConfig.Match;
pub const Origin = enum { config, runtime };

/// A rule's definition, borrowed. Both config and `status.rule.set` build one.
pub const Def = struct {
    id: []const u8,
    on: []const []const u8,
    match: []const Match = &.{},
    clear_on: []const []const u8 = &.{},
    format: []const u8,
    ttl_ms: ?u64 = null,
    side: chrome.Side = .right,
    priority: u8 = 50,
    style: chrome.Style = .normal,
    when: []const chrome.Tag = &.{},
    /// `server`, `event` or a session ID.
    scope: []const u8 = "server",
    bind: chrome.Bind = .daemon,
    group: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    click: ?chrome.Click = null,
};

pub const Failure = struct { code: []const u8, param: []const u8, offset: usize = 0, reason: []const u8 = "" };

/// The rule checks shared by config and the verbs. Null when valid.
pub fn check(a: std.mem.Allocator, d: Def) !?Failure {
    if (d.on.len == 0 or d.on.len > max_selectors) return .{ .code = "invalid_params.rule", .param = "on" };
    for (d.on) |x| if (!proto.events.validSelector(x)) return .{ .code = "invalid_params.rule", .param = "on" };
    if (d.match.len > max_selectors) return .{ .code = "invalid_params.rule", .param = "match" };
    for (d.match) |m| if (!validKey(m.key) or !chrome.validText(m.value, 0, 256)) return .{ .code = "invalid_params.rule", .param = "match" };
    if (d.clear_on.len > max_selectors) return .{ .code = "invalid_params.rule", .param = "clear_on" };
    for (d.clear_on) |x| if (!proto.events.validSelector(x)) return .{ .code = "invalid_params.rule", .param = "clear_on" };
    // Lifetime: a rule can't leave a segment up for ever by accident.
    if (d.ttl_ms == null and d.clear_on.len == 0) return .{ .code = "invalid_params.rule", .param = "ttl_ms" };
    if (d.ttl_ms) |t| if (t < 1000 or t > 86400000) return .{ .code = "invalid_params.rule", .param = "ttl_ms" };
    if (try template.check(a, d.format, .rule)) |f| return .{ .code = "invalid_params.template", .param = "format", .offset = f.offset, .reason = f.reason.text() };
    if (d.when.len > chrome.max_tags) return .{ .code = "invalid_params.segment", .param = "when" };
    for (d.when) |t| if (!chrome.validKey(t.key) or !chrome.validValue(t.value)) return .{ .code = "invalid_params.segment", .param = "when" };
    if (d.group) |x| if (!chrome.validGroup(x)) return .{ .code = "invalid_params.segment", .param = "group" };
    if (d.icon) |x| if (!chrome.validIcon(x)) return .{ .code = "invalid_params.segment", .param = "icon" };
    if (d.click) |x| if (!chrome.validClick(x)) return .{ .code = "invalid_params.segment", .param = "click" };
    return null;
}
/// A match key: a top-level data field, or the envelope's `type` and `resource`.
fn validKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 64) return false;
    if (!(std.ascii.isLower(key[0]) or key[0] == '_')) return false;
    for (key) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return false;
    return true;
}

pub const Rule = struct {
    /// Owns the definition's strings.
    arena: std.heap.ArenaAllocator,
    def: Def,
    revision: u64,
    origin: Origin,
    /// The registering connection for `bind = connection`.
    conn: ?*proto.Connection,
    /// Whose `read` grants filter the events this rule sees.
    identity: g.Identity,
    /// The resource of the event that last fired the rule (pending or set).
    fired_resource: ?[]u8 = null,
    last_fire: i64 = std.math.minInt(i64),
    /// A firing waiting for its coalescing window, owned.
    pending: ?Pending = null,
    /// A `clear_on` event arrived since the last apply.
    pending_clear: bool = false,
    /// Doctor: firings applied, and matching events withheld by grants.
    fired: u64 = 0,
    withheld: u64 = 0,
    const Pending = struct { text: []u8, scope: []u8 };

    fn create(gpa: std.mem.Allocator, d: Def, revision: u64, origin: Origin, conn: ?*proto.Connection, identity: g.Identity) !*Rule {
        const r = try gpa.create(Rule);
        errdefer gpa.destroy(r);
        r.* = .{ .arena = .init(gpa), .def = undefined, .revision = revision, .origin = origin, .conn = if (d.bind == .connection) conn else null, .identity = identity };
        errdefer r.arena.deinit();
        const a = r.arena.allocator();
        var def = d;
        def.id = try a.dupe(u8, d.id);
        def.on = try dupeList(a, d.on);
        const match = try a.alloc(Match, d.match.len);
        for (d.match, match) |m, *dst| dst.* = .{ .key = try a.dupe(u8, m.key), .op = m.op, .value = try a.dupe(u8, m.value) };
        def.match = match;
        def.clear_on = try dupeList(a, d.clear_on);
        def.format = try a.dupe(u8, d.format);
        def.when = try chrome.cloneTags(a, d.when);
        def.scope = try a.dupe(u8, d.scope);
        if (d.group) |x| def.group = try a.dupe(u8, x);
        if (d.icon) |x| def.icon = try a.dupe(u8, x);
        if (d.click) |x| def.click = try chrome.cloneClick(x, a);
        r.def = def;
        return r;
    }
    fn destroy(self: *Rule, gpa: std.mem.Allocator) void {
        self.clearPending(gpa);
        if (self.fired_resource) |x| gpa.free(x);
        self.arena.deinit();
        gpa.destroy(self);
    }
    fn clearPending(self: *Rule, gpa: std.mem.Allocator) void {
        if (self.pending) |pd| {
            gpa.free(pd.text);
            gpa.free(pd.scope);
        }
        self.pending = null;
    }
    pub const Json = struct { id: []const u8, on: []const []const u8, match: []const Match, clear_on: []const []const u8, format: []const u8, ttl_ms: ?u64, side: []const u8, priority: u8, style: []const u8, when: []const chrome.Tag, scope: []const u8, bind: []const u8, group: ?[]const u8, icon: ?[]const u8, click: ?chrome.Click, revision: u64, origin: []const u8 };
    pub fn json(self: *const Rule) Json {
        const d = self.def;
        return .{ .id = d.id, .on = d.on, .match = d.match, .clear_on = d.clear_on, .format = d.format, .ttl_ms = d.ttl_ms, .side = @tagName(d.side), .priority = d.priority, .style = @tagName(d.style), .when = d.when, .scope = d.scope, .bind = @tagName(d.bind), .group = d.group, .icon = d.icon, .click = d.click, .revision = self.revision, .origin = @tagName(self.origin) };
    }
    /// The resource whose grants cover the rule: its scope's.
    fn resource(self: *const Rule) g.Resource {
        return chrome.scopeResource(if (eq(u8, self.def.scope, "event")) "server" else self.def.scope);
    }
};
fn dupeList(a: std.mem.Allocator, items: []const []const u8) ![]const []const u8 {
    const out = try a.alloc([]const u8, items.len);
    for (items, out) |x, *dst| dst.* = try a.dupe(u8, x);
    return out;
}

pub const Rules = struct {
    items: std.ArrayList(*Rule) = .empty,
    revision: u64 = 0,
    /// The last log entry the rules have seen, and the log generation.
    seen: u64 = 0,
    generation: u64 = 0,
    started: bool = false,
    pub fn deinit(self: *Rules, a: std.mem.Allocator) void {
        for (self.items.items) |r| r.destroy(a);
        self.items.deinit(a);
    }
    pub fn get(self: *const Rules, id: []const u8) ?*Rule {
        for (self.items.items) |r| if (eq(u8, r.def.id, id)) return r;
        return null;
    }
    fn remove(self: *Rules, r: *Rule) void {
        for (self.items.items, 0..) |x, i| if (x == r) {
            _ = self.items.orderedRemove(i);
            return;
        };
    }
    fn count(self: *const Rules, namespace: []const u8) usize {
        var n: usize = 0;
        for (self.items.items) |r| n += @intFromBool(eq(u8, chrome.idNamespace(r.def.id), namespace));
        return n;
    }
};

// ------------------------------------------------------------------ verbs

pub fn call(p: *Product, c: *proto.Call) !void {
    const verb = c.verb.name;
    if (eq(u8, verb, "status.rule.set")) return ruleSet(p, c);
    if (eq(u8, verb, "status.rule.clear")) return ruleClear(p, c);
    if (eq(u8, verb, "status.rule.list")) return ruleList(p, c);
    unreachable;
}

fn strings(a: std.mem.Allocator, v: ?Value) ![]const []const u8 {
    const items = (v orelse return &.{}).array.items;
    const out = try a.alloc([]const u8, items.len);
    for (items, out) |x, *dst| dst.* = x.string;
    return out;
}
fn fail(c: *proto.Call, f: Failure) !void {
    if (eq(u8, f.code, "invalid_params.template")) return c.fail(f.code, "invalid status template", .{ .param = f.param, .offset = f.offset, .reason = f.reason });
    if (eq(u8, f.code, "invalid_params.segment")) return chrome.segmentInvalid(c, f.param);
    return c.fail(f.code, "invalid status rule", .{ .param = f.param });
}
fn configRule(c: *proto.Call, id: []const u8) !void {
    return c.fail("conflict.config_rule", "the rule comes from the config files", .{ .id = id });
}

fn ruleSet(p: *Product, c: *proto.Call) !void {
    const a = c.arena();
    const o = c.params.object;
    const scope = chrome.arg(c, "scope").?;
    const is_event = eq(u8, scope, "event");
    if (!try p.admit(c, .write, chrome.scopeResource(if (is_event) "server" else scope))) return;
    const id = chrome.arg(c, "id").?;
    if (!chrome.validSegmentId(id)) return chrome.segmentInvalid(c, "id");
    if (!chrome.mayUse(c.namespace(), id, chrome.isolated(c))) return chrome.namespaceDenied(c, id);
    const when: []chrome.Tag = if (o.get("when")) |v| switch (try chrome.parsePairs(a, v, "when", true)) {
        .ok => |pairs| pairs,
        .failed => return chrome.segmentInvalid(c, "when"),
    } else &.{};
    const slot = (try chrome.slotParams(c)) orelse return;
    const match_items = if (o.get("match")) |v| v.array.items else &[_]Value{};
    const match = try a.alloc(Match, match_items.len);
    for (match_items, match) |m, *dst| dst.* = .{ .key = m.object.get("key").?.string, .op = std.meta.stringToEnum(Op, m.object.get("op").?.string).?, .value = m.object.get("value").?.string };
    const def: Def = .{
        .id = id,
        .on = try strings(a, o.get("on")),
        .match = match,
        .clear_on = try strings(a, o.get("clear_on")),
        .format = chrome.arg(c, "format").?,
        .ttl_ms = if (o.get("ttl_ms")) |v| @intCast(v.integer) else null,
        .side = std.meta.stringToEnum(chrome.Side, chrome.arg(c, "side").?).?,
        .priority = @intCast(o.get("priority").?.integer),
        .style = std.meta.stringToEnum(chrome.Style, chrome.arg(c, "style").?).?,
        .when = when,
        .scope = scope,
        .bind = std.meta.stringToEnum(chrome.Bind, chrome.arg(c, "bind").?).?,
        .group = slot.group,
        .icon = slot.icon,
        .click = slot.click,
    };
    if (try check(a, def)) |f| return fail(c, f);
    if (!is_event and !eq(u8, scope, "server") and p.session(scope) == null) return c.fail("not_found.session", "not_found.session", struct {}{});
    const rules = &p.chrome.rules;
    const existing = rules.get(id);
    if (existing) |r| if (r.origin == .config) return configRule(c, id);
    if (existing == null) {
        const same = rules.count(chrome.idNamespace(id));
        if (same >= max_rules_per_namespace or rules.items.items.len >= max_rules) return c.fail("conflict.rule_limit", "too many status rules", .{ .namespace = chrome.idNamespace(id), .limit = @as(u64, if (same >= max_rules_per_namespace) max_rules_per_namespace else max_rules) });
    }
    const r = try Rule.create(p.a, def, rules.revision + 1, .runtime, c.conn, c.conn.identity);
    var committed = false;
    defer if (!committed) r.destroy(p.a);
    if (existing == null) try rules.items.ensureUnusedCapacity(p.a, 1);
    var batch = try Batch.init(p.events);
    defer batch.deinit();
    try batch.append(try Product.resourceName(a, "status", id), "status.rule_changed", .{ .id = id, .revision = r.revision, .rule = r.json() });
    try batch.reserve();
    try chrome.result(c, .{ .id = id, .revision = r.revision });
    start(p);
    rules.revision += 1;
    if (existing) |old| {
        for (rules.items.items) |*slot_ptr| if (slot_ptr.* == old) {
            slot_ptr.* = r;
        };
        old.destroy(p.a);
    } else rules.items.appendAssumeCapacity(r);
    batch.commit();
    committed = true;
}

fn ruleClear(p: *Product, c: *proto.Call) !void {
    const id = chrome.arg(c, "id").?;
    if (!chrome.validSegmentId(id)) return chrome.segmentInvalid(c, "id");
    if (!chrome.mayUse(c.namespace(), id, chrome.isolated(c))) return chrome.namespaceDenied(c, id);
    const r = p.chrome.rules.get(id) orelse {
        if (!try p.admit(c, .write, .{ .kind = "server", .id = "root" })) return;
        return c.fail("not_found.rule", "no such status rule", .{ .id = id });
    };
    if (!try p.admit(c, .write, r.resource())) return;
    if (r.origin == .config) return configRule(c, id);
    var batch = try Batch.init(p.events);
    defer batch.deinit();
    try batch.append(try Product.resourceName(c.arena(), "status", id), "status.rule_cleared", .{ .id = id, .reason = "clear" });
    try batch.reserve();
    try chrome.result(c, struct {}{});
    batch.commit();
    discard(p, r, "rule");
}

fn ruleList(p: *Product, c: *proto.Call) !void {
    const a = c.arena();
    var out: std.ArrayList(Value) = .empty;
    for (p.chrome.rules.items.items) |r| {
        if (!p.registry.allows(c.conn.identity, .read, r.resource(), g.nowSeconds())) continue;
        try out.append(a, try chrome.jsonValue(a, r.json()));
    }
    return chrome.result(c, .{ .rules = out.items });
}

/// Removes a rule whose `status.rule_cleared` was emitted, with its segment.
fn discard(p: *Product, r: *Rule, segment_reason: []const u8) void {
    p.chrome.rules.remove(r);
    if (p.chrome.segment(r.def.id)) |s| if (s.origin == .rule) chrome.unpublish(p, r.def.id, segment_reason);
    r.destroy(p.a);
}
/// Emits `status.rule_cleared` and removes the rule, outside a call.
fn drop(p: *Product, r: *Rule, reason: []const u8, segment_reason: []const u8) void {
    var buf: [128]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "status:{s}", .{r.def.id})) |resource| {
        p.events.append(resource, "status.rule_cleared", .{ .id = r.def.id, .reason = reason }) catch {};
    } else |_| {}
    discard(p, r, segment_reason);
}

/// Rules read the log from the first one on: no history is replayed.
fn start(p: *Product) void {
    const rules = &p.chrome.rules;
    if (rules.started) return;
    rules.started = true;
    rules.seen = p.events.high;
    rules.generation = p.events.generation;
}

// ----------------------------------------------------------------- config

/// Reconciles the config rules with `.status.segments`:
/// new and changed entries are set (`status.rule_changed`), removed ones
/// cleared (`status.rule_cleared`, reason `clear`). Config rules belong to
/// the owner and are `bind = daemon`.
pub fn configure(p: *Product, entries: []const chrome.SegmentEntry) !void {
    const rules = &p.chrome.rules;
    var scratch = std.heap.ArenaAllocator.init(p.a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var i: usize = 0;
    while (i < rules.items.items.len) {
        const r = rules.items.items[i];
        if (r.origin == .config and findEntry(entries, r.def.id) == null) {
            drop(p, r, "clear", "rule");
            continue;
        }
        i += 1;
    }
    for (entries) |e| {
        const def = configDef(e) orelse continue;
        if (try check(sa, def) != null) continue;
        const existing = rules.get(e.id);
        if (existing) |r| {
            if (r.origin != .config) {
                // A runtime rule took the id first; the config entry wins.
                drop(p, r, "clear", "rule");
            } else {
                var tmp = r.json();
                tmp.revision = 0;
                const before = try std.json.Stringify.valueAlloc(sa, tmp, .{});
                const candidate = try Rule.create(p.a, def, 0, .config, null, owner_identity);
                defer candidate.destroy(p.a);
                const after = try std.json.Stringify.valueAlloc(sa, candidate.json(), .{});
                if (eq(u8, before, after)) continue;
            }
        } else {
            if (rules.items.items.len >= max_rules) continue;
        }
        const r = try Rule.create(p.a, def, rules.revision + 1, .config, null, owner_identity);
        var committed = false;
        defer if (!committed) r.destroy(p.a);
        const old = rules.get(e.id);
        if (old == null) try rules.items.ensureUnusedCapacity(p.a, 1);
        try p.events.append(try Product.resourceName(sa, "status", e.id), "status.rule_changed", .{ .id = e.id, .revision = r.revision, .rule = r.json() });
        start(p);
        rules.revision += 1;
        if (old) |x| {
            for (rules.items.items) |*slot| if (slot.* == x) {
                slot.* = r;
            };
            x.destroy(p.a);
        } else rules.items.appendAssumeCapacity(r);
        committed = true;
    }
}
const owner_identity: g.Identity = .{ .principal = g.owner };
fn findEntry(entries: []const chrome.SegmentEntry, id: []const u8) ?*const chrome.SegmentEntry {
    for (entries) |*e| if (e.rule != null and eq(u8, e.id, id)) return e;
    return null;
}
/// The rule an entry defines, or null when it defines none.
pub fn configDef(e: chrome.SegmentEntry) ?Def {
    const rule = e.rule orelse return null;
    return .{
        .id = e.id,
        .on = rule.on,
        .match = rule.match,
        .clear_on = rule.clear_on,
        .format = e.format orelse "",
        .ttl_ms = if (e.ttl_ms) |t| t else null,
        .side = e.side orelse .right,
        .priority = e.priority orelse 50,
        .style = e.style orelse .normal,
        .when = e.when,
        .scope = e.scope orelse "server",
        .bind = .daemon,
        .group = e.group,
        .icon = e.icon,
        .click = e.click,
    };
}

// ------------------------------------------------------------------- turn

/// One reactor turn: read new events, decide, then apply.
pub fn tick(p: *Product) !void {
    const rules = &p.chrome.rules;
    const log = p.events;
    // Revoked principals take their rules with them.
    var i: usize = 0;
    while (i < rules.items.items.len) {
        const r = rules.items.items[i];
        if (r.identity.principal != g.owner) if (p.registry.get(r.identity.principal)) |entry| if (entry.revoked) {
            drop(p, r, "revoked", "revoked");
            continue;
        };
        i += 1;
    }
    if (!rules.started) return;
    if (rules.items.items.len > 0) try scan(p);
    rules.seen = log.high;
    rules.generation = log.generation;
    try apply(p);
}

fn scan(p: *Product) !void {
    const rules = &p.chrome.rules;
    const log = p.events;
    var scratch = std.heap.ArenaAllocator.init(p.a);
    defer scratch.deinit();
    const sa = scratch.allocator();
    const entries = log.entries.items[log.head..];
    // A new generation restarted the sequence: everything retained is new.
    const from = if (rules.generation != log.generation) 0 else rules.seen;
    const now = g.nowSeconds();
    for (entries) |e| {
        if (e.seq <= from) continue;
        var interested = false;
        for (rules.items.items) |r| {
            if (selected(r.def.on, e.type) or selected(r.def.clear_on, e.type)) interested = true;
        }
        if (!interested) continue;
        _ = scratch.reset(.retain_capacity);
        const value = std.json.parseFromSliceLeaky(Value, sa, e.bytes, .{}) catch continue;
        const data: ?std.json.ObjectMap = if (value.object.get("data")) |d| (if (d == .object) d.object else null) else null;
        for (rules.items.items) |r| {
            const fires = selected(r.def.on, e.type) and matches(r.def.match, e.type, e.resource, data);
            const clears = selected(r.def.clear_on, e.type);
            if (!fires and !clears) continue;
            // A rule's own segment changes never feed it.
            if (std.mem.startsWith(u8, e.resource, "status:") and eq(u8, e.resource["status:".len..], r.def.id)) continue;
            if (!visible(p.registry, r.identity, e.resource, now)) {
                if (fires) r.withheld += 1;
                continue;
            }
            if (clears) if (r.fired_resource) |last| if (eq(u8, last, e.resource)) {
                r.clearPending(p.a);
                p.a.free(last);
                r.fired_resource = null;
                r.pending_clear = true;
            };
            if (fires) try decide(p, r, e.type, e.resource, data, sa);
        }
    }
}

/// Renders a firing and keeps it as the rule's pending one.
fn decide(p: *Product, r: *Rule, kind: []const u8, resource: []const u8, data: ?std.json.ObjectMap, sa: std.mem.Allocator) !void {
    // The event envelope, its top-level string and integer fields, and
    // the daemon's host and user. Client variables (pane.*, …) are empty.
    var vars: std.ArrayList(template.Pair) = .empty;
    try vars.appendSlice(sa, &.{ .{ "event.type", kind }, .{ "event.resource", resource }, .{ "host", hostName() }, .{ "user", userName(p) } });
    if (data) |d| {
        var it = d.iterator();
        while (it.next()) |kv| if (fieldText(sa, kv.value_ptr.*)) |text| try vars.append(sa, .{ try std.fmt.allocPrint(sa, "event.{s}", .{kv.key_ptr.*}), text });
    }
    const list: []const template.Pair = vars.items;
    const now = g.nowSeconds();
    const text = (try template.renderSource(sa, r.def.format, .rule, template.pairs(&list, template.Clock.fromEpoch(now, utcOffset(now))))) orelse "";
    const scope: []const u8 = if (eq(u8, r.def.scope, "event")) sessionOf(p, resource) orelse "server" else r.def.scope;
    const owned_text = try p.a.dupe(u8, text);
    errdefer p.a.free(owned_text);
    const owned_scope = try p.a.dupe(u8, scope);
    errdefer p.a.free(owned_scope);
    const owned_resource = try p.a.dupe(u8, resource);
    r.clearPending(p.a);
    r.pending = .{ .text = owned_text, .scope = owned_scope };
    if (r.fired_resource) |x| p.a.free(x);
    r.fired_resource = owned_resource;
    r.pending_clear = false;
}

/// Applies clears at once and firings whose coalescing window has passed.
fn apply(p: *Product) !void {
    const rules = &p.chrome.rules;
    const now = chrome.nowMs();
    for (rules.items.items) |r| {
        if (r.pending_clear) {
            r.pending_clear = false;
            if (p.chrome.segment(r.def.id)) |s| if (s.origin == .rule) chrome.unpublish(p, r.def.id, "rule");
        }
        const pd = r.pending orelse continue;
        if (now -| r.last_fire < coalesce_ms) continue;
        r.last_fire = now;
        defer r.clearPending(p.a);
        // Setting the segment needs `write` on its scope.
        if (!p.registry.allows(r.identity, .write, chrome.scopeResource(pd.scope), g.nowSeconds())) {
            r.withheld += 1;
            continue;
        }
        if (pd.text.len == 0) {
            // A template that renders empty draws nothing.
            if (p.chrome.segment(r.def.id)) |s| if (s.origin == .rule) chrome.unpublish(p, r.def.id, "rule");
            continue;
        }
        if (p.chrome.segment(r.def.id)) |s| if (s.origin != .rule) continue;
        const d = r.def;
        try chrome.publish(p, .{ .id = d.id, .text = pd.text, .side = d.side, .priority = d.priority, .style = d.style, .when = d.when, .scope = pd.scope, .ttl_ms = d.ttl_ms, .bind = d.bind, .conn = r.conn, .principal = r.identity.principal, .group = d.group, .icon = d.icon, .click = d.click, .origin = .rule });
        r.fired += 1;
    }
}

/// The time until a pending firing is due, for the reactor's poll timeout.
pub fn nextDue(p: *const Product) ?i64 {
    var best: ?i64 = null;
    for (p.chrome.rules.items.items) |r| if (r.pending != null) {
        const due = r.last_fire +| coalesce_ms;
        best = if (best) |b| @min(b, due) else due;
    };
    return best;
}

/// The stream server's connection-closed hook: `bind = connection` rules
/// and their segments go with their connection.
pub fn closed(p: *Product, conn: *proto.Connection) void {
    var i: usize = 0;
    while (i < p.chrome.rules.items.items.len) {
        const r = p.chrome.rules.items.items[i];
        if (r.conn == conn) {
            drop(p, r, "disconnect", "disconnect");
            continue;
        }
        i += 1;
    }
}

pub fn appendSnapshot(p: *Product, a: std.mem.Allocator, out: *std.ArrayList(proto.events.Entity)) !void {
    for (p.chrome.rules.items.items) |r| try out.append(a, .{ .resource = try Product.resourceName(a, "status", r.def.id), .entity_type = "status_rule", .content = try std.json.Stringify.valueAlloc(a, r.json(), .{ .emit_null_optional_fields = false }), .event_types = &.{ "status.rule_changed", "status.rule_cleared" } });
}

// ---------------------------------------------------------------- helpers

fn selected(selectors: []const []const u8, kind: []const u8) bool {
    for (selectors) |x| if (proto.events.matchesType(x, kind)) return true;
    return false;
}

/// A top-level string or integer field as text; anything else is missing.
fn fieldText(a: std.mem.Allocator, v: Value) ?[]const u8 {
    return switch (v) {
        .string => |x| x,
        .integer => |x| std.fmt.allocPrint(a, "{d}", .{x}) catch null,
        .number_string => |x| x,
        else => null,
    };
}

/// Matching: every condition holds. A missing field equals no value, so
/// `.ne` holds and `.eq` and `.prefix` don't.
fn matches(conds: []const Match, kind: []const u8, resource: []const u8, data: ?std.json.ObjectMap) bool {
    var buf: [32]u8 = undefined;
    for (conds) |m| {
        const actual: ?[]const u8 = if (eq(u8, m.key, "type")) kind else if (eq(u8, m.key, "resource")) resource else blk: {
            const d = data orelse break :blk null;
            const v = d.get(m.key) orelse break :blk null;
            break :blk switch (v) {
                .string => |x| x,
                .integer => |x| std.fmt.bufPrint(&buf, "{d}", .{x}) catch null,
                .number_string => |x| x,
                else => null,
            };
        };
        const holds = switch (m.op) {
            .eq => if (actual) |x| eq(u8, x, m.value) else false,
            .ne => if (actual) |x| !eq(u8, x, m.value) else true,
            .prefix => if (actual) |x| std.mem.startsWith(u8, x, m.value) else false,
        };
        if (!holds) return false;
    }
    return true;
}

/// The `events` verb's visibility rule for one entry: `read` on
/// the resource, and principal events only for the
/// principal, its ancestors and admin.
pub fn visible(reg: *const g.Registry, identity: g.Identity, resource: []const u8, now: i64) bool {
    const colon = std.mem.indexOfScalar(u8, resource, ':') orelse return false;
    const kind = resource[0..colon];
    const id = resource[colon + 1 ..];
    if (!reg.allows(identity, .read, null, now)) return false;
    if (!reg.allows(identity, .read, .{ .kind = kind, .id = id }, now)) return false;
    if (!eq(u8, kind, "principal")) return true;
    if (g.parseId(id)) |target| return reg.principalVisible(identity, target, now);
    return reg.connectionLive(identity, now) and reg.allows(identity, .admin, null, now);
}

/// The session that contains `resource`, if any (`scope = event`).
fn sessionOf(p: *Product, resource: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, resource, ':') orelse return null;
    var current: ?g.Resource = .{ .kind = resource[0..colon], .id = resource[colon + 1 ..] };
    for (0..16) |_| {
        const r = current orelse return null;
        if (eq(u8, r.kind, "session")) return if (p.session(r.id)) |s| s.id else null;
        current = p.parentOf(r);
    }
    return null;
}

const Tm = extern struct { sec: c_int, min: c_int, hour: c_int, mday: c_int, mon: c_int, year: c_int, wday: c_int, yday: c_int, isdst: c_int, gmtoff: c_long, zone: ?[*:0]const u8 };
extern "c" fn localtime_r(t: *const i64, out: *Tm) ?*Tm;
/// The C library's local UTC offset at `t`, for `clock`.
fn utcOffset(t: i64) i32 {
    var tm: Tm = undefined;
    if (localtime_r(&t, &tm) == null) return 0;
    return @intCast(std.math.clamp(tm.gmtoff, -86400, 86400));
}

var host_buf: [64]u8 = undefined;
var host_len: ?usize = null;
/// The short hostname of the daemon's host.
fn hostName() []const u8 {
    if (host_len == null) {
        var full: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const name = std.posix.gethostname(&full) catch "";
        const short = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
        const n = @min(short.len, host_buf.len);
        @memcpy(host_buf[0..n], short[0..n]);
        host_len = n;
    }
    return host_buf[0..host_len.?];
}
fn userName(p: *Product) []const u8 {
    return p.environ.getPosix("USER") orelse p.environ.getPosix("LOGNAME") orelse "";
}

/// `doctor` (agent-contract impact): rules whose matching events
/// were all withheld by grants never fired.
pub fn doctor(r: *@import("cli").doctor.Report, p: *const Product) !void {
    const fix = try r.command("{s} status rule list --json", r.tool);
    var hidden: std.ArrayList(u8) = .empty;
    var config: usize = 0;
    for (p.chrome.rules.items.items) |rule| {
        config += @intFromBool(rule.origin == .config);
        if (rule.fired == 0 and rule.withheld > 0) {
            if (hidden.items.len > 0) try hidden.appendSlice(r.arena, ", ");
            try hidden.appendSlice(r.arena, rule.def.id);
        }
    }
    const total = p.chrome.rules.items.items.len;
    if (hidden.items.len > 0) return r.add("status.rules", .warn, try r.print("status rules: {d}, {d} from config; never fired because the rule's principal cannot read the events or write the scope: {s}", .{ total, config, hidden.items }), fix);
    try r.add("status.rules", .ok, try r.print("status rules: {d}, {d} from config", .{ total, config }), fix);
}
