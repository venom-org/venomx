# Pane-stream defaults, measured

The pane-stream protocol took its defaults from tuios and tmux. This page records our own
numbers for each one.

| Default | Was | Verdict | Deciding number |
|---|---|---:|---|
| `ring_bytes` | 256 KiB | **1 MiB** | Real clients on a flood resynced in 10 of 20 runs at 256 KiB, 2 of 20 at 512 KiB, 0 of 20 at 1 MiB |
| `client_backlog_bytes` | 256 KiB | **1 MiB** | Same check; it stays equal to the ring |
| `latest_hold_ms` | 1000 | Confirmed | 12 flips/min with two people typing at once (260 with no hold); hands over within one key once the writer has paused 1 s |
| `resize_coalesce_ms` | 30 | Confirmed | Halves applied sizes on a 60 Hz drag and quarters them at 125 Hz; the last size lands within 31 ms |
| Overflow snapshots | 1/s per stream | Confirmed | About 1.5 ms of CPU each; 16 slow clients left a sibling pane's echo at 0.58 ms |
| PTY frame size | up to `max_frame` | **256 KiB** | Added: a lagging client holds about 0.38 MiB instead of 0.83 MiB, and waits 1.0 s instead of 1.8 s between frames at 256 KiB/s. See *Slow clients and large frames* |

## Method

2026-11-08, AMD Ryzen 7 9800X3D (16 threads), 62 GiB, Linux 7.3.1-cachyos,
Zig 0.17.0 ReleaseFast, Python 3.13. The binary was built with the doctor resync
counter and the old 256 KiB default; rings are set through config. Raw rows
and the load average of each scenario:
[measurements/pane-stream-defaults.json](measurements/pane-stream-defaults.json).

```sh
zig build -Doptimize=ReleaseFast --prefix zig-out/release
timeout 3300 python3 test/pane_stream_bench.py zig-out/release/bin/venomx \
    --report docs/measurements/pane-stream-defaults.json
```

Each run gets a new daemon in a temporary HOME and speaks the real wire
protocol. Each load run lasts 3 s, a typing trace 60 s, and a drag about 2 s.
The whole run takes about 2100 s (exit 0 with the frame cap, load
average 0.3 to 5.5). `--max-seconds` defaults to 3000; if it or `timeout` stops a
run, finished scenarios stay in the report and the daemon is stopped.

The tables below are from that first run, without the frame cap, unless they say
otherwise. The rerun with the cap agrees on the overflow path (208–214 MiB/s
produced with 0 to 16 slow clients, a throttle of exactly 1/s, echo p99 up to
1.5 ms).

**The machine was shared.** Other agents ran builds and tests, with a load
average between 0.8 and 7 on 16 threads. Single runs are noisy: flood throughput moved
between 129 and 198 MiB/s with no trend against snapshot rate. A first
overflow run showed 16 slow clients costing 19% throughput, and the repeat
showed 2%. So the ring verdict rests on 5 repeats per case, and small
differences here mean nothing.

**Limits of this data:**

- The loads are synthetic and seeded, except `htop` and `git log -p`. The floods
  are a Python generator writing fixed lines, not `cat`.
- The clients have a PTY sink, not a real terminal: `venomx attach` wrote to a
  Python reader, so GPU and host-terminal cost is missing.
- The typing traces are a model of two people. They count flips and delays.
  **Whether the hold feels sticky was not measured**, and only a person can
  judge that.
- Sleep was not exercised. See *Resume window*.

## Load rates

Pane size 200×50, one fast watcher.

| Load | Output | Daemon CPU |
|---|---:|---:|
| Idle `sh -i` | 0 | 0% |
| `htop -d 1` (real) | 0.02 MiB/s | 0.3% |
| Build log: 1000 lines/s plus a warning burst of about 128 KiB every 2 s | 0.14 MiB/s | 0.7% |
| `git log -p` of this repo (real; ended within the window) | 0.8 MiB/s | 2% |
| Full-screen TUI, every cell repainted at 60 fps | 1.0 MiB/s | 2.3% |
| Flood, 80-byte lines | 166–205 MiB/s | 91–96% |
| Flood, 200-byte lines | 294–330 MiB/s | 90–94% |

A flood runs as fast as the daemon's emulator, so the daemon is the bottleneck
and takes a whole core.

## Ring and client backlog

### Real clients on a flood

`venomx attach` on a PTY whose reader never blocks, 3 s, five runs per case.
Runs with at least one resync, counted by the daemon:

| Ring | Emulating, 80-byte | Emulating, 200-byte | Raw, 80-byte | Raw, 200-byte | Total |
|---:|---:|---:|---:|---:|---:|
| 256 KiB | 0/5 | **5/5** | 2/5 | 3/5 | **10/20** |
| 512 KiB | 1/5 | 0/5 | 0/5 | 1/5 | 2/20 |
| 1 MiB | 0/5 | 0/5 | 0/5 | 0/5 | **0/20** |
| 2 MiB | 0/5 | 0/5 | 0/5 | 0/5 | 0/20 |

A later repeat shows how much noise is in counts like these. Without the cap, at
load 4.6 to 7.2, 1 MiB had 3 of 20 (all emulating on 80-byte lines), and 256 KiB,
512 KiB and 2 MiB had 10, 2 and 0. With the cap, at load 4.4, they were 12, 4, 0 of 20 at 256
KiB, 512 KiB, 1 MiB, and 0 at 2 MiB. The order is stable, and the cap doesn't hurt
a client on one stream.

The reason is time. At 300 MiB/s, 256 KiB lasts 0.85 ms and 1 MiB lasts 3.5 ms.
A client that keeps up on average still falls off a small ring if it is
descheduled or finishes a frame at the wrong moment. A resync then costs far
more than its snapshot, because the next one can wait for the 1 s throttle:
the Python watcher that overflowed at 256 KiB froze for 603 ms and got 84% of
the bytes, against 4 ms and 100% at 1 MiB. Raw throughput on 200-byte lines fell
to 150–186 MiB/s in the two runs with 2 and 3 resyncs. The other three runs at
256 KiB reached 323–326 MiB/s, more than the 277–306 MiB/s at 1 MiB, so this
shows what a resync costs and not that the larger ring is faster.

The [raw attach](raw-attach.md) measurements saw the same thing: their narrow-window and full-width probes overran
the default ring. Rerunning `raw_bench.py` with 64 MiB of 198-byte lines did
not reproduce a failure at either size (5 of 5 passed at 256 KiB, 3 of 3 at
1 MiB), so that bench is not the evidence here.

### Slow clients do not benefit

A client slower than the program resyncs at the throttle's rate whatever the
ring. Python client on a read cap, 3 s:

| Load | Reader | 64 KiB | 256 KiB | 1 MiB | 4 MiB |
|---|---|---:|---:|---:|---:|
| Build log | 256 KiB/s | 0/s | 0/s | 0/s | 0/s |
| TUI | 1 MiB/s and up | 0/s | 0/s | 0/s | 0/s |
| TUI | 256 KiB/s | 1/s | 1/s | 0/s | 0/s |
| Flood | 256 KiB/s to 10 MiB/s | 1/s | 1/s | 1/s | 1/s (one 0.33/s) |

The TUI's 0/s at 1 MiB and up doesn't mean that client keeps up: it received
16% of the bytes, and a 3 s run is too short to show its rate at those sizes.
A real raw client on a sink capped at 20 MiB/s also resynced at 1/s on floods at
all three sizes tried (64 KiB to 1 MiB). Build and TUI loads never resynced a
real client at those sizes, on either sink. So the larger ring helps a client
that keeps up and doesn't stop one that can't from resyncing, which is the
behaviour the pane-stream protocol wants. It does change how long that client can stay behind
without a resync: see the next section.

### Slow clients and large frames

The overflow check runs between frames, and a connection's other streams wait
behind a frame. A larger ring lets frames grow, because a frame takes whatever
is pending, so venomx caps a PTY frame at 256 KiB. Before and after, on a
Python client with a second stream on an echo pane, over 21 s:

| Load | Reader | Largest frame | Longest wait between frames | Sibling echo, longest |
|---|---|---:|---:|---:|
| Build log | 64 KiB/s | 418 → 256 KiB | 6.5 → 4.0 s | 6.5 → 4.0 s |
| TUI | 256 KiB/s | 472 → 256 KiB | 1.8 → 1.0 s | 2.0 → 1.0 s |
| Flood | 256 KiB/s | 126 → 128 KiB | 1.0 → 0.95 s | 0.79 → 0.79 s |
| Flood | 1 MiB/s | 735 → 256 KiB | 0.94 → 0.94 s | 0.75 → 0.25 s |

One run each, at a load average of 7 to 15. The rerun with the cap at load 0.3 to
1 gave the same waits (4.0, 1.0, 1.0 and 0.92 s). Raw rows are in
[measurements/pane-stream-frame-cap.json](measurements/pane-stream-frame-cap.json).

**What the cap bounds.** The wait for one frame is at most 256 KiB / read rate:
the 4.0 s at 64 KiB/s and the 1.0 s at 256 KiB/s above.

**What it doesn't bound.**

- A client behind on output that doesn't overflow can be up to
  `client_backlog_bytes` behind, which is 1 MiB / read rate: about 4 s at
  256 KiB/s. It went from about 1 s when the ring was 256 KiB. That is the price
  of the larger ring, and it only applies to output that stops before the
  backlog fills; a steady load overflows and resyncs instead.
- SNAPSHOT and SCROLLBACK frames can still reach `max_frame`, since a ghostty
  record can't be split. They are not capped.
- **Several panes flooding on one connection get worse from about 8.** A
  connection queues one frame per daemon turn, shared by its streams, and each
  pane can produce 64 KiB per turn. `venomx attach` puts a window's panes on one
  connection. Two 4 s runs per case, on 200-byte floods:

  | Flooding panes | Overflows/s per stream, no cap | With cap | MiB/s delivered, no cap | With cap |
  |---:|---:|---:|---:|---:|
  | 1–4 | 0 | 0 | 327–343 | 322–343 |
  | 6 | 0.04–0.08 | 0.04–0.08 | 305–315 | 318–320 |
  | 8 | 0.09 | 0.59–0.62 | 309–311 | 228–241 |
  | 12 | 0.23–0.44 | 0.94–0.98 | 241–275 | 149–152 |

  This is accepted for now: eight panes flooding at once is unusual, and each
  still gets a correct screen from a snapshot. It is a known limitation.

### Memory

Daemon RSS with 32 panes at 80×24:

| Ring | No output | Each pane wrote 8 MiB |
|---:|---:|---:|
| 64 KiB | 9.1 MiB | 206 MiB |
| 256 KiB | 9.1 MiB | 212 MiB |
| 1 MiB | 9.1 MiB | 236 MiB |
| 4 MiB | 9.1 MiB | 332 MiB |

In this ReleaseFast build, ring pages are touched only as output arrives, so an
idle pane pays nothing. Scrollback dominates: moving from 256 KiB to 1 MiB adds
24 MiB (11%) for 32 busy panes, and 4 MiB adds 120 MiB for no further gain in
resyncs.

**The build mode matters.** Debug and ReleaseSafe fill each allocation when it
is made, so every page is touched from the start. 32 idle panes:

| Ring | ReleaseFast | ReleaseSafe | Debug |
|---:|---:|---:|---:|
| 64 KiB | 8.8 MiB | 63.7 MiB | 75.3 MiB |
| 256 KiB | 8.8 MiB | 69.9 MiB | 81.5 MiB |
| 1 MiB | 8.7 MiB | 94.6 MiB | 106.5 MiB |
| 4 MiB | 8.7 MiB | 193.6 MiB | 205.2 MiB |

So the move to 1 MiB costs an idle Debug or ReleaseSafe daemon about 25 MiB over
32 panes. The numbers on this page are ReleaseFast. venom-os has to pin its
build mode for them to hold.

**A lagging client costs more than its share of the ring.** A connection's send
buffer keeps its largest size until the client disconnects. 64 clients that read
in bursts on a TUI and then stop, against a run with none, twice each:

| Ring | Largest frame | RSS, no slow clients | RSS, 64 clients, no cap | RSS, 64 clients, 256 KiB cap | Per client, no cap → cap |
|---:|---:|---:|---:|---:|---:|
| 256 KiB | 219 KiB | 8.7 MiB | 34.1–35.7 MiB | 34.1–35.8 MiB | 0.41 MiB → 0.41 MiB |
| 1 MiB | 724 → 256 KiB | 9.4 MiB | 62.4–62.7 MiB | 33.5–33.6 MiB | 0.83 MiB → 0.38 MiB |

So the bound is about 0.4 MiB per connection that has ever lagged, held until it
disconnects: the 256 KiB frame plus allocator overhead. The cap removes the extra
cost that the 1 MiB ring brought.

A client that stops during its backfill costs far more, and the cap doesn't
touch it: the snapshot is kept until the history is sent. 64 such clients on a
pane with 10,000 lines of scrollback held about 220 MiB (24.6 to 244–246 MiB),
which is 3.4 MiB each.

### Resume window

The window is `ring_bytes / output rate`. Disconnecting for half of it resumed
and for twice of it fell back, except where noted below.

| Load | 64 KiB | 256 KiB | 1 MiB | 4 MiB |
|---|---:|---:|---:|---:|
| Idle shell | | no limit (5 s tested) | | |
| Build log | ≈0.5 s | ≈1.8 s | ≈7 s | ≈29 s |
| TUI at 60 fps | 0.06 s | 0.25 s | 1.0 s | 4.0 s |
| Flood | ≈0.3 ms | ≈1.3 ms | ≈5 ms | ≈21 ms |

Build-log windows are computed from the 0.14 MiB/s average, because bursts
shorten them: at 256 KiB, 1.35 s away already missed the ring. The 1 MiB run
resumed after 5.4 s and replayed 931 KiB in 1.1 ms. Absences over the run's
12 s bound were not tested, which leaves out twice the 1 MiB window and both
4 MiB cases on the build log. On a flood, 64 and 256 KiB never resumed: the
window is shorter than the reconnect.

Falling back is cheap: a TUI's snapshot was 103 KiB and caught up in 0.3 ms, the
same as replaying 118 KiB. So the window matters for keeping scrollback intact
through a short gap, not for speed.

**Laptop sleep.** On one machine, sleep suspends the daemon and its programs
together, so no output is produced and the ring doesn't move: resume always
works. The window only applies when the client stops and the daemon doesn't,
such as a stopped client process or a future remote transport. There, 1 MiB covers about 7 s of a build, and no ring size covers a
long sleep of anything busy; the fallback snapshot handles that.

## Hold (`latest_hold_ms`)

Two writers with viewports of 120×40 and 100×30, on a program that repaints on
`SIGWINCH`. 60 s traces with `resize_coalesce_ms = 0`, the same seeds per hold.

| Hold | Flips/min, typing at once | Flips/min, taking turns | Redraw KiB/min, at once |
|---:|---:|---:|---:|
| 0 | 260 | 17 | 1763 |
| 250 ms | 36 | 17 | 245 |
| 500 ms | 16 | 17 | 109 |
| **1000 ms** | **12** | **17** | **81** |
| 2000 ms | 2 | 13 | 14 |
| 5000 ms | 0 | 0 | 0 |

Delay from the second writer's first key until the size follows, typing a key
every 150 ms, by how long the first writer had been quiet:

| Hold | 100 ms | 500 ms | 1000 ms | 3000 ms |
|---:|---:|---:|---:|---:|
| 0 | 0 | 0 | 0 | 0 |
| 250 ms | 151 ms | 0 | 0 | 0 |
| 500 ms | 453 ms | 0 | 0 | 0 |
| **1000 ms** | **905 ms** | **602 ms** | **0** | **0** |
| 2000 ms | 1958 ms | 1506 ms | 1054 ms | 0 |
| 5000 ms | 4963 ms | 4512 ms | 4062 ms | 2106 ms |

**Confirmed at 1000 ms.** It follows every turn that taking turns produces,
and it cuts flips from simultaneous typing by 95%. 2000 ms starts losing real
turns (13 of 17), and 500 ms gives 16 flips/min instead of 12 in exchange for
half the wait. Those two are close, and the numbers don't justify a move
between them. If people find the hold sticky, 500 ms is the value to try; the
setting is hot-reloadable.

## Resize coalescing (`resize_coalesce_ms`)

A writer sends a new size every 8 ms (125 Hz) or 16 ms (60 Hz), in four drags
of about 2 s, to a program that repaints each time. Pane scrollback holds 10,000
lines, so each size also reflows.

| Window | Applied/s at 125 Hz | Applied/s at 60 Hz | Settle max, 125 Hz | Daemon CPU, 125 Hz | Repaint MiB, 125 Hz |
|---:|---:|---:|---:|---:|---:|
| 0 | 125 | 62.5 | 0.8 ms | 8.1% | 9.6 |
| 8 ms | 125 | 62.5 | 0.8 ms | 8.0% | 9.6 |
| 16 ms | 63 | 62.5 | 10.7 ms | 4.3% | 4.8 |
| **30 ms** | **32** | **31.5** | **31 ms** | **2.6%** | **2.4** |
| 50 ms | 21 | 21 | 41 ms | 2.1% | 1.6 |
| 100 ms | 11 | 11 | 92 ms | 1.3% | 0.8 |
| 250 ms | 4.9 | 4.9 | 242 ms | 0.9% | 0.4 |

"Settle" is the time from the last size sent to the client seeing it. Empty
scrollback gives the same applied rates at lower CPU (3.7% at 0 ms, 1.2% at
30 ms).

**Confirmed at 30 ms.** It is the smallest window tested that coalesces a 60 Hz
drag at all, and it cuts repaints to a quarter at 125 Hz. Beyond it, repaints and CPU
fall slowly while the lag grows into something visible. CPU is low everywhere,
so the benefit is mostly fewer repaints for the program and less output to send.

## Overflow snapshots (one per second)

Requested resyncs are not throttled, so a client asking at a chosen rate
measures the cost of faster snapshots without changing code. Pane 200×50,
10,000 lines of scrollback, idle:

| Snapshots/s | Daemon CPU | RESYNC to READY, p50 / p99 | Echo p50 / max, sibling pane |
|---:|---:|---:|---:|
| 0 | 0.3% | | 0.08 / 0.16 ms |
| 1 | 0.3% | 1.3 / 1.9 ms | 0.08 / 1.9 ms |
| 4 | 1.0% | 1.1 / 1.7 ms | 0.09 / 1.8 ms |
| 10 | 1.7% | 1.1 / 1.8 ms | 0.11 / 1.9 ms |
| 30 | 4.3% | 1.0 / 1.8 ms | 0.10 / 1.8 ms |
| 94 | 14.3% | 1.0 / 2.5 ms | 0.11 / 2.3 ms |

That is about 1.5 ms of CPU per snapshot, in line with the earlier
estimate of ≤ 1.2 ms for the encode alone; the `vt` format costs about 1.1 ms. Under a flood the daemon
is already saturated, so CPU shows nothing and throughput shows no trend below
noise up to 100/s. The largest echo delay matches the snapshot, as expected:
the encode runs on the reactor.

The real overflow path, on an 80-byte flood with a fast watcher and an echo
probe. Slow clients read 1 MiB/s and ask for all history:

| Slow clients | Overflow/s per client | Longest freeze | Produced | Echo p50 / p99 |
|---:|---:|---:|---:|---:|
| 0 | | | 205 MiB/s | 0.57 / 0.93 ms |
| 1 | 1.0 | 997 ms | 206 MiB/s | 0.60 / 0.90 ms |
| 4 | 1.0 | 1002 ms | 204 MiB/s | 0.56 / 0.93 ms |
| 16 | 1.0 | 1002 ms | 201 MiB/s | 0.58 / 0.92 ms |

The 1 MiB ring gave the same picture (198–205 MiB/s, echo p99 up to 1.0 ms).

**Confirmed at one per second.** The throttle holds exactly, and 16 slow clients
cost other panes nothing measurable. The numbers show room to go faster: 4/s
would still be cheap and would cut a slow client's freeze to 250 ms. But that
freeze only happens to a client that can't keep up with a flood, where it
refreshes once a second instead of showing garbage, and nothing here shows that
this hurts. With the larger ring, clients that keep up no longer reach it.

## Reproducing one number

```sh
python3 test/pane_stream_bench.py zig-out/release/bin/venomx --only trials --trials 5
python3 test/pane_stream_bench.py zig-out/release/bin/venomx --only hold --typing 12
python3 test/pane_stream_bench.py zig-out/release/bin/venomx --only frames,stalled
```

`venomx doctor` now reports the total in `pane_stream.state` (`N stream
resyncs`). It covers panes that still exist. A per-pane count would be finer;
the total was enough here.
