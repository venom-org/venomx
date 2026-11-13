//! venomx's single format-1 product manifest. Shared bundles merge before
//! CLI/MCP/docs/completions generation and complete-schema digest calculation.
const proto = @import("proto");
const s = proto.schema;
const cli = @import("cli");
pub const str: s.Type = .{ .kind = .string };
const int: s.Type = .{ .kind = .integer, .min = 0, .max = 9007199254740991 };
const boolean: s.Type = .{ .kind = .boolean };
pub fn field(comptime field_name: []const u8, comptime t: s.Type, comptime required: bool) s.Field {
    return .{ .name = field_name, .summary = field_name, .type = t, .required = required };
}
fn obj(comptime fields: []const s.Field) s.Type {
    return .{ .kind = .object, .fields = fields };
}
fn array(comptime t: s.Type) s.Type {
    return .{ .kind = .array, .items = &t };
}
const empty = obj(&.{});
const session = field("session", str, true);
const window = field("window", str, true);
const pane = field("pane", str, true);
/// The basename of the executed argv[0], at most 255 bytes.
const argv0_type: s.Type = str;
const name = field("name", str, true);
const name_param: s.Field = .{ .name = "name", .summary = "Display name (at most 128 UTF-8 bytes)", .type = str, .default = "\"\"" };
const session_item = obj(&.{ session, name });
const window_item = obj(&.{ window, name });
const axis: s.Type = .{ .kind = .string, .choices = &.{ "cols", "rows" } };
pub const node = obj(&.{ field("kind", .{ .kind = .string, .choices = &.{ "pane", "split" } }, true), field("pane", str, false), field("axis", axis, false), field("first", int, false), field("second", int, false), .{ .name = "ratio", .summary = "A split's first child's share of its cells, in 1/10000; absent means equal shares", .type = .{ .kind = .integer, .min = 1, .max = 9999 } } });
const nodes = field("nodes", array(node), true);
const revision = field("revision", int, true);
pub const layout_fields = [_]s.Field{ window, session, name, revision, nodes };
pub const layout = obj(&layout_fields);
pub const changed_fields = [_]s.Field{ window, session, revision, nodes };
const grants = array(obj(&.{ field("right", .{ .kind = .string, .choices = &.{ "none", "read", "write", "respond", "files", "spawn", "admin" } }, true), field("scope", str, true) }));
const spawn_params = [_]s.Field{
    field("argv", array(str), true),
    .{ .name = "cols", .summary = "Initial columns", .type = .{ .kind = .integer }, .default = "80" },
    .{ .name = "rows", .summary = "Initial rows", .type = .{ .kind = .integer }, .default = "24" },
    field("grants", grants, false),
    // Spawn cwd and environment. Optional with no defaults; absence differs from empty.
    .{ .name = "cwd", .summary = "Absolute working directory for the new process; default: the daemon's working directory", .type = str },
    .{ .name = "env", .summary = "Environment variables to set or replace in the new process, applied after env_unset", .type = array(obj(&.{
        .{ .name = "name", .summary = "Variable name", .type = str, .required = true },
        .{ .name = "value", .summary = "Variable value", .type = str, .required = true },
    })) },
    .{ .name = "env_unset", .summary = "Environment variable names to remove from the inherited environment", .type = array(str) },
};
/// The file to execute when it differs from argv[0].
const program_param: s.Field = .{ .name = "program", .summary = "File to execute, resolved like argv[0] would be; argv is then passed as given, so argv[0] may be any name, such as -sh for a login shell; default: argv[0]", .type = str };
/// Optional closed recovery metadata of a restored archive.
pub const recovery_meta = obj(&.{ field("checkpoint", str, true), field("previous_pane", str, true), field("process_state", .{ .kind = .string, .choices = &.{ "exited", "interrupted" } }, true), field("text_state", .{ .kind = .string, .choices = &.{ "omitted", "expired", "plain" } }, true), field("cut_rows", int, true) });
const recovery_field = field("recovery", recovery_meta, false);
const spawned = obj(&.{ pane, window, session, field("principal", str, true), field("pid", int, true) });
const errors = blk: {
    const codes = .{ "invalid_params.name", "invalid_params.argv", "invalid_params.size", "not_found.session", "not_found.window", "not_found.pane", "denied.read", "denied.write", "denied.spawn", "denied.delegation", "conflict.not_empty", "conflict.pane_running", "conflict.pane_exited", "unavailable.spawn", "unavailable.input", "unavailable.shutdown", "unsupported.result_size", "conflict.pane_terminating", "conflict.removing", "timeout.terminate" };
    var out: [codes.len]s.ErrorDecl = undefined;
    for (codes, 0..) |code, i| out[i] = .{ .code = code, .summary = code };
    break :blk out;
};
fn verb(comptime n: []const u8, comptime params: []const s.Field, comptime result: s.Type, comptime grant: s.Grant) s.Verb {
    return .{ .name = n, .summary = n, .params = params, .result = result, .grant = grant, .errors = &errors };
}
fn reasons(comptime choices: []const []const u8) s.Type {
    return obj(&.{field("reason", .{ .kind = .string, .choices = choices }, false)});
}
fn reasoned(comptime param: s.Type, comptime choices: []const []const u8) s.Type {
    return obj(&.{ field("param", param, true), field("reason", .{ .kind = .string, .choices = choices }, true) });
}
const spawn_env = @import("spawn_env.zig");
/// The spawn verbs' error set, with the changed
/// `unavailable.spawn` descriptor and the four new codes.
const spawn_errors = blk: {
    var out: [errors.len + 4]s.ErrorDecl = undefined;
    for (errors, 0..) |e, i| out[i] = if (@import("std").mem.eql(u8, e.code, "unavailable.spawn")) .{ .code = e.code, .summary = "The program could not be started; data.reason says why", .data = reasons(&spawn_env.spawn_reasons) } else e;
    out[errors.len] = .{ .code = "invalid_params.cwd", .summary = "cwd is not an absolute path of 1-4095 bytes without NUL", .data = reasoned(.{ .kind = .string, .choices = &.{"cwd"} }, &.{ "relative", "size", "nul" }) };
    out[errors.len + 1] = .{ .code = "invalid_params.env", .summary = "An env or env_unset entry is invalid (syntax, size, NUL, count, duplicate, reserved or credential-looking); data names its path, never its value", .data = reasoned(str, &spawn_env.env_reasons) };
    out[errors.len + 2] = .{ .code = "not_found.cwd", .summary = "cwd does not name an existing directory", .data = empty };
    out[errors.len + 3] = .{ .code = "unavailable.cwd", .summary = "cwd exists but cannot be resolved or entered", .data = reasons(&spawn_env.cwd_reasons) };
    const frozen = out;
    break :blk frozen;
};
/// Exited-pane removal policy, fixed at creation.
pub const on_exit_param: s.Field = .{ .name = "on_exit", .summary = "What happens when the pane's process exits: keep the exited pane (default) or remove it, cascading to an emptied window and an on_empty=remove session", .type = .{ .kind = .string, .choices = &.{ "keep", "remove" } }, .default = "\"keep\"" };
const on_empty_param: s.Field = .{ .name = "on_empty", .summary = "What happens when an on_exit cascade leaves the session without windows: keep it (default) or remove it", .type = .{ .kind = .string, .choices = &.{ "keep", "remove" } }, .default = "\"keep\"" };
fn spawnVerb(comptime n: []const u8, comptime params: []const s.Field, comptime summary: []const u8) s.Verb {
    return .{ .name = n, .summary = summary, .params = params, .result = spawned, .grant = .spawn, .errors = &spawn_errors };
}
// Pane tags. Format 1 has no map type, so a tag map is an array
// of `{key, value}` pairs (sorted by key in results and events).
pub const tag_pair = obj(&.{
    .{ .name = "key", .summary = "Tag key, [a-z][a-z0-9_.-]{0,31}", .type = str, .required = true },
    .{ .name = "value", .summary = "Tag value, 1-128 bytes of UTF-8 without control characters", .type = str, .required = true },
});
pub const tag_map = array(tag_pair);
const tags_error: s.ErrorDecl = .{ .code = "invalid_params.tags", .summary = "A tag breaks a tag rule (key or value syntax, duplicate, the read-only owner, or more than 16 tags)", .data = reasoned(str, &.{ "key", "value", "duplicate", "owner", "count" }) };
const tagged_spawn_errors = spawn_errors ++ [_]s.ErrorDecl{tags_error};
const tags_param: s.Field = .{ .name = "tags", .summary = "Pane tags as [{key,value}]; the daemon adds the read-only owner tag (the creator's namespace)", .type = tag_map };
fn taggedSpawnVerb(comptime n: []const u8, comptime params: []const s.Field, comptime summary: []const u8) s.Verb {
    var v = spawnVerb(n, params ++ &[_]s.Field{tags_param}, summary);
    v.errors = &tagged_spawn_errors;
    return v;
}
// Status segments, attention and notifications.
const level: s.Type = .{ .kind = .string, .choices = &.{ "none", "info", "warn", "urgent" } };
const notify_level: s.Type = .{ .kind = .string, .choices = &.{ "info", "warn", "urgent" } };
const segment_style: s.Type = .{ .kind = .string, .choices = &.{ "normal", "muted", "accent", "ok", "warn", "error" } };
const side: s.Type = .{ .kind = .string, .choices = &.{ "left", "center", "right" } };
// A segment's group and click target.
const segment_group = str;
pub const click = obj(&.{
    .{ .name = "local", .summary = "A local client action", .type = str },
    .{ .name = "verb", .summary = "A venomx schema verb sent with the clicking client's own identity", .type = str },
    .{ .name = "args", .summary = "The verb's params as JSON object text", .type = str },
    .{ .name = "exec", .summary = "An argv the client runs with no shell and no venomx token", .type = array(str) },
});
const bind: s.Type = .{ .kind = .string, .choices = &.{ "connection", "daemon" } };
const ttl: s.Type = .{ .kind = .integer, .min = 1000, .max = 86400000 };
const segment_id: s.Field = .{ .name = "id", .summary = "Segment ID <namespace>.<name>; the namespace must be the caller's (venomx.* is reserved)", .type = str, .required = true };
pub const segment_fields = [_]s.Field{
    field("id", str, true),              field("text", str, true),     field("side", side, true),            field("priority", .{ .kind = .integer, .min = 0, .max = 100 }, true),
    field("style", segment_style, true), field("when", tag_map, true), field("scope", str, true),            field("ttl_ms", ttl, false),
    field("bind", bind, true),           field("revision", int, true), field("group", segment_group, false), field("icon", str, false),
    field("click", click, false),
};
pub const segment = obj(&segment_fields);
const group_param: s.Field = .{ .name = "group", .summary = "Draw inside this group's segment (the tray is tray) instead of on its own", .type = segment_group };
const icon_param: s.Field = .{ .name = "icon", .summary = "What a group draws for it, at most 2 cells; the text when absent", .type = str };
const click_param: s.Field = .{ .name = "click", .summary = "Binding target a left click runs as the clicking client: exactly one of local, verb (with args) or exec", .type = click };
// Status rules.
const rule_match = obj(&.{
    .{ .name = "key", .summary = "A top-level data field, or type or resource", .type = str, .required = true },
    .{ .name = "op", .summary = "eq, ne or prefix; values compare as strings", .type = .{ .kind = .string, .choices = &.{ "eq", "ne", "prefix" } }, .required = true },
    .{ .name = "value", .summary = "The value to compare with", .type = str, .required = true },
});
pub const rule_fields = [_]s.Field{
    field("id", str, true),                                                            field("on", array(str), true), field("match", array(rule_match), true), field("clear_on", array(str), true),
    field("format", str, true),                                                        field("ttl_ms", ttl, false),   field("side", side, true),               field("priority", .{ .kind = .integer, .min = 0, .max = 100 }, true),
    field("style", segment_style, true),                                               field("when", tag_map, true),  field("scope", str, true),               field("bind", bind, true),
    field("group", segment_group, false),                                              field("icon", str, false),     field("click", click, false),            field("revision", int, true),
    field("origin", .{ .kind = .string, .choices = &.{ "config", "runtime" } }, true),
};
pub const rule = obj(&rule_fields);
const notification_fields = [_]s.Field{ field("id", str, true), field("text", str, true), field("level", notify_level, true), field("pane", str, false), field("ttl_ms", int, true), field("namespace", str, true) };
fn chromeErrors(comptime extra: []const s.ErrorDecl) []const s.ErrorDecl {
    const base = [_]s.ErrorDecl{
        .{ .code = "denied.read", .summary = "The caller cannot read the target" },
        .{ .code = "denied.write", .summary = "The caller cannot write the target" },
        .{ .code = "unavailable.shutdown", .summary = "The daemon is stopping" },
        .{ .code = "unsupported.result_size", .summary = "The reply exceeds max_frame" },
    };
    const out = base ++ extra[0..extra.len].*;
    return &out;
}
const segment_errors = chromeErrors(&.{
    .{ .code = "invalid_params.segment", .summary = "Bad id, text (at most 256 bytes, no control characters) or when", .data = obj(&.{field("param", .{ .kind = .string, .choices = &.{ "id", "text", "when", "group", "icon", "click" } }, true)}) },
    .{ .code = "denied.namespace", .summary = "The id is outside the caller's namespace, or venomx.*", .data = obj(&.{ field("id", str, true), field("namespace", str, true) }) },
    .{ .code = "conflict.segment_limit", .summary = "More than 32 segments for one namespace, or 128 in total", .data = obj(&.{ field("namespace", str, true), field("limit", int, true) }) },
    .{ .code = "not_found.session", .summary = "The scope names no session" },
    .{ .code = "not_found.segment", .summary = "No segment has this id" },
});
const rule_errors = chromeErrors(&.{
    .{ .code = "invalid_params.segment", .summary = "Bad id, when, group, icon or click", .data = obj(&.{field("param", .{ .kind = .string, .choices = &.{ "id", "when", "group", "icon", "click" } }, true)}) },
    .{ .code = "invalid_params.rule", .summary = "Bad on, match or clear_on, or neither ttl_ms nor clear_on", .data = obj(&.{field("param", .{ .kind = .string, .choices = &.{ "on", "match", "clear_on", "ttl_ms" } }, true)}) },
    .{ .code = "invalid_params.template", .summary = "The format has an unknown variable, a bad spec or unbalanced brackets", .data = obj(&.{ field("param", str, true), field("offset", int, true), field("reason", str, true) }) },
    .{ .code = "denied.namespace", .summary = "The id is outside the caller's namespace, or venomx.*", .data = obj(&.{ field("id", str, true), field("namespace", str, true) }) },
    .{ .code = "conflict.rule_limit", .summary = "More than 32 rules for one namespace, or 128 in total", .data = obj(&.{ field("namespace", str, true), field("limit", int, true) }) },
    .{ .code = "conflict.config_rule", .summary = "The id is a rule from the config files, which only config changes" },
    .{ .code = "not_found.session", .summary = "The scope names no session" },
    .{ .code = "not_found.rule", .summary = "No rule has this id" },
});
const pane_chrome_errors = chromeErrors(&.{
    .{ .code = "not_found.pane", .summary = "No such pane" },
    tags_error,
    .{ .code = "invalid_params.attention", .summary = "Neither or both of level and clear=true, or a reason over 256 bytes", .data = obj(&.{field("param", .{ .kind = .string, .choices = &.{ "level", "clear", "reason" } }, true)}) },
});
const notify_errors = chromeErrors(&.{
    .{ .code = "invalid_params.notification", .summary = "text is not 1-512 bytes without control characters", .data = obj(&.{field("param", .{ .kind = .string, .choices = &.{"text"} }, true)}) },
    .{ .code = "not_found.pane", .summary = "No such pane" },
    .{ .code = "not_found.notification", .summary = "No such notification (dismissed, expired or dropped)" },
});
fn chromeVerb(comptime n: []const u8, comptime params: []const s.Field, comptime result: s.Type, comptime grant: s.Grant, comptime errs: []const s.ErrorDecl, comptime summary: []const u8) s.Verb {
    return .{ .name = n, .summary = summary, .params = params, .result = result, .grant = grant, .errors = errs };
}
pub const chrome_verbs = [_]s.Verb{
    chromeVerb("pane.tag", &.{
        pane,
        .{ .name = "set", .summary = "Tags to add or replace, as [{key,value}]", .type = tag_map },
        .{ .name = "unset", .summary = "Tag keys to remove (applied before set)", .type = array(str) },
    }, obj(&.{ pane, field("tags", tag_map, true) }), .write, pane_chrome_errors, "Set or remove a pane's tags. Tags describe panes for status segments and key tables; owner is set by the daemon and is read-only. Needs write on the pane."),
    chromeVerb("pane.attention", &.{
        pane,
        .{ .name = "level", .summary = "Attention level; give exactly one of level or clear=true", .type = level },
        .{ .name = "reason", .summary = "Why the pane needs attention (at most 256 bytes)", .type = str, .default = "\"\"" },
        .{ .name = "clear", .summary = "Clear attention (level none)", .type = boolean, .default = "false" },
    }, obj(&.{ pane, field("level", level, true) }), .write, pane_chrome_errors, "Mark a pane as needing the human's attention, or clear it. Every client marks the pane and counts it; nothing moves anyone's focus. Needs write on the pane."),
    chromeVerb("status.set", &.{
        segment_id,
        .{ .name = "text", .summary = "Text shown verbatim (at most 256 bytes, no control characters); clients truncate", .type = str, .required = true },
        .{ .name = "side", .summary = "Status line side", .type = side, .default = "\"right\"" },
        .{ .name = "priority", .summary = "Higher stays longer when space is short", .type = .{ .kind = .integer, .min = 0, .max = 100 }, .default = "50" },
        .{ .name = "style", .summary = "Theme role, never a raw colour", .type = segment_style, .default = "\"normal\"" },
        .{ .name = "when", .summary = "Show only while the client's focused pane has all these tags", .type = tag_map },
        .{ .name = "scope", .summary = "server, or a session ID to show only on clients of that session", .type = str, .default = "\"server\"" },
        .{ .name = "ttl_ms", .summary = "Remove the segment after this many milliseconds", .type = ttl },
        .{ .name = "bind", .summary = "connection: removed when the setting connection closes; daemon: kept until cleared or ttl_ms. Default: daemon with ttl_ms, else connection", .type = bind },
        group_param,
        icon_param,
        click_param,
    }, obj(&.{ field("id", str, true), field("revision", int, true) }), .write, segment_errors, "Publish or replace a status segment shown in every client's status line. Needs write on the scope (server:root for server)."),
    chromeVerb("status.clear", &.{segment_id}, empty, .write, segment_errors, "Remove a status segment of the caller's namespace."),
    chromeVerb("status.list", &.{.{ .name = "scope", .summary = "Only segments of this scope (server or a session ID)", .type = str }}, obj(&.{field("segments", array(segment), true)}), .read, segment_errors, "List the status segments the caller can read."),
    chromeVerb("status.rule.set", &.{
        segment_id,
        .{ .name = "on", .summary = "Event types (or type.* selectors) that fire the rule, 1-8", .type = array(str), .required = true },
        .{ .name = "match", .summary = "Conditions that must all hold, 0-8: [{key,op,value}] on a top-level data field (or type, resource); op is eq, ne or prefix", .type = array(rule_match) },
        .{ .name = "clear_on", .summary = "Event types that clear the segment, for the resource that last fired it, 0-8", .type = array(str) },
        .{ .name = "format", .summary = "Status template rendered on each firing; variables event.type, event.resource, event.<field>, host, user, clock", .type = str, .required = true },
        .{ .name = "ttl_ms", .summary = "Clear the segment this long after the last firing; a rule needs ttl_ms, clear_on or both", .type = ttl },
        .{ .name = "side", .summary = "Status line side", .type = side, .default = "\"right\"" },
        .{ .name = "priority", .summary = "Higher stays longer when space is short", .type = .{ .kind = .integer, .min = 0, .max = 100 }, .default = "50" },
        .{ .name = "style", .summary = "Theme role, never a raw colour", .type = segment_style, .default = "\"normal\"" },
        .{ .name = "when", .summary = "Show only while the client's focused pane has all these tags", .type = tag_map },
        .{ .name = "scope", .summary = "server, event (the session of the event's resource, else server) or a session ID", .type = str, .default = "\"server\"" },
        .{ .name = "bind", .summary = "connection: the rule and its segment go when the setting connection closes; daemon: kept until cleared", .type = bind, .default = "\"connection\"" },
        group_param,
        icon_param,
        click_param,
    }, obj(&.{ field("id", str, true), field("revision", int, true) }), .write, rule_errors, "Turn events into a status segment. The rule sees only events the caller can read, and its segment needs write on the scope (server:root for server and event)."),
    chromeVerb("status.rule.clear", &.{segment_id}, empty, .write, rule_errors, "Remove a status rule of the caller's namespace and its segment."),
    chromeVerb("status.rule.list", &.{}, obj(&.{field("rules", array(rule), true)}), .read, rule_errors, "List the status rules the caller can read."),
    chromeVerb("notify.post", &.{
        .{ .name = "text", .summary = "Message (at most 512 bytes, no control characters)", .type = str, .required = true },
        .{ .name = "level", .summary = "Level", .type = notify_level, .default = "\"info\"" },
        .{ .name = "pane", .summary = "Pane the message is about", .type = str },
        .{ .name = "ttl_ms", .summary = "How long clients show it", .type = ttl, .default = "8000" },
    }, obj(&.{field("id", str, true)}), .write, notify_errors, "Post a short notification to every client's status line. The daemon keeps the newest 64. Needs write on server:root."),
    chromeVerb("notify.list", &.{}, obj(&.{field("notifications", array(obj(&notification_fields)), true)}), .read, notify_errors, "List unexpired notifications this connection has not dismissed."),
    chromeVerb("notify.dismiss", &.{
        .{ .name = "id", .summary = "Notification ID", .type = str, .required = true },
        .{ .name = "all", .summary = "Remove it for every client (needs write on server:root); otherwise only for this connection", .type = boolean, .default = "false" },
    }, obj(&.{ field("id", str, true), field("all", boolean, true) }), .read, notify_errors, "Dismiss a notification for this connection, or for everyone with all=true."),
} ++ key_verbs;
// Key tables.
const key_binding = obj(&.{
    .{ .name = "key", .summary = "Key sequence after the table's prefix: Kitty names joined with + (ctrl+space, alt+shift+left, %), keys separated by spaces", .type = str, .required = true },
    .{ .name = "local", .summary = "A local client action (detach, zoom, focus-attention, lock, split-right, ...)", .type = str },
    .{ .name = "verb", .summary = "A venomx schema verb sent with the client's own identity", .type = str },
    .{ .name = "args", .summary = "The verb's params as JSON object text; {pane}, {window}, {session} replace whole string values", .type = str },
    .{ .name = "exec", .summary = "An argv the client runs with no shell, no stdin/stdout and no venomx token; placeholders replace whole elements only", .type = array(str) },
    .{ .name = "label", .summary = "What the leader popup shows, 1-40 bytes; without one, the local action, verb or argv[0]", .type = str },
});
const key_group = obj(&.{
    .{ .name = "key", .summary = "The inner prefix, relative to the table's prefix", .type = str, .required = true },
    .{ .name = "label", .summary = "What the leader popup shows for it, 1-40 bytes", .type = str, .required = true },
    .{ .name = "sticky", .summary = "Stay in the group after a binding runs, until esc", .type = boolean },
});
const key_table = obj(&.{
    field("name", str, true),
    field("layer", .{ .kind = .string, .choices = &.{ "builtin", "product", "defaults", "user" } }, true),
    .{ .name = "prefix", .summary = "The effective sub-prefix, after keys.prefixes", .type = str },
    field("label", str, false),
    field("groups", array(key_group), false),
    field("when", tag_map, true),
    field("bindings", array(key_binding), true),
    field("source", str, false),
});
const key_layer: s.Type = .{ .kind = .string, .choices = &.{ "builtin", "product", "defaults", "user" } };
const key_shadow = obj(&.{ field("key", str, true), field("table", str, true), field("layer", key_layer, true), field("by", str, true), field("by_layer", key_layer, true) });
const key_errors = chromeErrors(&.{
    .{ .code = "invalid_params.bindings", .summary = "Bad name, prefix, when or binding (key syntax, not exactly one target, unknown local or verb, args not a JSON object, spliced placeholder)", .data = obj(&.{ field("param", str, true), field("reason", str, true) }) },
    .{ .code = "denied.namespace", .summary = "The table name is not the caller's namespace; the owner principal may use any name but venomx, which is built in", .data = obj(&.{ field("id", str, true), field("namespace", str, true) }) },
    .{ .code = "conflict.key_prefix", .summary = "The prefix is a built-in key or taken by another product table, or 32 tables exist", .data = obj(&.{ field("prefix", str, true), field("table", str, true) }) },
    .{ .code = "not_found.key_table", .summary = "No registered table has this name", .data = obj(&.{field("name", str, true)}) },
});
const key_verbs = [_]s.Verb{
    chromeVerb("keys.register", &.{
        .{ .name = "name", .summary = "Table name: the caller's namespace; the owner principal may use any name but venomx", .type = str, .required = true },
        .{ .name = "prefix", .summary = "The one key after the leader that opens the table; keys.prefixes in the config can move it", .type = str, .required = true },
        .{ .name = "label", .summary = "What the leader popup shows for the prefix, 1-40 bytes; without one, the table's name", .type = str },
        .{ .name = "groups", .summary = "Named inner prefixes: {key, label, sticky}", .type = array(key_group) },
        .{ .name = "when", .summary = "Active only while the focused pane has all these tags", .type = tag_map },
        .{ .name = "bindings", .summary = "Bindings: {key, and exactly one of local, verb (+ args) or exec}", .type = array(key_binding), .required = true },
        .{ .name = "bind", .summary = "connection: removed when the registering connection closes; daemon: kept until unregistered", .type = bind, .default = "\"connection\"" },
    }, obj(&.{ field("name", str, true), field("prefix", str, true), field("layer", key_layer, true), field("shadowed", array(key_shadow), true) }), .write, key_errors, "Register a key table under a sub-prefix of the leader, or replace the whole table of that name. A principal uses its own namespace as the name; the owner principal may use any name but venomx, and with bind=daemon its table has no expiry. Another principal's table goes when that principal is revoked or expires. Every presentation client loads it; user config and the defaults file take precedence and shadowed bindings are reported. Needs write on server:root."),
    chromeVerb("keys.unregister", &.{.{ .name = "name", .summary = "Table name: the caller's namespace; the owner principal may use any name but venomx", .type = str, .required = true }}, empty, .write, key_errors, "Remove the key table named after the caller's namespace; the owner principal may remove any registered table."),
    chromeVerb("keys.list", &.{}, obj(&.{
        field("leader", str, true),
        field("unlock", str, true),
        field("popup_delay_ms", int, true),
        field("timeout_ms", int, true),
        field("revision", int, true),
        field("tables", array(key_table), true),
        field("shadowed", array(key_shadow), true),
        field("conflicts", array(obj(&.{ field("layer", key_layer, true), field("key", str, true), field("tables", array(str), true) })), true),
    }), .read, key_errors, "List every key table (built-in, product, defaults file, user config) with bindings, shadowed bindings and same-layer conflicts."),
};
// Floating panes, popups, presets and placement intent.
pub const anchor_type: s.Type = .{ .kind = .string, .choices = &.{ "center", "top", "bottom", "left", "right", "top_left", "top_right", "bottom_left", "bottom_right" } };
pub const border_type: s.Type = .{ .kind = .string, .choices = &.{ "none", "single", "rounded", "heavy" } };
const layer_type: s.Type = .{ .kind = .string, .choices = &.{ "tile", "float", "popup" } };
const offset: s.Type = .{ .kind = .integer, .min = -4096, .max = 4096 };
const cells: s.Type = .{ .kind = .integer, .min = 1, .max = 65535 };
const geometry_fields = [_]s.Field{
    .{ .name = "width", .summary = "Cells (\"80\") or percent of the window area (\"60%\"); overrides the preset", .type = str },
    .{ .name = "height", .summary = "Cells (\"24\") or percent of the window area (\"60%\"); overrides the preset", .type = str },
    .{ .name = "anchor", .summary = "Where the rectangle sits in the window area", .type = anchor_type },
    .{ .name = "x", .summary = "Column offset from the anchor", .type = offset },
    .{ .name = "y", .summary = "Row offset from the anchor", .type = offset },
    .{ .name = "min_cols", .summary = "Below this many columns the client shows the float full-window", .type = cells },
    .{ .name = "min_rows", .summary = "Below this many rows the client shows the float full-window", .type = cells },
    .{ .name = "border", .summary = "Border drawn by the client", .type = border_type },
    .{ .name = "title", .summary = "Border title (at most 128 bytes); default: the pane's OSC 2 title", .type = str },
};
const preset_param: s.Field = .{ .name = "preset", .summary = "Float preset <namespace>.<name> (floats.presets in config, or floats.register); prefer it to raw sizes. Unknown presets fall back to floats.default", .type = str };
const placement_params = [_]s.Field{preset_param} ++ geometry_fields;
pub const float_wire = obj(&.{
    field("preset", str, false), field("width", str, true),      field("height", str, true),     field("anchor", anchor_type, true), field("x", offset, true),
    field("y", offset, true),    field("min_cols", cells, true), field("min_rows", cells, true), field("border", border_type, true), field("title", str, false),
    field("z", int, true),
});
const geometry_error: s.ErrorDecl = .{ .code = "invalid_params.geometry", .summary = "An unparsable size, offset, title or preset name", .data = obj(&.{field("param", str, true)}) };
const layer_error: s.ErrorDecl = .{ .code = "conflict.layer", .summary = "The pane's layer does not allow this (split a float, place a popup, raise a tiled pane)", .data = obj(&.{field("layer", layer_type, true)}) };
const ticket_error: s.ErrorDecl = .{ .code = "denied.popup_ticket", .summary = "No valid popup ticket: missing, unknown, spent, expired, or minted for another client", .data = obj(&.{field("reason", .{ .kind = .string, .choices = &.{ "missing", "unknown", "expired", "client" } }, true)}) };
const client_error: s.ErrorDecl = .{ .code = "not_found.client", .summary = "The ticket's client has detached", .data = obj(&.{field("client", str, true)}) };
const float_errors = tagged_spawn_errors ++ [_]s.ErrorDecl{ geometry_error, layer_error };
const popup_errors = float_errors ++ [_]s.ErrorDecl{ ticket_error, client_error };
const near_param: s.Field = .{ .name = "near", .summary = "Placement intent: split the largest live tiled pane of the session whose tags match all of these, falling back to the given target", .type = tag_map };
const place_errors = [_]s.ErrorDecl{
    .{ .code = "not_found.pane", .summary = "No such pane" },
    .{ .code = "denied.write", .summary = "The caller cannot write the pane's window" },
    .{ .code = "unavailable.shutdown", .summary = "The daemon is stopping" },
    .{ .code = "unsupported.result_size", .summary = "The reply exceeds max_frame" },
    .{ .code = "conflict.removing", .summary = "The pane or its window is being removed" },
    .{ .code = "invalid_params.place", .summary = "Neither or both of float and tile, or a bad tile target or axis", .data = obj(&.{field("param", str, true)}) },
    geometry_error,
    layer_error,
};
const resize_errors = [_]s.ErrorDecl{
    .{ .code = "not_found.pane", .summary = "No such pane" },
    .{ .code = "denied.write", .summary = "The caller cannot write the pane's window" },
    .{ .code = "unavailable.shutdown", .summary = "The daemon is stopping" },
    .{ .code = "conflict.removing", .summary = "The pane or its window is being removed" },
    layer_error,
};
const float_verbs = [_]s.Verb{
    .{ .name = "pane.float", .summary = "Create a floating pane in a window's float layer, running argv directly (no shell). Every client showing the window draws it (unless it hid floats) at the preset's geometry resolved against its own window area; it never takes focus. Prefer --preset over raw sizes.", .params = &([_]s.Field{window} ++ spawn_params ++ placement_params ++ [_]s.Field{ tags_param, on_exit_param }), .result = spawned, .grant = .spawn, .errors = &float_errors },
    .{ .name = "pane.popup", .summary = "Open a popup on exactly one presentation client: the one that minted the ticket (a binding's {popup_ticket}). The popup takes that client's focus and closes when its process exits (on_exit=remove by default), on dismiss, or when the client detaches.", .params = &([_]s.Field{.{ .name = "ticket", .summary = "Single-use popup ticket, valid 10 s, from the client's {popup_ticket} placeholder", .type = str }} ++ spawn_params ++ placement_params ++ [_]s.Field{ tags_param, .{ .name = "on_exit", .summary = "What happens when the popup's process exits: remove it (default) or keep it", .type = .{ .kind = .string, .choices = &.{ "keep", "remove" } }, .default = "\"remove\"" } }), .result = spawned, .grant = .spawn, .errors = &popup_errors },
    .{ .name = "popup.ticket", .summary = "Presentation clients only: mint a single-use popup ticket bound to this connection and session, valid 10 s. Agents receive tickets through a human's key binding and never mint them.", .params = &.{ session, .{ .name = "window", .summary = "The window the client shows (the popup's window for grants); default: the session's lowest window", .type = str } }, .result = obj(&.{ field("ticket", str, true), field("client", str, true), session, window, field("ttl_ms", int, true) }), .grant = .read, .errors = &.{
        .{ .code = "not_found.session", .summary = "No such session" },
        .{ .code = "not_found.window", .summary = "No such window in the session, or the session has none" },
        .{ .code = "denied.read", .summary = "The caller cannot read the session" },
        .{ .code = "unsupported.result_size", .summary = "The reply exceeds max_frame" },
        .{ .code = "unavailable.entropy", .summary = "No entropy for the ticket" },
    } },
    .{ .name = "pane.place", .summary = "Move a pane between layers or change a float's geometry: float={preset or geometry fields} floats it (or re-geometries a float), tile={target, axis} splits target with it. Popups cannot be placed.", .params = &.{
        pane,
        .{ .name = "float", .summary = "Float geometry: preset plus optional fields", .type = obj(&placement_params) },
        .{ .name = "tile", .summary = "Tile it next to target (a tiled pane of the same window) on axis; target may be omitted when the window has no tiled pane", .type = obj(&.{ field("target", str, false), field("axis", axis, false) }) },
    }, .result = obj(&.{ pane, field("layer", layer_type, true) }), .grant = .write, .errors = &place_errors },
    .{ .name = "pane.raise", .summary = "Put a floating pane (or popup) above the others of its window", .params = &.{pane}, .result = obj(&.{ pane, field("z", int, true) }), .grant = .write, .errors = &place_errors },
    .{ .name = "pane.resize", .summary = "Move the divider of the pane's nearest split on the direction's axis by cells (left and right are columns, up and down rows), changing that split's shared ratio for every client. The move stops at a child's minimum (one cell per pane and separator it holds) and never goes against the direction; moved is the cells it really moved, 0 with no event when there is no such split or it can't move.", .params = &.{
        pane,
        .{ .name = "direction", .summary = "The way the divider moves", .type = .{ .kind = .string, .choices = &.{ "left", "down", "up", "right" } }, .required = true },
        .{ .name = "cells", .summary = "How far, in cells of the panes' current size", .type = .{ .kind = .integer, .min = 1, .max = 65535 }, .required = true },
    }, .result = obj(&.{ window, revision, field("moved", int, true) }), .grant = .write, .errors = &resize_errors },
    .{ .name = "floats.register", .summary = "Ship a default float preset under the caller's namespace (product layer); the owner principal may use any name outside venomx.*, with no expiry under bind=daemon. floats.presets in config wins field by field; bind=connection removes it when this connection closes.", .params = &([_]s.Field{.{ .name = "name", .summary = "Preset name <namespace>.<name>; the namespace must be the caller's (the owner principal may use any but venomx)", .type = str, .required = true }} ++ geometry_fields ++ [_]s.Field{.{ .name = "bind", .summary = "connection: removed when the registering connection closes; daemon: kept", .type = bind, .default = "\"connection\"" }}), .result = obj(&.{ field("name", str, true), field("layer", .{ .kind = .string, .choices = &.{"product"} }, true) }), .grant = .write, .errors = &.{
        .{ .code = "denied.write", .summary = "The caller cannot write server:root" },
        .{ .code = "denied.namespace", .summary = "The name is outside the caller's namespace; for the owner principal, it is in venomx.*", .data = obj(&.{ field("id", str, true), field("namespace", str, true) }) },
        .{ .code = "conflict.preset_limit", .summary = "64 presets are registered", .data = obj(&.{field("limit", int, true)}) },
        .{ .code = "unavailable.shutdown", .summary = "The daemon is stopping" },
        .{ .code = "unsupported.result_size", .summary = "The reply exceeds max_frame" },
        geometry_error,
    } },
};
/// `pane.relaunch`: the spawn errors without the
/// cwd/environment codes, plus the acknowledgement and archive codes.
const relaunch_errors = blk: {
    var out: [errors.len + 2]s.ErrorDecl = undefined;
    for (spawn_errors[0..errors.len], 0..) |e, i| out[i] = e;
    out[errors.len] = .{ .code = "invalid_params.ack_orphans", .summary = "ack_orphans was not true", .data = obj(&.{field("param", .{ .kind = .string, .choices = &.{"ack_orphans"} }, true)}) };
    out[errors.len + 1] = .{ .code = "conflict.not_archive", .summary = "The pane is not a restored archive (an ordinary exited or live pane)", .data = empty };
    const frozen = out;
    break :blk frozen;
};
const relaunch: s.Verb = .{
    .name = "pane.relaunch",
    .summary = "Replace a restored archive pane with a fresh process running argv directly (no shell), under a new pane ID in the same layout position. A new execution, not a continuation: nothing (argv, cwd, environment, grants, screen or input) is taken from the archive or the checkpoint. Needs spawn and write on the archive. ack_orphans=true acknowledges that processes of the previous daemon may survive and the new run may duplicate their external work. Launches at most once: a retry names the removed archive and fails not_found.pane.",
    .params = &.{
        pane,
        field("argv", array(str), true),
        .{ .name = "ack_orphans", .summary = "Must be true: old processes may survive and work may be duplicated; this does not certify cleanup", .type = boolean, .required = true },
        field("grants", grants, false),
    },
    .result = spawned,
    .grant = .spawn,
    .errors = &relaunch_errors,
};
// Shared termination parameters.
const signal_param: s.Field = .{ .name = "signal", .summary = "First signal sent to each live pane's process group", .type = .{ .kind = .string, .choices = &.{ "SIGHUP", "SIGTERM", "SIGINT" } }, .default = "\"SIGHUP\"" };
const grace_param: s.Field = .{ .name = "grace_ms", .summary = "Milliseconds to wait after the first signal before sending SIGKILL", .type = .{ .kind = .integer, .min = 0, .max = 30000 }, .default = "2000" };
const recursive_param: s.Field = .{ .name = "recursive", .summary = "Terminate every live pane and remove all children (destructive); signal and grace_ms apply only when true", .type = boolean, .default = "false" };
const kill_params = [_]s.Field{
    .{ .name = "pane", .summary = "Pane to terminate", .type = str, .required = true },
    signal_param,
    grace_param,
    .{ .name = "remove", .summary = "Also remove the pane once it has exited", .type = boolean, .default = "false" },
};
const kill_result = obj(&.{
    pane,
    field("outcome", .{ .kind = .string, .choices = &.{ "terminated", "already_exited" } }, true),
    field("removed", boolean, true),
    field("escalated", boolean, true),
    field("exit_code", .{ .kind = .integer, .min = 0, .max = 255 }, false),
    field("signal", str, false),
});
const destructive = " Destructive: once the first signal is sent it cannot be undone.";
fn described(comptime v: s.Verb, comptime summary: []const u8) s.Verb {
    var out = v;
    out.summary = summary;
    return out;
}
// History-range capture.
const row_int: s.Type = .{ .kind = .integer, .min = 0, .max = 9007199254740991 };
const capture_rows_params = [_]s.Field{
    .{ .name = "pane", .summary = "Pane to read", .type = str, .required = true },
    .{ .name = "epoch", .summary = "Row epoch that start and end belong to; required with start or end", .type = .{ .kind = .integer, .min = 0, .max = 4294967295 } },
    .{ .name = "start", .summary = "First absolute row (inclusive); default: oldest retained row", .type = row_int },
    .{ .name = "end", .summary = "Absolute row after the last one (exclusive); default: current end", .type = row_int },
    .{ .name = "tail", .summary = "Select at most this many newest rows of the current epoch; excludes epoch, start and end", .type = .{ .kind = .integer, .min = 1, .max = 9007199254740991 } },
    .{ .name = "max_rows", .summary = "Most rows in this reply", .type = .{ .kind = .integer, .min = 1, .max = 10000 }, .default = "1000" },
    .{ .name = "max_bytes", .summary = "Most UTF-8 bytes of line text in this reply", .type = .{ .kind = .integer, .min = 1, .max = 16777216 }, .default = "262144" },
};
const capture_rows_result = obj(&.{
    .{ .name = "pane", .summary = "The pane read", .type = str, .required = true },
    .{ .name = "screen", .summary = "The screen that was active at the read", .type = .{ .kind = .string, .choices = &.{ "primary", "alternate" } }, .required = true },
    .{ .name = "epoch", .summary = "Row epoch of every row number in this result", .type = row_int, .required = true },
    .{ .name = "offset", .summary = "Pane byte offset the read is as of: it reflects exactly PTY bytes [0, offset)", .type = row_int, .required = true },
    .{ .name = "cols", .summary = "Pane columns at offset", .type = row_int, .required = true },
    .{ .name = "rows", .summary = "Pane rows at offset", .type = row_int, .required = true },
    .{ .name = "bounds", .summary = "Retained rows [oldest, end), with the screen at [active, end)", .type = obj(&.{
        .{ .name = "oldest", .summary = "Oldest retained row", .type = row_int, .required = true },
        .{ .name = "active", .summary = "First row of the screen", .type = row_int, .required = true },
        .{ .name = "end", .summary = "Row after the newest", .type = row_int, .required = true },
    }), .required = true },
    .{ .name = "start", .summary = "Absolute row of lines[0]", .type = row_int, .required = true },
    .{ .name = "end", .summary = "End of the selection (exclusive), pinned by the first page", .type = row_int, .required = true },
    .{ .name = "next", .summary = "Present only when done is false: the start of the next page", .type = row_int },
    .{ .name = "done", .summary = "True when this page reaches end", .type = boolean, .required = true },
    .{ .name = "lines", .summary = "Physical rows [start, start + len(lines)), oldest first, padded to cols, plain UTF-8", .type = array(str), .required = true },
});
const capture_rows_errors = [_]s.ErrorDecl{
    .{ .code = "invalid_params.rows", .summary = "tail with epoch/start/end (exclusive), start or end without epoch (epoch_required), or end < start (order)" },
    .{ .code = "not_found.rows", .summary = "Selection reaches outside the retained rows: evicted (before oldest) or future (at or after end)" },
    .{ .code = "conflict.epoch", .summary = "The given epoch is not current: the screen was resized, cleared, reset or switched" },
    .{ .code = "unsupported.result_size", .summary = "The first selected row alone does not fit max_bytes or the connection's max_frame" },
    .{ .code = "not_found.pane", .summary = "No such pane" },
    .{ .code = "denied.read", .summary = "The caller cannot read the pane" },
};
const capture_rows: s.Verb = .{ .name = "pane.capture_rows", .summary = "Read physical scrollback and screen rows of a pane as plain UTF-8, paged and bounded. Use --tail N for recent output; page with --epoch, --start <next> and the first page's --end until done.", .params = &capture_rows_params, .result = capture_rows_result, .grant = .read, .errors = &capture_rows_errors };
// Trusted run/wait.
const run_state: s.Type = .{ .kind = .string, .choices = &.{ "running", "terminating", "completed" } };
const run_outcome: s.Type = .{ .kind = .string, .choices = &.{ "succeeded", "failed", "signaled", "terminated" } };
const run_cause: s.Type = .{ .kind = .string, .choices = &.{ "cancel", "deadline", "pane_kill", "removal", "shutdown" } };
const byte: s.Type = .{ .kind = .integer, .min = 0, .max = 255 };
const run_output = obj(&.{
    field("screen", str, true), field("epoch", int, true), field("offset", int, true), field("cols", int, true),         field("rows", int, true),
    field("oldest", int, true), field("start", int, true), field("end", int, true),    field("complete", boolean, true), field("lines", array(str), true),
});
fn runRecord(comptime done: bool) s.Type {
    return obj(&.{
        field("run", str, true),          field("source", str, true),       field("key", str, true),             field("pane", str, true),
        field("window", str, true),       field("session", str, true),      field("principal", str, true),       field("pid", int, true),
        field("shell", boolean, true),    field("state", run_state, true),  field("outcome", run_outcome, done), field("exit_code", byte, false),
        field("signal", str, false),      field("cause", run_cause, false), field("status", byte, done),         field("started_at", str, true),
        field("completed_at", str, done), field("duration_ms", int, done),  field("output", run_output, false),
    });
}
const run_started = obj(&.{ field("run", str, true), field("source", str, true), field("key", str, true), pane, window, session, field("principal", str, true), field("pid", int, true), field("reused", boolean, true) });
const run_errors = blk: {
    const extra = [_]s.ErrorDecl{
        .{ .code = "invalid_params.command", .summary = "Neither or both of argv and shell, or a bad shell", .data = reasoned(.{ .kind = .string, .choices = &.{ "argv", "shell" } }, &.{ "missing", "exclusive", "size", "nul" }) },
        .{ .code = "invalid_params.target", .summary = "Neither or both of session and pane, or axis/name misplaced or missing", .data = reasoned(str, &.{ "missing", "exclusive", "misplaced" }) },
        .{ .code = "invalid_params.key", .summary = "key is not 1-128 bytes of [A-Za-z0-9._:-]", .data = reasoned(.{ .kind = .string, .choices = &.{"key"} }, &.{"syntax"}) },
        .{ .code = "not_found.run", .summary = "No such run; expired for IDs the daemon allocated and evicted", .data = obj(&.{field("reason", .{ .kind = .string, .choices = &.{ "expired", "unknown" } }, true)}) },
        .{ .code = "conflict.run_key", .summary = "The key is bound to a run started with different parameters", .data = obj(&.{field("run", str, true)}) },
        .{ .code = "conflict.source", .summary = "The daemon's event source differs from the given one (the daemon restarted)", .data = obj(&.{field("source", str, true)}) },
        .{ .code = "unavailable.run_limit", .summary = "run.max_active runs are not yet completed", .data = obj(&.{field("max_active", int, true)}) },
        .{ .code = "timeout.wait", .summary = "timeout_ms passed before the run completed; the run is unaffected", .data = obj(&.{ field("run", str, true), field("state", run_state, true) }) },
    };
    var out: [spawn_errors.len + extra.len]s.ErrorDecl = undefined;
    for (spawn_errors, 0..) |e, i| out[i] = if (@import("std").mem.eql(u8, e.code, "unsupported.result_size")) .{ .code = e.code, .summary = "The reply exceeds max_frame; retry with output=false and read rows with pane capture-rows", .data = obj(&.{field("bytes", int, true)}) } else e;
    for (extra, 0..) |e, i| out[spawn_errors.len + i] = e;
    const frozen = out;
    break :blk frozen;
};
const run_id: s.Field = .{ .name = "run", .summary = "Run ID", .type = str, .required = true };
const output_param: s.Field = .{ .name = "output", .summary = "Include the output tail of a completed run", .type = boolean, .default = "true" };
const run_params = [_]s.Field{
    .{ .name = "key", .summary = "Idempotency key: a retry with the same key and parameters returns the same run instead of starting the command again", .type = str, .required = true },
    .{ .name = "session", .summary = "Run in a new window of this session; give exactly one of session or pane", .type = str },
    .{ .name = "pane", .summary = "Run in a new pane split from this live pane; give exactly one of session or pane", .type = str },
    .{ .name = "axis", .summary = "Split axis; required with pane, not allowed with session", .type = axis },
    .{ .name = "argv", .summary = "Program and arguments, executed directly with no shell; give exactly one of argv or shell", .type = array(str) },
    .{ .name = "shell", .summary = "Command line run explicitly as /bin/sh -c; give exactly one of argv or shell", .type = str },
    .{ .name = "name", .summary = "Window name; only with session", .type = str },
    .{ .name = "cols", .summary = "Pane columns", .type = .{ .kind = .integer, .min = 1, .max = 65535 }, .default = "80" },
    .{ .name = "rows", .summary = "Pane rows", .type = .{ .kind = .integer, .min = 1, .max = 65535 }, .default = "24" },
    .{ .name = "deadline_ms", .summary = "Terminate the command this many milliseconds after it starts; default: no deadline", .type = .{ .kind = .integer, .min = 1, .max = 86400000 } },
    .{ .name = "output_rows", .summary = "Most rows of output kept in the result", .type = .{ .kind = .integer, .min = 0, .max = 1000 }, .default = "100" },
    .{ .name = "output_bytes", .summary = "Most UTF-8 bytes of output lines kept in the result", .type = .{ .kind = .integer, .min = 0, .max = 262144 }, .default = "65536" },
    .{ .name = "source", .summary = "Fail unless the daemon's event source is this one (detects a daemon restart between retries)", .type = str },
    field("grants", grants, false),
} ++ spawn_params[spawn_params.len - 3 ..].*;
fn runVerb(comptime n: []const u8, comptime params: []const s.Field, comptime result: s.Type, comptime grant: s.Grant, comptime summary: []const u8) s.Verb {
    return .{ .name = n, .summary = summary, .params = params, .result = result, .grant = grant, .errors = &run_errors };
}
pub const run_verbs = [_]s.Verb{
    runVerb("run", &run_params, run_started, .spawn, "Start a process as the root of a new pane and return once it has been exec'd; its result comes only from the daemon's wait status. key makes retries safe (same key and parameters return the same run). argv runs directly with no shell; shell runs /bin/sh -c explicitly."),
    blk: {
        var v = runVerb("run.wait", &.{ run_id, .{ .name = "timeout_ms", .summary = "Most milliseconds to wait; absent: no limit, 0: a non-blocking check", .type = .{ .kind = .integer, .min = 0, .max = 86400000 } }, output_param }, runRecord(true), .read, "Wait for a run to complete and return its outcome, exit code or signal and output tail. The CLI exits with the result's status. A wait blocks the tool call: use timeout_ms of at most 60000 and loop on timeout.wait. A wait timeout, cancel or disconnect never stops the command.");
        v.exit = .{ .result = "status" };
        break :blk v;
    },
    runVerb("run.get", &.{ run_id, output_param }, runRecord(false), .read, "Read a run record without waiting."),
    runVerb("run.list", &.{
        .{ .name = "pane", .summary = "Only runs of this pane", .type = str },
        .{ .name = "key", .summary = "Only the caller's run with this key", .type = str },
        .{ .name = "after", .summary = "List runs after this run ID (the previous page's next)", .type = str },
        .{ .name = "limit", .summary = "Most runs returned", .type = .{ .kind = .integer, .min = 1, .max = 1024 }, .default = "256" },
    }, obj(&.{ field("source", str, true), field("runs", array(runRecord(false)), true), field("next", str, false) }), .read, "List retained run records in ID order, without output."),
    runVerb("run.cancel", &.{ run_id, signal_param, grace_param }, runRecord(false), .write, "Terminate a run's pane process group (signal, then SIGKILL after grace_ms) and return the completed record." ++ destructive),
};
pub const product = [_]s.Verb{
    described(verb("session.create", &.{ name_param, on_empty_param }, session_item, .write), "Create an empty session (no window or shell). on_empty=remove removes it once an on_exit cascade leaves it without windows."),
    verb("session.list", &.{}, obj(&.{field("sessions", array(session_item), true)}), .read),
    verb("session.get", &.{session}, obj(&.{ session, name, field("windows", array(window_item), true) }), .read),
    described(verb("session.remove", &.{ session, recursive_param, signal_param, grace_param }, empty, .write), "Remove a session; with recursive=true terminate every live pane in it and remove all its windows." ++ destructive),
    taggedSpawnVerb("window.create", &(.{ session, name_param } ++ spawn_params ++ .{ program_param, on_exit_param, near_param }), "Create a window running argv directly (no shell). cwd must be absolute; env applies after env_unset on the daemon's environment; the executable is found on the child's final PATH; VENOMX_* is reserved. on_exit=remove removes the pane when its process exits."),
    verb("window.get", &.{window}, obj(&(layout_fields ++ [_]s.Field{field("floats", array(obj(&.{ pane, field("layer", layer_type, true), field("z", int, true) })), true)})), .read),
    described(verb("window.remove", &.{ window, recursive_param, signal_param, grace_param }, empty, .write), "Remove a window; with recursive=true terminate every live pane in it and remove them all." ++ destructive),
    verb("pane.list", &.{field("session", str, false)}, obj(&.{field("panes", array(obj(&.{ pane, window, session, field("title", str, true), field("argv0", argv0_type, false), field("process", str, false), field("title_current", boolean, false), field("exited", boolean, true), recovery_field, field("tags", tag_map, true), field("attention", level, true), field("layer", layer_type, true), field("pid", int, false), field("start", int, false) })), true)}), .read),
    taggedSpawnVerb("pane.split", &(.{ pane, field("axis", axis, true) } ++ spawn_params ++ .{ program_param, on_exit_param, near_param }), "Split a pane, running argv directly (no shell). cwd must be absolute and is not inherited from the source pane; env applies after env_unset; VENOMX_* is reserved. on_exit=remove removes the pane when its process exits."),
    relaunch,
    verb("pane.send", &.{ pane, field("text", str, true) }, obj(&.{field("bytes", int, true)}), .write),
    verb("pane.capture", &.{pane}, obj(&.{ field("text", str, true), field("cols", int, true), field("rows", int, true), field("exited", boolean, true), field("exit_code", .{ .kind = .integer, .min = 0, .max = 255 }, false), field("signal", str, false), recovery_field }), .read),
    capture_rows,
    verb("pane.remove", &.{pane}, empty, .write),
    described(verb("pane.kill", &kill_params, kill_result, .write), "Terminate a pane's process group (signal, then SIGKILL after grace_ms) and answer once it is reaped; remove=true also removes it." ++ destructive),
} ++ run_verbs ++ chrome_verbs ++ float_verbs;
fn hasField(comptime fields: []const s.Field, comptime wanted: []const u8) bool {
    for (fields) |x| if (@import("std").mem.eql(u8, x.name, wanted)) return true;
    return false;
}
/// The OSC 133 `cmdline` for the events data union, unless the shared
/// venom-std schema already declares it.
fn shared_cmdline(comptime fields: []const s.Field) [if (hasField(fields, "cmdline")) 0 else 1]s.Field {
    return if (comptime hasField(fields, "cmdline")) .{} else .{field("cmdline", str, false)};
}
pub const events = blk: {
    const base = cli.manifest.normalize(.{ .format = 1, .tool = "venomx", .summary = "events", .verbs = .{proto.events.manifest} }).verbs[0];
    var out = base;
    var fields = base.item.?.fields.?[0..base.item.?.fields.?.len].*;
    for (&fields) |*f| if (@import("std").mem.eql(u8, f.name, "data")) {
        const all = f.type.fields.?[0..f.type.fields.?.len].* ++ .{ field("window", str, false), field("name", str, false), field("revision", int, false), field("nodes", array(node), false), field("requested_signal", str, false), field("checkpoint", str, false), field("cleanup_unverified", boolean, false), field("run", str, false), field("outcome", str, false), field("cause", str, false), field("state", str, false), field("signal", str, false), field("tags", tag_map, false), field("level", str, false), field("id", str, false), field("segment", segment, false), field("rule", rule, false), field("text", str, false), field("ttl_ms", int, false), field("namespace", str, false), field("layer", str, false), field("float", float_wire, false), field("client", str, false), field("z", int, false), field("table", str, false), field("kind", str, false), field("parent", str, false), field("grants", grants, false), field("expires", str, false), field("verb", str, false), field("right", str, false), field("resource", str, false), field("cascade", int, false), field("suppressed", int, false), field("argv0", argv0_type, false), field("process", str, false) } ++ shared_cmdline(f.type.fields.?);
        f.type.fields = &all;
    };
    const frozen_fields = fields;
    out.item.?.fields = &frozen_fields;
    break :blk out;
};
// Recovery verbs: admin on server:root, nonstreaming.
const recovery_errors = blk: {
    const codes = .{ "invalid_params.checkpoint", "not_found.checkpoint", "denied.admin", "conflict.recovery_busy", "conflict.not_empty", "conflict.checkpoint_corrupt", "conflict.checkpoint_expired", "unavailable.recovery_disabled", "unavailable.recovery_io", "unavailable.shutdown", "unsupported.checkpoint_format", "unsupported.checkpoint_size", "unsupported.result_size" };
    var out: [codes.len]s.ErrorDecl = undefined;
    for (codes, 0..) |code, i| out[i] = .{ .code = code, .summary = code };
    break :blk out;
};
const checkpoint_param: s.Field = .{ .name = "checkpoint", .summary = "Checkpoint ID (c followed by a lowercase UUID v4)", .type = str, .required = true };
const mapping = array(obj(&.{ field("previous", str, true), field("current", str, true) }));
fn rverb(comptime n: []const u8, comptime params: []const s.Field, comptime result: s.Type, comptime summary: []const u8) s.Verb {
    return .{ .name = n, .summary = summary, .params = params, .result = result, .grant = .admin, .errors = &recovery_errors };
}
pub const recovery_verbs = [_]s.Verb{
    rverb("recovery.checkpoint", &.{}, obj(&.{ field("checkpoint", str, true), field("generation", int, true) }), "Durably write a checkpoint of the session/window/split topology and pane states now (requires recovery.enabled)."),
    rverb("recovery.list", &.{}, obj(&.{field("checkpoints", array(obj(&.{ field("checkpoint", str, true), field("status", .{ .kind = .string, .choices = &.{ "valid", "corrupt", "incompatible", "expired", "unsafe", "future" } }, true), field("generation", int, false) })), true)}), "List this socket's checkpoints with their status; never reveals payload."),
    rverb("recovery.inspect", &.{checkpoint_param}, obj(&.{ field("checkpoint", str, true), field("generation", int, true), field("shutdown", .{ .kind = .string, .choices = &.{ "open", "clean" } }, true), field("sessions", int, true), field("windows", int, true), field("panes", int, true), field("text_panes", int, true), field("expired_text_panes", int, true) }), "Counts of a valid checkpoint; returns no terminal content."),
    rverb("recovery.restore", &.{checkpoint_param}, obj(&.{ field("checkpoint", str, true), field("sessions", mapping, true), field("windows", mapping, true), field("panes", mapping, true) }), "Restore a valid checkpoint into an empty daemon as exited archive panes with fresh IDs. Executes and signals no process; cleanup of old processes is unverified."),
    rverb("recovery.forget", &.{checkpoint_param}, obj(&.{}), "Delete one checkpoint file (any status except unsafe), then sync the store."),
};
/// Product and events verbs only, for unit tests that bind no recovery handler.
pub const core_model: s.Schema = .{ .tool = "venomx", .summary = "core", .verbs = &(product ++ .{events}) };
pub const model: s.Schema = .{ .tool = "venomx", .summary = "Headless terminal sessions; explicit serve by default, opt-in on-demand startup, in-memory lifetime with opt-in durable checkpoints and explicit restore", .verbs = &(product ++ recovery_verbs ++ .{events}) };
/// Removals by an on_exit cascade carry `reason` (`on_exit` for
/// the pane, `empty` for its emptied window and session); explicit removals
/// carry none.
const removal_reason = field("reason", .{ .kind = .string, .choices = &.{ "on_exit", "empty" } }, false);
const base_events = blk: {
    var out = proto.events.catalog.entries;
    for (&out) |*e| if (@import("std").mem.eql(u8, e.name, "pane.removed")) {
        e.fields = &.{ pane, removal_reason };
    } else if (@import("std").mem.eql(u8, e.name, "pane.created")) {
        // Floats and popups carry their layer and geometry;
        // absent layer means tiled. `tags` is the pane's tag map at
        // creation (additive), so attached clients match `when` without a resync.
        e.fields = &.{ pane, session, field("layer", layer_type, false), field("window", str, false), field("float", float_wire, false), field("client", str, false), field("tags", tag_map, false), field("argv0", argv0_type, false) };
    } else if (@import("std").mem.eql(u8, e.name, "command.started") and !hasField(e.fields, "cmdline")) {
        // The shell's untrusted command line from OSC 133 C,
        // until venom-std's shared catalog carries it.
        e.fields = &.{ pane, field("command", str, true), field("cmdline", str, false) };
    };
    const frozen = out;
    break :blk frozen;
};
pub const catalog = base_events ++ [_]proto.events.catalog.Entry{
    .{ .name = "session.created", .resource_kind = "session", .fields = &.{ session, name } },
    .{ .name = "session.removed", .resource_kind = "session", .fields = &.{ session, removal_reason } },
    .{ .name = "window.created", .resource_kind = "window", .fields = &layout_fields },
    .{ .name = "window.layout_changed", .resource_kind = "window", .fields = &changed_fields },
    .{ .name = "window.removed", .resource_kind = "window", .fields = &.{ window, session, removal_reason } },
    // The foreground process name changed (absent: unknown).
    .{ .name = "pane.process_changed", .resource_kind = "pane", .fields = &.{ pane, field("process", str, false) } },
    .{ .name = "pane.terminating", .resource_kind = "pane", .fields = &.{ pane, field("requested_signal", str, true) } },
    .{ .name = "recovery.restored", .resource_kind = "server", .fields = &.{ field("checkpoint", str, true), field("cleanup_unverified", boolean, true) } },
    // Trusted run events. Never argv, shell text, key, output, environment or cwd.
    .{ .name = "run.started", .resource_kind = "run", .fields = &.{ field("run", str, true), pane } },
    .{ .name = "run.terminating", .resource_kind = "run", .fields = &.{ field("run", str, true), field("cause", run_cause, true) } },
    .{ .name = "run.completed", .resource_kind = "run", .fields = &.{ field("run", str, true), pane, field("outcome", run_outcome, true), field("exit_code", byte, false), field("signal", str, false), field("cause", run_cause, false) } },
    .{ .name = "run.expired", .resource_kind = "run", .fields = &.{field("run", str, true)} },
    // Principal events, resource `principal:<id>`. Never a token, a label or request params.
    .{ .name = "principal.created", .resource_kind = "principal", .fields = &.{ field("kind", .{ .kind = .string, .choices = &.{ "pane", "agent", "token", "process" } }, true), field("parent", str, true), field("grants", grants, true), field("expires", str, false), field("pane", str, false) } },
    .{ .name = "principal.revoked", .resource_kind = "principal", .fields = &.{ field("reason", .{ .kind = .string, .choices = &.{ "revoked", "expired", "exited" } }, true), field("cascade", int, true) } },
    .{ .name = "principal.denied", .resource_kind = "principal", .fields = &.{ field("verb", str, true), field("right", .{ .kind = .string, .choices = &.{ "read", "write", "respond", "files", "spawn", "admin" } }, true), field("resource", str, false), field("suppressed", int, false) } },
    // Tags, status segments, attention and notifications.
    .{ .name = "pane.tags_changed", .resource_kind = "pane", .fields = &.{ pane, field("tags", tag_map, true), revision } },
    .{ .name = "pane.attention_changed", .resource_kind = "pane", .fields = &.{ pane, field("level", level, true), field("reason", str, true), revision } },
    .{ .name = "status.changed", .resource_kind = "status", .fields = &.{ field("id", str, true), revision, field("segment", segment, true) } },
    .{ .name = "status.cleared", .resource_kind = "status", .fields = &.{ field("id", str, true), field("reason", .{ .kind = .string, .choices = &.{ "clear", "ttl", "disconnect", "revoked", "rule", "exec" } }, true) } },
    // Status rules.
    .{ .name = "status.rule_changed", .resource_kind = "status", .fields = &.{ field("id", str, true), revision, field("rule", rule, true) } },
    .{ .name = "status.rule_cleared", .resource_kind = "status", .fields = &.{ field("id", str, true), field("reason", .{ .kind = .string, .choices = &.{ "clear", "disconnect", "revoked" } }, true) } },
    .{ .name = "notify.posted", .resource_kind = "notification", .fields = &notification_fields },
    .{ .name = "notify.dismissed", .resource_kind = "notification", .fields = &.{field("id", str, true)} },
    // keys.changed (below): clients reload key tables on it.
    // Floats and popups.
    .{ .name = "pane.placed", .resource_kind = "pane", .fields = &.{ pane, window, field("layer", layer_type, true), field("float", float_wire, false) } },
    .{ .name = "pane.raised", .resource_kind = "pane", .fields = &.{ pane, window, field("z", int, true) } },
    .{ .name = "keys.changed", .resource_kind = "server", .fields = &.{ field("layer", key_layer, true), field("table", str, true), revision } },
};

/// Compiled extension: discoverable CLI commands, never daemon verbs.
/// It adds `new` (also the bare `venomx` command) and makes the
/// attach selector optional.
pub const local = .{ .{
    .name = "attach",
    .summary = "Attach this terminal to a session (its lowest-ID window) or one pane. Give at most one of session or pane; with neither, attach to the most recently attached session, else the most recently created one. Never starts a daemon or creates anything. " ++ @import("attach.zig").description,
    .interactive = true,
    .params = .{
        .{ .name = "session", .summary = "Session ID", .type = .{ .kind = .string } },
        .{ .name = "pane", .summary = "Pane ID", .type = .{ .kind = .string } },
        .{ .name = "raw", .summary = "Raw single-pane passthrough; requires --pane, falls back to emulation on size mismatch", .type = .{ .kind = .boolean }, .default = false },
        .{ .name = "history", .summary = "Scrollback rows to backfill per pane", .type = .{ .kind = .integer, .min = 0 }, .default = 10000 },
    },
    .result = .{ .kind = .object, .fields = .{} },
    .errors = .{
        .{ .code = "invalid_params.selector", .summary = "Both session and pane were given, or raw without pane" },
        .{ .code = "not_found.session", .summary = "No such session, or no session at all for a selector-less attach" },
        .{ .code = "not_found.pane", .summary = "No such pane" },
        .{ .code = "denied.read", .summary = "The caller cannot read the target" },
    },
}, .{
    .name = "new",
    .summary = "Start a new session with one shell and attach to it, like tmux new-session; bare `venomx` does the same with no options. Starts an on-demand daemon (serve --lifetime on-demand --origin interactive) when none runs and daemon.interactive_start allows it, authorizing as the owner through the owner file. The session is named after the working directory's basename unless --name is given. Its pane uses on_exit=remove and the session on_empty=remove, so exiting the shell ends the session (and an on-demand daemon). Short forms: -A for --attach-existing=true, -d for --detached=true, --nested for --nested=true; a trailing `-- program args...` sets --argv. Refused inside a venomx pane (VENOMX_PANE or VENOMX_PRINCIPAL set) unless --nested=true, which uses the caller's own token against a running daemon and never starts one. Agents must not use it.",
    .interactive = true,
    .params = .{
        .{ .name = "name", .summary = "Session name; default: the basename of the working directory (/ gives root), truncated to 128 bytes", .type = .{ .kind = .string } },
        .{ .name = "cwd", .summary = "Absolute working directory of the shell; default: the caller's", .type = .{ .kind = .string } },
        .{ .name = "attach_existing", .summary = "If exactly one session has this name, attach to it instead of creating one (-A)", .type = .{ .kind = .boolean }, .default = false },
        .{ .name = "detached", .summary = "Create the session but do not attach (-d); prints the new IDs", .type = .{ .kind = .boolean }, .default = false },
        .{ .name = "nested", .summary = "Allow running inside a venomx pane against a running daemon with the caller's own token; never starts a daemon", .type = .{ .kind = .boolean }, .default = false },
        .{ .name = "argv", .summary = "Program and arguments to run instead of the login shell; default: $SHELL (absolute and executable), else the password-database shell, else /bin/sh, as a login shell", .type = .{ .kind = .array, .items = .{ .kind = .string } } },
        .{ .name = "history", .summary = "Scrollback rows to backfill per pane", .type = .{ .kind = .integer, .min = 0 }, .default = 10000 },
    },
    .result = .{ .kind = .object, .fields = .{
        .{ .name = "session", .summary = "Session ID (with --detached=true)", .type = .{ .kind = .string } },
        .{ .name = "window", .summary = "Window ID (with --detached=true)", .type = .{ .kind = .string } },
        .{ .name = "pane", .summary = "Pane ID (with --detached=true)", .type = .{ .kind = .string } },
        .{ .name = "attached", .summary = "True when an existing session was reused (-A)", .type = .{ .kind = .boolean } },
    } },
    .errors = .{
        .{ .code = "denied.startup_context", .summary = "Run inside a venomx pane (VENOMX_PANE or VENOMX_PRINCIPAL set) without --nested=true, or with no daemon running and a manager's marker above the caller" },
        .{ .code = "conflict.ambiguous_name", .summary = "attach_existing matched several sessions; data.sessions lists their IDs" },
        .{ .code = "unavailable.not_running", .summary = "No daemon runs and starting one is not allowed (daemon.interactive_start=false, or --nested)" },
        .{ .code = "unavailable.startup_failed", .summary = "The daemon candidate failed during startup" },
        .{ .code = "unavailable.startup_deadline", .summary = "The daemon did not become ready within daemon.startup_timeout_ms" },
        .{ .code = "invalid_params.startup_config", .summary = "The startup configuration could not be read" },
        .{ .code = "invalid_params.name", .summary = "invalid display name" },
        .{ .code = "invalid_params.argv", .summary = "empty argv or NUL in argv" },
        .{ .code = "invalid_params.cwd", .summary = "cwd is not an absolute path" },
        .{ .code = "not_found.cwd", .summary = "cwd does not name an existing directory" },
        .{ .code = "unavailable.cwd", .summary = "cwd exists but cannot be entered" },
        .{ .code = "unavailable.spawn", .summary = "The program could not be started" },
        .{ .code = "unavailable.shutdown", .summary = "The daemon is shutting down" },
        .{ .code = "denied.token", .summary = "Token authentication failed" },
        .{ .code = "denied.write", .summary = "The caller cannot create sessions" },
        .{ .code = "denied.spawn", .summary = "The caller cannot start processes" },
        .{ .code = "not_found.session", .summary = "The session vanished before attach" },
    },
}, .{
    .name = "shell.init",
    .summary = "Print the shell integration snippet for zsh, bash or fish: inside a venomx pane it sends OSC 133 marks with the command line, so the status line shows `ping google.com` rather than the shell. Without --json it prints only the script. Load it from your rc file with `eval \"$(venomx shell init --shell=zsh)\"` (or bash), or `venomx shell init --shell=fish | source`. Outside a venomx pane, and on a second load, the snippet does nothing. Needs no daemon.",
    .params = .{
        .{ .name = "shell", .summary = "Which shell's snippet", .type = .{ .kind = .string, .choices = .{ "zsh", "bash", "fish" } }, .required = true },
    },
    .result = .{ .kind = .object, .fields = .{
        .{ .name = "shell", .summary = "The shell", .type = .{ .kind = .string }, .required = true },
        .{ .name = "script", .summary = "The snippet to evaluate", .type = .{ .kind = .string }, .required = true },
    } },
    .errors = .{},
} };

/// Compiled bootstrap extension: the local `serve.lifetime`
/// parameter and the startup policy keyed to `session.create`. Neither is a
/// format-1 member, a remote tool or an MCP startup path.
pub const serve_params = .{ .{
    .name = "lifetime",
    .summary = "Daemon lifetime policy",
    .type = .{ .kind = .string, .choices = .{ "persistent", "on-demand" } },
    .default = "persistent",
}, .{
    .name = "origin",
    .summary = "Who started the daemon, set by the launcher; reported by doctor only, never grants anything",
    .type = .{ .kind = .string, .choices = .{ "serve", "interactive", "session_create" } },
    .default = "serve",
} };
pub const startup = .{
    .verb = "session.create",
    .summary = "Startup policy (local CLI only): with daemon.startup=\"on-demand\" persisted in config, an ordinary CLI call with VENOMX_TOKEN=@owner outside any venomx pane and below no manager's marker may start a missing daemon as `serve --lifetime on-demand` on the selected socket, wait for readiness within daemon.startup_timeout_ms, then send this request once. MCP, wire requests and every other command never start a daemon. A lost reply is an unknown outcome (unavailable.startup_result): inspect state, never blindly retry.",
};

test "every catalog event's data fields pass the events item schema" {
    const std = @import("std");
    const data = for (events.item.?.fields.?) |f| {
        if (std.mem.eql(u8, f.name, "data")) break f.type.fields.?;
    } else unreachable;
    for (catalog) |e| for (e.fields) |ef| {
        const found = for (data) |df| {
            if (std.mem.eql(u8, df.name, ef.name)) break true;
        } else false;
        if (!found) std.debug.print("event {s}: data.{s} is not in the events item schema\n", .{ e.name, ef.name });
        try std.testing.expect(found);
    };
}
