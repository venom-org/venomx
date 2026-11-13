# Off-reactor checkpoint writer

## Question

The first checkpoint implementation captured, encoded, published (temp, fsync,
rename, directory fsync) and pruned every checkpoint synchronously on the
reactor. Does that stall PTY processing enough to justify an off-reactor
writer, which is allowed as long as capture stays at one
reactor boundary?

## Method

`test/checkpoint_bench.py` runs the seam build with `terminal_text=.plain`,
`text_max_rows=100000`, `text_max_bytes=16777216` and
`max_checkpoint_bytes=67108864`. It fills one 200x50 pane with 99,864 rows of
167 ASCII bytes, which is 16 MiB of text and a 17,197,395-byte checkpoint. It
then sends `recovery.checkpoint` three times on one connection while a second
connection sends `ping` in a tight loop. The longest ping round trip during
a checkpoint is the **reactor stall**: for that long no request, PTY read
or attach frame is serviced. State is on ext4 on NVMe (`--state-parent
~/.cache`), not tmpfs. The test machine is Linux 7.3 on x86_64.

```sh
zig build -Dtest-seams=true [-Doptimize=ReleaseFast] --prefix <p>
python3 test/checkpoint_bench.py <p>/bin/venomx-seam --trials 3 --state-parent ~/.cache --report <json>
```

The baseline (`*-sync`) is the synchronous checkpoint path from before this
writer. Debug builds use
a venom-term that optimizes ghostty in Debug.

## Results (medians of 3)

| Build | Version | `recovery.checkpoint` reply | Reactor stall (max ping) |
|---|---|---|---|
| ReleaseFast | sync (previous) | 5.22 s | **5.22 s** |
| ReleaseFast | writer (current) | 5.24 s | **4.86 s** |
| Debug | sync (previous) | 10.24 s | **10.24 s** |
| Debug | writer (current) | 9.85 s | **7.63 s** |

Raw samples: [release sync](measurements/checkpoint-writer-release-sync.json),
[release writer](measurements/checkpoint-writer-release-writer.json),
[debug sync](measurements/checkpoint-writer-debug-sync.json),
[debug writer](measurements/checkpoint-writer-debug-writer.json).

A temporary per-phase timing build of main (ReleaseFast, ext4, second trial,
so the store already holds one 16 MiB checkpoint) split the 5.2 s like this:

| Phase | Where it runs now | Time |
|---|---|---|
| capture: `Vt.exportPlain` of 100k rows plus change hash | reactor (one consistent boundary) | 4.85 s |
| generation scan (read and decode retained checkpoints) | writer thread | 0.105 s |
| encode | writer thread | 0.03 s |
| publish (write, fsync, rename, directory fsync) | writer thread | 0.017–0.055 s |
| prune (rescan and delete) | writer thread | 0.11–0.22 s |

A Debug build with unoptimized ghostty spent 0.64 s on the scan, 0.17 s on encoding and
1.3 s on pruning. All of that time now runs off the reactor.

## Decision

Implement the writer. The work moved off the reactor took 0.37 s in
release and 2.2 s in debug, plus the fsync. On a busy or rotating disk an
fsync can take seconds, and the scan and prune grow with `max_checkpoints` x
`max_checkpoint_bytes` (up to 100 x 64 MiB). Semantics:

- Capture (topology, lifecycle, plain text) stays on the reactor at one
  boundary. It is deep-copied into the job's arena, so the writer never
  touches live records.
- One writer thread per job (`std.Thread`; the venom-std `Supervisor` is for
  long-lived restartable workers, and this is a bounded one-shot job joined
  by the reactor). At most one job is in flight.
- A periodic tick while busy sets a coalesce flag and causes exactly one
  capture after the write completes. An explicit `recovery.checkpoint` while
  busy fails `conflict.recovery_busy` (exit 5, empty data). Otherwise it is
  answered on a later reactor turn, only after the directory fsync. A caller
  that cancels or disconnects gets no reply, and the write stands.
- Config reload (retention or the text-off purge) and the final clean
  checkpoint first wait for the in-flight write, so a checkpoint captured
  under an old policy is never published after the purge.
- Store listing uses its own open file description (`openat(dir, ".")`)
  instead of `dup()`, so the reactor and the writer can enumerate the store
  concurrently.

The remaining stall is `Vt.exportPlain` (per-cell grid lookups), which only
applies with `terminal_text=.plain`. Capture must happen at one reactor
boundary, so speeding it up belongs in venom-term. With `terminal_text=.off` (the default), capture is the topology
only and has no text export.
