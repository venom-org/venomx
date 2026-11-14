---
title: Performance
order: 9
---

venomx keeps a full terminal emulator per pane in the daemon and another in
each attached client, and still aims to be at least as fast as the
multiplexers it replaces. `test/muxbench.py` measures that by driving each
multiplexer's real client on a PTY, the way a person would.

## Results

200×50 pane, 16 MiB flood, 5 trials, medians, venomx built with
ReleaseFast. AMD Ryzen 7 9800X3D, Linux 7.3; tmux 3.8, zellij 0.45.1, tuios
0.12.1, each with its default config.

**Text with heavy styling** (256-colour foreground plus bold or dim on every
word):

| Metric | Better | venomx | tmux | zellij | tuios |
|---|---|---|---|---|---|
| Flood throughput (MiB/s) | higher | **92.4** | 25.1 | 59.6 | 73.7 |
| Flood CPU (s) | lower | **0.28** | 0.47 | 0.32 | 0.53 |
| Startup (ms) | lower | **14.8** | 23.8 | 77.4 | 69.3 |
| Echo latency p50 / p90 (ms) | lower | 0.37 / 0.57 | **0.14 / 0.19** | 11.37 / 11.45 | 2.14 / 2.60 |
| Idle memory, PSS (MiB) | lower | 11.5 | **4.3** | 94.7 | 80.0 |
| Memory after flood (MiB) | lower | 19.7 | **6.4** | 162.1 | 121.2 |

**Plain ASCII:**

| Metric | Better | venomx | tmux | zellij | tuios |
|---|---|---|---|---|---|
| Flood throughput (MiB/s) | higher | **177.9** | 77.1 | 37.2 | 80.5 |
| Flood CPU (s) | lower | **0.15** | 0.21 | 0.49 | 0.46 |
| Startup (ms) | lower | **15.7** | 21.8 | 77.4 | 68.8 |
| Echo latency p50 / p90 (ms) | lower | 0.39 / 0.58 | **0.14 / 0.19** | 11.36 / 11.48 | 2.14 / 2.57 |
| Idle memory, PSS (MiB) | lower | 11.5 | **4.3** | 94.9 | 79.9 |
| Memory after flood (MiB) | lower | 19.2 | **5.6** | 136.2 | 104.6 |

The defaults are not equal on every count: tmux keeps 2000 lines of history,
venomx 10000.

## What is measured

- **Startup:** from launch until the pane's first text shows.
- **Echo latency:** from a keystroke to its echo on screen.
- **Flood:** throughput and CPU time while a pane prints 16 MiB.
- **Memory:** PSS summed over each multiplexer's client and server
  processes, idle and after the flood.

The harness plays the host terminal: it reads all output and answers the
usual queries (device attributes, cursor position, colours, size), but draws
nothing, so the numbers measure the multiplexer and not a terminal emulator.
Each trial starts in fresh HOME and XDG directories, and the first trial is a
warmup.

## Run it yourself

```sh
zig build bench-compare -Doptimize=ReleaseFast                  # every installed multiplexer
zig build bench-compare -Doptimize=ReleaseFast -- --data sgr --report sgr.json
python3 test/muxbench.py --compare old.json new.json            # deltas; >10% regressions marked !
```

Multiplexers that are not installed are skipped. `--mux`, `--tmux`,
`--zellij` and `--tuios` choose which run and which binaries they use.
