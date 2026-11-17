const std = @import("std");
const cli = @import("cli");
const cfg = @import("cfg");
const proto = @import("proto");
const log = @import("log");
const supervisor = @import("supervisor");
const xdg = @import("xdg");
const stream = @import("stream.zig");
const Streams = @import("server.zig");
const Product = @import("product.zig").Product;
const seam = @import("seam.zig");
const manifest = @import("manifest.zig");
const lifecycle = @import("lifecycle.zig");
const recovery = @import("recovery.zig");
/// The renderer's debug logs would write over the attach client's screen.
pub const std_options: std.Options = .{ .log_scope_levels = &.{.{ .scope = .vaxis, .level = .warn }} };
const run_mod = @import("run.zig");
const tmux_shim = @import("tmux_shim.zig");
const standalone_mod = @import("standalone.zig");
const chrome = @import("chrome.zig");
const edges = @import("attach_border.zig");
const keys = @import("keys.zig");
const keys_registry = @import("keys_registry.zig");
const principal_events_mod = @import("principal_events.zig");
const floats = @import("floats.zig");
const chrome_theme = @import("chrome_theme.zig");
const Config = struct { grants: proto.grants.Policy = .{ .isolation = false }, pane_stream: stream.Config = .{}, log: log.Config = .{}, daemon: lifecycle.Settings = .{}, recovery: recovery.Settings = .{}, run: run_mod.Settings = .{}, attach: lifecycle.AttachSettings = .{}, status: chrome.StatusConfig = .{}, attention: chrome.AttentionConfig = .{}, keys: keys.Config = .{}, floats: floats.Config = .{}, theme: chrome_theme.Name = .trve };
/// `keys.tables` and `keys.prefixes` merge per table name
/// across layers.
const policies = lifecycle.policies ++ [_]cfg.FieldPolicy{ .{ .key = "keys.tables", .by_name = true }, .{ .key = "keys.prefixes", .by_name = true } };
const Store = cfg.Store(Config, &policies);
fn validate(config: Config) ?cfg.Validation {
    config.grants.check() catch return .{ .key = "grants" };
    config.pane_stream.check() catch return .{ .key = "pane_stream" };
    config.daemon.check() catch return .{ .key = "daemon" };
    config.recovery.check() catch return .{ .key = "recovery" };
    config.run.check() catch return .{ .key = "run" };
    config.attach.check() catch return .{ .key = "attach" };
    if (chrome.statusFailure(config.status)) |code| return .{ .key = "status", .code = code };
    if (config.status.segmentsFailure()) |code| return .{ .key = "status.segments", .code = code };
    config.attention.check() catch return .{ .key = "attention" };
    config.keys.check() catch return .{ .key = "keys" };
    config.floats.check() catch return .{ .key = "floats" };
    return null;
}
/// Per config file: same-layer key conflicts in that file's own
/// `keys.tables` fail as `invalid_params.key_conflict`.
fn validateLayer(config: Config, source: cfg.Source) ?cfg.Validation {
    return keys_registry.layerConflict(config.keys, source);
}
/// Checkpoint retention as a pre-activation effect: a reload that
/// would leave forbidden text or excess/expired checkpoints on disk fails.
const Retention = struct {
    recovery: ?*recovery.Recovery = null,
    pub fn apply(self: *Retention, previous: Config, candidate: Config) ?cfg.ActivationFailure {
        _ = previous;
        const r = self.recovery orelse return null;
        if (r.enforce(candidate.recovery)) |failure| return failure;
        r.settings = candidate.recovery;
        return null;
    }
};
const App = cli.WithBootstrap(cfg.mergeWith(manifest.model, .{ .errors = &(keys_registry.config_errors ++ chrome.config_errors) }), &.{}, .{ .local = manifest.local, .serve_params = manifest.serve_params, .startup = manifest.startup });
const Launcher = lifecycle.Launcher(Store, validate, validateLayer, createParamsValid);
fn createParamsValid(params: std.json.Value) bool {
    const name = params.object.get("name") orelse return true;
    return name == .string and Product.nameValid(name.string);
}
const notes =
    \\Humans start with a bare `venomx` in a terminal (the interactive new
    \\command): it starts an on-demand daemon if none runs and creates a session
    \\with a login shell (pane on_exit=remove, session on_empty=remove) shown on
    \\that terminal; exiting the shell ends the session. Agents must never run
    \\the interactive entry points (bare venomx or new): they need a terminal
    \\and refuse to run inside panes; use the headless verbs. window.create and pane.split take --on-exit
    \\keep|remove (default keep: exited panes stay capturable); session.create
    \\takes --on-empty keep|remove. run panes ignore on_exit.
    \\Start explicitly with `venomx serve` (default lifetime persistent: it never
    \\stops because of session, pane, child or client counts). Opt-in on-demand
    \\operation: with daemon.startup="on-demand" persisted in config, only an
    \\ordinary CLI `session create` with VENOMX_TOKEN=@owner from outside any pane
    \\may start a missing daemon (`serve --lifetime on-demand`) on the selected
    \\socket; MCP, wire requests and every other command (reads, ping, events,
    \\doctor, config, grants) never start one; agents must not try to elevate. An
    \\on-demand daemon waits 5000 ms for its first session, then stays up while
    \\any session exists (empty sessions, empty windows and exited panes count;
    \\detach and zero clients do not stop it) and exits right after its last
    \\session is removed. A lost create reply returns unavailable.startup_result:
    \\the outcome is unknown, so inspect state before retrying. daemon.* settings
    \\are restart-only and never change a running daemon's lifetime.
    \\Sessions, windows and panes live in
    \\memory until explicit removal or daemon shutdown. Disconnecting clients
    \\does not stop processes. Daemon restart loses all live state; durable
    \\checkpoints are opt-in (recovery.enabled=true, a human config choice):
    \\the daemon then writes private versioned checkpoints of the topology and
    \\pane states (terminal text only with recovery.terminal_text=.plain, which
    \\stores sensitive screen content). Nothing is ever restored, launched or
    \\replayed implicitly. A human with admin (VENOMX_TOKEN=@owner) runs
    \\`recovery list`, `recovery inspect --checkpoint=<id>` and `recovery restore
    \\--checkpoint=<id>` on an empty daemon: restored panes are exited archives
    \\(pane list/capture show a recovery object; process_state interrupted means
    \\the exit was never observed) with fresh IDs, owners and principals; old
    \\tokens, event cursors and stream offsets confer nothing. Restore runs and
    \\signals no process, and cannot verify that old processes stopped
    \\(cleanup_unverified). After a lost restore reply, inspect state before
    \\retrying. Agents must not use @owner and should not attempt recovery
    \\verbs; to run something again, create a new pane with a fresh argv, or
    \\replace an archive in place with `pane relaunch --pane=<archive>
    \\--argv=<json> --ack-orphans=true` (needs spawn and write on the archive).
    \\Relaunch is a new execution, never a continuation: no argv, cwd, env,
    \\grants, screen or input come from the archive; the new pane has a new ID,
    \\principal and token; archive streams close with pane_removed. The ack
    \\only admits that old processes may survive and the new run may repeat
    \\their external work. Relaunch launches at most once: after a lost reply
    \\the archive ID fails not_found.pane, so inspect pane list instead of
    \\retrying; a vanished executable fails unavailable.spawn and leaves the
    \\archive as it was. Ordinary exited panes are not archives
    \\(conflict.not_archive). Creation executes
    \\the nonempty argv array directly, by default in the daemon's cwd and sanitized
    \\environment, and never implicitly starts a shell. Every mutation checks
    \\scoped grants. With grants.isolation off (the venomx default, like tmux)
    \\unknown callers and panes may read, write and spawn everywhere; with it on
    \\unknown callers are read-only and panes write within self. Check
    \\`whoami --json`, never assume either. Use named flags. Agents
    \\use headless verbs and events.
    \\Config is data-only ZON at $XDG_CONFIG_HOME/venomx/config.zon (otherwise
    \\$HOME/.config/venomx/config.zon), above a read-only defaults file: the
    \\first venomx/defaults.zon in $XDG_CONFIG_DIRS (default /etc/xdg), which
    \\venom-os ships. A user key replaces the same default (keys.tables merge
    \\per name); config set always writes the user file and config get --json
    \\reports each value's source (builtin, defaults, user).
    \\Change it with config get/set/check/reload/schema.
    \\Events use source-qualified cursors; stage snapshots through their checkpoint.
    \\Plain pane/window/session remove never kills: it fails conflict.pane_running
    \\or conflict.not_empty. `pane kill` and `--recursive=true` removal are
    \\destructive and irreversible once the first signal is sent: they signal the
    \\pane process group (--signal, default SIGHUP), send SIGKILL after
    \\--grace-ms, answer only after every leader is reaped, and need write on the
    \\target and on every affected window and pane. Inspect with `window get` /
    \\`session get` first, and treat a lost response as an unknown outcome.
    \\`window create` and `pane split` take optional --cwd, --env and --env-unset.
    \\--cwd takes an absolute path only; from a shell use
    \\--cwd "$PWD". The CLI never resolves relative paths and `pane split` does
    \\not inherit the source pane's directory. The child's environment is the
    \\daemon's own, minus inherited *_TOKEN, *_PRINCIPAL, VENOMX_* and
    \\token-shaped values; then --env-unset names are removed; then --env
    \\entries ([{"name":..,"value":..}]) are set; then venomx sets VENOMX_TOKEN,
    \\VENOMX_PRINCIPAL, VENOMX_PANE and VENOMX_SOCKET. VENOMX_* names are
    \\reserved. The executable is found on the child's final PATH (empty and
    \\relative entries skipped) with no shell fallback. --program names the file
    \\to execute when it differs from argv[0] (--program /bin/sh --argv '["-sh"]'
    \\starts a login shell); it is resolved the same way. venomx and owner tokens
    \\are rejected; another tool's token passes only as exactly <TOOL>_TOKEN.
    \\Values passed with --env are visible in your argv, shell history and MCP
    \\transcripts: pass only what the child needs. venomx never echoes them.
    \\Read output that scrolled off with `pane capture-rows` (prefer it to a
    \\pane stream client): `--tail N` for the N most recent rows. To read a range, page
    \\with --epoch, --start <next> and the first page's --end until done is true.
    \\conflict.epoch means the pane was resized, cleared, reset or switched
    \\screens: re-read with --tail. not_found.rows reason evicted means output
    \\outran the reader; data.oldest says where to continue. Lines are physical
    \\rows padded to the pane width (trim trailing spaces for display); wrapped
    \\lines are split. Full-screen programs on the alternate screen have no
    \\history (screen "alternate"). `pane capture` stays the visible screen.
    \\Trusted commands: prefer `run` over `pane send` for commands
    \\whose result matters. Start with `run --key <unique> --session <s>
    \\--argv '[..]'` and wait with `run wait --run <id>`; on a lost response
    \\retry either with the identical request (the same key and parameters
    \\return the same run, never a second execution). Use --argv (no shell);
    \\add --shell only when shell syntax is needed. A wait timeout or Ctrl-C
    \\does not stop the command: use `run cancel` or --deadline-ms. Trust the
    \\record's outcome, never screen text, OSC 133/7501 or command.* events.
    \\`run wait` exits with status: the exit code, 128+signal, 124 deadline,
    \\125 other termination. Read more output with `pane capture-rows` and
    \\remove finished panes with `pane remove`. Pass --source from an earlier
    \\result to detect a daemon restart (conflict.source) instead of rerunning.
    \\Keys: never bind unprefixed keys or read the human's keys;
    \\register a table under your own sub-prefix with `keys register --name
    \\<namespace> --prefix <key> --bindings '[{"key":"a","exec":[..]}]'` (exec
    \\argv run by the client with no shell and no venomx token; {pane}
    \\placeholders are whole elements). `keys list --json` shows all layers.
    \\This needs write on server:root, which a pane does not hold; the owner,
    \\from outside every pane, may register any name but venomx.
    \\Shared chrome: never draw a status bar or overlay inside a
    \\pane, and never try to move a human's focus (no verb can). Describe panes
    \\with tags: --tags on window create / pane split, or `pane tag --set
    \\'[{"key":"role","value":"agent"}]'`; the owner tag is your namespace and is
    \\read-only. Publish status with `status set --id <namespace>.<name> --text ..`
    \\(your own namespace while isolation is on; venomx.* is always reserved;
    \\with --ttl-ms it defaults to bind=daemon and stays until it expires,
    \\otherwise bind=connection removes it when your connection closes). Ask for a human with
    \\`pane attention --pane <p> --level warn|urgent --reason ..` and clear it
    \\with --clear=true; post short messages with `notify post --text ..`. A BEL
    \\or an OSC 7501 state=blocked report from a pane's program sets info
    \\attention on a pane without any (config attention.from_bell, default true).
    \\Status rules turn events into a segment without a held
    \\connection: `status rule set --id <namespace>.<name> --on
    \\'["command.finished"]' --match '[{"key":"exit_code","op":"ne","value":"0"}]'
    \\--format '{event.command} {event.exit_code}' --ttl-ms 5000` (a rule needs
    \\--ttl-ms, --clear-on or both; it sees only events you can read; --scope
    \\event shows it in the event's session). `status set` takes --group tray
    \\(drawn in the tray), --icon and --click (a key-binding target run as the
    \\clicking client). Exec sources come only from the config files and only
    \\the owner changes them; never add one.
    \\Floats and popups: `pane float --window <w> --argv '[..]'
    \\--preset <namespace>.<name>` keeps a pane above a window for every
    \\client; it never takes focus. Refer to presets, not raw sizes, so the
    \\human can resize your views in config (floats.presets; sizes are "80"
    \\cells or "60%"); ship defaults with `floats register --name <ns>.<x>`.
    \\Unknown presets fall back to floats.default (doctor reports them). A
    \\popup covers one human's screen: only `pane popup --ticket <t>` with a
    \\ticket the human's key binding passed you ({popup_ticket}, single use,
    \\10 s) opens one; never mint tickets yourself. Describe placement with
    \\--near '[{"key":"group","value":"g"}]' on pane split / window create
    \\instead of choosing geometry; `pane place` and `pane raise` move panes
    \\between layers and up the float stack.
;
/// The `daemon.terminal_glyphs` result for what the daemon's environment can draw.
fn glyphsCheck(r: *cli.doctor.Report, sup: edges.Support) !void {
    const fix = try r.command("{s} doctor --json", r.tool);
    if (sup.heavy and sup.fang) return r.add("daemon.terminal_glyphs", .ok, "the daemon's environment (TERM, locale) can draw heavy box lines and ◤; attach checks its own terminal", fix);
    try r.add("daemon.terminal_glyphs", .warn, try r.print("the daemon's environment (TERM, locale; not necessarily the attaching terminal's) cannot draw heavy box lines or ◤; where attach finds the same, the focused border falls back to {s}, and ◤ to {s}. To get them, run attach from a terminal that can (not the Linux console or TERM=dumb) with a UTF-8 locale, e.g. LANG=C.UTF-8", .{ edges.Support.heavy_fallback, edges.Support.fang_fallback }), fix);
}
const Checks = struct {
    config: *Store,
    product: *Product,
    recovery: *recovery.Recovery,
    pub fn run(self: *Checks, r: *cli.doctor.Report) anyerror!void {
        const fix = try r.command("{s} config check --json", r.tool);
        self.config.check() catch |err| {
            if (err == error.OutOfMemory) return err;
            try r.add("config.valid", .fail, "configuration is invalid", fix);
            return self.runtime(r);
        };
        try r.add("config.valid", .ok, "configuration is valid", fix);
        try self.runtime(r);
        try keys_registry.doctor(r, self.product);
        try @import("status_rules.zig").doctor(r, self.product);
        try @import("status_exec.zig").doctor(r, self.product);
        try floats.doctor(r, self.product);
        try self.glyphs(r);
    }
    /// Heavy focus lines and the status line's `◤`, which a
    /// Linux console, a dumb terminal or a non-UTF-8 locale cannot draw.
    fn glyphs(self: *Checks, r: *cli.doctor.Report) !void {
        return glyphsCheck(r, @import("attach.zig").hostSupport(self.product.environ));
    }
    /// Latched lifetime, startup policy and budget (active vs
    /// persisted, pending restart warns), and lifecycle consistency.
    fn daemon(self: *Checks, r: *cli.doctor.Report, p: *Product) !void {
        const fix = try r.command("{s} doctor --json", r.tool);
        const config_fix = try r.command("{s} config check --json", r.tool);
        const st = &p.lifecycle;
        try r.add("daemon.lifetime", .ok, if (st.lifetime == .on_demand) "on-demand (latched from serve --lifetime; exits after its last session)" else "persistent (latched from serve --lifetime; never stops on resource or client counts)", fix);
        // Who started it; recorded only, grants nothing.
        try r.add("daemon.origin", .ok, try r.print("origin {s} (serve --origin)", .{@tagName(st.origin)}), fix);
        const active = self.config.current().daemon;
        const persisted_startup = self.config.get(r.arena, "daemon.startup") catch |err| if (err == error.OutOfMemory) return err else "invalid";
        const persisted_budget = self.config.get(r.arena, "daemon.startup_timeout_ms") catch |err| if (err == error.OutOfMemory) return err else "invalid";
        const active_startup = try r.print("\"{s}\"", .{active.startup});
        const active_budget = try r.print("{d}", .{active.startup_timeout_ms});
        const policy_pending = !std.mem.eql(u8, persisted_startup, active_startup);
        try r.add("daemon.startup_policy", if (policy_pending) .warn else .ok, try r.print("active {s}; persisted {s}{s}", .{ active_startup, persisted_startup, if (policy_pending) "; restart required to apply" else "" }), config_fix);
        const budget_pending = !std.mem.eql(u8, persisted_budget, active_budget);
        try r.add("daemon.startup_deadline", if (budget_pending) .warn else .ok, try r.print("client startup budget {s} ms; persisted {s}{s}", .{ active_budget, persisted_budget, if (budget_pending) "; restart required to apply" else "" }), config_fix);
        const persisted_interactive = self.config.get(r.arena, "daemon.interactive_start") catch |err| if (err == error.OutOfMemory) return err else "invalid";
        const active_interactive = if (active.interactive_start) "true" else "false";
        const interactive_pending = !std.mem.eql(u8, persisted_interactive, active_interactive);
        try r.add("daemon.interactive_start", if (interactive_pending) .warn else .ok, try r.print("active {s}; persisted {s}{s}", .{ active_interactive, persisted_interactive, if (interactive_pending) "; restart required to apply" else "" }), config_fix);
        try lastSessionCheck(r, p, fix);
        var sessions: usize = 0;
        for (p.sessions.items) |s| if (!s.removed) {
            sessions += 1;
        };
        const now = supervisor.monotonicMs();
        try r.add("daemon.lifecycle", if (st.consistent(sessions)) .ok else .fail, try r.print("state {s}; {d} sessions; first-session grace remaining {d} ms", .{ @tagName(st.phase), sessions, st.graceRemainingMs(now) }), fix);
    }
    /// Doctor check: a last-session file naming another
    /// daemon epoch (or a session gone from this one) is stale; it is
    /// ignored by selector-less attach.
    fn lastSessionCheck(r: *cli.doctor.Report, p: *Product, fix: []const u8) !void {
        const standalone = @import("standalone.zig");
        const last = try standalone.readLast(r.arena, p.environ) orelse return r.add("attach.last_session", .ok, "no last-session file", fix);
        const current = std.mem.eql(u8, last.epoch, p.events.source) and p.session(last.session) != null;
        try r.add("attach.last_session", if (current) .ok else .warn, if (current) "last-session file names a live session of this daemon" else "last-session file is stale (another daemon epoch or a removed session); selector-less attach ignores it", fix);
    }
    fn runtime(self: *Checks, r: *cli.doctor.Report) !void {
        const p = self.product;
        const st = p.events.status();
        const fix = try r.command("{s} doctor --json", r.tool);
        try r.add("events.log", .ok, try r.print("source {s}; retention seq {d}..{d}, {d}/{d} bytes", .{ st.source, st.low, st.high, st.bytes, st.limits.bytes }), fix);
        var sessions: usize = 0;
        var windows: usize = 0;
        var panes: usize = 0;
        var valid = true;
        for (p.sessions.items) |s| if (!s.removed) {
            sessions += 1;
        };
        for (p.windows.items) |w| if (!w.removed) {
            windows += 1;
            valid = valid and @import("layout.zig").valid(w.nodes);
        };
        for (p.panes.items) |pane| if (!pane.removed) {
            panes += 1;
        };
        try r.add("resources.tree", if (valid) .ok else .fail, try r.print("{d} sessions, {d} windows, {d} panes; authoritative preorder topology", .{ sessions, windows, panes }), fix);
        try r.add("process.supervision", .ok, "PTY groups, bound principals, child start barrier and bounded HUP/KILL shutdown; escaped descendants are not sandboxed", fix);
        // Doctor checks: termination state and counters.
        try r.add("panes.terminating", .ok, try r.print("{d} panes terminating", .{p.terminatingCount()}), fix);
        var stuck: std.ArrayList(u8) = .empty;
        for (p.panes.items) |pane| if (!pane.removed and pane.stuck) {
            if (stuck.items.len > 0) try stuck.appendSlice(r.arena, ", ");
            try stuck.appendSlice(r.arena, pane.id);
        };
        try r.add("panes.stuck", if (stuck.items.len == 0) .ok else .warn, if (stuck.items.len == 0) "no pane past its kill-wait deadline" else try r.print("past their kill-wait deadline: {s}", .{stuck.items}), fix);
        try r.add("panes.termination", .ok, try r.print("{d} kills, {d} escalations, {d} timeout.terminate, {d} discarded input bytes, {d} escaped descendants reaped", .{ p.kills, p.escalations, p.timeouts, p.discardedInput(), p.orphansReaped() }), fix);
        try r.add("events.removed_records", .ok, try r.print("{d} frozen authorization records of removed resources", .{p.removedRecords()}), fix);
        try self.daemon(r, p);
        try spawnChecks(p, r, fix);
        // capture_rows counters; never text, ranges or contents.
        const rs = p.rows_stats;
        try r.add("capture_rows", if (rs.max_hold_us > 50_000) .warn else .ok, try r.print("{d} calls, {d} pages not done; errors: {d} denied.read, {d} not_found.pane, {d} invalid_params.rows, {d} not_found.rows evicted, {d} not_found.rows future, {d} conflict.epoch, {d} unsupported.result_size; max pane-thread hold {d} us (warn above 50000)", .{ rs.calls, rs.partial, rs.denied, rs.missing, rs.params, rs.evicted, rs.future, rs.epoch, rs.size, rs.max_hold_us }), fix);
        try self.recovery.doctor(r);
        try runChecks(p, r, fix);
        // Stream resync counters; counts the panes that still exist.
        var resyncs: u64 = 0;
        for (p.streams.panes.items) |pane| resyncs += pane.resync_count;
        try r.add("pane_stream.state", .ok, try r.print("{d} clients; ring budget {d}, client backlog {d}; resize policy {s}; {d} stream resyncs", .{ p.streams.peers.items.len, p.streams.config.ring_bytes, p.streams.config.client_backlog_bytes, @tagName(p.streams.config.size_policy), resyncs }), fix);
    }
};
fn counts(r: *cli.doctor.Report, comptime names: []const []const u8, values: []const u64) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names, values, 0..) |name, n, i| try out.print(r.arena, "{s}{s} {d}", .{ if (i == 0) "" else ", ", name, n });
    return out.items;
}
/// Doctor checks for pane cwd and environment. Never reports paths, names or values.
fn spawnChecks(p: *Product, r: *cli.doctor.Report, fix: []const u8) !void {
    const spawn_env = @import("spawn_env.zig");
    const base = try p.baseEnv();
    if (base.pathWarning()) |warning| try r.add("spawn.path", .warn, warning, fix) else try r.add("spawn.path", .ok, "the daemon PATH has only absolute entries", fix);
    const st = base.stripped;
    try r.add("spawn.base_env", .ok, try r.print("inherited variables stripped: {d} *_TOKEN, {d} *_PRINCIPAL, {d} VENOMX_*, {d} token-shaped values", .{ st.token, st.principal, st.venomx, st.token_shaped }), fix);
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const cwd_ok = std.c.getcwd(&buf, buf.len) != null;
    std.crypto.secureZero(u8, &buf);
    try r.add("spawn.cwd", if (cwd_ok) .ok else .warn, if (cwd_ok) "the daemon's working directory exists" else "the daemon's working directory no longer exists; pass --cwd", fix);
    try r.add("spawn.failures", .ok, try r.print("invalid_params.env: {s}; not_found.cwd {d}; unavailable.cwd: {s}; unavailable.spawn: {s}", .{ try counts(r, &spawn_env.env_reasons, &p.env_failures), p.cwd_not_found, try counts(r, &spawn_env.cwd_reasons, &p.cwd_failures), try counts(r, &spawn_env.spawn_reasons, &p.spawn_failures) }), fix);
}
/// Doctor checks for trusted runs. Never argv, shell text, keys, output,
/// env or cwd.
fn runChecks(p: *Product, r: *cli.doctor.Report, fix: []const u8) !void {
    const runs = &p.runs;
    const max = runs.settings.max_active;
    const n = runs.active();
    try r.add("run.active", if (n * 10 >= @as(usize, max) * 9) .warn else .ok, try r.print("{d} runs not yet completed; max_active {d}", .{ n, max }), fix);
    try r.add("run.retained", .ok, try r.print("{d} records, {d} output bytes; evictions: count {d}, ms {d}, bytes {d}", .{ runs.records.items.len, runs.retainedBytes(), runs.evictions[0], runs.evictions[1], runs.evictions[2] }), fix);
    var stuck: usize = 0;
    for (p.panes.items) |pane| if (pane.run) |x| if (x.state == .terminating and pane.stuck) {
        stuck += 1;
    };
    try r.add("run.stuck", if (stuck == 0) .ok else .warn, try r.print("{d} runs terminating past their kill-wait", .{stuck}), fix);
    try r.add("run.counters", .ok, try r.print("started {d}, reused {d}; succeeded {d}, failed {d}, signaled {d}, terminated {d}; causes: cancel {d}, deadline {d}, pane_kill {d}, removal {d}, shutdown {d}; escaped descendants reaped {d}", .{ runs.started, runs.reused, runs.outcomes[0], runs.outcomes[1], runs.outcomes[2], runs.outcomes[3], runs.causes[0], runs.causes[1], runs.causes[2], runs.causes[3], runs.causes[4], p.orphansReaped() }), fix);
}
const KeyLayers = keys_registry.KeyLayers(Store);
const Snapshot = struct {
    config: *Store,
    product: *Product,
    pub fn capture(self: *Snapshot, a: std.mem.Allocator) anyerror![]const proto.events.Entity {
        const config = try self.config.capture(a);
        const product = try self.product.capture(a);
        return std.mem.concat(a, proto.events.Entity, &.{ config, product });
    }
};
fn samePolicy(a: proto.grants.Policy, b: proto.grants.Policy) bool {
    if (a.max_token_ttl != b.max_token_ttl or a.isolation != b.isolation) return false;
    for ([_][]const proto.grants.Grant{ a.unknown, a.interactive }, [_][]const proto.grants.Grant{ b.unknown, b.interactive }) |left, right| {
        if (left.len != right.len) return false;
        for (left, right) |l, r| if (l.right != r.right or !std.mem.eql(u8, l.scope, r.scope)) return false;
    }
    return true;
}
/// Only the owner principal changes an exec status source.
const ExecGuard = @import("status_exec.zig").ExecGuard(Store, Config);
const Loop = struct {
    server: *proto.Server,
    dispatcher: *proto.Dispatcher,
    product: *Product,
    config: *Store,
    logger: *log.Logger,
    recovery: *recovery.Recovery,
    /// The `.status.segments` last applied; a reload replaces the slice.
    segments: []const chrome.SegmentEntry = &.{},
    pub fn run(self: *Loop, stop: *const supervisor.Stop) anyerror!void {
        var polls: std.ArrayList(std.posix.pollfd) = .empty;
        defer polls.deinit(self.product.a);
        // Initialization is complete; the first-session grace
        // of an on-demand daemon starts at readiness.
        self.product.lifecycle.ready(supervisor.monotonicMs());
        while (!stop.requested()) {
            const now = Streams.nowMs();
            self.product.lifecycle.tick(supervisor.monotonicMs(), self.product.liveSessions());
            if (self.product.lifecycle.stopping()) {
                // The final removal (or grace expiry) committed: hand its
                // queued response and events to the bounded shutdown drain.
                try self.dispatcher.tick();
                try self.product.events.tick();
                return;
            }
            try self.product.supervise();
            try self.product.streams.pump(now);
            try self.product.tick();
            try self.dispatcher.tick();
            try self.product.events.tick();
            // Include PTYs in the same readiness wait as sockets. Waiting
            // only on sockets adds a 10 ms stall whenever a producer wakes
            // just after its last bounded read drained the PTY.
            polls.clearRetainingCapacity();
            try polls.append(self.product.a, .{ .fd = self.server.fd, .events = std.posix.POLL.IN, .revents = 0 });
            var buffered = false;
            for (self.server.connections.items) |conn| {
                buffered = buffered or conn.consumed > 0;
                try polls.append(self.product.a, .{ .fd = conn.fd, .events = (if (!conn.closing) std.posix.POLL.IN else @as(i16, 0)) |
                    (if (conn.output.items.len > 0) std.posix.POLL.OUT else @as(i16, 0)), .revents = 0 });
            }
            // A pidfd wakes the turn that reaps an exited leader.
            for (self.product.leaders.leaders.items) |l| if (l.pollFd()) |fd| {
                try polls.append(self.product.a, .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 });
            };
            for (self.product.streams.panes.items) |pane| {
                // Unemulated PTY output is pending work.
                buffered = buffered or pane.backlogged();
            }
            for (self.product.streams.panes.items) |pane| if (pane.pty) |pty| if (!pty.eof and pane.status == null) {
                try polls.append(self.product.a, .{ .fd = pty.fd, .events = std.posix.POLL.IN |
                    (if (pane.input_sent < pane.input.items.len) std.posix.POLL.OUT else @as(i16, 0)), .revents = 0 });
            };
            _ = std.posix.poll(polls.items, if (buffered) 0 else self.product.leaders.timeoutMs(10)) catch |err| if (err != error.Interrupted) return err;
            try self.server.poll(0);
            self.config.watch(now) catch |err| {
                if (err == error.OutOfMemory) return err;
                self.logger.warn("config reload failed", .{});
            };
            const current = self.config.current();
            if (!samePolicy(self.product.registry.policy, current.grants)) try self.product.registry.setPolicy(current.grants);
            // Only an isolating venomx is a process manager: with isolation off
            // its panes count as the user's terminal for other venom daemons.
            self.server.setManagerMarker(current.grants.isolation) catch self.logger.warn("manager marker could not be changed", .{});
            self.product.streams.config = current.pane_stream;
            self.product.runs.settings = current.run;
            // A reload re-resolves every float's preset.
            floats.configure(self.product, current.floats);
            self.product.attention = current.attention;
            // Rule and exec sources follow `.status.segments`.
            if (current.status.segments.ptr != self.segments.ptr or current.status.segments.len != self.segments.len) {
                try chrome.configure(self.product, current.status);
                self.segments = current.status.segments;
            }
            self.product.streams.source = self.product.events.source;
            // Panes attached from now on get the new theme's colours.
            self.product.streams.host_colors = chrome_theme.hostColors(current.theme);
            for (self.product.streams.panes.items) |p| try p.reconfigure(current.pane_stream);
            self.logger.setConfig(current.log);
            self.recovery.tick(current.recovery);
        }
    }
};
const Daemon = struct {
    a: std.mem.Allocator,
    io: std.Io,
    environ: std.process.Environ,
    stderr: *std.Io.Writer,
    stopped: *const std.atomic.Value(bool),
    entry_ms: i64,
    pub fn serve(self: *Daemon, path: proto.SocketOptions, params: std.json.Value) anyerror!void {
        // After every child is reaped and every path is cleaned up, the single
        // termination record may meet a launcher that already exited.
        defer ignorePipe();
        const lifetime = lifecycle.State.parse(params.object.get("lifetime").?.string);
        const origin = lifecycle.Origin.parse(params.object.get("origin").?.string);
        var logger = log.Logger.init(.{ .source = "venomx", .stderr = self.stderr });
        defer logger.deinit();
        var events = try proto.events.Log.init(self.a, "venomx", .{}, null);
        defer events.deinit();
        events.catalog = &manifest.catalog;
        const config_path = try cfg.configPath(self.a, "venomx", self.environ);
        defer self.a.free(config_path);
        try lifecycle.regularOrMissing(self.a, config_path);
        var retention: Retention = .{};
        const defaults = try cfg.defaultsPaths(self.a, "venomx", self.environ);
        defer cfg.freePaths(self.a, defaults);
        var config = try Store.init(self.a, .{ .io = self.io, .path = config_path, .defaults = defaults, .validate = validate, .validate_layer = validateLayer, .events = &events, .pre_activate = Store.PreActivate.init(&retention) });
        defer config.deinit();
        var key_layers: KeyLayers = .{ .store = &config };
        var registry = try proto.grants.Registry.init(self.a, "venomx", config.current().grants);
        defer registry.deinit();
        var streams = Streams.Server.init(self.a, events.source);
        streams.host_colors = chrome_theme.hostColors(config.current().theme);
        defer streams.deinit();
        streams.config = config.current().pane_stream;
        seam.init(self.environ);
        var leaders = supervisor.Leaders.init(self.a, if (seam.enabled) .{ .send = seam.send } else .{});
        defer leaders.deinit();
        var product: Product = .{ .leaders = &leaders, .a = self.a, .streams = &streams, .events = &events, .registry = &registry, .environ = self.environ, .lifecycle = .{ .lifetime = lifetime, .origin = origin }, .runs = .{ .settings = config.current().run }, .floats = .{ .config = config.current().floats }, .attention = config.current().attention };
        defer product.deinit();
        registry.containment = proto.grants.Containment.init(&product);
        // Principal lifecycle events. Set before the server, which chains the audit log in front.
        var principal_events: principal_events_mod.Emitter = .{ .events = &events, .registry = &registry };
        defer principal_events.deinit();
        registry.observer = principal_events.observer();
        product.principals = &principal_events;
        product.keytables.source = key_layers.source();
        streams.authorize = Product.streamGrants;
        streams.on_closed = .{ .context = &product, .f = Product.connectionClosed };
        streams.auth_context = &product;
        var rec = try recovery.Recovery.init(self.a, &product, self.environ);
        rec.logger = &logger;
        defer rec.deinit();
        rec.settings = config.current().recovery;
        var snapshot: Snapshot = .{ .config = &config, .product = &product };
        events.snapshot = proto.events.Snapshot.init(&snapshot);
        var checks: Checks = .{ .config = &config, .product = &product, .recovery = &rec };
        var server_check: cli.doctor.ServerCheck = .{ .server = undefined };
        const all_checks = [_]cli.doctor.Check{ .init("product", &checks), .init("runtime", &server_check) };
        const digest = try App.digest(self.a);
        var standard: cli.Standard(App) = .init(.{ .notes = notes, .home = self.environ.getPosix("HOME"), .checks = &all_checks, .schema = &digest });
        // Only the owner changes an exec source.
        var exec_guard: ExecGuard = .{ .store = &config };
        var config_bindings = config.bindings();
        for (&config_bindings) |*b| if (std.mem.eql(u8, b.verb, "config.set")) {
            b.handler = proto.VerbHandler.init(&exec_guard);
        };
        const bindings = product.bindings() ++ .{proto.Binding{ .verb = "events", .handler = proto.VerbHandler.init(&events) }} ++ config_bindings ++ rec.bindings() ++ standard.bindings();
        var dispatcher = try proto.Dispatcher.init(self.a, &App.schema, &bindings, .{}, null);
        defer dispatcher.deinit();
        streams.control = dispatcher.handler();
        var server = try proto.Server.init(self.a, .{ .hello = .{ .identity = .{ .name = "venomx", .version = @import("version.zig").version }, .caps = &.{ "cancel", stream.capability }, .schema = &digest }, .path = path, .registry = &registry, .subreaper = true, .manager_marker = registry.policy.isolation }, streams.handler());
        defer server.deinit();
        product.socket = server.path;
        // Only the socket lock holder touches its store; retention
        // (and temporary cleanup) completes before readiness.
        try rec.bind(server.path);
        retention.recovery = &rec;
        try rec.startup();
        server_check.server = &server;
        // An on-demand candidate bounds its own initialization by
        // the configured budget measured from process entry, then aborts with
        // cleanup (deferred deinit releases the socket, owner file and lock).
        if (lifetime == .on_demand) {
            const budget: i64 = config.current().daemon.startup_timeout_ms;
            if (seam.startupFailure()) return error.StartupInjected;
            while (seam.startupDelay(supervisor.monotonicMs() - self.entry_ms)) {
                if (supervisor.monotonicMs() - self.entry_ms >= budget or self.stopped.load(.acquire)) break;
                var none: [1]std.posix.pollfd = undefined;
                _ = std.posix.poll(none[0..0], 10) catch {};
            }
            if (supervisor.monotonicMs() - self.entry_ms >= budget) return error.StartupDeadline;
        }
        // The shared supervisor owns the reactor thread; it never restarts PTYs.
        // From this thread it also reaps escaped descendants.
        const status = try xdg.siblingPath(self.a, server.path, "status.json");
        defer self.a.free(status);
        var sup = supervisor.Supervisor.init(self.a, .{ .status_path = status, .logger = &logger, .reap_orphans = true });
        defer sup.deinit();
        product.orphans_reaped = &sup.orphans_reaped;
        var loop: Loop = .{ .server = &server, .dispatcher = &dispatcher, .product = &product, .config = &config, .logger = &logger, .recovery = &rec };
        try sup.addThread("reactor", supervisor.Task.init(&loop), .{ .restart = .never });
        sup.run(self.stopped, .{ .poll_ms = 10, .grace_ms = 2000 });
        product.shutting_down = true;
        dispatcher.cancelAll();
        server.shutdown();
        // Shutdown through Leaders: SIGHUP, SIGKILL at the deadline, then
        // a short bounded wait to reap; never a blocking wait.
        const deadline = Streams.nowMs() + 2000;
        product.shutdownLeaders(leaders.now() + 2000);
        while (true) {
            try product.supervise();
            if (leaders.live() == 0 and server.connections.items.len == 0) break;
            const now = Streams.nowMs();
            if (now >= deadline + 200 or (now >= deadline and leaders.live() == 0)) break;
            try streams.pump(now);
            try server.poll(@intCast(@max(1, @min(10, leaders.timeoutMs(10)))));
        }
        if (leaders.live() != 0) return error.ShutdownFailed;
        // A final clean checkpoint only after every group was
        // reaped, with its own 2000 ms budget; the lock is still held.
        try rec.finalize(proto.os.nowMs() + 2000);
        for (sup.workers.items) |w| if (w.last_exit) |exit| {
            if (exit.failed()) return error.ReactorFailed;
        };
    }
};
/// `venomx new`: the persisted config and an interactive-origin launcher.
const Interactive = struct {
    launcher: Launcher,
    fn settings(ptr: *anyopaque, a: std.mem.Allocator, environ: std.process.Environ) anyerror!@import("standalone.zig").Settings {
        const self: *Interactive = @ptrCast(@alignCast(ptr));
        const path = try cfg.configPath(a, "venomx", environ);
        lifecycle.regularOrMissing(a, path) catch |err| return if (err == error.OutOfMemory) err else error.StartupConfig;
        const defaults = try cfg.defaultsPaths(a, "venomx", environ);
        var store = Store.init(self.launcher.gpa, .{ .io = self.launcher.io, .path = path, .defaults = defaults, .validate = validate, .validate_layer = validateLayer }) catch |err| return if (err == error.OutOfMemory) err else error.StartupConfig;
        defer store.deinit();
        const current = store.current();
        return .{ .interactive_start = current.daemon.interactive_start, .startup_timeout_ms = current.daemon.startup_timeout_ms, .on_session_end = if (std.mem.eql(u8, current.attach.on_session_end, "next")) "next" else "exit" };
    }
    fn launch(ptr: *anyopaque, a: std.mem.Allocator, socket: []const u8, environ: std.process.Environ) anyerror!void {
        const self: *Interactive = @ptrCast(@alignCast(ptr));
        return self.launcher.launch(context(a, socket, environ));
    }
    fn failed(ptr: *anyopaque) anyerror!bool {
        const self: *Interactive = @ptrCast(@alignCast(ptr));
        if (self.launcher.pid == 0) return true;
        return (try self.launcher.poll(context(undefined, "", null))) == .failed;
    }
    fn context(a: std.mem.Allocator, socket: []const u8, environ: ?std.process.Environ) cli.runtime.Startup.Context {
        return .{ .allocator = a, .call = .{}, .path = .{ .socket = socket, .environ = environ }, .started_ms = 0, .deadline_ms = 0, .interrupted = null };
    }
    const vtable: @import("standalone.zig").Host.VTable = .{ .settings = settings, .launch = launch, .failed = failed };
    fn host(self: *Interactive) @import("standalone.zig").Host {
        return .{ .ptr = self, .vtable = &vtable };
    }
};
fn ignorePipe() void {
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.PIPE, &action, null);
}
/// serve ignores SIGPIPE on its way out, so a candidate whose launcher already
/// exited sees its termination record fail here (a loser of
/// the on-demand start race, or a winner at shutdown). Nobody is left to read it. Exit at once:
/// returning the error from main symbolizes a stack trace, which takes a debug
/// build about 300 ms of CPU, seconds on a loaded machine.
fn noReader(err: anyerror) anyerror {
    if (err == error.WriteFailed) std.process.exit(1);
    return err;
}
/// The fangs for the command line. Coloured only on a
/// terminal, without a non-empty `NO_COLOR`.
fn fangsChrome(env: *const std.process.Environ.Map, tty: bool) ?@import("venom-term").theme.Chrome {
    if (!tty) return null;
    if (env.get("NO_COLOR")) |v| if (v.len > 0) return null;
    return chrome_theme.chrome(.trve, @import("venom-term").theme.Mode.detect(env));
}

/// `venomx --version`: the fangs; with `--json` (either order) only
/// `{"version":"..."}`. True when it was a version request and has been
/// answered. Anything else with `--version` goes to the shared parser.
fn printVersion(args: []const []const u8, env: *const std.process.Environ.Map, tty: bool, w: *std.Io.Writer) !bool {
    var version = false;
    var json = false;
    for (args) |x| {
        if (std.mem.eql(u8, x, "--version")) version = true else if (std.mem.eql(u8, x, "--json")) json = true else return false;
    }
    if (!version) return false;
    const fangs_mod = @import("fangs.zig");
    if (json) {
        try w.writeAll("{\"version\":\"" ++ fangs_mod.version ++ "\"}\n");
    } else try fangs_mod.write(w, fangsChrome(env, tty), &.{ "venomx " ++ fangs_mod.version, fangs_mod.tagline });
    return true;
}

/// The command's verb: the first argument that is not an option, skipping
/// the value of `--socket <path>`.
fn verbOf(args: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--socket")) {
            i += 1;
        } else if (!std.mem.startsWith(u8, args[i], "-")) return args[i];
    }
    return null;
}

/// Whether `args` is a human `doctor`, whose output `printDoctor` frames.
fn isHumanDoctor(args: []const []const u8) bool {
    const verb = verbOf(args) orelse return false;
    if (!std.mem.eql(u8, verb, "doctor")) return false;
    for (args) |x| if (std.mem.startsWith(u8, x, "--json") or std.mem.eql(u8, x, "--help") or std.mem.eql(u8, x, "-h")) return false;
    return true;
}

/// Whether `args` is a human `shell init`, whose JSON result `printScript`
/// unwraps to the bare script so `eval "$(venomx shell init ...)"` works.
fn isHumanShellInit(args: []const []const u8) bool {
    var words: [2][]const u8 = .{ "", "" };
    var n: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (std.mem.startsWith(u8, x, "--json") or std.mem.eql(u8, x, "--help") or std.mem.eql(u8, x, "-h")) return false;
        if (std.mem.eql(u8, x, "--socket")) {
            i += 1;
        } else if (!std.mem.startsWith(u8, x, "-") and n < 2) {
            words[n] = x;
            n += 1;
        }
    }
    return n == 2 and std.mem.eql(u8, words[0], "shell") and std.mem.eql(u8, words[1], "init");
}

/// A successful `shell init` result line becomes its script; anything else
/// (a usage error) passes through unchanged.
fn printScript(gpa: std.mem.Allocator, captured: []const u8, w: *std.Io.Writer) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, captured, .{}) catch return w.writeAll(captured);
    defer parsed.deinit();
    if (parsed.value == .object) if (parsed.value.object.get("script")) |v| if (v == .string) return w.writeAll(v.string);
    try w.writeAll(captured);
}

/// The `doctor` header: the fangs, a blank line, then the report. Only for a
/// report (`captured` starts with a check line), never for usage errors.
fn printDoctor(env: *const std.process.Environ.Map, tty: bool, captured: []const u8, w: *std.Io.Writer) !void {
    const fangs_mod = @import("fangs.zig");
    if (std.mem.startsWith(u8, captured, "[")) {
        try fangs_mod.write(w, fangsChrome(env, tty), &.{ "venomx " ++ fangs_mod.version ++ " doctor", fangs_mod.tagline });
        try w.writeByte('\n');
    }
    try w.writeAll(captured);
}

pub fn main(init: std.process.Init) !void {
    const entry_ms = supervisor.monotonicMs();
    const stopped = supervisor.installSignalHandlers();
    const argv = try init.minimal.args.toSlice(init.arena.allocator());
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &out_buf);
    var err = std.Io.File.stderr().writer(init.io, &err_buf);
    var presentation: @import("attach.zig").Context = .{ .gpa = init.gpa, .io = init.io, .environ = init.minimal.environ, .environ_map = init.environ_map, .stopped = stopped };
    // Retention: the daemon's heap is zeroed on every free.
    var scrub: @import("scrub.zig").Scrub = .{ .child = init.gpa };
    var daemon: Daemon = .{ .a = scrub.allocator(), .io = init.io, .environ = init.minimal.environ, .stderr = &err.interface, .stopped = stopped, .entry_ms = entry_ms };
    var launcher: Launcher = .{ .gpa = init.gpa, .io = init.io, .environ = init.minimal.environ, .stderr = &err.interface };
    defer launcher.deinit();
    var interactive: Interactive = .{ .launcher = .{ .gpa = init.gpa, .io = init.io, .environ = init.minimal.environ, .stderr = &err.interface, .origin = .interactive } };
    defer interactive.launcher.deinit();
    presentation.host = interactive.host();
    // `venomx tmux ...`, or this binary run under the name `tmux`.
    if (tmux_shim.invocation(argv)) |rest| {
        const stderr_w = &err.interface;
        const cwd = try standalone_mod.currentDir(init.arena.allocator());
        const sock = @import("xdg").socketPath(init.arena.allocator(), "venomx", .{ .socket = null, .environ = init.minimal.environ, .uid = std.c.getuid() }) catch |e| {
            stderr_w.print("venomx tmux: cannot work out the daemon socket path ({s})\n", .{@errorName(e)}) catch {};
            stderr_w.flush() catch {};
            std.process.exit(1);
        };
        const lock_path = @import("xdg").siblingPath(init.arena.allocator(), sock, "tmux.lock") catch |e| {
            stderr_w.print("venomx tmux: cannot build the respawn lock path ({s})\n", .{@errorName(e)}) catch {};
            stderr_w.flush() catch {};
            std.process.exit(1);
        };
        const env: tmux_shim.Env = .{ .lock_path = lock_path, .stopped = stopped, .pane = init.minimal.environ.getPosix("VENOMX_PANE"), .cwd = cwd, .shell = init.minimal.environ.getPosix("SHELL") orelse "/bin/sh" };
        const plain = try init.arena.allocator().alloc([]const u8, rest.len);
        for (rest, 0..) |r, i| plain[i] = r;
        if (plain.len == 1 and (std.mem.eql(u8, plain[0], "--help") or std.mem.eql(u8, plain[0], "-h"))) {
            try tmux_shim.usage(&out.interface);
            out.interface.flush() catch |e| return noReader(e);
            return;
        }
        var conn = tmux_shim.Daemon.connect(init.gpa, init.minimal.environ, stopped) catch |e| {
            stderr_w.print("venomx tmux: cannot reach the venomx daemon ({s}); run inside a venomx pane or set VENOMX_SOCKET\n", .{@errorName(e)}) catch {};
            stderr_w.flush() catch {};
            std.process.exit(1);
        };
        const code = tmux_shim.run(init.arena.allocator(), conn.backend(), env, plain, &out.interface, stderr_w);
        // process.exit skips defers: flush and close the connection first.
        var flushed = true;
        out.interface.flush() catch {
            flushed = false;
        };
        err.interface.flush() catch {
            flushed = false;
        };
        conn.deinit();
        if (!flushed) std.process.exit(if (code != 0) code else 1);
        if (code != 0) std.process.exit(code);
        return;
    }
    const tty = std.c.isatty(1) == 1;
    if (try printVersion(argv[1..], init.environ_map, tty, &out.interface)) {
        out.interface.flush() catch |e| return noReader(e);
        return;
    }
    // Bare `venomx` is `new`; `new`'s short forms and trailing
    // argv are rewritten for the shared parser.
    const args = try @import("standalone.zig").rewriteArgs(init.arena.allocator(), argv[1..]);
    // A human `doctor` is captured, to put the fangs ahead of its report.
    var captured: std.Io.Writer.Allocating = .init(init.gpa);
    defer captured.deinit();
    const framed = isHumanDoctor(argv[1..]);
    const script = isHumanShellInit(argv[1..]);
    const status = App.run(init.gpa, args, .{ .stdout = if (framed or script) &captured.writer else &out.interface, .stderr = &err.interface, .environ = init.minimal.environ, .bootstrap = cli.Bootstrap.initWithParams(&daemon), .startup = cli.runtime.Startup.init(&launcher), .local = cli.Local.init(&presentation), .interrupted = stopped }) catch |e| return noReader(e);
    if (framed) printDoctor(init.environ_map, tty, captured.written(), &out.interface) catch |e| return noReader(e);
    if (script) printScript(init.gpa, captured.written(), &out.interface) catch |e| return noReader(e);
    out.interface.flush() catch |e| return noReader(e);
    err.interface.flush() catch |e| return noReader(e);
    if (status != 0) std.process.exit(status);
}

test "daemon.terminal_glyphs is ok where the terminal can draw them, and warns with the remedy where it cannot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var report: cli.doctor.Report = .{ .arena = arena.allocator(), .tool = "venomx" };
    try glyphsCheck(&report, edges.Support.detect("xterm-256color", null, null, "en_US.UTF-8"));
    try glyphsCheck(&report, edges.Support.detect("linux", null, null, "en_US.UTF-8"));
    try glyphsCheck(&report, edges.Support.detect("xterm-256color", null, null, "C"));
    try std.testing.expectEqual(cli.doctor.Status.ok, report.results.items[0].status);
    for (report.results.items[1..]) |res| {
        try std.testing.expectEqual(cli.doctor.Status.warn, res.status);
        try std.testing.expectEqualStrings("daemon.terminal_glyphs", res.id);
        try std.testing.expect(std.mem.indexOf(u8, res.message, "UTF-8 locale") != null);
    }
}

test "--version prints the fangs, or only JSON with --json in either order" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.testing.expect(try printVersion(&.{"--version"}, &env, false, &w));
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "━━━━━━  ━━━━━━\n"));
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b") == null);
    for ([_][]const []const u8{ &.{ "--version", "--json" }, &.{ "--json", "--version" } }) |args| {
        w = .fixed(&buf);
        try std.testing.expect(try printVersion(args, &env, true, &w));
        try std.testing.expectEqualStrings("{\"version\":\"" ++ @import("version.zig").version ++ "\"}\n", w.buffered());
    }
    w = .fixed(&buf);
    try std.testing.expect(!try printVersion(&.{ "doctor", "--version" }, &env, true, &w));
    try std.testing.expect(!try printVersion(&.{"ping"}, &env, true, &w));
    try std.testing.expectEqual(@as(usize, 0), w.buffered().len);
}

test "the doctor header frames a human report only; NO_COLOR turns colour off" {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try std.testing.expect(isHumanDoctor(&.{"doctor"}));
    try std.testing.expect(isHumanDoctor(&.{ "--socket", "x", "doctor" }));
    try std.testing.expect(!isHumanDoctor(&.{ "doctor", "--json" }));
    try std.testing.expect(!isHumanDoctor(&.{ "doctor", "--help" }));
    try std.testing.expect(!isHumanDoctor(&.{ "attach", "doctor" }));
    try std.testing.expect(!isHumanDoctor(&.{"--help"}));
    try std.testing.expect(isHumanShellInit(&.{ "shell", "init", "--shell=zsh" }));
    try std.testing.expect(isHumanShellInit(&.{ "--socket", "x", "shell", "init", "--shell=fish" }));
    try std.testing.expect(!isHumanShellInit(&.{ "shell", "init", "--shell=zsh", "--json" }));
    try std.testing.expect(!isHumanShellInit(&.{ "shell", "init", "--help" }));
    try std.testing.expect(!isHumanShellInit(&.{ "attach", "shell", "init" }));
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try printDoctor(&env, true, "[ok] a: b\n", &w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "venomx " ++ @import("version.zig").version ++ " doctor") != null);
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), "\n\n[ok] a: b\n"));
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[") != null);
    // A usage error or anything else that is not a report passes unframed.
    w = .fixed(&buf);
    try printDoctor(&env, true, "usage: x\n", &w);
    try std.testing.expectEqualStrings("usage: x\n", w.buffered());
    // NO_COLOR: any non-empty value; empty does not count.
    try env.put("NO_COLOR", "1");
    w = .fixed(&buf);
    try printDoctor(&env, true, "[ok] a: b\n", &w);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b") == null);
    try env.put("NO_COLOR", "");
    try std.testing.expect(fangsChrome(&env, true) != null);
}
