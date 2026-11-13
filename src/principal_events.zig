//! Principal events. The registry reports principal changes to an
//! observer; this one turns them into `principal.created`, `principal.revoked`
//! and `principal.denied` on resource `principal:<id>`. Who sees them is
//! decided at delivery by venom-std (the principal, its ancestors, `admin`).
//!
//! An event carries only its documented fields. It never carries a token, the
//! principal's label, or request params: `denied` is built from the verb
//! name, the right and the resource the caller itself named.
const std = @import("std");
const proto = @import("proto");
const g = proto.grants;

pub const Emitter = struct {
    events: *proto.events.Log,
    registry: *g.Registry,
    silent: ?g.Id = null,
    /// Last `principal.denied` per (principal, verb, right), so one agent
    /// retrying a refused verb cannot fill the log. Bounded by `max_tracked`,
    /// and by `max_root_keys` (plus the fold window) for each top-level
    /// principal tree. A tree's keys are linked in the order of `last`.
    last_denied: std.AutoHashMapUnmanaged(DeniedKey, Window) = .empty,
    /// One token bucket per principal tree (keyed by its root): bounds the
    /// tree's events per second whatever the number of verbs and children.
    /// Bounded by `max_tracked`.
    buckets: std.AutoHashMapUnmanaged(g.Id, Bucket) = .empty,
    /// The tree's keys in `last_denied`, so `admit` never scans the table to
    /// count or age them. Holds exactly the roots that have a key.
    roots: std.AutoHashMapUnmanaged(g.Id, Root) = .empty,
    /// Stored keys of each principal (the fold key counts for its root).
    owned: std.AutoHashMapUnmanaged(g.Id, u32) = .empty,
    /// What the rate limit held back per principal: the count its next event
    /// reports, and the folded key it last published. Bounded by
    /// `max_root_keys` entries (plus the root's own) for each tree, so a tree
    /// that mints children cannot fill it; a tree's further counts go to its
    /// root's entry. Also bounded by `max_tracked`; a count that finds the
    /// table full is lost and counted.
    held: std.AutoHashMapUnmanaged(g.Id, Held) = .empty,
    /// Lower bound of the oldest `last` in `last_denied`: while it is live no
    /// key anywhere has expired.
    floor: i64 = 0,
    /// Denials lost to a full table (counted, and warned about each time the
    /// count crosses a power of two).
    dropped: u64 = 0,
    /// How many of those warnings were logged (for tests).
    drop_warnings: u32 = 0,
    /// Tests pin the clock; the daemon leaves it null.
    now_ms: ?i64 = null,

    pub const DeniedKey = struct { principal: g.Id, verb: u64, right: g.Right };
    /// The top-level ancestor of the principal (the child of `owner` that its
    /// chain leads to) owns the key, so a tree of children shares one budget.
    /// `prev` and `next` link the tree's keys, oldest first.
    const Window = struct { last: i64, root: g.Id, prev: ?DeniedKey = null, next: ?DeniedKey = null };
    /// `held_n` counts the tree's `held` entries; the root is kept while it has
    /// keys or entries.
    const Root = struct { keys: u32, head: ?DeniedKey, tail: ?DeniedKey, held_n: u32 = 0 };
    const Bucket = struct { milli: u32, at: i64 };
    const Held = struct { suppressed: u32 = 0, fold: ?Fold = null, root: g.Id = 0 };
    /// The last key of a principal that went to its tree's `(root, *)`
    /// window, and that window's `last` then: its retries in the same window
    /// are coalesced like a retry of a known key.
    const Fold = struct { verb: u64, right: g.Right, since: i64 };
    /// Volume is left to the daemon: one denial per key per window.
    pub const window_ms: i64 = 1000;
    pub const max_tracked: u32 = 1024;
    /// Keys one principal may hold once its tree is this large; its further
    /// keys fold into `fold_key`.
    pub const per_root_keys: u32 = 32;
    /// Keys one tree may hold in all (plus the one fold window): past it even
    /// a principal with no key of its own folds, so minting children cannot
    /// grow a tree beyond this.
    pub const max_root_keys: u32 = 2 * per_root_keys;
    /// A tree publishes `burst` events at once and `rate_per_s` after that.
    pub const rate_per_s: u32 = 2;
    pub const burst: u32 = 4;
    /// A resource the caller named is copied only up to this length.
    pub const max_resource: usize = 64;

    /// The `(principal, *)` key that stands for every verb past the budget.
    const fold_verb: u64 = 0;

    /// What `admit` decided; `record` makes it count once the event is out.
    const Admission = struct { key: DeniedKey, asked: DeniedKey, principal: g.Id, root: g.Id, suppressed: u32, t: i64 };

    pub fn deinit(self: *Emitter) void {
        const gpa = self.events.gpa;
        self.last_denied.deinit(gpa);
        self.buckets.deinit(gpa);
        self.roots.deinit(gpa);
        self.owned.deinit(gpa);
        self.held.deinit(gpa);
    }

    fn now(self: *const Emitter) i64 {
        return self.now_ms orelse @import("server.zig").nowMs();
    }

    pub fn rootOf(self: *const Emitter, id: g.Id) g.Id {
        var cur = id;
        // Ids are issued in increasing order, so a parent is always smaller
        // than its child: the walk ends at the top whatever the depth. A parent
        // that is not smaller is a malformed registry and stops it.
        while (true) {
            const p = self.registry.get(cur) orelse return cur;
            const parent = p.parent orelse return cur;
            if (parent == g.owner or parent >= cur) return cur;
            cur = parent;
        }
    }

    fn lost(self: *Emitter, principal: g.Id) void {
        self.addDropped(principal, 1, "table full");
    }

    /// Every loss goes through here: it warns whenever the count crosses a
    /// power of two, even when it jumps past several at once.
    fn addDropped(self: *Emitter, principal: g.Id, n: u64, why: []const u8) void {
        const before = self.dropped;
        self.dropped +|= n;
        if (!crossesPowerOfTwo(before, self.dropped)) return;
        self.drop_warnings +|= 1;
        std.log.warn("principal.denied dropped for {d} ({d} lost so far): {s}", .{ principal, self.dropped, why });
    }

    fn crossesPowerOfTwo(before: u64, after: u64) bool {
        if (after <= before) return false;
        if (before == 0) return true;
        return std.math.log2_int(u64, after) > std.math.log2_int(u64, before);
    }

    fn refilled(b: Bucket, t: i64) u32 {
        const dt: u64 = @intCast(std.math.clamp(t - b.at, 0, burst * 1000));
        return @intCast(@min(@as(u64, burst) * 1000, @as(u64, b.milli) + dt * rate_per_s));
    }

    fn foldKey(root: g.Id) DeniedKey {
        return .{ .principal = root, .verb = fold_verb, .right = .read };
    }

    /// Keys the principal holds of its own: the tree's fold window is not one.
    fn ownKeys(self: *const Emitter, principal: g.Id, root: g.Id) u32 {
        const n = self.owned.get(principal) orelse 0;
        if (n > 0 and principal == root and self.last_denied.contains(foldKey(root))) return n - 1;
        return n;
    }

    /// The principal's `held` entry, made if the tree's share and the table
    /// allow. Infallible: `admit` reserved the room.
    fn claimHeld(self: *Emitter, principal: g.Id, root: g.Id) ?*Held {
        if (self.held.getPtr(principal)) |h| return h;
        if (self.held.count() >= max_tracked) return null;
        const r = self.roots.getOrPutAssumeCapacity(root);
        if (!r.found_existing) r.value_ptr.* = .{ .keys = 0, .head = null, .tail = null };
        // The root's own entry is the tree's overflow: one more than the share.
        if (r.value_ptr.held_n >= max_root_keys and principal != root) {
            if (!r.found_existing) _ = self.roots.remove(root);
            return null;
        }
        r.value_ptr.held_n += 1;
        const slot = self.held.getOrPutAssumeCapacity(principal);
        slot.value_ptr.* = .{ .root = root };
        return slot.value_ptr;
    }

    fn dropHeld(self: *Emitter, principal: g.Id) void {
        const h = self.held.get(principal) orelse return;
        _ = self.held.remove(principal);
        if (self.roots.getPtr(h.root)) |r| {
            if (r.held_n > 0) r.held_n -= 1;
            if (r.held_n == 0 and r.keys == 0) _ = self.roots.remove(h.root);
        }
    }

    /// Counts one denial the rate limit held back against the principal, or
    /// against its tree's root when the tree has used its share of the table.
    /// Null when the table is full: the denial is lost and counted. `own` is
    /// false for the root's entry standing in for the principal.
    fn holdBack(self: *Emitter, principal: g.Id, root: g.Id, t: i64) ?struct { h: *Held, own: bool } {
        if (self.claimHeld(principal, root)) |h| return .{ .h = h, .own = true };
        if (self.held.count() >= max_tracked) {
            self.pruneHeld(t);
            if (self.claimHeld(principal, root)) |h| return .{ .h = h, .own = true };
        }
        if (self.held.count() < max_tracked and principal != root) {
            if (self.claimHeld(root, root)) |h| return .{ .h = h, .own = false };
        }
        self.lost(principal);
        return null;
    }

    /// Decides whether a denial of this key may be published now. Everything
    /// that can fail is reserved first, so an allocation failure changes
    /// nothing. It may already have evicted another tree's window or a bucket
    /// to make room, and counts the denials held back against the principal.
    /// Only the caller's own window and the tree's token are taken, by
    /// `record`, once the append has succeeded.
    pub fn admit(self: *Emitter, principal: g.Id, verb: []const u8, right: g.Right) !?Admission {
        const t = self.now();
        const gpa = self.events.gpa;
        const root = self.rootOf(principal);
        var key: DeniedKey = .{ .principal = principal, .verb = std.hash.Wyhash.hash(0, verb), .right = right };
        if (key.verb == fold_verb) key.verb = 1;
        const asked = key;
        const known = self.last_denied.get(key);
        // A retry of a live key is coalesced and takes nothing.
        if (known) |w| if (t - w.last < window_ms) return null;
        try self.last_denied.ensureUnusedCapacity(gpa, 1);
        try self.roots.ensureUnusedCapacity(gpa, 1);
        try self.owned.ensureUnusedCapacity(gpa, 1);
        try self.held.ensureUnusedCapacity(gpa, 1);
        try self.buckets.ensureUnusedCapacity(gpa, 1);
        if (known == null) {
            self.compactRoot(root, t);
            const held: u32 = if (self.roots.get(root)) |r| r.keys else 0;
            // Past its budget a principal's further keys share the tree's
            // `(root, *)` window; one with no key of its own is folded only
            // once the tree is at its hard cap.
            if (held >= max_root_keys or (held >= per_root_keys and self.ownKeys(principal, root) > 0)) key = foldKey(root);
        }
        if (self.last_denied.get(key)) |w| {
            if (t - w.last < window_ms) {
                // A new key folded into a busy window is a denial held back;
                // a retry of a key the principal already published through it
                // is just coalesced.
                const hb = self.holdBack(principal, root, t) orelse return null;
                if (hb.own) {
                    if (hb.h.fold) |f| {
                        if (f.since == w.last and f.verb == asked.verb and f.right == asked.right) return null;
                    }
                    hb.h.fold = .{ .verb = asked.verb, .right = asked.right, .since = w.last };
                }
                hb.h.suppressed +|= 1;
                return null;
            }
        }
        const bucket = self.buckets.get(root);
        if (bucket) |b| if (refilled(b, t) < 1000) {
            const hb = self.holdBack(principal, root, t) orelse return null;
            hb.h.suppressed +|= 1;
            return null;
        };
        const suppressed: u32 = if (self.held.get(principal)) |h| h.suppressed else 0;
        if (!self.last_denied.contains(key)) {
            if (self.last_denied.count() >= max_tracked) self.makeRoom(root, principal, t);
            if (self.last_denied.count() >= max_tracked) {
                self.lost(principal);
                return null;
            }
        }
        if (bucket == null) {
            if (self.buckets.count() >= max_tracked) self.pruneBuckets(t);
            if (self.buckets.count() >= max_tracked) self.evictBucket(t);
        }
        return .{ .key = key, .asked = asked, .principal = principal, .root = root, .suppressed = suppressed, .t = t };
    }

    /// Takes the window and one tree token for an admitted denial. Infallible:
    /// the capacity was reserved by `admit`.
    pub fn record(self: *Emitter, a: Admission) void {
        if (self.last_denied.count() == 0) self.floor = a.t else self.floor = @min(self.floor, a.t);
        const slot = self.last_denied.getOrPutAssumeCapacity(a.key);
        if (slot.found_existing) self.unlink(slot.value_ptr);
        slot.value_ptr.* = .{ .last = a.t, .root = a.root };
        const r = self.roots.getOrPutAssumeCapacity(a.root);
        if (!r.found_existing) r.value_ptr.* = .{ .keys = 0, .head = null, .tail = null };
        if (!slot.found_existing) {
            r.value_ptr.keys += 1;
            const o = self.owned.getOrPutAssumeCapacity(a.key.principal);
            o.value_ptr.* = if (o.found_existing) o.value_ptr.* + 1 else 1;
        }
        // Link it as the tree's newest.
        slot.value_ptr.prev = r.value_ptr.tail;
        if (r.value_ptr.tail) |tl| self.last_denied.getPtr(tl).?.next = a.key else r.value_ptr.head = a.key;
        r.value_ptr.tail = a.key;
        const prior: Bucket = self.buckets.get(a.root) orelse .{ .milli = burst * 1000, .at = a.t };
        self.buckets.putAssumeCapacity(a.root, .{ .milli = refilled(prior, a.t) - 1000, .at = a.t });
        // The principal's count is reported now. A denial published through
        // the fold window is remembered, so its retries in that window are
        // coalesced.
        if (a.key.verb == fold_verb) {
            if (self.claimHeld(a.principal, a.root)) |h| {
                h.suppressed = 0;
                h.fold = .{ .verb = a.asked.verb, .right = a.asked.right, .since = a.t };
            }
        } else if (self.held.getPtr(a.principal)) |h| {
            h.suppressed = 0;
            if (h.fold == null) self.dropHeld(a.principal);
        }
    }

    /// Takes the key out of its tree's list.
    fn unlink(self: *Emitter, w: *Window) void {
        const r = self.roots.getPtr(w.root).?;
        if (w.prev) |p| self.last_denied.getPtr(p).?.next = w.next else r.head = w.next;
        if (w.next) |n| self.last_denied.getPtr(n).?.prev = w.prev else r.tail = w.prev;
        w.prev = null;
        w.next = null;
    }

    /// Removes a stored key and its share of the per-tree and per-principal
    /// counts. Safe while iterating `last_denied` or `roots`.
    fn dropKey(self: *Emitter, k: DeniedKey) void {
        const w = self.last_denied.getPtr(k).?;
        const root = w.root;
        self.unlink(w);
        _ = self.last_denied.remove(k);
        const r = self.roots.getPtr(root).?;
        r.keys -= 1;
        if (r.keys == 0 and r.held_n == 0) _ = self.roots.remove(root);
        if (self.owned.getPtr(k.principal)) |n| {
            n.* -= 1;
            if (n.* == 0) _ = self.owned.remove(k.principal);
        }
    }

    /// Forgets the tree's expired windows from the front of its list: each
    /// one is paid for by its own retirement, never by a scan.
    fn compactRoot(self: *Emitter, root: g.Id, t: i64) void {
        while (self.roots.get(root)) |r| {
            const head = r.head orelse return;
            if (t - self.last_denied.get(head).?.last < window_ms) return;
            self.dropKey(head);
        }
    }

    /// The table is full: forget what is expired (when `floor` says there may
    /// be some), and if that is not enough, evict the oldest key of the largest
    /// holder, unless that holder is the caller's own tree.
    fn makeRoom(self: *Emitter, root: g.Id, principal: g.Id, t: i64) void {
        if (t - self.floor >= window_ms) {
            var oldest: i64 = std.math.maxInt(i64);
            var it = self.roots.keyIterator();
            while (it.next()) |rk| {
                const id = rk.*;
                self.compactRoot(id, t);
                if (self.roots.get(id)) |r| if (r.head) |h| {
                    oldest = @min(oldest, self.last_denied.get(h).?.last);
                };
            }
            self.floor = oldest;
        }
        if (self.last_denied.count() < max_tracked) return;
        var biggest: g.Id = root;
        var most: u32 = if (self.roots.get(root)) |r| r.keys else 0;
        var cit = self.roots.iterator();
        while (cit.next()) |e| {
            // On a tie the other tree gives way.
            if (e.key_ptr.* != root and e.value_ptr.keys > 0 and e.value_ptr.keys >= most) {
                most = e.value_ptr.keys;
                biggest = e.key_ptr.*;
            }
        }
        // Its own tree is the largest. A principal with no key of its own
        // still gets one, from a sibling's oldest.
        if (biggest == root and self.ownKeys(principal, root) > 0) return;
        if (self.roots.get(biggest)) |r| if (r.head) |h| self.dropKey(h);
    }

    /// Every bucket is in use: the one nearest to full gives way, so a tree
    /// with no bucket is always admitted. A missing bucket is a full one.
    fn evictBucket(self: *Emitter, t: i64) void {
        var best: ?g.Id = null;
        var most: u32 = 0;
        var it = self.buckets.iterator();
        while (it.next()) |e| {
            const tokens = refilled(e.value_ptr.*, t);
            if (best == null or tokens > most) {
                best = e.key_ptr.*;
                most = tokens;
            }
        }
        if (best) |k| _ = self.buckets.remove(k);
    }

    /// Forget revoked trees and buckets that have refilled completely (a
    /// missing bucket behaves the same).
    fn pruneBuckets(self: *Emitter, t: i64) void {
        var it = self.buckets.iterator();
        while (it.next()) |e| {
            const gone = if (self.registry.get(e.key_ptr.*)) |p| p.revoked else true;
            if (gone or refilled(e.value_ptr.*, t) >= burst * 1000) self.buckets.removeByPtr(e.key_ptr);
        }
    }

    /// Forget revoked principals, and entries that owe no count and remember
    /// no live fold.
    fn pruneHeld(self: *Emitter, t: i64) void {
        var it = self.held.iterator();
        while (it.next()) |e| {
            const gone = if (self.registry.get(e.key_ptr.*)) |p| p.revoked else true;
            const folding = if (e.value_ptr.fold) |f| t - f.since < window_ms else false;
            if (gone or (e.value_ptr.suppressed == 0 and !folding)) {
                const k = e.key_ptr.*;
                self.dropHeld(k);
            }
        }
    }

    /// The resource a caller named, as far as it is safe to publish: all of
    /// it when it is short and made of `[A-Za-z0-9._/-]` after the colon,
    /// else only its kind, else nothing.
    pub fn safeResource(r: []const u8) ?[]const u8 {
        const colon = std.mem.indexOfScalar(u8, r, ':') orelse return null;
        if (colon == 0 or colon > max_resource or !std.ascii.isLower(r[0])) return null;
        for (r[0..colon]) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '_')) return null;
        const rest = r[colon + 1 ..];
        if (rest.len > 0 and r.len <= max_resource) {
            const clean = for (rest) |ch| {
                if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '/' or ch == '-')) break false;
            } else true;
            if (clean) return r;
        }
        return r[0..colon];
    }

    pub fn observer(self: *Emitter) g.Observer {
        return .{ .ptr = self, .changed = changed };
    }

    fn changed(ptr: *anyopaque, change: g.Change) void {
        const self: *Emitter = @ptrCast(@alignCast(ptr));
        // A failed append loses the event, never the operation it reports.
        self.emit(change) catch |err| std.log.warn("principal event {s} dropped: {s}", .{ change.event, @errorName(err) });
    }

    fn emit(self: *Emitter, change: g.Change) !void {
        var arena = std.heap.ArenaAllocator.init(self.events.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var id_buf: [24]u8 = undefined;
        if (std.mem.eql(u8, change.event, "issued") or std.mem.eql(u8, change.event, "restored")) {
            const target = change.target orelse return;
            // A pane's principal is announced by the spawn, inside the batch
            // that creates the pane: a spawn that rolls back publishes nothing.
            if ((self.registry.get(target) orelse return).kind == .pane) return;
            try appendCreated(self.events, a, self.registry, target);
        } else if (std.mem.eql(u8, change.event, "revoked")) {
            const target = change.target orelse return;
            if (target <= g.unknown) return;
            // Its denial windows are no longer needed.
            self.forgetRevoked();
            if (self.silent == target) {
                self.silent = null;
                return;
            }
            const resource = try std.fmt.allocPrint(a, "principal:{s}", .{g.name(target, &id_buf)});
            try self.events.append(resource, "principal.revoked", .{ .reason = change.reason orelse "revoked", .cascade = change.cascade });
        } else if (std.mem.eql(u8, change.event, "denied")) {
            // `unknown` is shared by every unauthenticated caller: no event.
            if (change.principal <= g.unknown) return;
            const code = change.code orelse return;
            const prefix = "denied.";
            if (!std.mem.startsWith(u8, code, prefix)) return;
            // Only a missing right is a `principal.denied`; denied.token,
            // denied.revoked, denied.event_scope and the like are not.
            const right = code[prefix.len..];
            const known = for ([_][]const u8{ "read", "write", "respond", "files", "spawn", "admin" }) |r| {
                if (std.mem.eql(u8, r, right)) break true;
            } else false;
            if (!known) return;
            const admission = (try self.admit(change.principal, change.verb, std.meta.stringToEnum(g.Right, right).?)) orelse return;
            const resource = try std.fmt.allocPrint(a, "principal:{s}", .{g.name(change.principal, &id_buf)});
            // `suppressed`: denials of this principal alone that the rate
            // limit turned away since its last event. Absent when none.
            try self.events.append(resource, "principal.denied", .{
                .verb = change.verb,
                .right = right,
                .resource = if (change.resource) |r| safeResource(r) else null,
                .suppressed = if (admission.suppressed > 0) admission.suppressed else null,
            });
            // Only now does the denial use its window and token.
            self.record(admission);
        }
    }

    fn forgetRevoked(self: *Emitter) void {
        var it = self.last_denied.keyIterator();
        while (it.next()) |k| if (self.registry.get(k.principal)) |p| {
            if (p.revoked) self.dropKey(k.*);
        };
        var bt = self.buckets.keyIterator();
        while (bt.next()) |k| if (self.registry.get(k.*)) |p| {
            if (p.revoked) self.buckets.removeByPtr(k);
        };
        var ht = self.held.keyIterator();
        while (ht.next()) |k| if (self.registry.get(k.*)) |p| {
            if (p.revoked) self.dropHeld(k.*);
        };
    }

    /// The next revocation of `id` is a rolled-back creation that was never
    /// announced, so it is not announced either.
    pub fn silence(self: *Emitter, id: g.Id) void {
        self.silent = id;
    }
};

/// `principal.created` for `id` into a log or a `Batch`. Carries no token and
/// no label.
pub fn appendCreated(sink: anytype, a: std.mem.Allocator, registry: *const g.Registry, id: g.Id) !void {
    const p = registry.get(id) orelse return;
    const Grant = struct { right: []const u8, scope: []const u8 };
    const gs = try a.alloc(Grant, p.grants.len);
    for (p.grants, gs) |src, *dst| dst.* = .{ .right = @tagName(src.right), .scope = src.scope };
    var id_buf: [24]u8 = undefined;
    var parent_buf: [24]u8 = undefined;
    var ts: [32]u8 = undefined;
    const resource = try std.fmt.allocPrint(a, "principal:{s}", .{g.name(id, &id_buf)});
    try sink.append(resource, "principal.created", .{
        .kind = @tagName(p.kind),
        .parent = g.name(p.parent orelse g.owner, &parent_buf),
        .grants = gs,
        // Omitted for a principal that never expires.
        .expires = if (p.expires) |e| try proto.audit.timestamp(e, &ts) else null,
        .pane = p.pane,
    });
}
