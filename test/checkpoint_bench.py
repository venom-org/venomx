#!/usr/bin/env python3
"""Measure how long an explicit recovery checkpoint stalls the reactor.

Runs the seam build (for VENOMX_TEST_SCROLLBACK_LINES) with plain terminal
text enabled and the largest text bounds, fills panes with `--mib` MiB of
ASCII text each, then repeatedly runs `recovery.checkpoint` on one socket
connection while a second connection pings the daemon in a tight loop. The
longest ping round trip that overlaps a checkpoint is the reactor stall: the
time during which no request, PTY output or attach frame is serviced.

Isolated XDG dirs; the only process ever signalled is the daemon this script
started (SIGKILL in `finally`).
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('exe', type=lambda p: str(Path(p).resolve()), help='venomx-seam binary')
parser.add_argument('--mib', type=int, default=16, help='MiB of plain text per pane')
parser.add_argument('--panes', type=int, default=1)
parser.add_argument('--trials', type=int, default=5)
parser.add_argument('--label', default='')
parser.add_argument('--report', type=Path)
parser.add_argument('--state-parent', type=Path, help='Directory on the filesystem to measure (default: the temp dir, often tmpfs)')
args = parser.parse_args()

COLS, ROWS, WIDTH = 200, 50, 167  # 167 printable + LF = 168 bytes per row
LINES = args.mib * 1024 * 1024 // (WIDTH + 1)
TIMEOUT = 600


class Wire:
    def __init__(self, path, token):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(TIMEOUT)
        self.sock.connect(str(path))
        self.io = self.sock.makefile('rwb', buffering=0)
        self.n = 0
        self.call('hello', {'proto': [1], 'caps': ['cancel'], 'max_frame': 1048576, 'auth': {'token': token}}, ident=0)

    def call(self, verb, params=None, ident=None):
        self.n += 1
        self.io.write(json.dumps({'id': self.n if ident is None else ident, 'verb': verb, 'params': params or {}}).encode() + b'\n')
        reply = json.loads(self.io.readline())
        assert 'ok' in reply, reply
        return reply['ok']

    def close(self):
        self.io.close()
        self.sock.close()


root = Path(os.path.realpath(tempfile.mkdtemp(prefix='vx-ckb-')))
state = Path(tempfile.mkdtemp(prefix='vx-ckb-state-', dir=args.state_parent)) if args.state_parent else root / 'state'
daemon = None
try:
    (root / 'run').mkdir(mode=0o700)
    (root / 'cfg' / 'venomx').mkdir(parents=True)
    (root / 'cfg' / 'venomx' / 'config.zon').write_text(
        '.{ .recovery = .{ .enabled = true, .interval_ms = 3600000, .max_checkpoints = 2, .max_checkpoint_bytes = 67108864,'
        ' .terminal_text = .plain, .text_max_rows = 100000, .text_max_bytes = 16777216 } }\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith('VENOMX_')}
    env.update(HOME=str(root), XDG_RUNTIME_DIR=str(root / 'run'), XDG_CONFIG_HOME=str(root / 'cfg'), XDG_CONFIG_DIRS=str(root / 'cfg' / 'xdg'), XDG_STATE_HOME=str(state),
               VENOMX_TEST_SCROLLBACK_LINES=str(LINES + 1000))
    daemon = subprocess.Popen([args.exe, 'serve', '--json'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=env)
    sock = root / 'run' / 'venom' / 'venomx.sock'
    owner = root / 'run' / 'venom' / 'venomx.owner'
    deadline = time.monotonic() + 30
    while not owner.exists() or not sock.exists():
        assert daemon.poll() is None and time.monotonic() < deadline, daemon.stderr.read()
        time.sleep(.02)
    token = owner.read_text().strip()
    ctl = Wire(sock, token)
    ctl.call('session.create', {'name': 'bench'})
    script = f"python3 -c \"import sys; l=('x'*{WIDTH}+chr(10)).encode(); sys.stdout.buffer.write(l*{LINES}); sys.stdout.buffer.write(b'BENCH-END')\"; exec sleep 3600"
    panes = [ctl.call('window.create', {'session': 's0', 'argv': ['/bin/sh', '-c', script], 'cols': COLS, 'rows': ROWS})['pane']]
    for _ in range(args.panes - 1):
        panes.append(ctl.call('pane.split', {'pane': panes[0], 'axis': 'rows', 'argv': ['/bin/sh', '-c', script]})['pane'])
    for p in panes:
        while 'BENCH-END' not in ctl.call('pane.capture', {'pane': p})['text']:
            time.sleep(.2)
    # Stalls are measured by a second connection pinging continuously.
    pinger = Wire(sock, token)
    samples = []  # (start, end)
    stop = threading.Event()

    def ping():
        while not stop.is_set():
            t0 = time.monotonic()
            pinger.call('ping')
            samples.append((t0, time.monotonic()))
    thread = threading.Thread(target=ping)
    thread.start()
    time.sleep(.5)
    baseline = [e - s for s, e in samples]
    trials = []
    for _ in range(args.trials):
        t0 = time.monotonic()
        result = ctl.call('recovery.checkpoint')
        t1 = time.monotonic()
        time.sleep(.3)
        overlapping = [e - s for s, e in samples if e > t0 and s < t1]
        size = (next((state / 'venomx' / 'recovery').iterdir()) / f"{result['checkpoint']}.json").stat().st_size
        trials.append({'checkpoint_s': t1 - t0, 'max_ping_s': max(overlapping, default=0.0), 'pings_during': len(overlapping), 'file_bytes': size})
    stop.set()
    thread.join()
    report = {
        'label': args.label, 'state_fs': subprocess.run(['stat', '-f', '-c', '%T', str(state)], capture_output=True, text=True).stdout.strip(), 'panes': args.panes, 'mib_per_pane': args.mib, 'rows_per_pane': LINES, 'cols': COLS,
        'baseline_ping_median_s': statistics.median(baseline),
        'trials': trials,
        'median_checkpoint_s': statistics.median(t['checkpoint_s'] for t in trials),
        'median_max_ping_s': statistics.median(t['max_ping_s'] for t in trials),
    }
    print(json.dumps(report, indent=2))
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    pinger.close()
    ctl.close()
finally:
    if daemon and daemon.poll() is None:
        daemon.send_signal(signal.SIGKILL)
        daemon.wait()
    subprocess.run(['rm', '-rf', str(root), str(state)])
