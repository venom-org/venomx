#!/usr/bin/env bash
# Release smoke test for a built venomx binary: --version, an on-demand
# daemon started by the CLI launcher, one command run to completion, and the
# daemon stopping when its last session is removed. Runs in a throwaway HOME
# and XDG tree. Usage: test/release_smoke.sh path/to/venomx [expected-version]
# With an expected version (the tag without its leading v), --version and
# --version --json must print exactly it.
set -euo pipefail
bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
root="$(mktemp -d)"
# No XDG_RUNTIME_DIR, as on macOS: the socket goes under $TMPDIR.
unset XDG_RUNTIME_DIR
export HOME="$root" TMPDIR="$root/tmp" XDG_CONFIG_HOME="$root/cfg" XDG_STATE_HOME="$root/state"
mkdir -p "$TMPDIR" "$XDG_CONFIG_HOME/venomx"
echo '.{ .daemon = .{ .startup = "on-demand" } }' > "$XDG_CONFIG_HOME/venomx/config.zon"
"$bin" --version
if [ -n "${2:-}" ]; then
  "$bin" --version | grep -qF "venomx $2"
  test "$("$bin" --version --json)" = "{\"version\":\"$2\"}"
fi
# The first create starts an on-demand daemon from this binary.
VENOMX_TOKEN=@owner "$bin" session create --name=smoke --json < /dev/null
"$bin" run --key smoke --session s0 --shell 'echo venomx-smoke' --json < /dev/null
"$bin" run wait --run r0 --timeout-ms 15000 --json < /dev/null | tee "$root/wait.json"
grep -q '"outcome":"succeeded"' "$root/wait.json"
grep -q 'venomx-smoke' "$root/wait.json"
# Removing the last session stops the on-demand daemon.
VENOMX_TOKEN=@owner "$bin" session remove --session=s0 --recursive=true --json < /dev/null
for _ in $(seq 50); do
  if ! "$bin" ping --json < /dev/null > /dev/null 2>&1; then echo "daemon stopped"; exit 0; fi
  sleep 0.1
done
echo "daemon still running" >&2
exit 1
