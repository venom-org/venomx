//! Shared presentation state, held by the daemon and drawn by
//! every presentation client: pane tags, status segments, attention and the
//! bounded notification queue. Products only write this state with verbs;
//! nothing here moves a client's focus, window, scroll or zoom.
const std = @import("std");
const proto = @import("proto");
const g = proto.grants;
const product_mod = @import("product.zig");
const Product = product_mod.Product;
const Pane = product_mod.Pane;
const Batch = product_mod.Batch;
const Value = std.json.Value;
const eq = std.mem.eql;
const rules_mod = @import("status_rules.zig");
const exec_mod = @import("status_exec.zig");

// ------------------------------------------------------------------ tags

// Syntax, the owned map and `when` matching are venom-term's `chrome.tags`,
// shared with every presentation client.
const ct = @import("term_chrome");
pub const max_tags = ct.tags.max_tags;
pub const Tag = ct.tags.Tag;
pub const validKey = ct.tags.validKey;
pub const validText = ct.tags.validText;
pub const validValue = ct.tags.validValue;
pub const Tags = ct.tags.Tags;

pub const TagFailure = struct { param: []const u8, reason: []const u8 };
/// Reads a schema-validated `[{key,value}]` array. `owner` is rejected
/// unless `allow_owner` (a `when` filter may match on it).
pub fn parsePairs(a: std.mem.Allocator, v: Value, param: []const u8, allow_owner: bool) !union(enum) { ok: []Tag, failed: TagFailure } {
    const items = v.array.items;
    if (items.len > max_tags) return .{ .failed = .{ .param = param, .reason = "count" } };
    const out = try a.alloc(Tag, items.len);
    for (items, out, 0..) |item, *t, i| {
        const key = item.object.get("key").?.string;
        const value = item.object.get("value").?.string;
        const path = try std.fmt.allocPrint(a, "{s}.{d}", .{ param, i });
        if (!validKey(key)) return .{ .failed = .{ .param = path, .reason = "key" } };
        if (!validValue(value)) return .{ .failed = .{ .param = path, .reason = "value" } };
        if (!allow_owner and eq(u8, key, "owner")) return .{ .failed = .{ .param = path, .reason = "owner" } };
        for (out[0..i]) |prev| if (eq(u8, prev.key, key)) return .{ .failed = .{ .param = path, .reason = "duplicate" } };
        t.* = .{ .key = key, .value = value };
    }
    return .{ .ok = out };
}
fn tagsInvalid(c: *proto.Call, f: TagFailure) !void {
    return c.fail("invalid_params.tags", "invalid pane tags", f);
}
/// Creation-verb `tags` plus the daemon-set `owner`, owned by `a`.
/// Null once the call has been answered.
pub fn creationTags(a: std.mem.Allocator, c: *proto.Call) !?Tags {
    var tags: Tags = .{};
    errdefer tags.deinit(a);
    if (c.params.object.get("tags")) |v| switch (try parsePairs(c.arena(), v, "tags", false)) {
        .failed => |f| {
            try tagsInvalid(c, f);
            tags.deinit(a);
            return null;
        },
        .ok => |pairs| {
            if (pairs.len + 1 > max_tags) {
                try tagsInvalid(c, .{ .param = "tags", .reason = "count" });
                tags.deinit(a);
                return null;
            }
            for (pairs) |t| try tags.put(a, t.key, t.value);
        },
    };
    try tags.put(a, "owner", c.namespace());
    return tags;
}

// ------------------------------------------------------------- attention

pub const Level = ct.status.Level;
pub const Attention = struct {
    level: Level = .none,
    reason: []const u8 = "",
    revision: u64 = 0,
    pub fn deinit(self: *Attention, a: std.mem.Allocator) void {
        if (self.reason.len > 0) a.free(self.reason);
        self.reason = "";
    }
};

// -------------------------------------------------------------- segments

/// `left`, `center` or `right`.
pub const Side = ct.status.Side;
pub const Style = ct.status.Style;
pub const Bind = enum { connection, daemon };
pub const max_segments_per_namespace = 32;
pub const max_segments = 128;
/// What produced a segment: `status.set`, a rule or an exec source.
pub const Origin = enum { pushed, rule, exec };

/// A segment's click target: a key binding's target.
pub const Click = ct.status.Click;
pub fn cloneClick(self: Click, a: std.mem.Allocator) !Click {
    var out: Click = .{};
    errdefer deinitClick(&out, a);
    if (self.local) |x| out.local = try a.dupe(u8, x);
    if (self.verb) |x| out.verb = try a.dupe(u8, x);
    if (self.args) |x| out.args = try a.dupe(u8, x);
    if (self.exec) |argv| {
        const list = try a.alloc([]const u8, argv.len);
        var n: usize = 0;
        errdefer {
            for (list[0..n]) |x| a.free(x);
            a.free(list);
        }
        for (argv, list) |x, *dst| {
            dst.* = try a.dupe(u8, x);
            n += 1;
        }
        out.exec = list;
    }
    return out;
}
pub fn deinitClick(self: *Click, a: std.mem.Allocator) void {
    if (self.local) |x| a.free(x);
    if (self.verb) |x| a.free(x);
    if (self.args) |x| a.free(x);
    if (self.exec) |argv| {
        for (argv) |x| a.free(x);
        a.free(argv);
    }
    self.* = .{};
}
/// A request's `click` object (schema-validated), borrowed from it.
pub fn clickFromJson(a: std.mem.Allocator, v: Value) !Click {
    const o = v.object;
    var out: Click = .{};
    if (o.get("local")) |x| out.local = x.string;
    if (o.get("verb")) |x| out.verb = x.string;
    if (o.get("args")) |x| out.args = x.string;
    if (o.get("exec")) |x| {
        const list = try a.alloc([]const u8, x.array.items.len);
        for (x.array.items, list) |item, *dst| dst.* = item.string;
        out.exec = list;
    }
    return out;
}
/// Exactly one of `local`, `verb` (with optional `args`) or `exec`, by the
/// key-binding rules.
pub fn validClick(self: Click) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const keys = @import("keys.zig");
    const parsed = keys.parseBinding(arena.allocator(), .{ .key = "a", .local = self.local, .verb = self.verb, .args = self.args, .exec = self.exec }, "click") catch return false;
    return parsed == .ok;
}
pub const validGroup = ct.status.validGroup;
pub const validIcon = ct.status.validIcon;

pub const Segment = struct {
    id: []const u8,
    text: []const u8,
    side: Side,
    priority: u8,
    style: Style,
    when: []Tag,
    /// `server` or a session ID.
    scope: []const u8,
    ttl_ms: ?u64,
    bind: Bind,
    revision: u64,
    /// The setting connection for `bind = connection`.
    conn: ?*proto.Connection,
    principal: g.Id,
    expires: ?i64,
    group: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    click: ?Click = null,
    origin: Origin = .pushed,
    fn destroy(self: *Segment, a: std.mem.Allocator) void {
        a.free(self.id);
        a.free(self.text);
        freeTags(a, self.when);
        a.free(self.scope);
        if (self.group) |x| a.free(x);
        if (self.icon) |x| a.free(x);
        if (self.click) |*x| deinitClick(x, a);
        a.destroy(self);
    }
    pub const Json = struct { id: []const u8, text: []const u8, side: []const u8, priority: u8, style: []const u8, when: []Tag, scope: []const u8, ttl_ms: ?u64, bind: []const u8, revision: u64, group: ?[]const u8, icon: ?[]const u8, click: ?Click };
    pub fn json(self: *const Segment) Json {
        return .{ .id = self.id, .text = self.text, .side = @tagName(self.side), .priority = self.priority, .style = @tagName(self.style), .when = self.when, .scope = self.scope, .ttl_ms = self.ttl_ms, .bind = @tagName(self.bind), .revision = self.revision, .group = self.group, .icon = self.icon, .click = self.click };
    }
    pub fn resource(self: *const Segment) g.Resource {
        return scopeResource(self.scope);
    }
};
pub fn freeTags(a: std.mem.Allocator, tags: []const Tag) void {
    for (tags) |t| {
        a.free(t.key);
        a.free(t.value);
    }
    a.free(tags);
}
pub fn cloneTags(a: std.mem.Allocator, tags: []const Tag) ![]Tag {
    const out = try a.alloc(Tag, tags.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |t| {
            a.free(t.key);
            a.free(t.value);
        }
        a.free(out);
    }
    for (tags, out) |t, *dst| {
        const k = try a.dupe(u8, t.key);
        errdefer a.free(k);
        dst.* = .{ .key = k, .value = try a.dupe(u8, t.value) };
        filled += 1;
    }
    return out;
}
pub fn scopeResource(scope: []const u8) g.Resource {
    return if (eq(u8, scope, "server")) .{ .kind = "server", .id = "root" } else .{ .kind = "session", .id = scope };
}
/// `<namespace>.<name>`: the namespace matches `[a-z][a-z0-9-]{0,31}`, the
/// name `[a-z0-9][a-z0-9_.-]{0,63}`.
pub fn validSegmentId(id: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, id, '.') orelse return false;
    if (!g.validNamespace(id[0..dot])) return false;
    const name = id[dot + 1 ..];
    if (name.len == 0 or name.len > 64 or !(std.ascii.isLower(name[0]) or std.ascii.isDigit(name[0]))) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_' or ch == '.' or ch == '-')) return false;
    return true;
}
pub fn idNamespace(id: []const u8) []const u8 {
    return id[0 .. std.mem.indexOfScalar(u8, id, '.') orelse id.len];
}
/// A principal sets ids only in its own namespace; `venomx.*` is
/// reserved for built-ins, and a caller in `venomx` (the owner and the panes it
/// created) sets `user.*`. With isolation off any namespace
/// but `venomx` will do.
pub fn mayUse(caller: []const u8, id: []const u8, isolated_: bool) bool {
    const ns = idNamespace(id);
    if (eq(u8, ns, g.owner_namespace)) return false;
    if (!isolated_) return true;
    return eq(u8, ns, if (eq(u8, caller, g.owner_namespace)) g.default_namespace else caller);
}
/// The registry's `grants.isolation`; on without a registry.
pub fn isolated(c: *const proto.Call) bool {
    const r = c.conn.registry orelse return true;
    return r.isolated();
}
/// Who may register under `namespace` (a key table's name, or the
/// `<namespace>.` of a float preset). The `owner` principal may use any but
/// the reserved `venomx`; everyone else only their own namespace. This tests
/// the principal, never the namespace: a pane the owner created reads as
/// `venomx` too and gains nothing from it. With isolation off
/// everyone is treated like the owner.
pub fn mayRegister(principal: g.Id, caller: []const u8, namespace: []const u8, isolated_: bool) bool {
    if (eq(u8, namespace, g.owner_namespace)) return false;
    return !isolated_ or principal == g.owner or eq(u8, namespace, caller);
}

// --------------------------------------------------------- notifications

pub const max_notifications = 64;
pub const NotifyLevel = ct.status.NotifyLevel;
pub const Notification = struct {
    id: []const u8,
    text: []const u8,
    level: NotifyLevel,
    pane: ?[]const u8,
    ttl_ms: u64,
    namespace: []const u8,
    posted: i64,
    /// Connections that dismissed it locally.
    dismissed: std.ArrayList(*proto.Connection) = .empty,
    fn destroy(self: *Notification, a: std.mem.Allocator) void {
        a.free(self.id);
        a.free(self.text);
        if (self.pane) |p| a.free(p);
        a.free(self.namespace);
        self.dismissed.deinit(a);
        a.destroy(self);
    }
    fn json(self: *const Notification) @TypeOf(.{ .id = self.id, .text = self.text, .level = @tagName(self.level), .pane = self.pane, .ttl_ms = self.ttl_ms, .namespace = self.namespace }) {
        return .{ .id = self.id, .text = self.text, .level = @tagName(self.level), .pane = self.pane, .ttl_ms = self.ttl_ms, .namespace = self.namespace };
    }
    fn resource(self: *const Notification) g.Resource {
        return if (self.pane) |p| .{ .kind = "pane", .id = p } else .{ .kind = "server", .id = "root" };
    }
};

// ---------------------------------------------------------------- config

/// Status line configuration, read by every presentation
/// client: venom-term's `chrome.status.Config` (position, the `.left`,
/// `.center` and `.right` lists, `.unlisted` and `.segments`), plus the removed
/// `hide` and `priority`, kept only so that a config that still sets
/// them fails as `invalid_params.config_key`.
pub const StatusConfig = struct {
    const Shared = ct.status.Config;
    pub const Position = Shared.Position;
    pub const Unlisted = Shared.Unlisted;
    position: Position = .top,
    left: []const []const u8 = (Shared{}).left,
    center: []const []const u8 = (Shared{}).center,
    right: []const []const u8 = (Shared{}).right,
    unlisted: Unlisted = .show,
    segments: []const ct.status.Segment = &.{},
    /// Removed: a `.segments` entry with `.show = false` replaces it.
    hide: ?[]const []const u8 = null,
    /// Removed: a `.segments` entry with `.priority` replaces it.
    priority: ?[]const struct { id: []const u8 = "", priority: u8 = 0 } = null,
    /// The client-side view, venom-term's type.
    pub fn shared(self: StatusConfig) Shared {
        return .{ .position = self.position, .left = self.left, .center = self.center, .right = self.right, .unlisted = self.unlisted, .segments = self.segments };
    }
    pub fn segment(self: StatusConfig, id: []const u8) ?ct.status.Segment {
        return self.shared().segment(id);
    }
    pub fn format(self: StatusConfig, id: []const u8) ?[]const u8 {
        return self.shared().format(id);
    }
    /// The daemon's checks of `.segments`: rule and
    /// exec sources only in `user.*`, valid rules, exec argv and intervals,
    /// click targets, at most 16 exec sources and 32 config rules. The
    /// client-side checks are venom-term's `chrome.status.Config.check`.
    pub fn segmentsFailure(self: StatusConfig) ?[]const u8 {
        var execs: usize = 0;
        var rules: usize = 0;
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        for (self.segments) |e| {
            if (e.rule == null and e.exec == null and e.click == null) continue;
            if (!validSegmentId(e.id)) return "invalid_params.segment";
            const user = eq(u8, idNamespace(e.id), g.default_namespace);
            if (!user and (e.rule != null or e.exec != null)) return "invalid_params.segment";
            if (e.click) |x| if (!validClick(x)) return "invalid_params.segment";
            if (e.exec) |x| {
                if (e.rule != null or !exec_mod.validExec(x)) return "invalid_params.segment";
                execs += 1;
            }
            if (rules_mod.configDef(e)) |def| {
                if (e.scope) |x| if (!eq(u8, x, "server") and !eq(u8, x, "event") and !validScopeId(x)) return "invalid_params.segment";
                const failure = rules_mod.check(arena.allocator(), def) catch return "invalid_params.segment";
                if (failure) |f| return if (eq(u8, f.code, "invalid_params.template")) f.code else "invalid_params.segment";
                rules += 1;
            }
        }
        if (execs > exec_mod.max_sources or rules > rules_mod.max_rules_per_namespace) return "invalid_params.segment";
        return null;
    }
};
pub const SegmentEntry = ct.status.Segment;
/// The `config check` error code for an invalid `status`, if any:
/// `invalid_params.config_key` for the removed
/// `hide` and `priority`, then `invalid_params.status_layout`, `.segment`
/// or `.template`.
pub fn statusFailure(config: StatusConfig) ?[]const u8 {
    if (config.hide != null or config.priority != null) return "invalid_params.config_key";
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const failure = (config.shared().check(arena.allocator()) catch return "invalid_params.segment") orelse return null;
    return switch (failure.code) {
        .status_layout => "invalid_params.status_layout",
        .segment => "invalid_params.segment",
        .template => "invalid_params.template",
    };
}
pub const config_errors = [_]@import("cfg").ErrorCode{
    .{ .code = "invalid_params.status_layout", .summary = "A status segment id is listed twice, or on two of status.left, status.center and status.right" },
    .{ .code = "invalid_params.segment", .summary = "A status.segments entry is invalid: a user.* entry without exactly one source, more than one source, a source outside user.*, a bad group, icon or priority, or a repeated id" },
    .{ .code = "invalid_params.template", .summary = "A status.segments format has an unknown variable, a bad spec or unbalanced brackets" },
};
fn validScopeId(x: []const u8) bool {
    if (x.len == 0 or x.len > 64) return false;
    for (x) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return false;
    return true;
}
/// Applies `.status.segments`' rule and exec sources to the daemon, at
/// start and on every reload.
pub fn configure(p: *Product, config: StatusConfig) !void {
    const entries = if (config.segmentsFailure() == null) config.segments else &.{};
    try rules_mod.configure(p, entries);
    try exec_mod.configure(p, entries);
}
/// Attention configuration. `sticky` keeps attention when a client
/// focuses the pane. `from_bell` lets a BEL, or an OSC 7501 report that
/// moves a record to `blocked`, set `info` attention on a pane without any.
pub const AttentionConfig = ct.status.AttentionConfig;

// ----------------------------------------------------------------- state

pub const Chrome = struct {
    segments: std.ArrayList(*Segment) = .empty,
    notifications: std.ArrayList(*Notification) = .empty,
    next_notification: u64 = 0,
    revision: u64 = 0,
    /// Status rules and exec sources.
    rules: rules_mod.Rules = .{},
    exec: exec_mod.Sources = .{},
    pub fn deinit(self: *Chrome, a: std.mem.Allocator) void {
        self.rules.deinit(a);
        self.exec.deinit(a);
        for (self.segments.items) |s| s.destroy(a);
        self.segments.deinit(a);
        for (self.notifications.items) |n| n.destroy(a);
        self.notifications.deinit(a);
    }
    /// Segments a rule or an exec source made, outside the segment limits.
    fn derivedCount(self: *const Chrome) usize {
        var n: usize = 0;
        for (self.segments.items) |s| n += @intFromBool(s.origin != .pushed);
        return n;
    }
    pub fn segment(self: *const Chrome, id: []const u8) ?*Segment {
        for (self.segments.items) |s| if (eq(u8, s.id, id)) return s;
        return null;
    }
    pub fn notification(self: *const Chrome, id: []const u8) ?*Notification {
        for (self.notifications.items) |n| if (eq(u8, n.id, id)) return n;
        return null;
    }
    fn removeSegment(self: *Chrome, s: *Segment) void {
        for (self.segments.items, 0..) |x, i| if (x == s) {
            _ = self.segments.orderedRemove(i);
            return;
        };
    }
    /// Resource containment for `status:<id>` and `notification:<id>`.
    pub fn parentOf(self: *const Chrome, resource: g.Resource) ?g.Resource {
        const root: g.Resource = .{ .kind = "server", .id = "root" };
        if (eq(u8, resource.kind, "status")) return if (self.segment(resource.id)) |s| s.resource() else root;
        if (eq(u8, resource.kind, "notification")) return if (self.notification(resource.id)) |n| n.resource() else root;
        return null;
    }
};

pub fn arg(c: *proto.Call, key: []const u8) ?[]const u8 {
    return if (c.params.object.get(key)) |v| (if (v == .string) v.string else null) else null;
}
pub fn result(c: *proto.Call, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(c.arena(), value, .{ .emit_null_optional_fields = false });
    if (bytes.len + c.id_json.len + 16 > c.conn.max_frame) return c.fail("unsupported.result_size", "unsupported.result_size", struct {}{});
    try c.ok(try std.json.parseFromSliceLeaky(Value, c.arena(), bytes, .{}));
}
pub fn segmentInvalid(c: *proto.Call, param: []const u8) !void {
    return c.fail("invalid_params.segment", "invalid status segment", .{ .param = param });
}
pub fn namespaceDenied(c: *proto.Call, id: []const u8) !void {
    return c.fail("denied.namespace", "id is outside the caller's namespace", .{ .id = id, .namespace = c.namespace() });
}

pub fn call(p: *Product, c: *proto.Call) !void {
    const verb = c.verb.name;
    if (eq(u8, verb, "status.set")) return statusSet(p, c);
    if (eq(u8, verb, "status.clear")) return statusClear(p, c);
    if (eq(u8, verb, "status.list")) return statusList(p, c);
    if (std.mem.startsWith(u8, verb, "status.rule.")) return rules_mod.call(p, c);
    if (eq(u8, verb, "notify.post")) return notifyPost(p, c);
    if (eq(u8, verb, "notify.list")) return notifyList(p, c);
    if (eq(u8, verb, "notify.dismiss")) return notifyDismiss(p, c);
    unreachable;
}

/// Everything a segment is made from, borrowed.
pub const Spec = struct {
    id: []const u8,
    text: []const u8,
    side: Side = .right,
    priority: u8 = 50,
    style: Style = .normal,
    when: []const Tag = &.{},
    scope: []const u8 = "server",
    ttl_ms: ?u64 = null,
    bind: Bind = .daemon,
    conn: ?*proto.Connection = null,
    principal: g.Id = g.owner,
    group: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    click: ?Click = null,
    origin: Origin = .pushed,
};
/// A new segment owning copies of `spec`, at `revision`.
fn newSegment(a: std.mem.Allocator, spec: Spec, revision: u64) !*Segment {
    const s = try a.create(Segment);
    errdefer a.destroy(s);
    const id = try a.dupe(u8, spec.id);
    errdefer a.free(id);
    const text = try a.dupe(u8, spec.text);
    errdefer a.free(text);
    const scope = try a.dupe(u8, spec.scope);
    errdefer a.free(scope);
    const when = try cloneTags(a, spec.when);
    errdefer freeTags(a, when);
    const group: ?[]const u8 = if (spec.group) |x| try a.dupe(u8, x) else null;
    errdefer if (group) |x| a.free(x);
    const icon: ?[]const u8 = if (spec.icon) |x| try a.dupe(u8, x) else null;
    errdefer if (icon) |x| a.free(x);
    const click: ?Click = if (spec.click) |x| try cloneClick(x, a) else null;
    s.* = .{
        .id = id,
        .text = text,
        .side = spec.side,
        .priority = spec.priority,
        .style = spec.style,
        .when = when,
        .scope = scope,
        .ttl_ms = spec.ttl_ms,
        .bind = spec.bind,
        .revision = revision,
        .conn = if (spec.bind == .connection) spec.conn else null,
        .principal = spec.principal,
        .expires = if (spec.ttl_ms) |t| nowMs() + @as(i64, @intCast(t)) else null,
        .group = group,
        .icon = icon,
        .click = click,
        .origin = spec.origin,
    };
    return s;
}
/// Replaces the segment with `s`'s id, or appends it (capacity reserved).
fn install(chrome: *Chrome, a: std.mem.Allocator, s: *Segment) void {
    if (chrome.segment(s.id)) |old| {
        for (chrome.segments.items) |*slot| if (slot.* == old) {
            slot.* = s;
        };
        old.destroy(a);
    } else chrome.segments.appendAssumeCapacity(s);
}
/// Sets a segment outside a call, for rules and exec sources:
/// a new revision, `status.changed`, and a restarted ttl. They are
/// bounded by their own limits, not the segment limits.
pub fn publish(p: *Product, spec: Spec) !void {
    const chrome = &p.chrome;
    const s = try newSegment(p.a, spec, chrome.revision + 1);
    var committed = false;
    defer if (!committed) s.destroy(p.a);
    if (chrome.segment(spec.id) == null) try chrome.segments.ensureUnusedCapacity(p.a, 1);
    var scratch = std.heap.ArenaAllocator.init(p.a);
    defer scratch.deinit();
    try p.events.append(try Product.resourceName(scratch.allocator(), "status", spec.id), "status.changed", .{ .id = spec.id, .revision = s.revision, .segment = s.json() });
    chrome.revision += 1;
    install(chrome, p.a, s);
    committed = true;
}
/// Removes a segment outside a call, if there is one.
pub fn unpublish(p: *Product, id: []const u8, reason: []const u8) void {
    if (p.chrome.segment(id)) |s| drop(p, s, reason);
}

/// `group`, `icon` and `click` of a `status.set` or `status.rule.set`
/// request; null once the call has been answered.
pub fn slotParams(c: *proto.Call) !?struct { group: ?[]const u8, icon: ?[]const u8, click: ?Click } {
    const o = c.params.object;
    const group = arg(c, "group");
    if (group) |x| if (!validGroup(x)) {
        try segmentInvalid(c, "group");
        return null;
    };
    const icon = arg(c, "icon");
    if (icon) |x| if (!validIcon(x)) {
        try segmentInvalid(c, "icon");
        return null;
    };
    const click: ?Click = if (o.get("click")) |v| try clickFromJson(c.arena(), v) else null;
    if (click) |x| if (!validClick(x)) {
        try segmentInvalid(c, "click");
        return null;
    };
    return .{ .group = group, .icon = icon, .click = click };
}

fn statusSet(p: *Product, c: *proto.Call) !void {
    const a = c.arena();
    const o = c.params.object;
    const scope = arg(c, "scope").?;
    if (!try p.admit(c, .write, scopeResource(scope))) return;
    const id = arg(c, "id").?;
    if (!validSegmentId(id)) return segmentInvalid(c, "id");
    if (!mayUse(c.namespace(), id, isolated(c))) return namespaceDenied(c, id);
    const body = arg(c, "text").?;
    if (!validText(body, 0, 256)) return segmentInvalid(c, "text");
    const when: []Tag = if (o.get("when")) |v| switch (try parsePairs(a, v, "when", true)) {
        .ok => |pairs| pairs,
        .failed => return segmentInvalid(c, "when"),
    } else &.{};
    const slot = (try slotParams(c)) orelse return;
    if (!eq(u8, scope, "server") and p.session(scope) == null) return c.fail("not_found.session", "not_found.session", struct {}{});
    const chrome = &p.chrome;
    const existing = chrome.segment(id);
    if (existing == null) {
        var same: usize = 0;
        for (chrome.segments.items) |s| {
            if (s.origin == .pushed and eq(u8, idNamespace(s.id), idNamespace(id))) same += 1;
        }
        const total = chrome.segments.items.len - chrome.derivedCount();
        if (same >= max_segments_per_namespace or total >= max_segments) return c.fail("conflict.segment_limit", "too many status segments", .{ .namespace = idNamespace(id), .limit = @as(u64, if (same >= max_segments_per_namespace) max_segments_per_namespace else max_segments) });
    }
    const pa = p.a;
    // A segment with `ttl_ms` already says when it ends, and a
    // CLI call's would otherwise go as soon as the call returns.
    const bind: Bind = if (arg(c, "bind")) |b| std.meta.stringToEnum(Bind, b).? else if (o.get("ttl_ms") != null) .daemon else .connection;
    const s = try newSegment(pa, .{
        .id = id,
        .text = body,
        .side = std.meta.stringToEnum(Side, arg(c, "side").?).?,
        .priority = @intCast(o.get("priority").?.integer),
        .style = std.meta.stringToEnum(Style, arg(c, "style").?).?,
        .when = when,
        .scope = scope,
        .ttl_ms = if (o.get("ttl_ms")) |v| @intCast(v.integer) else null,
        .bind = bind,
        .conn = c.conn,
        .principal = c.conn.identity.principal,
        .group = slot.group,
        .icon = slot.icon,
        .click = slot.click,
    }, chrome.revision + 1);
    var committed = false;
    defer if (!committed) s.destroy(pa);
    if (existing == null) try chrome.segments.ensureUnusedCapacity(pa, 1);
    var batch = try Batch.init(p.events);
    defer batch.deinit();
    try batch.append(try Product.resourceName(a, "status", id), "status.changed", .{ .id = id, .revision = s.revision, .segment = s.json() });
    try batch.reserve();
    try result(c, .{ .id = id, .revision = s.revision });
    chrome.revision += 1;
    install(chrome, pa, s);
    batch.commit();
    committed = true;
}

fn statusClear(p: *Product, c: *proto.Call) !void {
    const id = arg(c, "id").?;
    if (!validSegmentId(id)) return segmentInvalid(c, "id");
    if (!mayUse(c.namespace(), id, isolated(c))) return namespaceDenied(c, id);
    const s = p.chrome.segment(id) orelse {
        // Authorize against the server before revealing absence.
        if (!try p.admit(c, .write, .{ .kind = "server", .id = "root" })) return;
        return c.fail("not_found.segment", "no such status segment", .{ .id = id });
    };
    if (!try p.admit(c, .write, s.resource())) return;
    var batch = try Batch.init(p.events);
    defer batch.deinit();
    try batch.append(try Product.resourceName(c.arena(), "status", id), "status.cleared", .{ .id = id, .reason = "clear" });
    try batch.reserve();
    try result(c, struct {}{});
    p.chrome.removeSegment(s);
    s.destroy(p.a);
    batch.commit();
}

fn statusList(p: *Product, c: *proto.Call) !void {
    const a = c.arena();
    const scope = arg(c, "scope");
    if (scope) |x| if (!eq(u8, x, "server")) {
        if (!try c.authorize(.read, scopeResource(x))) return;
        if (p.session(x) == null) return c.fail("not_found.session", "not_found.session", struct {}{});
    };
    var out: std.ArrayList(Value) = .empty;
    for (p.chrome.segments.items) |s| {
        if (scope) |x| if (!eq(u8, x, s.scope)) continue;
        if (!p.registry.allows(c.conn.identity, .read, s.resource(), g.nowSeconds())) continue;
        try out.append(a, try jsonValue(a, s.json()));
    }
    return result(c, .{ .segments = out.items });
}

/// Drops a segment outside a call (ttl, disconnect, revoked).
fn drop(p: *Product, s: *Segment, reason: []const u8) void {
    var buf: [128]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "status:{s}", .{s.id})) |resource| {
        p.events.append(resource, "status.cleared", .{ .id = s.id, .reason = reason }) catch {};
    } else |_| {}
    p.chrome.removeSegment(s);
    s.destroy(p.a);
}

/// A BEL from the pane's program, or an OSC 7501 report that moves a
/// record to `blocked`, sets `info` attention on a pane that has none
/// (`attention.from_bell`). These are observations: they never carry
/// approval or identity, and never raise or replace a level a product set.
pub fn observe(p: *Product, pane: *Pane) !void {
    const bell = pane.pane.bell_pending;
    const blocked = pane.observation.blocked_pending;
    if (!bell and !blocked) return;
    pane.pane.bell_pending = false;
    pane.observation.blocked_pending = false;
    if (!p.attention.from_bell or pane.attention.level != .none) return;
    const reason: []const u8 = if (blocked) "program status: blocked" else "bell";
    const owned = try p.a.dupe(u8, reason);
    errdefer p.a.free(owned);
    var scratch = std.heap.ArenaAllocator.init(p.a);
    defer scratch.deinit();
    const resource = try Product.resourceName(scratch.allocator(), "pane", pane.id);
    const revision = pane.attention.revision + 1;
    try p.events.append(resource, "pane.attention_changed", .{ .pane = pane.id, .level = @tagName(Level.info), .reason = reason, .revision = revision });
    pane.attention.deinit(p.a);
    pane.attention = .{ .level = .info, .reason = owned, .revision = revision };
}

/// Status rules and exec sources, once per reactor turn before `tick`.
pub fn tickSources(p: *Product) !void {
    try rules_mod.tick(p);
    try exec_mod.tick(p);
}

/// One reactor turn: expire segments and notifications, and drop segments
/// whose setting principal was revoked.
pub fn tick(p: *Product) void {
    const now = nowMs();
    var i: usize = 0;
    while (i < p.chrome.segments.items.len) {
        const s = p.chrome.segments.items[i];
        if (s.expires) |e| if (now >= e) {
            drop(p, s, "ttl");
            continue;
        };
        if (s.principal != g.owner) if (p.registry.get(s.principal)) |entry| if (entry.revoked) {
            drop(p, s, "revoked");
            continue;
        };
        i += 1;
    }
    i = 0;
    while (i < p.chrome.notifications.items.len) {
        const n = p.chrome.notifications.items[i];
        if (now >= n.posted + @as(i64, @intCast(n.ttl_ms))) {
            _ = p.chrome.notifications.orderedRemove(i);
            n.destroy(p.a);
        } else i += 1;
    }
}

/// The stream server's connection-closed hook: `bind = connection`
/// segments go with their connection, local dismissals too.
pub fn closed(p: *Product, conn: *proto.Connection) void {
    rules_mod.closed(p, conn);
    var i: usize = 0;
    while (i < p.chrome.segments.items.len) {
        const s = p.chrome.segments.items[i];
        if (s.conn == conn) {
            drop(p, s, "disconnect");
            continue;
        }
        i += 1;
    }
    for (p.chrome.notifications.items) |n| {
        var j: usize = 0;
        while (j < n.dismissed.items.len) {
            if (n.dismissed.items[j] == conn) _ = n.dismissed.swapRemove(j) else j += 1;
        }
    }
}

// ------------------------------------------------------------- pane verbs

pub fn paneTag(p: *Product, c: *proto.Call, pane: *Pane) !void {
    const a = c.arena();
    const o = c.params.object;
    var next = try pane.tags.clone(p.a);
    defer next.deinit(p.a);
    if (o.get("unset")) |v| for (v.array.items, 0..) |item, i| {
        const path = try std.fmt.allocPrint(a, "unset.{d}", .{i});
        if (!validKey(item.string)) return tagsInvalid(c, .{ .param = path, .reason = "key" });
        if (eq(u8, item.string, "owner")) return tagsInvalid(c, .{ .param = path, .reason = "owner" });
        next.remove(p.a, item.string);
    };
    if (o.get("set")) |v| switch (try parsePairs(a, v, "set", false)) {
        .failed => |f| return tagsInvalid(c, f),
        .ok => |pairs| for (pairs) |t| try next.put(p.a, t.key, t.value),
    };
    if (next.items.items.len > max_tags) return tagsInvalid(c, .{ .param = "set", .reason = "count" });
    if (next.same(&pane.tags)) return result(c, .{ .pane = pane.id, .tags = pane.tags.items.items });
    var batch = try Batch.init(p.events);
    defer batch.deinit();
    try batch.append(try Product.resourceName(a, "pane", pane.id), "pane.tags_changed", .{ .pane = pane.id, .tags = next.items.items, .revision = pane.tags_revision + 1 });
    try batch.reserve();
    try result(c, .{ .pane = pane.id, .tags = next.items.items });
    std.mem.swap(Tags, &pane.tags, &next);
    pane.tags_revision += 1;
    batch.commit();
}

pub fn paneAttention(p: *Product, c: *proto.Call, pane: *Pane) !void {
    const o = c.params.object;
    const clear = if (o.get("clear")) |v| v.bool else false;
    const given = arg(c, "level");
    if (clear == (given != null)) return c.fail("invalid_params.attention", "give exactly one of level or clear=true", .{ .param = if (clear) "clear" else "level" });
    const level: Level = if (clear) .none else std.meta.stringToEnum(Level, given.?).?;
    const reason = if (level == .none) "" else arg(c, "reason").?;
    if (!validText(reason, 0, 256)) return c.fail("invalid_params.attention", "reason is not 0-256 bytes of text", .{ .param = "reason" });
    const at = &pane.attention;
    if (at.level == level and eq(u8, at.reason, reason)) return result(c, .{ .pane = pane.id, .level = @tagName(level) });
    const owned: []const u8 = if (reason.len > 0) try p.a.dupe(u8, reason) else "";
    var committed = false;
    defer if (!committed and owned.len > 0) p.a.free(owned);
    var batch = try Batch.init(p.events);
    defer batch.deinit();
    try batch.append(try Product.resourceName(c.arena(), "pane", pane.id), "pane.attention_changed", .{ .pane = pane.id, .level = @tagName(level), .reason = reason, .revision = at.revision + 1 });
    try batch.reserve();
    try result(c, .{ .pane = pane.id, .level = @tagName(level) });
    at.deinit(p.a);
    at.* = .{ .level = level, .reason = owned, .revision = at.revision + 1 };
    batch.commit();
    committed = true;
}

// ------------------------------------------------------- notification verbs

fn notifyPost(p: *Product, c: *proto.Call) !void {
    const o = c.params.object;
    if (!try p.admit(c, .write, .{ .kind = "server", .id = "root" })) return;
    const body = arg(c, "text").?;
    if (!validText(body, 1, 512)) return c.fail("invalid_params.notification", "text is not 1-512 bytes of text", .{ .param = "text" });
    const pane_id = arg(c, "pane");
    if (pane_id) |id| {
        if (!try c.authorize(.read, .{ .kind = "pane", .id = id })) return;
        if (p.pane(id) == null) return c.fail("not_found.pane", "not_found.pane", struct {}{});
    }
    const chrome = &p.chrome;
    if (chrome.next_notification == std.math.maxInt(u64)) return error.Overflow;
    const pa = p.a;
    const n = try pa.create(Notification);
    var committed = false;
    defer if (!committed) pa.destroy(n);
    const id = try std.fmt.allocPrint(pa, "n{d}", .{chrome.next_notification});
    defer if (!committed) pa.free(id);
    const owned_text = try pa.dupe(u8, body);
    defer if (!committed) pa.free(owned_text);
    const owned_pane: ?[]const u8 = if (pane_id) |x| try pa.dupe(u8, x) else null;
    defer if (!committed) if (owned_pane) |x| pa.free(x);
    const ns = try pa.dupe(u8, c.namespace());
    defer if (!committed) pa.free(ns);
    n.* = .{ .id = id, .text = owned_text, .level = std.meta.stringToEnum(NotifyLevel, arg(c, "level").?).?, .pane = owned_pane, .ttl_ms = @intCast(o.get("ttl_ms").?.integer), .namespace = ns, .posted = nowMs() };
    try chrome.notifications.ensureUnusedCapacity(pa, 1);
    var batch = try Batch.init(p.events);
    defer batch.deinit();
    try batch.append(try Product.resourceName(c.arena(), "notification", id), "notify.posted", n.json());
    try batch.reserve();
    try result(c, .{ .id = id });
    chrome.next_notification += 1;
    // The queue is bounded: the oldest entry is dropped.
    if (chrome.notifications.items.len >= max_notifications) chrome.notifications.orderedRemove(0).destroy(pa);
    chrome.notifications.appendAssumeCapacity(n);
    batch.commit();
    committed = true;
}

fn notifyList(p: *Product, c: *proto.Call) !void {
    const a = c.arena();
    const now = nowMs();
    var out: std.ArrayList(Value) = .empty;
    for (p.chrome.notifications.items) |n| {
        if (now >= n.posted + @as(i64, @intCast(n.ttl_ms))) continue;
        if (std.mem.indexOfScalar(*proto.Connection, n.dismissed.items, c.conn) != null) continue;
        if (!p.registry.allows(c.conn.identity, .read, n.resource(), g.nowSeconds())) continue;
        try out.append(a, try jsonValue(a, n.json()));
    }
    return result(c, .{ .notifications = out.items });
}

fn notifyDismiss(p: *Product, c: *proto.Call) !void {
    const id = arg(c, "id").?;
    const all = c.params.object.get("all").?.bool;
    if (all and !try p.admit(c, .write, .{ .kind = "server", .id = "root" })) return;
    const n = p.chrome.notification(id) orelse return c.fail("not_found.notification", "no such notification", .{ .id = id });
    if (!try c.authorize(.read, n.resource())) return;
    if (!all) {
        if (std.mem.indexOfScalar(*proto.Connection, n.dismissed.items, c.conn) == null) try n.dismissed.append(p.a, c.conn);
        return result(c, .{ .id = id, .all = false });
    }
    var batch = try Batch.init(p.events);
    defer batch.deinit();
    try batch.append(try Product.resourceName(c.arena(), "notification", id), "notify.dismissed", .{ .id = id });
    try batch.reserve();
    try result(c, .{ .id = id, .all = true });
    for (p.chrome.notifications.items, 0..) |x, i| if (x == n) {
        _ = p.chrome.notifications.orderedRemove(i);
        break;
    };
    n.destroy(p.a);
    batch.commit();
}

// --------------------------------------------------------------- snapshot

pub fn appendSnapshot(p: *Product, a: std.mem.Allocator, out: *std.ArrayList(proto.events.Entity)) !void {
    try rules_mod.appendSnapshot(p, a, out);
    for (p.chrome.segments.items) |s| try out.append(a, .{ .resource = try Product.resourceName(a, "status", s.id), .entity_type = "status", .content = try std.json.Stringify.valueAlloc(a, s.json(), .{ .emit_null_optional_fields = false }), .event_types = &.{ "status.changed", "status.cleared" } });
    const now = nowMs();
    for (p.chrome.notifications.items) |n| {
        const left = n.posted + @as(i64, @intCast(n.ttl_ms)) - now;
        if (left <= 0) continue;
        var v = n.json();
        // A late subscriber shows it only for the time that is left.
        v.ttl_ms = @intCast(left);
        try out.append(a, .{ .resource = try Product.resourceName(a, "notification", n.id), .entity_type = "notification", .content = try std.json.Stringify.valueAlloc(a, v, .{ .emit_null_optional_fields = false }), .event_types = &.{ "notify.posted", "notify.dismissed" } });
    }
}

pub fn jsonValue(a: std.mem.Allocator, v: anytype) !Value {
    return std.json.parseFromSliceLeaky(Value, a, try std.json.Stringify.valueAlloc(a, v, .{ .emit_null_optional_fields = false }), .{});
}
pub fn nowMs() i64 {
    return @import("server.zig").nowMs();
}

test "tag and segment id syntax" {
    const t = std.testing;
    try t.expect(validKey("role") and validKey("a.b-c_9") and !validKey("Role") and !validKey("9a") and !validKey(&@as([33]u8, @splat('a'))));
    try t.expect(validValue("thread-7") and !validValue("") and !validValue("a\x1bb") and !validValue("\xc2\x85") and !validValue(&@as([129]u8, @splat('x'))));
    try t.expect(validSegmentId("venom.agents") and validSegmentId("venom-os.a.b") and !validSegmentId("venom") and !validSegmentId("Venom.x") and !validSegmentId("venom.") and !validSegmentId(".x"));
    try t.expect(mayUse("venom", "venom.agents", true));
    try t.expect(!mayUse("venom", "venomx.clock", true));
    try t.expect(!mayUse("venom", "user.x", true));
    try t.expect(!mayUse("venomx", "venomx.clock", true));
    try t.expect(mayUse("venomx", "user.mine", true));
    try t.expect(mayUse("user", "user.mine", true));
    // Registered names: the owner principal, not the namespace, gets any name.
    try t.expect(mayRegister(g.owner, "venomx", "venom", true));
    try t.expect(mayRegister(g.owner, "venomx", "user", true));
    try t.expect(!mayRegister(g.owner, "venomx", "venomx", true));
    try t.expect(mayRegister(5, "venom", "venom", true));
    try t.expect(!mayRegister(5, "venom", "venom-os", true));
    try t.expect(!mayRegister(5, "venomx", "venom", true));
    try t.expect(!mayRegister(5, "venomx", "user", true));
    try t.expect(!mayRegister(5, "venomx", "venomx", true));
    try t.expect(!mayRegister(5, "user", "venomx", true));
    // With isolation off the namespace is a name, venomx stays reserved.
    try t.expect(mayRegister(5, "venomx", "venom", false));
    try t.expect(mayRegister(5, "user", "venom-os", false));
    try t.expect(!mayRegister(5, "user", "venomx", false));
    try t.expect(mayUse("user", "venom.x", false));
    try t.expect(mayUse("venom", "user.x", false));
    try t.expect(!mayUse("user", "venomx.x", false));
    try t.expect(!mayUse("user", "venom.x", true));
    var tags: Tags = .{};
    defer tags.deinit(t.allocator);
    try tags.put(t.allocator, "role", "agent");
    try tags.put(t.allocator, "group", "g1");
    try tags.put(t.allocator, "role", "shell");
    try t.expectEqualStrings("group", tags.items.items[0].key);
    try t.expectEqualStrings("shell", tags.get("role").?);
    try t.expect(tags.matches(&.{.{ .key = "role", .value = "shell" }}));
    try t.expect(!tags.matches(&.{.{ .key = "role", .value = "agent" }}));
    tags.remove(t.allocator, "group");
    try t.expectEqual(@as(usize, 1), tags.items.items.len);
}
