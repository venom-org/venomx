---
title: Command reference
description: Every venomx verb, its flags, result and errors, generated from the verb schema.
order: 9
generated: by `zig build site-docs` from `venomx docs`; do not edit
---
# venomx

Headless terminal sessions; explicit serve by default, opt-in on-demand startup, in-memory lifetime with opt-in durable checkpoints and explicit restore

## Conventions

- Subcommands are space-separated (`venomx grant issue`); the exact dotted wire name is also accepted (`venomx grant.issue`).
- Every parameter is a named flag: `--name value` or `--name=value`. Values starting with `-` must use `=`. Booleans need `=true` or `=false`; arrays and objects take one JSON value. Flags cannot repeat and there are no positional arguments.
- Global options: `--json`, `--socket <path>`, `--help`. With `--json`, stdout holds only the result or `{"error":...}`; diagnostics go to stderr.
- Streaming commands with `--json` print one JSON item per line; the final success summary is validated (and sets the exit status) but not printed.
- Match `error.code` and the exit status, never English messages.

| Error class | Exit |
|---|---|
| success | 0 |
| failed (and unknown classes) | 1 |
| invalid_params (and CLI usage) | 2 |
| not_found | 3 |
| denied | 4 |
| conflict | 5 |
| unavailable | 6 |
| timeout | 7 |
| cancelled | 8 |
| protocol | 9 |
| unsupported | 10 |
| internal | 11 |

## Commands

### `venomx attach`

Attach this terminal to a session (its lowest-ID window) or one pane. Give at most one of session or pane; with neither, attach to the most recently attached session, else the most recently created one. Never starts a daemon or creates anything. After the leader (default ctrl+b, see keys.leader) a popup lists the next keys of your active tables; ? shows it at once. The default keys: h j k l or the arrows move focus, Tab and Shift-Tab next and previous pane, \\ and - split, c new window, n and p next and previous window, 1-9 a window, \[ scroll (then j k, the arrows, PgUp, PgDn, { } for the previous or next command, until Esc), PgUp, PgDn and \] scroll, z zoom (this client only), ! next pane needing attention, d detach, X close pane, f show or hide floats (this client only), F next float, x close popup, : command, L lock (every key goes to the pane until the unlock key, default ctrl+alt+b, see keys.unlock). Esc cancels and clears the selection (at the first level it can also close a focused popup), Backspace goes up one level, and the leader again sends it to the pane. Every other key reaches the focused pane unchanged. Products add tables under their own sub-prefix (keys register). Mouse wheel scrolls; left drag selects and copies with OSC 52. Presentation clients use the owner file by default; VENOMX\_TOKEN overrides it. Inside a venomx pane the pane's own rights apply. The daemon must already be running. With --raw=true and --pane, use host scrollback and forward host input unchanged (leader d detaches; leader leader sends the leader). A size mismatch switches to single-pane emulation.

- Wire name: `attach`
- MCP tool: none (local command)
- Grant: `none`
- Exit status: standard error mapping
- Interactive: needs a terminal on stdin and stdout

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--session` | string | no |  | Session ID |
| `--pane` | string | no |  | Pane ID |
| `--raw` | boolean | no | false | Raw single-pane passthrough; requires --pane, falls back to emulation on size mismatch |
| `--history` | integer [0..] | no | 10000 | Scrollback rows to backfill per pane |

Result: object {}

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.selector` | 2 | Both session and pane were given, or raw without pane |
| `not_found.session` | 3 | No such session, or no session at all for a selector-less attach |
| `not_found.pane` | 3 | No such pane |
| `denied.read` | 4 | The caller cannot read the target |

### `venomx audit`

Read recent audit records

- Wire name: `audit`
- MCP tool: `audit`
- Grant: `admin`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--limit` | integer [1..1000] | no | 100 | Maximum records |

Result: object { records: array of object { ts: string (required), source: string (required), event: string (required), principal: string (required), peer: object { pid: integer (required), exe: string, start: integer } (required), verb: string (required), right: string (required), resource: string, code: string, target: string, cascade: integer } (required) }

### `venomx completions`

Print shell completions generated from the verb schema

- Wire name: `completions`
- MCP tool: none (local command)
- Grant: `none`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--shell` | string (one of: bash, zsh, fish) | yes |  | Target shell |

Result: object { content: string (required) }

### `venomx config check`

Validate defaults.zon, config.zon and overlays without changing active state

- Wire name: `config.check`
- MCP tool: `config_dcheck`
- Grant: `read`
- Exit status: standard error mapping

No parameters.

Result: object { valid: boolean (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.config_zon` | 2 | Malformed or incorrectly typed data-only ZON |
| `invalid_params.config_key` | 2 | Unknown or invalid dotted object key |
| `invalid_params.config_value` | 2 | Whole configuration validation failed |
| `invalid_params.config_secret` | 2 | Secret fields in ZON must be references |
| `failed.config_activation` | 1 | Pre-activation cleanup failed; active config preserved |
| `failed.config_io` | 1 | Cannot read or atomically replace config, or the file is read-only |
| `failed.config_edit` | 1 | Cannot edit this key in the file's text; the file is unchanged |
| `failed.config_secret_store` | 1 | Secret store unavailable or failed |
| `invalid_params.key_conflict` | 2 | Two key tables of one config file bind the same key or sub-prefix; data.source names the file |
| `invalid_params.status_layout` | 2 | A status segment id is listed twice, or on two of status.left, status.center and status.right |
| `invalid_params.segment` | 2 | A status.segments entry is invalid: a user.\* entry without exactly one source, more than one source, a source outside user.\*, a bad group, icon or priority, or a repeated id |
| `invalid_params.template` | 2 | A status.segments format has an unknown variable, a bad spec or unbalanced brackets |

### `venomx config get`

Read redacted effective ZON (builtin \< defaults.zon \< config.zon \< overlays) and each value's source

- Wire name: `config.get`
- MCP tool: `config_dget`
- Grant: `read`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--key` | string | no | "" | Dotted field path; empty reads all |

Result: object { content: string (required), source: string (required), path: string, sources: array of object { key: string (required), source: string (required), path: string } (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.config_zon` | 2 | Malformed or incorrectly typed data-only ZON |
| `invalid_params.config_key` | 2 | Unknown or invalid dotted object key |
| `invalid_params.config_value` | 2 | Whole configuration validation failed |
| `invalid_params.config_secret` | 2 | Secret fields in ZON must be references |
| `failed.config_activation` | 1 | Pre-activation cleanup failed; active config preserved |
| `failed.config_io` | 1 | Cannot read or atomically replace config, or the file is read-only |
| `failed.config_edit` | 1 | Cannot edit this key in the file's text; the file is unchanged |
| `failed.config_secret_store` | 1 | Secret store unavailable or failed |
| `invalid_params.key_conflict` | 2 | Two key tables of one config file bind the same key or sub-prefix; data.source names the file |
| `invalid_params.status_layout` | 2 | A status segment id is listed twice, or on two of status.left, status.center and status.right |
| `invalid_params.segment` | 2 | A status.segments entry is invalid: a user.\* entry without exactly one source, more than one source, a source outside user.\*, a bad group, icon or priority, or a repeated id |
| `invalid_params.template` | 2 | A status.segments format has an unknown variable, a bad spec or unbalanced brackets |

### `venomx config reload`

Apply validated hot settings; preserve restart-only values

- Wire name: `config.reload`
- MCP tool: `config_dreload`
- Grant: `admin`
- Exit status: standard error mapping

No parameters.

Result: object { changed: boolean (required), restart_required: boolean (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.config_zon` | 2 | Malformed or incorrectly typed data-only ZON |
| `invalid_params.config_key` | 2 | Unknown or invalid dotted object key |
| `invalid_params.config_value` | 2 | Whole configuration validation failed |
| `invalid_params.config_secret` | 2 | Secret fields in ZON must be references |
| `failed.config_activation` | 1 | Pre-activation cleanup failed; active config preserved |
| `failed.config_io` | 1 | Cannot read or atomically replace config, or the file is read-only |
| `failed.config_edit` | 1 | Cannot edit this key in the file's text; the file is unchanged |
| `failed.config_secret_store` | 1 | Secret store unavailable or failed |
| `invalid_params.key_conflict` | 2 | Two key tables of one config file bind the same key or sub-prefix; data.source names the file |
| `invalid_params.status_layout` | 2 | A status segment id is listed twice, or on two of status.left, status.center and status.right |
| `invalid_params.segment` | 2 | A status.segments entry is invalid: a user.\* entry without exactly one source, more than one source, a source outside user.\*, a bad group, icon or priority, or a repeated id |
| `invalid_params.template` | 2 | A status.segments format has an unknown variable, a bad spec or unbalanced brackets |

### `venomx config schema`

Describe JSON-equivalent config types and field policies

- Wire name: `config.schema`
- MCP tool: `config_dschema`
- Grant: `read`
- Exit status: standard error mapping

No parameters.

Result: object { content: string (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.config_zon` | 2 | Malformed or incorrectly typed data-only ZON |
| `invalid_params.config_key` | 2 | Unknown or invalid dotted object key |
| `invalid_params.config_value` | 2 | Whole configuration validation failed |
| `invalid_params.config_secret` | 2 | Secret fields in ZON must be references |
| `failed.config_activation` | 1 | Pre-activation cleanup failed; active config preserved |
| `failed.config_io` | 1 | Cannot read or atomically replace config, or the file is read-only |
| `failed.config_edit` | 1 | Cannot edit this key in the file's text; the file is unchanged |
| `failed.config_secret_store` | 1 | Secret store unavailable or failed |

### `venomx config set`

Validate and atomically persist a ZON value to the product's config file (the user file unless it picks an overlay) without reloading

- Wire name: `config.set`
- MCP tool: `config_dset`
- Grant: `admin`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--key` | string | yes |  | Dotted object field path; map entry names may be quoted (a."b.c".d) |
| `--value` | string | yes |  | One data-only ZON value |

Result: object { changed: boolean (required), restart_required: boolean (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.config_zon` | 2 | Malformed or incorrectly typed data-only ZON |
| `invalid_params.config_key` | 2 | Unknown or invalid dotted object key |
| `invalid_params.config_value` | 2 | Whole configuration validation failed |
| `invalid_params.config_secret` | 2 | Secret fields in ZON must be references |
| `failed.config_activation` | 1 | Pre-activation cleanup failed; active config preserved |
| `failed.config_io` | 1 | Cannot read or atomically replace config, or the file is read-only |
| `failed.config_edit` | 1 | Cannot edit this key in the file's text; the file is unchanged |
| `failed.config_secret_store` | 1 | Secret store unavailable or failed |
| `invalid_params.key_conflict` | 2 | Two key tables of one config file bind the same key or sub-prefix; data.source names the file |
| `invalid_params.status_layout` | 2 | A status segment id is listed twice, or on two of status.left, status.center and status.right |
| `invalid_params.segment` | 2 | A status.segments entry is invalid: a user.\* entry without exactly one source, more than one source, a source outside user.\*, a bad group, icon or priority, or a repeated id |
| `invalid_params.template` | 2 | A status.segments format has an unknown variable, a bad spec or unbalanced brackets |

### `venomx docs`

Print Markdown or man documentation, or write it to a directory

- Wire name: `docs`
- MCP tool: none (local command)
- Grant: `none`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--format` | string (one of: markdown, man) | no | "markdown" | Output format |
| `--directory` | string | no |  | Write one file per page into this existing directory instead of printing |

Result: object { content: string, files: array of string }

### `venomx doctor`

Run read-only diagnostic checks; exits 1 if any check fails

- Wire name: `doctor`
- MCP tool: `doctor`
- Grant: `read`
- Exit status: on success, `result.status`; errors use the standard mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--client-schema` | string | no |  | Schema digest the caller was built against; a mismatch is reported as a warning |

Result: object { status: integer [0..255] (required), checks: array of object { id: string (required), status: string (one of: ok, warn, fail) (required), message: string (required), fix: string (required) } (required) }

### `venomx events`

Replay events and follow changes

- Wire name: `events`
- MCP tool: `events`
- Grant: `read`
- Exit status: standard error mapping
- Streams: `--json` prints one item per line and suppresses the final success summary; MCP buffers at most 1024 items and 1 MiB per call (else `unsupported.stream_limit`)

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--after` | string | no | "" | after |
| `--types` | array of string | no | \[\] | types |
| `--resources` | array of string | no | \[\] | resources |
| `--follow` | boolean | no | true | follow |

Result: object {}

Stream item: object { seq: integer [0..9007199254740991] (required), ts: string (required), source: string (required), type: string (required), data: object { pane: string, session: string, title: string, command: string, cmdline: string, reason: string, restart_required: boolean, exit_code: integer [0..255], records: array of object { id: string (required), state: string (required), kind: string, app: string, title: string, msg: string, progress: integer [0..100] }, entities: array of object { resource: string (required), entity_type: string (required), content: string (required) }, complete: boolean, window: string, name: string, revision: integer [0..9007199254740991], nodes: array of object { kind: string (one of: pane, split) (required), pane: string, axis: string (one of: cols, rows), first: integer [0..9007199254740991], second: integer [0..9007199254740991], ratio: integer [1..9999] }, requested_signal: string, checkpoint: string, cleanup_unverified: boolean, run: string, outcome: string, cause: string, state: string, signal: string, tags: array of object { key: string (required), value: string (required) }, level: string, id: string, segment: object { id: string (required), text: string (required), side: string (one of: left, center, right) (required), priority: integer [0..100] (required), style: string (one of: normal, muted, accent, ok, warn, error) (required), when: array of object { key: string (required), value: string (required) } (required), scope: string (required), ttl_ms: integer [1000..86400000], bind: string (one of: connection, daemon) (required), revision: integer [0..9007199254740991] (required), group: string, icon: string, click: object { local: string, verb: string, args: string, exec: array of string } }, rule: object { id: string (required), on: array of string (required), match: array of object { key: string (required), op: string (one of: eq, ne, prefix) (required), value: string (required) } (required), clear_on: array of string (required), format: string (required), ttl_ms: integer [1000..86400000], side: string (one of: left, center, right) (required), priority: integer [0..100] (required), style: string (one of: normal, muted, accent, ok, warn, error) (required), when: array of object { key: string (required), value: string (required) } (required), scope: string (required), bind: string (one of: connection, daemon) (required), group: string, icon: string, click: object { local: string, verb: string, args: string, exec: array of string }, revision: integer [0..9007199254740991] (required), origin: string (one of: config, runtime) (required) }, text: string, ttl_ms: integer [0..9007199254740991], namespace: string, layer: string, float: object { preset: string, width: string (required), height: string (required), anchor: string (one of: center, top, bottom, left, right, top\_left, top\_right, bottom\_left, bottom\_right) (required), x: integer [-4096..4096] (required), y: integer [-4096..4096] (required), min_cols: integer [1..65535] (required), min_rows: integer [1..65535] (required), border: string (one of: none, single, rounded, heavy) (required), title: string, z: integer [0..9007199254740991] (required) }, client: string, z: integer [0..9007199254740991], table: string, kind: string, parent: string, grants: array of object { right: string (one of: none, read, write, respond, files, spawn, admin) (required), scope: string (required) }, expires: string, verb: string, right: string, resource: string, cascade: integer [0..9007199254740991], suppressed: integer [0..9007199254740991], argv0: string, process: string } (required) }

### `venomx floats register`

Ship a default float preset under the caller's namespace (product layer); the owner principal may use any name outside venomx.\*, with no expiry under bind=daemon. floats.presets in config wins field by field; bind=connection removes it when this connection closes.

- Wire name: `floats.register`
- MCP tool: `floats_dregister`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--name` | string | yes |  | Preset name \<namespace\>.\<name\>; the namespace must be the caller's (the owner principal may use any but venomx) |
| `--width` | string | no |  | Cells ("80") or percent of the window area ("60%"); overrides the preset |
| `--height` | string | no |  | Cells ("24") or percent of the window area ("60%"); overrides the preset |
| `--anchor` | string (one of: center, top, bottom, left, right, top\_left, top\_right, bottom\_left, bottom\_right) | no |  | Where the rectangle sits in the window area |
| `--x` | integer [-4096..4096] | no |  | Column offset from the anchor |
| `--y` | integer [-4096..4096] | no |  | Row offset from the anchor |
| `--min-cols` | integer [1..65535] | no |  | Below this many columns the client shows the float full-window |
| `--min-rows` | integer [1..65535] | no |  | Below this many rows the client shows the float full-window |
| `--border` | string (one of: none, single, rounded, heavy) | no |  | Border drawn by the client |
| `--title` | string | no |  | Border title (at most 128 bytes); default: the pane's OSC 2 title |
| `--bind` | string (one of: connection, daemon) | no | "connection" | connection: removed when the registering connection closes; daemon: kept |

Result: object { name: string (required), layer: string (one of: product) (required) }

| Error | Exit | Meaning |
|---|---|---|
| `denied.write` | 4 | The caller cannot write server:root |
| `denied.namespace` | 4 | The name is outside the caller's namespace; for the owner principal, it is in venomx.\* |
| `conflict.preset_limit` | 5 | 64 presets are registered |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `invalid_params.geometry` | 2 | An unparsable size, offset, title or preset name |

### `venomx grant issue`

Issue an attenuated token, returned once; with pid, bind a principal to that process instead, with no token

- Wire name: `grant.issue`
- MCP tool: `grant_dissue`
- Grant: `spawn`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--grants` | array of object { right: string (one of: none, read, write, respond, files, spawn, admin) (required), scope: string (required) } | yes |  | Requested grants |
| `--ttl` | integer [1..4294967295] | no |  | Lifetime in seconds |
| `--label` | string | no |  | Human label |
| `--namespace` | string | no |  | Tool namespace (\[a-z\]\[a-z0-9-\]{0,31}); defaults to the issuer's. Owner and admin may pass any but the daemon's tool name (venomx), others only their own |
| `--pid` | integer [2..2147483647] | no |  | Bind to this process alone, not those below it: no token, no expiry unless ttl is given, and kept across a restart of this daemon while the process lives. Only the owner, an admin or a process principal may |

Result: object { principal: string (required), token: string, expires: string or null (required) }

### `venomx grant list`

List visible principals

- Wire name: `grant.list`
- MCP tool: `grant_dlist`
- Grant: `read`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--principal` | string | no |  | Principal to list |

Result: object { principals: array of object { principal: string (required), kind: string (required), parent: string or null, grants: array of object { right: string (one of: none, read, write, respond, files, spawn, admin) (required), scope: string (required) } (required), expires: string or null, pane: string, label: string, namespace: string (required), capped_by: array of string, restored: boolean } (required) }

### `venomx grant revoke`

Revoke a principal and its descendants

- Wire name: `grant.revoke`
- MCP tool: `grant_drevoke`
- Grant: `spawn`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--principal` | string | yes |  | Principal to revoke |

Result: object { revoked: array of string (required) }

### `venomx keys list`

List every key table (built-in, product, defaults file, user config) with bindings, shadowed bindings and same-layer conflicts.

- Wire name: `keys.list`
- MCP tool: `keys_dlist`
- Grant: `read`
- Exit status: standard error mapping

No parameters.

Result: object { leader: string (required), unlock: string (required), popup_delay_ms: integer [0..9007199254740991] (required), timeout_ms: integer [0..9007199254740991] (required), revision: integer [0..9007199254740991] (required), tables: array of object { name: string (required), layer: string (one of: builtin, product, defaults, user) (required), prefix: string, label: string, groups: array of object { key: string (required), label: string (required), sticky: boolean }, when: array of object { key: string (required), value: string (required) } (required), bindings: array of object { key: string (required), local: string, verb: string, args: string, exec: array of string, label: string } (required), source: string } (required), shadowed: array of object { key: string (required), table: string (required), layer: string (one of: builtin, product, defaults, user) (required), by: string (required), by_layer: string (one of: builtin, product, defaults, user) (required) } (required), conflicts: array of object { layer: string (one of: builtin, product, defaults, user) (required), key: string (required), tables: array of string (required) } (required) }

| Error | Exit | Meaning |
|---|---|---|
| `denied.read` | 4 | The caller cannot read the target |
| `denied.write` | 4 | The caller cannot write the target |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `invalid_params.bindings` | 2 | Bad name, prefix, when or binding (key syntax, not exactly one target, unknown local or verb, args not a JSON object, spliced placeholder) |
| `denied.namespace` | 4 | The table name is not the caller's namespace; the owner principal may use any name but venomx, which is built in |
| `conflict.key_prefix` | 5 | The prefix is a built-in key or taken by another product table, or 32 tables exist |
| `not_found.key_table` | 3 | No registered table has this name |

### `venomx keys register`

Register a key table under a sub-prefix of the leader, or replace the whole table of that name. A principal uses its own namespace as the name; the owner principal may use any name but venomx, and with bind=daemon its table has no expiry. Another principal's table goes when that principal is revoked or expires. Every presentation client loads it; user config and the defaults file take precedence and shadowed bindings are reported. Needs write on server:root.

- Wire name: `keys.register`
- MCP tool: `keys_dregister`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--name` | string | yes |  | Table name: the caller's namespace; the owner principal may use any name but venomx |
| `--prefix` | string | yes |  | The one key after the leader that opens the table; keys.prefixes in the config can move it |
| `--label` | string | no |  | What the leader popup shows for the prefix, 1-40 bytes; without one, the table's name |
| `--groups` | array of object { key: string (required), label: string (required), sticky: boolean } | no |  | Named inner prefixes: {key, label, sticky} |
| `--when` | array of object { key: string (required), value: string (required) } | no |  | Active only while the focused pane has all these tags |
| `--bindings` | array of object { key: string (required), local: string, verb: string, args: string, exec: array of string, label: string } | yes |  | Bindings: {key, and exactly one of local, verb (+ args) or exec} |
| `--bind` | string (one of: connection, daemon) | no | "connection" | connection: removed when the registering connection closes; daemon: kept until unregistered |

Result: object { name: string (required), prefix: string (required), layer: string (one of: builtin, product, defaults, user) (required), shadowed: array of object { key: string (required), table: string (required), layer: string (one of: builtin, product, defaults, user) (required), by: string (required), by_layer: string (one of: builtin, product, defaults, user) (required) } (required) }

| Error | Exit | Meaning |
|---|---|---|
| `denied.read` | 4 | The caller cannot read the target |
| `denied.write` | 4 | The caller cannot write the target |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `invalid_params.bindings` | 2 | Bad name, prefix, when or binding (key syntax, not exactly one target, unknown local or verb, args not a JSON object, spliced placeholder) |
| `denied.namespace` | 4 | The table name is not the caller's namespace; the owner principal may use any name but venomx, which is built in |
| `conflict.key_prefix` | 5 | The prefix is a built-in key or taken by another product table, or 32 tables exist |
| `not_found.key_table` | 3 | No registered table has this name |

### `venomx keys unregister`

Remove the key table named after the caller's namespace; the owner principal may remove any registered table.

- Wire name: `keys.unregister`
- MCP tool: `keys_dunregister`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--name` | string | yes |  | Table name: the caller's namespace; the owner principal may use any name but venomx |

Result: object {}

| Error | Exit | Meaning |
|---|---|---|
| `denied.read` | 4 | The caller cannot read the target |
| `denied.write` | 4 | The caller cannot write the target |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `invalid_params.bindings` | 2 | Bad name, prefix, when or binding (key syntax, not exactly one target, unknown local or verb, args not a JSON object, spliced placeholder) |
| `denied.namespace` | 4 | The table name is not the caller's namespace; the owner principal may use any name but venomx, which is built in |
| `conflict.key_prefix` | 5 | The prefix is a built-in key or taken by another product table, or 32 tables exist |
| `not_found.key_table` | 3 | No registered table has this name |

### `venomx mcp`

Serve the verbs as an MCP stdio server (JSON-RPC on stdin/stdout)

- Wire name: `mcp`
- MCP tool: none (local command)
- Grant: `none`
- Exit status: standard error mapping

No parameters.

Result: object {}

### `venomx new`

Start a new session with one shell and attach to it, like tmux new-session; bare \`venomx\` does the same with no options. Starts an on-demand daemon (serve --lifetime on-demand --origin interactive) when none runs and daemon.interactive\_start allows it, authorizing as the owner through the owner file. The session is named after the working directory's basename unless --name is given. Its pane uses on\_exit=remove and the session on\_empty=remove, so exiting the shell ends the session (and an on-demand daemon). Short forms: -A for --attach-existing=true, -d for --detached=true, --nested for --nested=true; a trailing \`-- program args...\` sets --argv. Refused inside a venomx pane (VENOMX\_PANE or VENOMX\_PRINCIPAL set) unless --nested=true, which uses the caller's own token against a running daemon and never starts one. Agents must not use it.

- Wire name: `new`
- MCP tool: none (local command)
- Grant: `none`
- Exit status: standard error mapping
- Interactive: needs a terminal on stdin and stdout

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--name` | string | no |  | Session name; default: the basename of the working directory (/ gives root), truncated to 128 bytes |
| `--cwd` | string | no |  | Absolute working directory of the shell; default: the caller's |
| `--attach-existing` | boolean | no | false | If exactly one session has this name, attach to it instead of creating one (-A) |
| `--detached` | boolean | no | false | Create the session but do not attach (-d); prints the new IDs |
| `--nested` | boolean | no | false | Allow running inside a venomx pane against a running daemon with the caller's own token; never starts a daemon |
| `--argv` | array of string | no |  | Program and arguments to run instead of the login shell; default: $SHELL (absolute and executable), else the password-database shell, else /bin/sh, as a login shell |
| `--history` | integer [0..] | no | 10000 | Scrollback rows to backfill per pane |

Result: object { session: string, window: string, pane: string, attached: boolean }

| Error | Exit | Meaning |
|---|---|---|
| `denied.startup_context` | 4 | Run inside a venomx pane (VENOMX\_PANE or VENOMX\_PRINCIPAL set) without --nested=true, or with no daemon running and a manager's marker above the caller |
| `conflict.ambiguous_name` | 5 | attach\_existing matched several sessions; data.sessions lists their IDs |
| `unavailable.not_running` | 6 | No daemon runs and starting one is not allowed (daemon.interactive\_start=false, or --nested) |
| `unavailable.startup_failed` | 6 | The daemon candidate failed during startup |
| `unavailable.startup_deadline` | 6 | The daemon did not become ready within daemon.startup\_timeout\_ms |
| `invalid_params.startup_config` | 2 | The startup configuration could not be read |
| `invalid_params.name` | 2 | invalid display name |
| `invalid_params.argv` | 2 | empty argv or NUL in argv |
| `invalid_params.cwd` | 2 | cwd is not an absolute path |
| `not_found.cwd` | 3 | cwd does not name an existing directory |
| `unavailable.cwd` | 6 | cwd exists but cannot be entered |
| `unavailable.spawn` | 6 | The program could not be started |
| `unavailable.shutdown` | 6 | The daemon is shutting down |
| `denied.token` | 4 | Token authentication failed |
| `denied.write` | 4 | The caller cannot create sessions |
| `denied.spawn` | 4 | The caller cannot start processes |
| `not_found.session` | 3 | The session vanished before attach |

### `venomx notify dismiss`

Dismiss a notification for this connection, or for everyone with all=true.

- Wire name: `notify.dismiss`
- MCP tool: `notify_ddismiss`
- Grant: `read`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--id` | string | yes |  | Notification ID |
| `--all` | boolean | no | false | Remove it for every client (needs write on server:root); otherwise only for this connection |

Result: object { id: string (required), all: boolean (required) }

| Error | Exit | Meaning |
|---|---|---|
| `denied.read` | 4 | The caller cannot read the target |
| `denied.write` | 4 | The caller cannot write the target |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `invalid_params.notification` | 2 | text is not 1-512 bytes without control characters |
| `not_found.pane` | 3 | No such pane |
| `not_found.notification` | 3 | No such notification (dismissed, expired or dropped) |

### `venomx notify list`

List unexpired notifications this connection has not dismissed.

- Wire name: `notify.list`
- MCP tool: `notify_dlist`
- Grant: `read`
- Exit status: standard error mapping

No parameters.

Result: object { notifications: array of object { id: string (required), text: string (required), level: string (one of: info, warn, urgent) (required), pane: string, ttl_ms: integer [0..9007199254740991] (required), namespace: string (required) } (required) }

| Error | Exit | Meaning |
|---|---|---|
| `denied.read` | 4 | The caller cannot read the target |
| `denied.write` | 4 | The caller cannot write the target |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `invalid_params.notification` | 2 | text is not 1-512 bytes without control characters |
| `not_found.pane` | 3 | No such pane |
| `not_found.notification` | 3 | No such notification (dismissed, expired or dropped) |

### `venomx notify post`

Post a short notification to every client's status line. The daemon keeps the newest 64. Needs write on server:root.

- Wire name: `notify.post`
- MCP tool: `notify_dpost`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--text` | string | yes |  | Message (at most 512 bytes, no control characters) |
| `--level` | string (one of: info, warn, urgent) | no | "info" | Level |
| `--pane` | string | no |  | Pane the message is about |
| `--ttl-ms` | integer [1000..86400000] | no | 8000 | How long clients show it |

Result: object { id: string (required) }

| Error | Exit | Meaning |
|---|---|---|
| `denied.read` | 4 | The caller cannot read the target |
| `denied.write` | 4 | The caller cannot write the target |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `invalid_params.notification` | 2 | text is not 1-512 bytes without control characters |
| `not_found.pane` | 3 | No such pane |
| `not_found.notification` | 3 | No such notification (dismissed, expired or dropped) |

### `venomx pane attention`

Mark a pane as needing the human's attention, or clear it. Every client marks the pane and counts it; nothing moves anyone's focus. Needs write on the pane.

- Wire name: `pane.attention`
- MCP tool: `pane_dattention`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--pane` | string | yes |  | pane |
| `--level` | string (one of: none, info, warn, urgent) | no |  | Attention level; give exactly one of level or clear=true |
| `--reason` | string | no | "" | Why the pane needs attention (at most 256 bytes) |
| `--clear` | boolean | no | false | Clear attention (level none) |

Result: object { pane: string (required), level: string (one of: none, info, warn, urgent) (required) }

| Error | Exit | Meaning |
|---|---|---|
| `denied.read` | 4 | The caller cannot read the target |
| `denied.write` | 4 | The caller cannot write the target |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `not_found.pane` | 3 | No such pane |
| `invalid_params.tags` | 2 | A tag breaks a tag rule (key or value syntax, duplicate, the read-only owner, or more than 16 tags) |
| `invalid_params.attention` | 2 | Neither or both of level and clear=true, or a reason over 256 bytes |

### `venomx pane capture`

pane.capture

- Wire name: `pane.capture`
- MCP tool: `pane_dcapture`
- Grant: `read`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--pane` | string | yes |  | pane |

Result: object { text: string (required), cols: integer [0..9007199254740991] (required), rows: integer [0..9007199254740991] (required), exited: boolean (required), exit_code: integer [0..255], signal: string, recovery: object { checkpoint: string (required), previous_pane: string (required), process_state: string (one of: exited, interrupted) (required), text_state: string (one of: omitted, expired, plain) (required), cut_rows: integer [0..9007199254740991] (required) } }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | unavailable.spawn |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |

### `venomx pane capture-rows`

Read physical scrollback and screen rows of a pane as plain UTF-8, paged and bounded. Use --tail N for recent output; page with --epoch, --start \<next\> and the first page's --end until done.

- Wire name: `pane.capture_rows`
- MCP tool: `pane_dcapture__rows`
- Grant: `read`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--pane` | string | yes |  | Pane to read |
| `--epoch` | integer [0..4294967295] | no |  | Row epoch that start and end belong to; required with start or end |
| `--start` | integer [0..9007199254740991] | no |  | First absolute row (inclusive); default: oldest retained row |
| `--end` | integer [0..9007199254740991] | no |  | Absolute row after the last one (exclusive); default: current end |
| `--tail` | integer [1..9007199254740991] | no |  | Select at most this many newest rows of the current epoch; excludes epoch, start and end |
| `--max-rows` | integer [1..10000] | no | 1000 | Most rows in this reply |
| `--max-bytes` | integer [1..16777216] | no | 262144 | Most UTF-8 bytes of line text in this reply |

Result: object { pane: string (required), screen: string (one of: primary, alternate) (required), epoch: integer [0..9007199254740991] (required), offset: integer [0..9007199254740991] (required), cols: integer [0..9007199254740991] (required), rows: integer [0..9007199254740991] (required), bounds: object { oldest: integer [0..9007199254740991] (required), active: integer [0..9007199254740991] (required), end: integer [0..9007199254740991] (required) } (required), start: integer [0..9007199254740991] (required), end: integer [0..9007199254740991] (required), next: integer [0..9007199254740991], done: boolean (required), lines: array of string (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.rows` | 2 | tail with epoch/start/end (exclusive), start or end without epoch (epoch\_required), or end \< start (order) |
| `not_found.rows` | 3 | Selection reaches outside the retained rows: evicted (before oldest) or future (at or after end) |
| `conflict.epoch` | 5 | The given epoch is not current: the screen was resized, cleared, reset or switched |
| `unsupported.result_size` | 10 | The first selected row alone does not fit max\_bytes or the connection's max\_frame |
| `not_found.pane` | 3 | No such pane |
| `denied.read` | 4 | The caller cannot read the pane |

### `venomx pane float`

Create a floating pane in a window's float layer, running argv directly (no shell). Every client showing the window draws it (unless it hid floats) at the preset's geometry resolved against its own window area; it never takes focus. Prefer --preset over raw sizes.

- Wire name: `pane.float`
- MCP tool: `pane_dfloat`
- Grant: `spawn`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--window` | string | yes |  | window |
| `--argv` | array of string | yes |  | argv |
| `--cols` | integer | no | 80 | Initial columns |
| `--rows` | integer | no | 24 | Initial rows |
| `--grants` | array of object { right: string (one of: none, read, write, respond, files, spawn, admin) (required), scope: string (required) } | no |  | grants |
| `--cwd` | string | no |  | Absolute working directory for the new process; default: the daemon's working directory |
| `--env` | array of object { name: string (required), value: string (required) } | no |  | Environment variables to set or replace in the new process, applied after env\_unset |
| `--env-unset` | array of string | no |  | Environment variable names to remove from the inherited environment |
| `--preset` | string | no |  | Float preset \<namespace\>.\<name\> (floats.presets in config, or floats.register); prefer it to raw sizes. Unknown presets fall back to floats.default |
| `--width` | string | no |  | Cells ("80") or percent of the window area ("60%"); overrides the preset |
| `--height` | string | no |  | Cells ("24") or percent of the window area ("60%"); overrides the preset |
| `--anchor` | string (one of: center, top, bottom, left, right, top\_left, top\_right, bottom\_left, bottom\_right) | no |  | Where the rectangle sits in the window area |
| `--x` | integer [-4096..4096] | no |  | Column offset from the anchor |
| `--y` | integer [-4096..4096] | no |  | Row offset from the anchor |
| `--min-cols` | integer [1..65535] | no |  | Below this many columns the client shows the float full-window |
| `--min-rows` | integer [1..65535] | no |  | Below this many rows the client shows the float full-window |
| `--border` | string (one of: none, single, rounded, heavy) | no |  | Border drawn by the client |
| `--title` | string | no |  | Border title (at most 128 bytes); default: the pane's OSC 2 title |
| `--tags` | array of object { key: string (required), value: string (required) } | no |  | Pane tags as \[{key,value}\]; the daemon adds the read-only owner tag (the creator's namespace) |
| `--on-exit` | string (one of: keep, remove) | no | "keep" | What happens when the pane's process exits: keep the exited pane (default) or remove it, cascading to an emptied window and an on\_empty=remove session |

Result: object { pane: string (required), window: string (required), session: string (required), principal: string (required), pid: integer [0..9007199254740991] (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | The program could not be started; data.reason says why |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |
| `invalid_params.cwd` | 2 | cwd is not an absolute path of 1-4095 bytes without NUL |
| `invalid_params.env` | 2 | An env or env\_unset entry is invalid (syntax, size, NUL, count, duplicate, reserved or credential-looking); data names its path, never its value |
| `not_found.cwd` | 3 | cwd does not name an existing directory |
| `unavailable.cwd` | 6 | cwd exists but cannot be resolved or entered |
| `invalid_params.tags` | 2 | A tag breaks a tag rule (key or value syntax, duplicate, the read-only owner, or more than 16 tags) |
| `invalid_params.geometry` | 2 | An unparsable size, offset, title or preset name |
| `conflict.layer` | 5 | The pane's layer does not allow this (split a float, place a popup, raise a tiled pane) |

### `venomx pane kill`

Terminate a pane's process group (signal, then SIGKILL after grace\_ms) and answer once it is reaped; remove=true also removes it. Destructive: once the first signal is sent it cannot be undone.

- Wire name: `pane.kill`
- MCP tool: `pane_dkill`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--pane` | string | yes |  | Pane to terminate |
| `--signal` | string (one of: SIGHUP, SIGTERM, SIGINT) | no | "SIGHUP" | First signal sent to each live pane's process group |
| `--grace-ms` | integer [0..30000] | no | 2000 | Milliseconds to wait after the first signal before sending SIGKILL |
| `--remove` | boolean | no | false | Also remove the pane once it has exited |

Result: object { pane: string (required), outcome: string (one of: terminated, already\_exited) (required), removed: boolean (required), escalated: boolean (required), exit_code: integer [0..255], signal: string }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | unavailable.spawn |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |

### `venomx pane list`

pane.list

- Wire name: `pane.list`
- MCP tool: `pane_dlist`
- Grant: `read`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--session` | string | no |  | session |

Result: object { panes: array of object { pane: string (required), window: string (required), session: string (required), title: string (required), argv0: string, process: string, title_current: boolean, exited: boolean (required), recovery: object { checkpoint: string (required), previous_pane: string (required), process_state: string (one of: exited, interrupted) (required), text_state: string (one of: omitted, expired, plain) (required), cut_rows: integer [0..9007199254740991] (required) }, tags: array of object { key: string (required), value: string (required) } (required), attention: string (one of: none, info, warn, urgent) (required), layer: string (one of: tile, float, popup) (required), pid: integer [0..9007199254740991], start: integer [0..9007199254740991] } (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | unavailable.spawn |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |

### `venomx pane place`

Move a pane between layers or change a float's geometry: float={preset or geometry fields} floats it (or re-geometries a float), tile={target, axis} splits target with it. Popups cannot be placed.

- Wire name: `pane.place`
- MCP tool: `pane_dplace`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--pane` | string | yes |  | pane |
| `--float` | object { preset: string, width: string, height: string, anchor: string (one of: center, top, bottom, left, right, top\_left, top\_right, bottom\_left, bottom\_right), x: integer [-4096..4096], y: integer [-4096..4096], min_cols: integer [1..65535], min_rows: integer [1..65535], border: string (one of: none, single, rounded, heavy), title: string } | no |  | Float geometry: preset plus optional fields |
| `--tile` | object { target: string, axis: string (one of: cols, rows) } | no |  | Tile it next to target (a tiled pane of the same window) on axis; target may be omitted when the window has no tiled pane |

Result: object { pane: string (required), layer: string (one of: tile, float, popup) (required) }

| Error | Exit | Meaning |
|---|---|---|
| `not_found.pane` | 3 | No such pane |
| `denied.write` | 4 | The caller cannot write the pane's window |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `conflict.removing` | 5 | The pane or its window is being removed |
| `invalid_params.place` | 2 | Neither or both of float and tile, or a bad tile target or axis |
| `invalid_params.geometry` | 2 | An unparsable size, offset, title or preset name |
| `conflict.layer` | 5 | The pane's layer does not allow this (split a float, place a popup, raise a tiled pane) |

### `venomx pane popup`

Open a popup on exactly one presentation client: the one that minted the ticket (a binding's {popup\_ticket}). The popup takes that client's focus and closes when its process exits (on\_exit=remove by default), on dismiss, or when the client detaches.

- Wire name: `pane.popup`
- MCP tool: `pane_dpopup`
- Grant: `spawn`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--ticket` | string | no |  | Single-use popup ticket, valid 10 s, from the client's {popup\_ticket} placeholder |
| `--argv` | array of string | yes |  | argv |
| `--cols` | integer | no | 80 | Initial columns |
| `--rows` | integer | no | 24 | Initial rows |
| `--grants` | array of object { right: string (one of: none, read, write, respond, files, spawn, admin) (required), scope: string (required) } | no |  | grants |
| `--cwd` | string | no |  | Absolute working directory for the new process; default: the daemon's working directory |
| `--env` | array of object { name: string (required), value: string (required) } | no |  | Environment variables to set or replace in the new process, applied after env\_unset |
| `--env-unset` | array of string | no |  | Environment variable names to remove from the inherited environment |
| `--preset` | string | no |  | Float preset \<namespace\>.\<name\> (floats.presets in config, or floats.register); prefer it to raw sizes. Unknown presets fall back to floats.default |
| `--width` | string | no |  | Cells ("80") or percent of the window area ("60%"); overrides the preset |
| `--height` | string | no |  | Cells ("24") or percent of the window area ("60%"); overrides the preset |
| `--anchor` | string (one of: center, top, bottom, left, right, top\_left, top\_right, bottom\_left, bottom\_right) | no |  | Where the rectangle sits in the window area |
| `--x` | integer [-4096..4096] | no |  | Column offset from the anchor |
| `--y` | integer [-4096..4096] | no |  | Row offset from the anchor |
| `--min-cols` | integer [1..65535] | no |  | Below this many columns the client shows the float full-window |
| `--min-rows` | integer [1..65535] | no |  | Below this many rows the client shows the float full-window |
| `--border` | string (one of: none, single, rounded, heavy) | no |  | Border drawn by the client |
| `--title` | string | no |  | Border title (at most 128 bytes); default: the pane's OSC 2 title |
| `--tags` | array of object { key: string (required), value: string (required) } | no |  | Pane tags as \[{key,value}\]; the daemon adds the read-only owner tag (the creator's namespace) |
| `--on-exit` | string (one of: keep, remove) | no | "remove" | What happens when the popup's process exits: remove it (default) or keep it |

Result: object { pane: string (required), window: string (required), session: string (required), principal: string (required), pid: integer [0..9007199254740991] (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | The program could not be started; data.reason says why |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |
| `invalid_params.cwd` | 2 | cwd is not an absolute path of 1-4095 bytes without NUL |
| `invalid_params.env` | 2 | An env or env\_unset entry is invalid (syntax, size, NUL, count, duplicate, reserved or credential-looking); data names its path, never its value |
| `not_found.cwd` | 3 | cwd does not name an existing directory |
| `unavailable.cwd` | 6 | cwd exists but cannot be resolved or entered |
| `invalid_params.tags` | 2 | A tag breaks a tag rule (key or value syntax, duplicate, the read-only owner, or more than 16 tags) |
| `invalid_params.geometry` | 2 | An unparsable size, offset, title or preset name |
| `conflict.layer` | 5 | The pane's layer does not allow this (split a float, place a popup, raise a tiled pane) |
| `denied.popup_ticket` | 4 | No valid popup ticket: missing, unknown, spent, expired, or minted for another client |
| `not_found.client` | 3 | The ticket's client has detached |

### `venomx pane raise`

Put a floating pane (or popup) above the others of its window

- Wire name: `pane.raise`
- MCP tool: `pane_draise`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--pane` | string | yes |  | pane |

Result: object { pane: string (required), z: integer [0..9007199254740991] (required) }

| Error | Exit | Meaning |
|---|---|---|
| `not_found.pane` | 3 | No such pane |
| `denied.write` | 4 | The caller cannot write the pane's window |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `conflict.removing` | 5 | The pane or its window is being removed |
| `invalid_params.place` | 2 | Neither or both of float and tile, or a bad tile target or axis |
| `invalid_params.geometry` | 2 | An unparsable size, offset, title or preset name |
| `conflict.layer` | 5 | The pane's layer does not allow this (split a float, place a popup, raise a tiled pane) |

### `venomx pane relaunch`

Replace a restored archive pane with a fresh process running argv directly (no shell), under a new pane ID in the same layout position. A new execution, not a continuation: nothing (argv, cwd, environment, grants, screen or input) is taken from the archive or the checkpoint. Needs spawn and write on the archive. ack\_orphans=true acknowledges that processes of the previous daemon may survive and the new run may duplicate their external work. Launches at most once: a retry names the removed archive and fails not\_found.pane.

- Wire name: `pane.relaunch`
- MCP tool: `pane_drelaunch`
- Grant: `spawn`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--pane` | string | yes |  | pane |
| `--argv` | array of string | yes |  | argv |
| `--ack-orphans` | boolean | yes |  | Must be true: old processes may survive and work may be duplicated; this does not certify cleanup |
| `--grants` | array of object { right: string (one of: none, read, write, respond, files, spawn, admin) (required), scope: string (required) } | no |  | grants |

Result: object { pane: string (required), window: string (required), session: string (required), principal: string (required), pid: integer [0..9007199254740991] (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | The program could not be started; data.reason says why |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |
| `invalid_params.ack_orphans` | 2 | ack\_orphans was not true |
| `conflict.not_archive` | 5 | The pane is not a restored archive (an ordinary exited or live pane) |

### `venomx pane remove`

pane.remove

- Wire name: `pane.remove`
- MCP tool: `pane_dremove`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--pane` | string | yes |  | pane |

Result: object {}

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | unavailable.spawn |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |

### `venomx pane resize`

Move the divider of the pane's nearest split on the direction's axis by cells (left and right are columns, up and down rows), changing that split's shared ratio for every client. The move stops at a child's minimum (one cell per pane and separator it holds) and never goes against the direction; moved is the cells it really moved, 0 with no event when there is no such split or it can't move.

- Wire name: `pane.resize`
- MCP tool: `pane_dresize`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--pane` | string | yes |  | pane |
| `--direction` | string (one of: left, down, up, right) | yes |  | The way the divider moves |
| `--cells` | integer [1..65535] | yes |  | How far, in cells of the panes' current size |

Result: object { window: string (required), revision: integer [0..9007199254740991] (required), moved: integer [0..9007199254740991] (required) }

| Error | Exit | Meaning |
|---|---|---|
| `not_found.pane` | 3 | No such pane |
| `denied.write` | 4 | The caller cannot write the pane's window |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `conflict.removing` | 5 | The pane or its window is being removed |
| `conflict.layer` | 5 | The pane's layer does not allow this (split a float, place a popup, raise a tiled pane) |

### `venomx pane send`

pane.send

- Wire name: `pane.send`
- MCP tool: `pane_dsend`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--pane` | string | yes |  | pane |
| `--text` | string | yes |  | text |

Result: object { bytes: integer [0..9007199254740991] (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | unavailable.spawn |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |

### `venomx pane split`

Split a pane, running argv directly (no shell). cwd must be absolute and is not inherited from the source pane; env applies after env\_unset; VENOMX\_\* is reserved. on\_exit=remove removes the pane when its process exits.

- Wire name: `pane.split`
- MCP tool: `pane_dsplit`
- Grant: `spawn`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--pane` | string | yes |  | pane |
| `--axis` | string (one of: cols, rows) | yes |  | axis |
| `--argv` | array of string | yes |  | argv |
| `--cols` | integer | no | 80 | Initial columns |
| `--rows` | integer | no | 24 | Initial rows |
| `--grants` | array of object { right: string (one of: none, read, write, respond, files, spawn, admin) (required), scope: string (required) } | no |  | grants |
| `--cwd` | string | no |  | Absolute working directory for the new process; default: the daemon's working directory |
| `--env` | array of object { name: string (required), value: string (required) } | no |  | Environment variables to set or replace in the new process, applied after env\_unset |
| `--env-unset` | array of string | no |  | Environment variable names to remove from the inherited environment |
| `--program` | string | no |  | File to execute, resolved like argv\[0\] would be; argv is then passed as given, so argv\[0\] may be any name, such as -sh for a login shell; default: argv\[0\] |
| `--on-exit` | string (one of: keep, remove) | no | "keep" | What happens when the pane's process exits: keep the exited pane (default) or remove it, cascading to an emptied window and an on\_empty=remove session |
| `--near` | array of object { key: string (required), value: string (required) } | no |  | Placement intent: split the largest live tiled pane of the session whose tags match all of these, falling back to the given target |
| `--tags` | array of object { key: string (required), value: string (required) } | no |  | Pane tags as \[{key,value}\]; the daemon adds the read-only owner tag (the creator's namespace) |

Result: object { pane: string (required), window: string (required), session: string (required), principal: string (required), pid: integer [0..9007199254740991] (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | The program could not be started; data.reason says why |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |
| `invalid_params.cwd` | 2 | cwd is not an absolute path of 1-4095 bytes without NUL |
| `invalid_params.env` | 2 | An env or env\_unset entry is invalid (syntax, size, NUL, count, duplicate, reserved or credential-looking); data names its path, never its value |
| `not_found.cwd` | 3 | cwd does not name an existing directory |
| `unavailable.cwd` | 6 | cwd exists but cannot be resolved or entered |
| `invalid_params.tags` | 2 | A tag breaks a tag rule (key or value syntax, duplicate, the read-only owner, or more than 16 tags) |

### `venomx pane tag`

Set or remove a pane's tags. Tags describe panes for status segments and key tables; owner is set by the daemon and is read-only. Needs write on the pane.

- Wire name: `pane.tag`
- MCP tool: `pane_dtag`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--pane` | string | yes |  | pane |
| `--set` | array of object { key: string (required), value: string (required) } | no |  | Tags to add or replace, as \[{key,value}\] |
| `--unset` | array of string | no |  | Tag keys to remove (applied before set) |

Result: object { pane: string (required), tags: array of object { key: string (required), value: string (required) } (required) }

| Error | Exit | Meaning |
|---|---|---|
| `denied.read` | 4 | The caller cannot read the target |
| `denied.write` | 4 | The caller cannot write the target |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `not_found.pane` | 3 | No such pane |
| `invalid_params.tags` | 2 | A tag breaks a tag rule (key or value syntax, duplicate, the read-only owner, or more than 16 tags) |
| `invalid_params.attention` | 2 | Neither or both of level and clear=true, or a reason over 256 bytes |

### `venomx ping`

Check daemon connectivity

- Wire name: `ping`
- MCP tool: `ping`
- Grant: `none`
- Exit status: standard error mapping

No parameters.

Result: object {}

### `venomx popup ticket`

Presentation clients only: mint a single-use popup ticket bound to this connection and session, valid 10 s. Agents receive tickets through a human's key binding and never mint them.

- Wire name: `popup.ticket`
- MCP tool: `popup_dticket`
- Grant: `read`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--session` | string | yes |  | session |
| `--window` | string | no |  | The window the client shows (the popup's window for grants); default: the session's lowest window |

Result: object { ticket: string (required), client: string (required), session: string (required), window: string (required), ttl_ms: integer [0..9007199254740991] (required) }

| Error | Exit | Meaning |
|---|---|---|
| `not_found.session` | 3 | No such session |
| `not_found.window` | 3 | No such window in the session, or the session has none |
| `denied.read` | 4 | The caller cannot read the session |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `unavailable.entropy` | 6 | No entropy for the ticket |

### `venomx recovery checkpoint`

Durably write a checkpoint of the session/window/split topology and pane states now (requires recovery.enabled).

- Wire name: `recovery.checkpoint`
- MCP tool: `recovery_dcheckpoint`
- Grant: `admin`
- Exit status: standard error mapping

No parameters.

Result: object { checkpoint: string (required), generation: integer [0..9007199254740991] (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.checkpoint` | 2 | invalid\_params.checkpoint |
| `not_found.checkpoint` | 3 | not\_found.checkpoint |
| `denied.admin` | 4 | denied.admin |
| `conflict.recovery_busy` | 5 | conflict.recovery\_busy |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.checkpoint_corrupt` | 5 | conflict.checkpoint\_corrupt |
| `conflict.checkpoint_expired` | 5 | conflict.checkpoint\_expired |
| `unavailable.recovery_disabled` | 6 | unavailable.recovery\_disabled |
| `unavailable.recovery_io` | 6 | unavailable.recovery\_io |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.checkpoint_format` | 10 | unsupported.checkpoint\_format |
| `unsupported.checkpoint_size` | 10 | unsupported.checkpoint\_size |
| `unsupported.result_size` | 10 | unsupported.result\_size |

### `venomx recovery forget`

Delete one checkpoint file (any status except unsafe), then sync the store.

- Wire name: `recovery.forget`
- MCP tool: `recovery_dforget`
- Grant: `admin`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--checkpoint` | string | yes |  | Checkpoint ID (c followed by a lowercase UUID v4) |

Result: object {}

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.checkpoint` | 2 | invalid\_params.checkpoint |
| `not_found.checkpoint` | 3 | not\_found.checkpoint |
| `denied.admin` | 4 | denied.admin |
| `conflict.recovery_busy` | 5 | conflict.recovery\_busy |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.checkpoint_corrupt` | 5 | conflict.checkpoint\_corrupt |
| `conflict.checkpoint_expired` | 5 | conflict.checkpoint\_expired |
| `unavailable.recovery_disabled` | 6 | unavailable.recovery\_disabled |
| `unavailable.recovery_io` | 6 | unavailable.recovery\_io |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.checkpoint_format` | 10 | unsupported.checkpoint\_format |
| `unsupported.checkpoint_size` | 10 | unsupported.checkpoint\_size |
| `unsupported.result_size` | 10 | unsupported.result\_size |

### `venomx recovery inspect`

Counts of a valid checkpoint; returns no terminal content.

- Wire name: `recovery.inspect`
- MCP tool: `recovery_dinspect`
- Grant: `admin`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--checkpoint` | string | yes |  | Checkpoint ID (c followed by a lowercase UUID v4) |

Result: object { checkpoint: string (required), generation: integer [0..9007199254740991] (required), shutdown: string (one of: open, clean) (required), sessions: integer [0..9007199254740991] (required), windows: integer [0..9007199254740991] (required), panes: integer [0..9007199254740991] (required), text_panes: integer [0..9007199254740991] (required), expired_text_panes: integer [0..9007199254740991] (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.checkpoint` | 2 | invalid\_params.checkpoint |
| `not_found.checkpoint` | 3 | not\_found.checkpoint |
| `denied.admin` | 4 | denied.admin |
| `conflict.recovery_busy` | 5 | conflict.recovery\_busy |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.checkpoint_corrupt` | 5 | conflict.checkpoint\_corrupt |
| `conflict.checkpoint_expired` | 5 | conflict.checkpoint\_expired |
| `unavailable.recovery_disabled` | 6 | unavailable.recovery\_disabled |
| `unavailable.recovery_io` | 6 | unavailable.recovery\_io |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.checkpoint_format` | 10 | unsupported.checkpoint\_format |
| `unsupported.checkpoint_size` | 10 | unsupported.checkpoint\_size |
| `unsupported.result_size` | 10 | unsupported.result\_size |

### `venomx recovery list`

List this socket's checkpoints with their status; never reveals payload.

- Wire name: `recovery.list`
- MCP tool: `recovery_dlist`
- Grant: `admin`
- Exit status: standard error mapping

No parameters.

Result: object { checkpoints: array of object { checkpoint: string (required), status: string (one of: valid, corrupt, incompatible, expired, unsafe, future) (required), generation: integer [0..9007199254740991] } (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.checkpoint` | 2 | invalid\_params.checkpoint |
| `not_found.checkpoint` | 3 | not\_found.checkpoint |
| `denied.admin` | 4 | denied.admin |
| `conflict.recovery_busy` | 5 | conflict.recovery\_busy |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.checkpoint_corrupt` | 5 | conflict.checkpoint\_corrupt |
| `conflict.checkpoint_expired` | 5 | conflict.checkpoint\_expired |
| `unavailable.recovery_disabled` | 6 | unavailable.recovery\_disabled |
| `unavailable.recovery_io` | 6 | unavailable.recovery\_io |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.checkpoint_format` | 10 | unsupported.checkpoint\_format |
| `unsupported.checkpoint_size` | 10 | unsupported.checkpoint\_size |
| `unsupported.result_size` | 10 | unsupported.result\_size |

### `venomx recovery restore`

Restore a valid checkpoint into an empty daemon as exited archive panes with fresh IDs. Executes and signals no process; cleanup of old processes is unverified.

- Wire name: `recovery.restore`
- MCP tool: `recovery_drestore`
- Grant: `admin`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--checkpoint` | string | yes |  | Checkpoint ID (c followed by a lowercase UUID v4) |

Result: object { checkpoint: string (required), sessions: array of object { previous: string (required), current: string (required) } (required), windows: array of object { previous: string (required), current: string (required) } (required), panes: array of object { previous: string (required), current: string (required) } (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.checkpoint` | 2 | invalid\_params.checkpoint |
| `not_found.checkpoint` | 3 | not\_found.checkpoint |
| `denied.admin` | 4 | denied.admin |
| `conflict.recovery_busy` | 5 | conflict.recovery\_busy |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.checkpoint_corrupt` | 5 | conflict.checkpoint\_corrupt |
| `conflict.checkpoint_expired` | 5 | conflict.checkpoint\_expired |
| `unavailable.recovery_disabled` | 6 | unavailable.recovery\_disabled |
| `unavailable.recovery_io` | 6 | unavailable.recovery\_io |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.checkpoint_format` | 10 | unsupported.checkpoint\_format |
| `unsupported.checkpoint_size` | 10 | unsupported.checkpoint\_size |
| `unsupported.result_size` | 10 | unsupported.result\_size |

### `venomx run`

Start a process as the root of a new pane and return once it has been exec'd; its result comes only from the daemon's wait status. key makes retries safe (same key and parameters return the same run). argv runs directly with no shell; shell runs /bin/sh -c explicitly.

- Wire name: `run`
- MCP tool: `run`
- Grant: `spawn`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--key` | string | yes |  | Idempotency key: a retry with the same key and parameters returns the same run instead of starting the command again |
| `--session` | string | no |  | Run in a new window of this session; give exactly one of session or pane |
| `--pane` | string | no |  | Run in a new pane split from this live pane; give exactly one of session or pane |
| `--axis` | string (one of: cols, rows) | no |  | Split axis; required with pane, not allowed with session |
| `--argv` | array of string | no |  | Program and arguments, executed directly with no shell; give exactly one of argv or shell |
| `--shell` | string | no |  | Command line run explicitly as /bin/sh -c; give exactly one of argv or shell |
| `--name` | string | no |  | Window name; only with session |
| `--cols` | integer [1..65535] | no | 80 | Pane columns |
| `--rows` | integer [1..65535] | no | 24 | Pane rows |
| `--deadline-ms` | integer [1..86400000] | no |  | Terminate the command this many milliseconds after it starts; default: no deadline |
| `--output-rows` | integer [0..1000] | no | 100 | Most rows of output kept in the result |
| `--output-bytes` | integer [0..262144] | no | 65536 | Most UTF-8 bytes of output lines kept in the result |
| `--source` | string | no |  | Fail unless the daemon's event source is this one (detects a daemon restart between retries) |
| `--grants` | array of object { right: string (one of: none, read, write, respond, files, spawn, admin) (required), scope: string (required) } | no |  | grants |
| `--cwd` | string | no |  | Absolute working directory for the new process; default: the daemon's working directory |
| `--env` | array of object { name: string (required), value: string (required) } | no |  | Environment variables to set or replace in the new process, applied after env\_unset |
| `--env-unset` | array of string | no |  | Environment variable names to remove from the inherited environment |

Result: object { run: string (required), source: string (required), key: string (required), pane: string (required), window: string (required), session: string (required), principal: string (required), pid: integer [0..9007199254740991] (required), reused: boolean (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | The program could not be started; data.reason says why |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame; retry with output=false and read rows with pane capture-rows |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |
| `invalid_params.cwd` | 2 | cwd is not an absolute path of 1-4095 bytes without NUL |
| `invalid_params.env` | 2 | An env or env\_unset entry is invalid (syntax, size, NUL, count, duplicate, reserved or credential-looking); data names its path, never its value |
| `not_found.cwd` | 3 | cwd does not name an existing directory |
| `unavailable.cwd` | 6 | cwd exists but cannot be resolved or entered |
| `invalid_params.command` | 2 | Neither or both of argv and shell, or a bad shell |
| `invalid_params.target` | 2 | Neither or both of session and pane, or axis/name misplaced or missing |
| `invalid_params.key` | 2 | key is not 1-128 bytes of \[A-Za-z0-9.\_:-\] |
| `not_found.run` | 3 | No such run; expired for IDs the daemon allocated and evicted |
| `conflict.run_key` | 5 | The key is bound to a run started with different parameters |
| `conflict.source` | 5 | The daemon's event source differs from the given one (the daemon restarted) |
| `unavailable.run_limit` | 6 | run.max\_active runs are not yet completed |
| `timeout.wait` | 7 | timeout\_ms passed before the run completed; the run is unaffected |

### `venomx run cancel`

Terminate a run's pane process group (signal, then SIGKILL after grace\_ms) and return the completed record. Destructive: once the first signal is sent it cannot be undone.

- Wire name: `run.cancel`
- MCP tool: `run_dcancel`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--run` | string | yes |  | Run ID |
| `--signal` | string (one of: SIGHUP, SIGTERM, SIGINT) | no | "SIGHUP" | First signal sent to each live pane's process group |
| `--grace-ms` | integer [0..30000] | no | 2000 | Milliseconds to wait after the first signal before sending SIGKILL |

Result: object { run: string (required), source: string (required), key: string (required), pane: string (required), window: string (required), session: string (required), principal: string (required), pid: integer [0..9007199254740991] (required), shell: boolean (required), state: string (one of: running, terminating, completed) (required), outcome: string (one of: succeeded, failed, signaled, terminated), exit_code: integer [0..255], signal: string, cause: string (one of: cancel, deadline, pane\_kill, removal, shutdown), status: integer [0..255], started_at: string (required), completed_at: string, duration_ms: integer [0..9007199254740991], output: object { screen: string (required), epoch: integer [0..9007199254740991] (required), offset: integer [0..9007199254740991] (required), cols: integer [0..9007199254740991] (required), rows: integer [0..9007199254740991] (required), oldest: integer [0..9007199254740991] (required), start: integer [0..9007199254740991] (required), end: integer [0..9007199254740991] (required), complete: boolean (required), lines: array of string (required) } }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | The program could not be started; data.reason says why |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame; retry with output=false and read rows with pane capture-rows |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |
| `invalid_params.cwd` | 2 | cwd is not an absolute path of 1-4095 bytes without NUL |
| `invalid_params.env` | 2 | An env or env\_unset entry is invalid (syntax, size, NUL, count, duplicate, reserved or credential-looking); data names its path, never its value |
| `not_found.cwd` | 3 | cwd does not name an existing directory |
| `unavailable.cwd` | 6 | cwd exists but cannot be resolved or entered |
| `invalid_params.command` | 2 | Neither or both of argv and shell, or a bad shell |
| `invalid_params.target` | 2 | Neither or both of session and pane, or axis/name misplaced or missing |
| `invalid_params.key` | 2 | key is not 1-128 bytes of \[A-Za-z0-9.\_:-\] |
| `not_found.run` | 3 | No such run; expired for IDs the daemon allocated and evicted |
| `conflict.run_key` | 5 | The key is bound to a run started with different parameters |
| `conflict.source` | 5 | The daemon's event source differs from the given one (the daemon restarted) |
| `unavailable.run_limit` | 6 | run.max\_active runs are not yet completed |
| `timeout.wait` | 7 | timeout\_ms passed before the run completed; the run is unaffected |

### `venomx run get`

Read a run record without waiting.

- Wire name: `run.get`
- MCP tool: `run_dget`
- Grant: `read`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--run` | string | yes |  | Run ID |
| `--output` | boolean | no | true | Include the output tail of a completed run |

Result: object { run: string (required), source: string (required), key: string (required), pane: string (required), window: string (required), session: string (required), principal: string (required), pid: integer [0..9007199254740991] (required), shell: boolean (required), state: string (one of: running, terminating, completed) (required), outcome: string (one of: succeeded, failed, signaled, terminated), exit_code: integer [0..255], signal: string, cause: string (one of: cancel, deadline, pane\_kill, removal, shutdown), status: integer [0..255], started_at: string (required), completed_at: string, duration_ms: integer [0..9007199254740991], output: object { screen: string (required), epoch: integer [0..9007199254740991] (required), offset: integer [0..9007199254740991] (required), cols: integer [0..9007199254740991] (required), rows: integer [0..9007199254740991] (required), oldest: integer [0..9007199254740991] (required), start: integer [0..9007199254740991] (required), end: integer [0..9007199254740991] (required), complete: boolean (required), lines: array of string (required) } }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | The program could not be started; data.reason says why |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame; retry with output=false and read rows with pane capture-rows |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |
| `invalid_params.cwd` | 2 | cwd is not an absolute path of 1-4095 bytes without NUL |
| `invalid_params.env` | 2 | An env or env\_unset entry is invalid (syntax, size, NUL, count, duplicate, reserved or credential-looking); data names its path, never its value |
| `not_found.cwd` | 3 | cwd does not name an existing directory |
| `unavailable.cwd` | 6 | cwd exists but cannot be resolved or entered |
| `invalid_params.command` | 2 | Neither or both of argv and shell, or a bad shell |
| `invalid_params.target` | 2 | Neither or both of session and pane, or axis/name misplaced or missing |
| `invalid_params.key` | 2 | key is not 1-128 bytes of \[A-Za-z0-9.\_:-\] |
| `not_found.run` | 3 | No such run; expired for IDs the daemon allocated and evicted |
| `conflict.run_key` | 5 | The key is bound to a run started with different parameters |
| `conflict.source` | 5 | The daemon's event source differs from the given one (the daemon restarted) |
| `unavailable.run_limit` | 6 | run.max\_active runs are not yet completed |
| `timeout.wait` | 7 | timeout\_ms passed before the run completed; the run is unaffected |

### `venomx run list`

List retained run records in ID order, without output.

- Wire name: `run.list`
- MCP tool: `run_dlist`
- Grant: `read`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--pane` | string | no |  | Only runs of this pane |
| `--key` | string | no |  | Only the caller's run with this key |
| `--after` | string | no |  | List runs after this run ID (the previous page's next) |
| `--limit` | integer [1..1024] | no | 256 | Most runs returned |

Result: object { source: string (required), runs: array of object { run: string (required), source: string (required), key: string (required), pane: string (required), window: string (required), session: string (required), principal: string (required), pid: integer [0..9007199254740991] (required), shell: boolean (required), state: string (one of: running, terminating, completed) (required), outcome: string (one of: succeeded, failed, signaled, terminated), exit_code: integer [0..255], signal: string, cause: string (one of: cancel, deadline, pane\_kill, removal, shutdown), status: integer [0..255], started_at: string (required), completed_at: string, duration_ms: integer [0..9007199254740991], output: object { screen: string (required), epoch: integer [0..9007199254740991] (required), offset: integer [0..9007199254740991] (required), cols: integer [0..9007199254740991] (required), rows: integer [0..9007199254740991] (required), oldest: integer [0..9007199254740991] (required), start: integer [0..9007199254740991] (required), end: integer [0..9007199254740991] (required), complete: boolean (required), lines: array of string (required) } } (required), next: string }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | The program could not be started; data.reason says why |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame; retry with output=false and read rows with pane capture-rows |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |
| `invalid_params.cwd` | 2 | cwd is not an absolute path of 1-4095 bytes without NUL |
| `invalid_params.env` | 2 | An env or env\_unset entry is invalid (syntax, size, NUL, count, duplicate, reserved or credential-looking); data names its path, never its value |
| `not_found.cwd` | 3 | cwd does not name an existing directory |
| `unavailable.cwd` | 6 | cwd exists but cannot be resolved or entered |
| `invalid_params.command` | 2 | Neither or both of argv and shell, or a bad shell |
| `invalid_params.target` | 2 | Neither or both of session and pane, or axis/name misplaced or missing |
| `invalid_params.key` | 2 | key is not 1-128 bytes of \[A-Za-z0-9.\_:-\] |
| `not_found.run` | 3 | No such run; expired for IDs the daemon allocated and evicted |
| `conflict.run_key` | 5 | The key is bound to a run started with different parameters |
| `conflict.source` | 5 | The daemon's event source differs from the given one (the daemon restarted) |
| `unavailable.run_limit` | 6 | run.max\_active runs are not yet completed |
| `timeout.wait` | 7 | timeout\_ms passed before the run completed; the run is unaffected |

### `venomx run wait`

Wait for a run to complete and return its outcome, exit code or signal and output tail. The CLI exits with the result's status. A wait blocks the tool call: use timeout\_ms of at most 60000 and loop on timeout.wait. A wait timeout, cancel or disconnect never stops the command.

- Wire name: `run.wait`
- MCP tool: `run_dwait`
- Grant: `read`
- Exit status: on success, `result.status`; errors use the standard mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--run` | string | yes |  | Run ID |
| `--timeout-ms` | integer [0..86400000] | no |  | Most milliseconds to wait; absent: no limit, 0: a non-blocking check |
| `--output` | boolean | no | true | Include the output tail of a completed run |

Result: object { run: string (required), source: string (required), key: string (required), pane: string (required), window: string (required), session: string (required), principal: string (required), pid: integer [0..9007199254740991] (required), shell: boolean (required), state: string (one of: running, terminating, completed) (required), outcome: string (one of: succeeded, failed, signaled, terminated) (required), exit_code: integer [0..255], signal: string, cause: string (one of: cancel, deadline, pane\_kill, removal, shutdown), status: integer [0..255] (required), started_at: string (required), completed_at: string (required), duration_ms: integer [0..9007199254740991] (required), output: object { screen: string (required), epoch: integer [0..9007199254740991] (required), offset: integer [0..9007199254740991] (required), cols: integer [0..9007199254740991] (required), rows: integer [0..9007199254740991] (required), oldest: integer [0..9007199254740991] (required), start: integer [0..9007199254740991] (required), end: integer [0..9007199254740991] (required), complete: boolean (required), lines: array of string (required) } }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | The program could not be started; data.reason says why |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame; retry with output=false and read rows with pane capture-rows |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |
| `invalid_params.cwd` | 2 | cwd is not an absolute path of 1-4095 bytes without NUL |
| `invalid_params.env` | 2 | An env or env\_unset entry is invalid (syntax, size, NUL, count, duplicate, reserved or credential-looking); data names its path, never its value |
| `not_found.cwd` | 3 | cwd does not name an existing directory |
| `unavailable.cwd` | 6 | cwd exists but cannot be resolved or entered |
| `invalid_params.command` | 2 | Neither or both of argv and shell, or a bad shell |
| `invalid_params.target` | 2 | Neither or both of session and pane, or axis/name misplaced or missing |
| `invalid_params.key` | 2 | key is not 1-128 bytes of \[A-Za-z0-9.\_:-\] |
| `not_found.run` | 3 | No such run; expired for IDs the daemon allocated and evicted |
| `conflict.run_key` | 5 | The key is bound to a run started with different parameters |
| `conflict.source` | 5 | The daemon's event source differs from the given one (the daemon restarted) |
| `unavailable.run_limit` | 6 | run.max\_active runs are not yet completed |
| `timeout.wait` | 7 | timeout\_ms passed before the run completed; the run is unaffected |

### `venomx serve`

Start the daemon

- Wire name: `serve`
- MCP tool: none (local command)
- Grant: `none`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--lifetime` | string (one of: persistent, on-demand) | no | "persistent" | Daemon lifetime policy |
| `--origin` | string (one of: serve, interactive, session\_create) | no | "serve" | Who started the daemon, set by the launcher; reported by doctor only, never grants anything |

Result: object {}

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.startup_config` | 2 | Invalid startup configuration |
| `denied.startup_context` | 4 | Managed context cannot bootstrap owner authority |
| `unavailable.startup_failed` | 6 | Daemon launch or initialization failed |
| `unavailable.startup_deadline` | 6 | Daemon did not become ready within the startup budget |
| `unavailable.startup_result` | 6 | Mutation outcome is unknown; inspect state before retrying |

### `venomx session create`

Create an empty session (no window or shell). on\_empty=remove removes it once an on\_exit cascade leaves it without windows. Startup policy (local CLI only): with daemon.startup="on-demand" persisted in config, an ordinary CLI call with VENOMX\_TOKEN=@owner outside any venomx pane and below no manager's marker may start a missing daemon as \`serve --lifetime on-demand\` on the selected socket, wait for readiness within daemon.startup\_timeout\_ms, then send this request once. MCP, wire requests and every other command never start a daemon. A lost reply is an unknown outcome (unavailable.startup\_result): inspect state, never blindly retry.

- Wire name: `session.create`
- MCP tool: `session_dcreate`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--name` | string | no | "" | Display name (at most 128 UTF-8 bytes) |
| `--on-empty` | string (one of: keep, remove) | no | "keep" | What happens when an on\_exit cascade leaves the session without windows: keep it (default) or remove it |

Result: object { session: string (required), name: string (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | unavailable.spawn |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |
| `invalid_params.startup_config` | 2 | Invalid startup configuration |
| `denied.startup_context` | 4 | Managed context cannot bootstrap owner authority |
| `unavailable.startup_failed` | 6 | Daemon launch or initialization failed |
| `unavailable.startup_deadline` | 6 | Daemon did not become ready within the startup budget |
| `unavailable.startup_result` | 6 | Mutation outcome is unknown; inspect state before retrying |

### `venomx session get`

session.get

- Wire name: `session.get`
- MCP tool: `session_dget`
- Grant: `read`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--session` | string | yes |  | session |

Result: object { session: string (required), name: string (required), windows: array of object { window: string (required), name: string (required) } (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | unavailable.spawn |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |

### `venomx session list`

session.list

- Wire name: `session.list`
- MCP tool: `session_dlist`
- Grant: `read`
- Exit status: standard error mapping

No parameters.

Result: object { sessions: array of object { session: string (required), name: string (required) } (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | unavailable.spawn |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |

### `venomx session remove`

Remove a session; with recursive=true terminate every live pane in it and remove all its windows. Destructive: once the first signal is sent it cannot be undone.

- Wire name: `session.remove`
- MCP tool: `session_dremove`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--session` | string | yes |  | session |
| `--recursive` | boolean | no | false | Terminate every live pane and remove all children (destructive); signal and grace\_ms apply only when true |
| `--signal` | string (one of: SIGHUP, SIGTERM, SIGINT) | no | "SIGHUP" | First signal sent to each live pane's process group |
| `--grace-ms` | integer [0..30000] | no | 2000 | Milliseconds to wait after the first signal before sending SIGKILL |

Result: object {}

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | unavailable.spawn |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |

### `venomx shell init`

Print the shell integration snippet for zsh, bash or fish: inside a venomx pane it sends OSC 133 marks with the command line, so the status line shows \`ping google.com\` rather than the shell. Without --json it prints only the script. Load it from your rc file with \`eval "$(venomx shell init --shell=zsh)"\` (or bash), or \`venomx shell init --shell=fish \| source\`. Outside a venomx pane, and on a second load, the snippet does nothing. Needs no daemon.

- Wire name: `shell.init`
- MCP tool: none (local command)
- Grant: `none`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--shell` | string (one of: zsh, bash, fish) | yes |  | Which shell's snippet |

Result: object { shell: string (required), script: string (required) }

### `venomx skill`

Print the generated SKILL.md for agents

- Wire name: `skill`
- MCP tool: `skill`
- Grant: `read`
- Exit status: standard error mapping

No parameters.

Result: object { content: string (required) }

### `venomx skill install`

Install the generated SKILL.md for an agent on the daemon's host

- Wire name: `skill.install`
- MCP tool: `skill_dinstall`
- Grant: `files`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--target` | string (one of: claude-code, codex, opencode) | yes |  | Skill consumer |
| `--directory` | string | no |  | Absolute skill root overriding the target's default |
| `--replace` | boolean | no | false | Atomically replace a different existing SKILL.md |

Result: object { target: string (required), path: string (required), changed: boolean (required) }

| Error | Exit | Meaning |
|---|---|---|
| `conflict.skill_exists` | 5 | A different SKILL.md exists and replace is false |
| `failed.skill_write` | 1 | The skill file could not be written |
| `invalid_params.skill_directory` | 2 | No usable skill root: HOME is unavailable, the path is not absolute, or it traverses a symlink |

### `venomx status clear`

Remove a status segment of the caller's namespace.

- Wire name: `status.clear`
- MCP tool: `status_dclear`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--id` | string | yes |  | Segment ID \<namespace\>.\<name\>; the namespace must be the caller's (venomx.\* is reserved) |

Result: object {}

| Error | Exit | Meaning |
|---|---|---|
| `denied.read` | 4 | The caller cannot read the target |
| `denied.write` | 4 | The caller cannot write the target |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `invalid_params.segment` | 2 | Bad id, text (at most 256 bytes, no control characters) or when |
| `denied.namespace` | 4 | The id is outside the caller's namespace, or venomx.\* |
| `conflict.segment_limit` | 5 | More than 32 segments for one namespace, or 128 in total |
| `not_found.session` | 3 | The scope names no session |
| `not_found.segment` | 3 | No segment has this id |

### `venomx status list`

List the status segments the caller can read.

- Wire name: `status.list`
- MCP tool: `status_dlist`
- Grant: `read`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--scope` | string | no |  | Only segments of this scope (server or a session ID) |

Result: object { segments: array of object { id: string (required), text: string (required), side: string (one of: left, center, right) (required), priority: integer [0..100] (required), style: string (one of: normal, muted, accent, ok, warn, error) (required), when: array of object { key: string (required), value: string (required) } (required), scope: string (required), ttl_ms: integer [1000..86400000], bind: string (one of: connection, daemon) (required), revision: integer [0..9007199254740991] (required), group: string, icon: string, click: object { local: string, verb: string, args: string, exec: array of string } } (required) }

| Error | Exit | Meaning |
|---|---|---|
| `denied.read` | 4 | The caller cannot read the target |
| `denied.write` | 4 | The caller cannot write the target |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `invalid_params.segment` | 2 | Bad id, text (at most 256 bytes, no control characters) or when |
| `denied.namespace` | 4 | The id is outside the caller's namespace, or venomx.\* |
| `conflict.segment_limit` | 5 | More than 32 segments for one namespace, or 128 in total |
| `not_found.session` | 3 | The scope names no session |
| `not_found.segment` | 3 | No segment has this id |

### `venomx status rule clear`

Remove a status rule of the caller's namespace and its segment.

- Wire name: `status.rule.clear`
- MCP tool: `status_drule_dclear`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--id` | string | yes |  | Segment ID \<namespace\>.\<name\>; the namespace must be the caller's (venomx.\* is reserved) |

Result: object {}

| Error | Exit | Meaning |
|---|---|---|
| `denied.read` | 4 | The caller cannot read the target |
| `denied.write` | 4 | The caller cannot write the target |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `invalid_params.segment` | 2 | Bad id, when, group, icon or click |
| `invalid_params.rule` | 2 | Bad on, match or clear\_on, or neither ttl\_ms nor clear\_on |
| `invalid_params.template` | 2 | The format has an unknown variable, a bad spec or unbalanced brackets |
| `denied.namespace` | 4 | The id is outside the caller's namespace, or venomx.\* |
| `conflict.rule_limit` | 5 | More than 32 rules for one namespace, or 128 in total |
| `conflict.config_rule` | 5 | The id is a rule from the config files, which only config changes |
| `not_found.session` | 3 | The scope names no session |
| `not_found.rule` | 3 | No rule has this id |

### `venomx status rule list`

List the status rules the caller can read.

- Wire name: `status.rule.list`
- MCP tool: `status_drule_dlist`
- Grant: `read`
- Exit status: standard error mapping

No parameters.

Result: object { rules: array of object { id: string (required), on: array of string (required), match: array of object { key: string (required), op: string (one of: eq, ne, prefix) (required), value: string (required) } (required), clear_on: array of string (required), format: string (required), ttl_ms: integer [1000..86400000], side: string (one of: left, center, right) (required), priority: integer [0..100] (required), style: string (one of: normal, muted, accent, ok, warn, error) (required), when: array of object { key: string (required), value: string (required) } (required), scope: string (required), bind: string (one of: connection, daemon) (required), group: string, icon: string, click: object { local: string, verb: string, args: string, exec: array of string }, revision: integer [0..9007199254740991] (required), origin: string (one of: config, runtime) (required) } (required) }

| Error | Exit | Meaning |
|---|---|---|
| `denied.read` | 4 | The caller cannot read the target |
| `denied.write` | 4 | The caller cannot write the target |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `invalid_params.segment` | 2 | Bad id, when, group, icon or click |
| `invalid_params.rule` | 2 | Bad on, match or clear\_on, or neither ttl\_ms nor clear\_on |
| `invalid_params.template` | 2 | The format has an unknown variable, a bad spec or unbalanced brackets |
| `denied.namespace` | 4 | The id is outside the caller's namespace, or venomx.\* |
| `conflict.rule_limit` | 5 | More than 32 rules for one namespace, or 128 in total |
| `conflict.config_rule` | 5 | The id is a rule from the config files, which only config changes |
| `not_found.session` | 3 | The scope names no session |
| `not_found.rule` | 3 | No rule has this id |

### `venomx status rule set`

Turn events into a status segment. The rule sees only events the caller can read, and its segment needs write on the scope (server:root for server and event).

- Wire name: `status.rule.set`
- MCP tool: `status_drule_dset`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--id` | string | yes |  | Segment ID \<namespace\>.\<name\>; the namespace must be the caller's (venomx.\* is reserved) |
| `--on` | array of string | yes |  | Event types (or type.\* selectors) that fire the rule, 1-8 |
| `--match` | array of object { key: string (required), op: string (one of: eq, ne, prefix) (required), value: string (required) } | no |  | Conditions that must all hold, 0-8: \[{key,op,value}\] on a top-level data field (or type, resource); op is eq, ne or prefix |
| `--clear-on` | array of string | no |  | Event types that clear the segment, for the resource that last fired it, 0-8 |
| `--format` | string | yes |  | Status template rendered on each firing; variables event.type, event.resource, event.\<field\>, host, user, clock |
| `--ttl-ms` | integer [1000..86400000] | no |  | Clear the segment this long after the last firing; a rule needs ttl\_ms, clear\_on or both |
| `--side` | string (one of: left, center, right) | no | "right" | Status line side |
| `--priority` | integer [0..100] | no | 50 | Higher stays longer when space is short |
| `--style` | string (one of: normal, muted, accent, ok, warn, error) | no | "normal" | Theme role, never a raw colour |
| `--when` | array of object { key: string (required), value: string (required) } | no |  | Show only while the client's focused pane has all these tags |
| `--scope` | string | no | "server" | server, event (the session of the event's resource, else server) or a session ID |
| `--bind` | string (one of: connection, daemon) | no | "connection" | connection: the rule and its segment go when the setting connection closes; daemon: kept until cleared |
| `--group` | string | no |  | Draw inside this group's segment (the tray is tray) instead of on its own |
| `--icon` | string | no |  | What a group draws for it, at most 2 cells; the text when absent |
| `--click` | object { local: string, verb: string, args: string, exec: array of string } | no |  | Binding target a left click runs as the clicking client: exactly one of local, verb (with args) or exec |

Result: object { id: string (required), revision: integer [0..9007199254740991] (required) }

| Error | Exit | Meaning |
|---|---|---|
| `denied.read` | 4 | The caller cannot read the target |
| `denied.write` | 4 | The caller cannot write the target |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `invalid_params.segment` | 2 | Bad id, when, group, icon or click |
| `invalid_params.rule` | 2 | Bad on, match or clear\_on, or neither ttl\_ms nor clear\_on |
| `invalid_params.template` | 2 | The format has an unknown variable, a bad spec or unbalanced brackets |
| `denied.namespace` | 4 | The id is outside the caller's namespace, or venomx.\* |
| `conflict.rule_limit` | 5 | More than 32 rules for one namespace, or 128 in total |
| `conflict.config_rule` | 5 | The id is a rule from the config files, which only config changes |
| `not_found.session` | 3 | The scope names no session |
| `not_found.rule` | 3 | No rule has this id |

### `venomx status set`

Publish or replace a status segment shown in every client's status line. Needs write on the scope (server:root for server).

- Wire name: `status.set`
- MCP tool: `status_dset`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--id` | string | yes |  | Segment ID \<namespace\>.\<name\>; the namespace must be the caller's (venomx.\* is reserved) |
| `--text` | string | yes |  | Text shown verbatim (at most 256 bytes, no control characters); clients truncate |
| `--side` | string (one of: left, center, right) | no | "right" | Status line side |
| `--priority` | integer [0..100] | no | 50 | Higher stays longer when space is short |
| `--style` | string (one of: normal, muted, accent, ok, warn, error) | no | "normal" | Theme role, never a raw colour |
| `--when` | array of object { key: string (required), value: string (required) } | no |  | Show only while the client's focused pane has all these tags |
| `--scope` | string | no | "server" | server, or a session ID to show only on clients of that session |
| `--ttl-ms` | integer [1000..86400000] | no |  | Remove the segment after this many milliseconds |
| `--bind` | string (one of: connection, daemon) | no |  | connection: removed when the setting connection closes; daemon: kept until cleared or ttl\_ms. Default: daemon with ttl\_ms, else connection |
| `--group` | string | no |  | Draw inside this group's segment (the tray is tray) instead of on its own |
| `--icon` | string | no |  | What a group draws for it, at most 2 cells; the text when absent |
| `--click` | object { local: string, verb: string, args: string, exec: array of string } | no |  | Binding target a left click runs as the clicking client: exactly one of local, verb (with args) or exec |

Result: object { id: string (required), revision: integer [0..9007199254740991] (required) }

| Error | Exit | Meaning |
|---|---|---|
| `denied.read` | 4 | The caller cannot read the target |
| `denied.write` | 4 | The caller cannot write the target |
| `unavailable.shutdown` | 6 | The daemon is stopping |
| `unsupported.result_size` | 10 | The reply exceeds max\_frame |
| `invalid_params.segment` | 2 | Bad id, text (at most 256 bytes, no control characters) or when |
| `denied.namespace` | 4 | The id is outside the caller's namespace, or venomx.\* |
| `conflict.segment_limit` | 5 | More than 32 segments for one namespace, or 128 in total |
| `not_found.session` | 3 | The scope names no session |
| `not_found.segment` | 3 | No segment has this id |

### `venomx whoami`

Show the caller and its issued grants (unknown callers are read-only; denied.\* exits 4)

- Wire name: `whoami`
- MCP tool: `whoami`
- Grant: `none`
- Exit status: standard error mapping

No parameters.

Result: object { principal: string (required), kind: string (required), parent: string or null, grants: array of object { right: string (one of: none, read, write, respond, files, spawn, admin) (required), scope: string (required) } (required), expires: string or null, pane: string, label: string, namespace: string (required), capped_by: array of string, restored: boolean }

### `venomx window create`

Create a window running argv directly (no shell). cwd must be absolute; env applies after env\_unset on the daemon's environment; the executable is found on the child's final PATH; VENOMX\_\* is reserved. on\_exit=remove removes the pane when its process exits.

- Wire name: `window.create`
- MCP tool: `window_dcreate`
- Grant: `spawn`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--session` | string | yes |  | session |
| `--name` | string | no | "" | Display name (at most 128 UTF-8 bytes) |
| `--argv` | array of string | yes |  | argv |
| `--cols` | integer | no | 80 | Initial columns |
| `--rows` | integer | no | 24 | Initial rows |
| `--grants` | array of object { right: string (one of: none, read, write, respond, files, spawn, admin) (required), scope: string (required) } | no |  | grants |
| `--cwd` | string | no |  | Absolute working directory for the new process; default: the daemon's working directory |
| `--env` | array of object { name: string (required), value: string (required) } | no |  | Environment variables to set or replace in the new process, applied after env\_unset |
| `--env-unset` | array of string | no |  | Environment variable names to remove from the inherited environment |
| `--program` | string | no |  | File to execute, resolved like argv\[0\] would be; argv is then passed as given, so argv\[0\] may be any name, such as -sh for a login shell; default: argv\[0\] |
| `--on-exit` | string (one of: keep, remove) | no | "keep" | What happens when the pane's process exits: keep the exited pane (default) or remove it, cascading to an emptied window and an on\_empty=remove session |
| `--near` | array of object { key: string (required), value: string (required) } | no |  | Placement intent: split the largest live tiled pane of the session whose tags match all of these, falling back to the given target |
| `--tags` | array of object { key: string (required), value: string (required) } | no |  | Pane tags as \[{key,value}\]; the daemon adds the read-only owner tag (the creator's namespace) |

Result: object { pane: string (required), window: string (required), session: string (required), principal: string (required), pid: integer [0..9007199254740991] (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | The program could not be started; data.reason says why |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |
| `invalid_params.cwd` | 2 | cwd is not an absolute path of 1-4095 bytes without NUL |
| `invalid_params.env` | 2 | An env or env\_unset entry is invalid (syntax, size, NUL, count, duplicate, reserved or credential-looking); data names its path, never its value |
| `not_found.cwd` | 3 | cwd does not name an existing directory |
| `unavailable.cwd` | 6 | cwd exists but cannot be resolved or entered |
| `invalid_params.tags` | 2 | A tag breaks a tag rule (key or value syntax, duplicate, the read-only owner, or more than 16 tags) |

### `venomx window get`

window.get

- Wire name: `window.get`
- MCP tool: `window_dget`
- Grant: `read`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--window` | string | yes |  | window |

Result: object { window: string (required), session: string (required), name: string (required), revision: integer [0..9007199254740991] (required), nodes: array of object { kind: string (one of: pane, split) (required), pane: string, axis: string (one of: cols, rows), first: integer [0..9007199254740991], second: integer [0..9007199254740991], ratio: integer [1..9999] } (required), floats: array of object { pane: string (required), layer: string (one of: tile, float, popup) (required), z: integer [0..9007199254740991] (required) } (required) }

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | unavailable.spawn |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |

### `venomx window remove`

Remove a window; with recursive=true terminate every live pane in it and remove them all. Destructive: once the first signal is sent it cannot be undone.

- Wire name: `window.remove`
- MCP tool: `window_dremove`
- Grant: `write`
- Exit status: standard error mapping

| Flag | Type | Required | Default | Description |
|---|---|---|---|---|
| `--window` | string | yes |  | window |
| `--recursive` | boolean | no | false | Terminate every live pane and remove all children (destructive); signal and grace\_ms apply only when true |
| `--signal` | string (one of: SIGHUP, SIGTERM, SIGINT) | no | "SIGHUP" | First signal sent to each live pane's process group |
| `--grace-ms` | integer [0..30000] | no | 2000 | Milliseconds to wait after the first signal before sending SIGKILL |

Result: object {}

| Error | Exit | Meaning |
|---|---|---|
| `invalid_params.name` | 2 | invalid\_params.name |
| `invalid_params.argv` | 2 | invalid\_params.argv |
| `invalid_params.size` | 2 | invalid\_params.size |
| `not_found.session` | 3 | not\_found.session |
| `not_found.window` | 3 | not\_found.window |
| `not_found.pane` | 3 | not\_found.pane |
| `denied.read` | 4 | denied.read |
| `denied.write` | 4 | denied.write |
| `denied.spawn` | 4 | denied.spawn |
| `denied.delegation` | 4 | denied.delegation |
| `conflict.not_empty` | 5 | conflict.not\_empty |
| `conflict.pane_running` | 5 | conflict.pane\_running |
| `conflict.pane_exited` | 5 | conflict.pane\_exited |
| `unavailable.spawn` | 6 | unavailable.spawn |
| `unavailable.input` | 6 | unavailable.input |
| `unavailable.shutdown` | 6 | unavailable.shutdown |
| `unsupported.result_size` | 10 | unsupported.result\_size |
| `conflict.pane_terminating` | 5 | conflict.pane\_terminating |
| `conflict.removing` | 5 | conflict.removing |
| `timeout.terminate` | 7 | timeout.terminate |

