# Raw single-pane attach

The functional client is implemented and tested. The performance target
is **not yet met**: a 64 MiB file is 12.9% slower than direct output in the
recorded Kitty run, against a 10% budget. Closing the gap is remaining
work; the shared terminal changes live in venom-term.

## Behavior

```sh
venomx attach --pane p0 --raw=true
```

Boolean flags take explicit values (`--raw=true`). The generated local-command schema
exposes `raw` in help, docs and completions, and rejects a session selector in
raw mode. Interactive local commands remain absent from MCP and the agent skill.

The client requests only VT snapshots, checks dimensions at READY, resets the
host and writes the replay there. Subsequent PTY bytes go through a tokenizer
and straight to stdout without a client VT. Retained history comes from replay;
subsequent scrollback, selection and scrolling belong to the host. Host input
bytes retain their original keyboard/mouse/paste encodings. Ctrl-B d detaches;
Ctrl-B Ctrl-B sends a literal prefix. Terminal modes and termios are restored
on exit.

The tokenizer removes queries already answered by the authoritative daemon and
clipboard reads. Clipboard writes require a writer and `raw_clipboard =
.external`; `.off` removes them. Tests cover sequences split across frames,
C1 controls versus UTF-8 continuations, aborted strings, repeated ESC, overlong
strings and continuation across an offset resume. Control strings over 64 KiB
are discarded through their terminator with bounded memory.

A host resize or authoritative pane-size mismatch stops passthrough immediately.
The client requests emulation with VT format on the same stream, discards PTY
until READY, and then renders a cropped/letterboxed single pane. It stays in
emulation for that attachment. VT-only switching avoids assuming the daemon's
Ghostty pin matches the client. Connection recovery resumes the existing host
and tokenizer state when possible and resets both for a fresh snapshot.

Write-grant and clipboard-policy changes are published before more live output
using a policy-change RESYNC. The client refreshes its input/filter permissions.
The existing negotiated capability and frame kinds are unchanged. ATTACHED and
RESYNC include optional `raw_clipboard: "external" | "off"` metadata; RESYNC
also repeats `input: boolean`. Older clients ignore the extra JSON members.

## Measurement method

2026-11-07; Linux 7.3.1, AMD Ryzen 7 9800X3D, Zig 0.17.0 ReleaseFast,
Kitty 0.49.2 with `--config NONE`; actual host size 284 × 69. Venomx uses
a venom-term build with the terminal throughput changes.

```sh
zig build -Doptimize=ReleaseFast --prefix zig-out/release
python3 test/raw_bench.py zig-out/release/bin/venomx --render --mib 8 --trials 7
python3 test/raw_bench.py zig-out/release/bin/venomx --render --mib 64 --trials 7
```

Run `--render` inside an actual host terminal. Both paths use a Python producer
that sets raw termios, prints a ready marker, waits for one input byte, then
runs the same `cat` on the same generated file. The harness drains replay
before starting the timer, alternates direct/raw order, forwards both outputs
to the same host stdout, and stops after the end marker has been written there.
Startup, replay and detach are excluded. Host rendering remains asynchronous,
as for ordinary `cat`; this does not measure the final GPU-present fence.

The default file contains 79 printable bytes plus CRLF per line. Every payload
byte must match the file; resync/loss or extra VT replay fails the benchmark
rather than counting snapshot replacement as successful transfer. Without
`--render`, the harness measures only PTY transport and cannot establish host
terminal acceptance. Release builds have a separate install prefix so a Debug
build cannot silently replace the measured binary.

## Results

Seven trials per final configuration; median elapsed seconds:

| File/configuration | Direct | Raw attach | Extra time |
|---|---:|---:|---:|
| 8 MiB, 79-byte lines, default 256 KiB ring/backlog | 0.044185 | 0.052990 | **19.9%** |
| 64 MiB, 79-byte lines, default 256 KiB ring/backlog | 0.362767 | 0.409489 | **12.9%** |
| 64 MiB, 283-byte lines, explicitly configured 16 MiB ring/backlog | 0.210387 | 0.247098 | **17.4%** |

Raw samples: [8 MiB](measurements/raw-attach-8mib.json),
[64 MiB](measurements/raw-attach-64mib.json), and
[full-width buffered](measurements/raw-attach-full-width-buffered.json).
The buffered experiment is a separate configuration, not a default change.
Some additional narrow-window/full-width probes overran the default ring and
failed byte equality; they are not reported as passing throughput measurements.

The first implementation measured 1.258 s raw versus 0.041 s direct for 8 MiB
(five trials). Profiling exposed full snapshot encoding after each PTY read
merely to extract the title. The product now uses `Vt.title()`, bulk copies
around ring wrap, a vectorized reset-boundary search, bounded coalesced PTY
reads, and a readiness wait that includes PTYs rather than sleeping only on
sockets. The raw tokenizer skips ASCII in vector-sized blocks.

The venom-term changes also reduce safe ground-state feed bookkeeping and batch
CRLF lines where they cannot wrap; their isolated benchmark and correctness
results are in venom-term's docs. Two ReleaseFast steady-state debugger
samples land in Ghostty's `printSliceStoreRun`/`printSliceFill` ASCII cell-writing
path. That is evidence of a remaining backend hotspot, not a quantified CPU
percentage or proof that all wrapper costs are gone.

## Verification

`zig build`, `zig build test` and `zig fmt --check .` run against that
venom-term build. The test target includes the packaged venom-std agent-contract
conformance suite, headless daemon acceptance, two emulating clients and raw
PTY clients. Raw coverage includes replay, exact live bytes, query filtering,
full host dimensions, input, detach/reattach, resize fallback, offset resume,
clipboard policy reload and write-grant changes. Unit tests use the testing
allocator. The performance gate remains separate and failing.
