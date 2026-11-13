#!/usr/bin/env python3
"""Measure the pane-stream defaults.

Starts a throwaway daemon per run, in a temporary HOME, and talks the real
wire protocol. Each scenario prints one JSON row per run; --report saves them
all together with the machine, commit and load average.

    zig build -Doptimize=ReleaseFast --prefix zig-out/release
    timeout 3300 python3 test/pane_stream_bench.py zig-out/release/bin/venomx \\
        --report docs/measurements/pane-stream-defaults.json

Scenarios (--only a,b,c):

  rates     Output rate of each load, including real programs (htop, btop,
            git log -p) when installed.
  ring      ring_bytes x load x client read rate: resyncs, data loss, CPU.
  resume    Disconnect for half and for twice ring/rate, then resume.
  real      Real `venomx attach` clients on a PTY sink: daemon resync count.
  trials    The flood cases of `real`, repeated, with more ring sizes.
  memory    Daemon RSS for 32 panes with full rings.
  snapshot  Requested snapshots per second: encode cost, CPU, sibling latency.
  overflow  N slow clients on a flood: the real overflow path and its throttle.
  hold      latest_hold_ms x two scripted writers: flips, take-over delay.
  coalesce  resize_coalesce_ms x a window drag: applied sizes, settle time.
  frames    A slow reader on a flood: largest PTY frame, freeze, and the delay of
            a sibling stream on the same connection.
  stalled   64 clients that lag, then stop reading: daemon RSS against a control.

Loads are synthetic and seeded unless named real. Typing traces are a model
of two people typing, not a measurement of how the hold feels.

All scenarios take about 2100 s. --max-seconds stops a run that goes past that
by far: finished scenarios stay in the report, and the exit code is 3.
"""
import argparse
import json
import os
from pathlib import Path
import platform
import random
import re
import select
import shutil
import signal
import socket
import statistics
import struct
import subprocess
import sys
import tempfile
import time

KIB = 1024
MIB = 1024 * 1024
RINGS = [64 * KIB, 256 * KIB, MIB, 4 * MIB]
DEFAULT_RING = MIB
HEADER = struct.Struct('>HII')
ERROR, HELLO, HELLO_OK = 3, 1, 2
ATTACH, ATTACHED, SNAPSHOT, READY, PTY, SCROLLBACK, INPUT, RESIZE, RESYNC, EXIT = range(0x100, 0x10A)
SIBLING = 3  # second stream on a connection, used by the frames scenario

# Runs inside the pane. It stops itself so a lost daemon cannot leave a flood.
GEN = r'''
import os, random, signal, sys, termios, tty
signal.alarm(600)
mode, args = sys.argv[1], sys.argv[2:]
tty.setraw(0)
def out(data):
    view = memoryview(data)
    while view:
        view = view[os.write(1, view):]
def frame(seed):
    cols, rows = os.get_terminal_size(0)
    rnd = random.Random(seed)
    parts = ['\x1b[?2026h']
    for row in range(1, rows + 1):
        parts.append(f'\x1b[{row};1H')
        col = 0
        while col < cols:
            run = min(cols - col, rnd.randint(4, 28))
            parts.append(f'\x1b[38;5;{rnd.randrange(256)}m' + rnd.choice('abcdefgh .:|') * run)
            col += run
    parts.append('\x1b[0m\x1b[?2026l')
    return ''.join(parts).encode()
def fill(lines):
    cols = os.get_terminal_size(0).columns
    line = b'h' * (cols - 1) + b'\r\n'
    for _ in range(lines // 100 + 1):
        out(line * 100)
if mode == 'echo':
    out(b'GATE')
    while True:
        b = os.read(0, 1)
        if not b: break
        out(b)
elif mode == 'winch':
    fill(int(args[0]))
    flag = [True]
    signal.signal(signal.SIGWINCH, lambda *_: flag.__setitem__(0, True))
    out(b'\x1b[?1049hGATE')
    n = 0
    while True:
        if flag[0]:
            flag[0] = False
            n += 1
            out(frame(n))
        signal.pause() if not flag[0] else None
else:
    fill(int(args[0]) if args else 0)
    out(b'GATE')
    os.read(0, 1)
    import time
    if mode == 'flood':
        width = int(args[1])
        block = (b'x' * width + b'\r\n') * (65536 // (width + 2) + 1)
        while True:
            out(block)
    elif mode == 'build':
        rnd = random.Random(7)
        lines = [f'[{i}/40000] \x1b[32mcc\x1b[0m -c src/mod_{i % 97}/file_{i}.c -o build/mod_{i % 97}/file_{i}.o -O2 -Wall -Iinclude\r\n'.encode() for i in range(4000)]
        warn = b''.join(f'src/mod/file.c:{i}:12: \x1b[35mwarning:\x1b[0m implicit conversion loses precision [-Wconversion]\r\n'.encode() for i in range(1500))
        at, i, burst = time.monotonic(), 0, time.monotonic() + 2
        while True:
            out(b''.join(lines[(i + k) % 4000] for k in range(10)))
            i += 10
            now = time.monotonic()
            if now >= burst:
                out(warn)
                burst = now + 2
            at += .01
            time.sleep(max(0, at - time.monotonic()))
    elif mode == 'tui':
        out(b'\x1b[?1049h')
        fps = int(args[1])
        at, n = time.monotonic(), 0
        while True:
            out(frame(n % 16))
            n += 1
            at += 1 / fps
            time.sleep(max(0, at - time.monotonic()))
'''


class Stop(Exception):
    pass


def alarm(signum, _):
    raise Stop(f'{signal.Signals(signum).name}: --max-seconds elapsed or the run was terminated')


class Client:
    """One binary connection with one stream, read at an optional byte rate."""

    def __init__(self, bench, pane, writer=False, rate=None, fmt=None, history=0, size=(200, 50),
                 claim=False, resume=None):
        self.rate, self.budget, self.at = rate, 0.0, time.monotonic()
        self.paused = False
        self.buf = bytearray()
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(5)
        self.sock.connect(bench.path)
        self.sock.setblocking(False)
        params = {'proto': [1], 'caps': ['cancel', 'venomx.pane_stream'], 'max_frame': MIB}
        if writer:
            params['auth'] = {'token': bench.token}
        self.sock.sendall(b'\xf5')
        self.send(HELLO, params, stream=0)
        kind, payload = self.frame_blocking()
        assert kind == HELLO_OK, payload
        self.attached = None
        self.ready = None
        self.error = None
        self.eof = False
        self.head = None
        self.gaps = 0
        self.tail = b''
        self.gate = False
        self.overflows = 0
        self.resyncs = 0
        self.skipped = 0
        self.pty_bytes = 0
        self.snapshot_bytes = 0
        self.history_bytes = 0
        self.resizes = []
        self.resync_at = None
        self.resync_from = None
        self.latencies = []
        self.snapshots = 0
        self.last_update = None
        self.max_freeze = 0.0
        self.on_pty = None
        self.on_sibling = None
        self.frame_stream = 1
        self.max_pty_frame = 0
        self.send(ATTACH, {'pane': pane, 'mode': 'emulate', 'formats': [fmt or bench.ghostty], 'history': history,
                           'size': {'cols': size[0], 'rows': size[1]}, 'claim': claim,
                           **({'resume': resume} if resume else {})})

    def send(self, kind, payload, stream=1):
        if not isinstance(payload, bytes):
            payload = json.dumps(payload, separators=(',', ':')).encode()
        view = memoryview(HEADER.pack(kind, stream, len(payload)) + payload)
        deadline = time.monotonic() + 5
        while view:
            assert time.monotonic() < deadline, 'send timed out'
            try:
                view = view[self.sock.send(view):]
            except BlockingIOError:
                select.select([], [self.sock], [], .05)

    def frame_blocking(self):
        while True:
            parsed = self.take()
            if parsed:
                return parsed
            select.select([self.sock], [], [], 5)
            data = self.sock.recv(65536)
            assert data, 'connection closed during handshake'
            self.buf += data

    def take(self):
        if len(self.buf) < HEADER.size:
            return None
        kind, self.frame_stream, length = HEADER.unpack_from(self.buf)
        if len(self.buf) < HEADER.size + length:
            return None
        payload = bytes(self.buf[HEADER.size:HEADER.size + length])
        del self.buf[:HEADER.size + length]
        return kind, payload

    def pump(self, now):
        if self.paused or self.eof:
            return
        want = MIB
        if self.rate is not None:
            self.budget = min(self.budget + self.rate * (now - self.at), max(self.rate * .05, 4 * KIB))
            self.at = now
            want = int(self.budget)
            if want < 1024:
                return
        try:
            data = self.sock.recv(want)
        except BlockingIOError:
            return
        except ConnectionError:
            self.eof = True
            return
        if not data:
            self.eof = True
            return
        if self.rate is not None:
            self.budget -= len(data)
        self.buf += data
        while True:
            parsed = self.take()
            if not parsed:
                return
            if self.frame_stream == SIBLING and self.on_sibling:
                self.on_sibling(now, *parsed)
            else:
                self.handle(*parsed, now)

    def touch(self, now):
        if self.last_update is not None:
            self.max_freeze = max(self.max_freeze, now - self.last_update)
        self.last_update = now

    def handle(self, kind, payload, now):
        if kind == PTY:
            offset = struct.unpack_from('>Q', payload)[0]
            if self.head is not None and offset != self.head:
                self.gaps += 1
            data = payload[8:]
            self.max_pty_frame = max(self.max_pty_frame, len(payload))
            self.head = offset + len(data)
            self.pty_bytes += len(data)
            self.gate = self.gate or b'GATE' in self.tail + data
            self.tail = data[-8:]
            self.touch(now)
            if self.on_pty:
                self.on_pty(now, data)
        elif kind == ATTACHED:
            self.attached = json.loads(payload)
            if self.attached.get('resumed'):
                self.head = self.attached['offset']
        elif kind == SNAPSHOT:
            self.snapshot_bytes += len(payload) - 12
        elif kind == READY:
            self.ready = json.loads(payload)
            self.head = self.ready['offset']
            self.snapshots += 1
            if self.resync_at is not None:
                self.latencies.append(now - self.resync_at)
                self.skipped += self.ready['offset'] - self.resync_from
                self.resync_at = None
            self.touch(now)
        elif kind == SCROLLBACK:
            self.history_bytes += len(payload) - 21
        elif kind == RESYNC:
            message = json.loads(payload)
            self.resyncs += 1
            self.overflows += message['reason'] == 'overflow'
            self.resync_at, self.resync_from = now, message['offset']
        elif kind == RESIZE:
            self.resizes.append((now, json.loads(payload)))
        elif kind == ERROR:
            self.error = json.loads(payload)
        elif kind == EXIT:
            pass

    def close(self):
        self.sock.close()


class Bench:
    """A daemon with one config in a temporary HOME. Always stopped on exit."""

    def __init__(self, exe, **pane_stream):
        self.exe = exe
        self.pane_stream = pane_stream

    def __enter__(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='vx-stream-bench-')
        self.root = Path(self.tmp.name)
        self.path = str(self.root / 'd.sock')
        self.env = {k: v for k, v in os.environ.items() if not k.endswith('_TOKEN')}
        self.env.update(HOME=str(self.root), XDG_CONFIG_HOME=str(self.root / 'cfg'),
                        XDG_CONFIG_DIRS=str(self.root / 'cfg' / 'xdg'), XDG_STATE_HOME=str(self.root / 'state'),
                        TERM='xterm-256color')
        self.owner = dict(self.env, VENOMX_TOKEN='@owner')
        if self.pane_stream:
            config = self.root / 'cfg' / 'venomx' / 'config.zon'
            config.parent.mkdir(parents=True)
            fields = ', '.join(f'.{k} = {v}' for k, v in self.pane_stream.items())
            config.write_text(f'.{{ .pane_stream = .{{ {fields} }} }}')
        (self.root / 'gen.py').write_text(GEN)
        self.daemon = subprocess.Popen([self.exe, 'serve', '--socket', self.path], env=self.env,
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 10
        while not Path(self.path).exists():
            assert time.monotonic() < deadline and self.daemon.poll() is None, 'daemon did not start'
            time.sleep(.01)
        self.session = self.cli('session', 'create')['session']
        self.token = (self.root / 'd.owner').read_text().strip()
        self.ghostty = self.formats()
        self.clients = []
        return self

    def __exit__(self, *_):
        for client in self.clients:
            client.close()
        self.daemon.send_signal(signal.SIGKILL)
        self.daemon.wait(timeout=10)
        self.tmp.cleanup()

    def cli(self, *argv):
        return json.loads(subprocess.check_output([self.exe, *argv, '--socket', self.path, '--json'], env=self.owner, timeout=20))

    def formats(self):
        """The server names its ghostty pin when refusing an unknown format."""
        pane = self.pane(['sleep', '60'], (80, 24))
        probe = Client(self, pane, fmt='none/0')
        end = time.monotonic() + 5
        while probe.error is None and time.monotonic() < end:
            probe.pump(time.monotonic())
        probe.close()
        return next(f for f in probe.error['data']['supported'] if f != 'vt')

    def pane(self, argv, size=(200, 50)):
        return self.cli('window', 'create', '--session', self.session, '--cols', str(size[0]), '--rows', str(size[1]),
                        '--argv', json.dumps(argv))['pane']

    def gen(self, *args, size=(200, 50)):
        return self.pane([sys.executable, str(self.root / 'gen.py'), *map(str, args)], size)

    def go(self, pane):
        self.cli('pane', 'send', '--pane', pane, '--text', 'x')

    def client(self, pane, **options):
        client = Client(self, pane, **options)
        self.clients.append(client)
        return client

    def cpu(self):
        fields = Path(f'/proc/{self.daemon.pid}/stat').read_text().rsplit(')', 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / os.sysconf('SC_CLK_TCK')

    def memory(self):
        status = Path(f'/proc/{self.daemon.pid}/status').read_text()
        return {k: int(re.search(rf'{k}:\s+(\d+)', status).group(1)) for k in ('VmRSS', 'VmHWM')}

    def resyncs(self):
        out = subprocess.run([self.exe, 'doctor', '--socket', self.path, '--json'], env=self.owner, timeout=20,
                             capture_output=True, text=True).stdout
        return int(re.search(r'(\d+) stream resyncs', out).group(1))


def loop(clients, seconds=None, until=None, tick=None, limit=30):
    """Pump clients until `until` holds or `seconds` pass. Returns `until`'s truth."""
    start = time.monotonic()
    end = start + (seconds if seconds is not None else limit)
    fds = [c.sock for c in clients if c.rate is None and not c.paused and not c.eof]
    while True:
        now = time.monotonic()
        if tick:
            tick(now)
        for client in clients:
            client.pump(now)
        if until and until():
            return True
        if now >= end:
            return until is None
        select.select(fds, [], [], .001)


def wait_gate(client, limit=30):
    assert loop([client], until=lambda: client.gate, limit=limit), 'program did not reach its gate'


def pct(values, q):
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(q * len(ordered)))] * 1000, 3)


def emit(rows, **row):
    rows.append(row)
    print(json.dumps(row), flush=True)


class Probe:
    """Keystroke-to-echo round trip on a sibling pane, 20 per second."""

    def __init__(self, bench):
        self.pane = bench.gen('echo', size=(80, 24))
        self.client = bench.client(self.pane, writer=True, size=(80, 24))
        wait_gate(self.client)
        self.client.on_pty = self.answer
        self.sent = None
        self.next = 0.0
        self.samples = []

    def answer(self, now, _):
        if self.sent is not None:
            self.samples.append(now - self.sent)
            self.sent = None

    def tick(self, now):
        if self.sent is None and now >= self.next:
            self.client.send(INPUT, b'z')
            self.sent = now
            self.next = now + .05

    def result(self):
        return {'echo_p50_ms': pct(self.samples, .5), 'echo_p99_ms': pct(self.samples, .99),
                'echo_max_ms': pct(self.samples, 1), 'echo_samples': len(self.samples)}


LOADS = {
    'idle': (),
    'build': ('build',),
    'tui': ('tui', 0, 60),
    'flood80': ('flood', 0, 78),
    'flood200': ('flood', 0, 198),
}


def start_load(bench, load, watcher_options=None):
    """A gated load with a fast watcher; returns (pane, watcher)."""
    if load == 'idle':
        pane = bench.pane(['/bin/sh', '-i'])
        return pane, bench.client(pane, **(watcher_options or {}))
    pane = bench.gen(*LOADS[load])
    watcher = bench.client(pane, **(watcher_options or {}))
    wait_gate(watcher)
    return pane, watcher


def rates(args, rows):
    """How fast each load really writes, the input to every ring/rate figure."""
    with Bench(args.exe) as bench:
        for load in LOADS:
            pane, watcher = start_load(bench, load)
            loop([watcher], .3)
            if load != 'idle':
                bench.go(pane)
            before, cpu = watcher.head, bench.cpu()
            loop([watcher], args.seconds)
            emit(rows, scenario='rates', load=load, kind='synthetic', mib_per_s=round((watcher.head - before) / args.seconds / MIB, 4),
                 daemon_cpu_pct=round((bench.cpu() - cpu) / args.seconds * 100, 1), resyncs=watcher.resyncs)
            bench.cli('pane', 'kill', '--pane', pane)
            watcher.close()
            bench.clients.remove(watcher)
        repo = Path(__file__).resolve().parent.parent
        commands = {'htop': ['htop', '-d', '1'],
                    'git-log-p': ['sh', '-c', f"exec git -C '{repo}' --no-pager log -p -n 3000 --color=always"]}
        for name, argv in commands.items():
            if not shutil.which(argv[0]):
                continue
            pane = bench.pane(['timeout', '--foreground', str(int(args.seconds) + 2), *argv])
            watcher = bench.client(pane)
            loop([watcher], until=lambda: watcher.head is not None, limit=5)
            start, cpu = watcher.head, bench.cpu()
            loop([watcher], args.seconds)
            emit(rows, scenario='rates', load=name, kind='real', mib_per_s=round((watcher.head - start) / args.seconds / MIB, 4),
                 daemon_cpu_pct=round((bench.cpu() - cpu) / args.seconds * 100, 1), resyncs=watcher.resyncs)
            watcher.close()
            bench.clients.remove(watcher)


def ring(args, rows):
    readers = [('fast', None), ('10MiB/s', 10 * MIB), ('1MiB/s', MIB), ('256KiB/s', 256 * KIB)]
    for load in ('build', 'tui', 'flood80', 'flood200'):
        for size in RINGS:
            with Bench(args.exe, ring_bytes=size, client_backlog_bytes=size) as bench:
                pane, fast = start_load(bench, load)
                slow = {name: bench.client(pane, rate=rate) for name, rate in readers[1:]}
                every = [fast, *slow.values()]
                loop(every, until=lambda: all(c.ready for c in every))
                # Let snapshot and initial output drain before counting.
                loop(every, .3)
                bench.go(pane)
                loop(every, .1)
                base = {c: (c.pty_bytes, c.overflows, c.skipped) for c in every}
                for client in every:
                    client.max_freeze = 0.0
                head, cpu = fast.head, bench.cpu()
                loop(every, args.seconds)
                produced = fast.head - head
                row = dict(scenario='ring', load=load, ring=size, seconds=args.seconds,
                           produced_mib_s=round(produced / args.seconds / MIB, 3),
                           daemon_cpu_pct=round((bench.cpu() - cpu) / args.seconds * 100, 1), clients={})
                for name, client in (('fast', fast), *slow.items()):
                    got, overflows, skipped = base[client]
                    row['clients'][name] = dict(
                        resyncs_per_s=round((client.overflows - overflows) / args.seconds, 2),
                        delivered_pct=round((client.pty_bytes - got) / produced * 100, 1) if produced else None,
                        max_freeze_ms=round(client.max_freeze * 1000), gaps=client.gaps)
                emit(rows, **row)


def resume(args, rows):
    with Bench(args.exe) as bench:
        pane, watcher = start_load(bench, 'idle')
        loop([watcher], until=lambda: watcher.ready)
        loop([watcher], .3)
        offset, source = watcher.head, watcher.attached['source']
        watcher.close()
        bench.clients.remove(watcher)
        time.sleep(5)
        back = bench.client(pane, resume={'source': source, 'offset': offset})
        loop([back], until=lambda: back.attached is not None, limit=5)
        emit(rows, scenario='resume', load='idle', ring=DEFAULT_RING, away_s=5, resumed=back.attached['resumed'])
    for load in ('build', 'tui', 'flood80'):
        for size in RINGS:
            with Bench(args.exe, ring_bytes=size, client_backlog_bytes=size) as bench:
                pane, watcher = start_load(bench, load)
                loop([watcher], until=lambda: watcher.ready)
                bench.go(pane)
                loop([watcher], .2)
                before = watcher.head
                loop([watcher], 1.0)
                rate = watcher.head - before
                window = size / rate
                source = watcher.attached['source']
                for factor in (.5, 2):
                    away = window * factor
                    if away > 12:
                        emit(rows, scenario='resume', load=load, ring=size, predicted_window_s=round(window, 3), away_s=round(away, 3), skipped='over the 12 s bound')
                        continue
                    leaving = bench.client(pane)
                    loop([leaving, watcher], until=lambda: leaving.ready and leaving.head is not None)
                    loop([leaving, watcher], .1)
                    offset = leaving.head
                    leaving.close()
                    bench.clients.remove(leaving)
                    loop([watcher], away)
                    began = time.monotonic()
                    back = bench.client(pane, resume={'source': source, 'offset': offset})
                    loop([back, watcher], until=lambda: back.attached is not None, limit=5)
                    resumed = back.attached['resumed']
                    target = watcher.head
                    loop([back, watcher], until=lambda: back.head is not None and back.head >= target, limit=5)
                    emit(rows, scenario='resume', load=load, ring=size, rate_mib_s=round(rate / MIB, 3), predicted_window_s=round(window, 3),
                         away_s=round(away, 3), resumed=resumed, catch_up_ms=round((time.monotonic() - began) * 1000, 2),
                         replayed_kib=round(back.pty_bytes / KIB, 1), snapshot_kib=round(back.snapshot_bytes / KIB, 1))
                    back.close()
                    bench.clients.remove(back)


def real(args, rows):
    real_runs(args, rows, ('build', 'tui', 'flood80', 'flood200'), RINGS[:3], (('fast', None), ('20MiB/s', 20 * MIB)), 1)


def trials(args, rows):
    """Repeat the runs that decide ring_bytes: a real client on a flood."""
    real_runs(args, rows, ('flood80', 'flood200'), (256 * KIB, 512 * KIB, MIB, 2 * MIB), (('fast', None),), args.trials)


def real_runs(args, rows, loads, rings, sinks, repeats):
    import fcntl
    import termios
    for load, size, raw, (sink_name, sink_rate), trial in ((l, r, m, s, t) for l in loads for r in rings for m in (False, True) for s in sinks for t in range(repeats)):
        with Bench(args.exe, ring_bytes=size, client_backlog_bytes=size) as bench:
            pane = bench.gen(*LOADS[load])
            master, slave = os.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 50, 200, 0, 0))
            argv = [args.exe, 'attach', '--pane', pane, '--history=0', '--socket', bench.path]
            proc = subprocess.Popen(argv + (['--raw=true'] if raw else []), stdin=slave, stdout=slave, stderr=subprocess.DEVNULL,
                                    env=bench.env, start_new_session=True)
            os.close(slave)
            os.set_blocking(master, False)
            got = 0
            budget, at = 0.0, time.monotonic()

            def drain(seconds):
                nonlocal got, budget, at
                end = time.monotonic() + seconds
                while time.monotonic() < end:
                    now = time.monotonic()
                    want = MIB
                    if sink_rate:
                        budget = min(budget + sink_rate * (now - at), sink_rate * .05)
                        at = now
                        want = int(budget)
                    if want > 0:
                        select.select([master], [], [], .002)
                        try:
                            chunk = os.read(master, want)
                            got += len(chunk)
                            budget -= len(chunk) if sink_rate else 0
                        except (BlockingIOError, OSError):
                            pass
                    else:
                        time.sleep(.001)
            try:
                drain(1.0)
                before_resyncs = bench.resyncs()
                got = 0
                cpu = bench.cpu()
                bench.go(pane)
                drain(args.seconds)
                resyncs = bench.resyncs() - before_resyncs
                emit(rows, scenario='real', trial=trial, load=load, ring=size, client='raw' if raw else 'emulating', sink=sink_name,
                     sink_mib_s=round(got / args.seconds / MIB, 2), daemon_resyncs=resyncs,
                     resyncs_per_s=round(resyncs / args.seconds, 2), daemon_cpu_pct=round((bench.cpu() - cpu) / args.seconds * 100, 1))
            finally:
                proc.kill()
                proc.wait()
                os.close(master)


def memory(args, rows):
    for size in RINGS:
        with Bench(args.exe, ring_bytes=size, client_backlog_bytes=size) as bench:
            for _ in range(32):
                bench.pane(['sleep', '60'], (80, 24))
            time.sleep(.5)
            idle_rss = bench.memory()['VmRSS']
        with Bench(args.exe, ring_bytes=size, client_backlog_bytes=size) as bench:
            empty = bench.memory()['VmRSS']
            panes = [bench.pane(['sh', '-c', f'head -c {8 * MIB} /dev/zero | tr "\\0" x; exec sleep 60'], (80, 24)) for _ in range(32)]
            deadline = time.monotonic() + 30
            last = -1
            while time.monotonic() < deadline:
                rss = bench.memory()['VmRSS']
                if rss == last:
                    break
                last = rss
                time.sleep(.5)
            emit(rows, scenario='memory', panes=len(panes), ring=size, rss_empty_mib=round(empty / KIB, 1), rss_32_idle_mib=round(idle_rss / KIB, 1), rss_full_mib=round(last / KIB, 1),
                 per_pane_kib=round((last - empty) / len(panes), 1), ring_share_pct=round(size / KIB / ((last - empty) / len(panes)) * 100, 1))


def snapshot(args, rows):
    for load in ('idle', 'flood80'):
        for prefill in (0, 10000):
            for fmt_name in ('ghostty', 'vt'):
                for per_second in (0, 1, 4, 10, 30, 100):
                    with Bench(args.exe) as bench:
                        fmt = bench.ghostty if fmt_name == 'ghostty' else 'vt'
                        pane = bench.gen('flood' if load == 'flood80' else 'build', prefill, 78)
                        client = bench.client(pane, fmt=fmt, history=10000 if fmt_name == 'ghostty' else 0)
                        wait_gate(client, 60)
                        probe = Probe(bench)
                        every = [client, probe.client]
                        if load == 'flood80':
                            bench.go(pane)
                        loop(every, .2)
                        state = {'next': 0.0}

                        def tick(now):
                            probe.tick(now)
                            if per_second and now >= state['next'] and client.resync_at is None:
                                client.send(RESYNC, {'history': 10000 if fmt_name == 'ghostty' else 0})
                                state['next'] = now + 1 / per_second
                        head, cpu, snaps = client.head, bench.cpu(), client.snapshots
                        client.latencies.clear()
                        got = client.snapshot_bytes
                        loop(every, args.seconds, tick=tick)
                        count = client.snapshots - snaps
                        emit(rows, scenario='snapshot', load=load, prefill_lines=prefill, format=fmt_name, target_per_s=per_second,
                             achieved_per_s=round(count / args.seconds, 1), daemon_cpu_pct=round((bench.cpu() - cpu) / args.seconds * 100, 1),
                             produced_mib_s=round((client.head - head) / args.seconds / MIB, 2),
                             resync_to_ready_p50_ms=pct(client.latencies, .5), resync_to_ready_p99_ms=pct(client.latencies, .99),
                             snapshot_kib=round((client.snapshot_bytes - got) / count / KIB, 1) if count else None, **probe.result())


def overflow(args, rows):
    for clients, size in ((c, r) for r in (256 * KIB, MIB) for c in (0, 1, 4, 16)):
        with Bench(args.exe, ring_bytes=size, client_backlog_bytes=size) as bench:
            pane = bench.gen('flood', 10000, 78)
            fast = bench.client(pane)
            wait_gate(fast, 60)
            slow = [bench.client(pane, rate=MIB, history=10000) for _ in range(clients)]
            probe = Probe(bench)
            every = [fast, probe.client, *slow]
            loop(every, .3)
            bench.go(pane)
            loop(every, .5)
            overflows = [c.overflows for c in slow]
            for c in slow:
                c.max_freeze = 0.0
            head, cpu = fast.head, bench.cpu()
            memory_before = bench.memory()['VmRSS']
            loop(every, args.seconds * 2, tick=probe.tick)
            elapsed = args.seconds * 2
            per_client = [(c.overflows - b) / elapsed for c, b in zip(slow, overflows)]
            emit(rows, scenario='overflow', ring=size, slow_clients=clients, produced_mib_s=round((fast.head - head) / elapsed / MIB, 2),
                 daemon_cpu_pct=round((bench.cpu() - cpu) / elapsed * 100, 1),
                 max_overflow_per_client_s=round(max(per_client), 2) if per_client else 0,
                 mean_overflow_per_client_s=round(statistics.mean(per_client), 2) if per_client else 0,
                 slow_max_freeze_ms=round(max(c.max_freeze for c in slow) * 1000) if slow else None,
                 fast_overflows=fast.overflows, fast_gaps=fast.gaps,
                 rss_delta_mib=round((bench.memory()['VmRSS'] - memory_before) / KIB, 1), **probe.result())


def frames(args, rows):
    """How stale a slow reader gets frame by frame, and who waits behind it."""
    for load, rate in (('build', 64 * KIB), ('tui', 256 * KIB), ('flood200', 256 * KIB), ('flood200', MIB)):
        with Bench(args.exe) as bench:
            echo = bench.gen('echo', size=(80, 24))
            pane = bench.gen(*LOADS[load])
            client = bench.client(pane, writer=True, rate=rate)
            state = {'ready': False, 'sent': None, 'next': 0.0}
            samples = []

            def sibling(now, kind, _):
                state['ready'] = state['ready'] or kind == READY
                if kind == PTY and state['sent'] is not None:
                    samples.append(now - state['sent'])
                    state['sent'] = None

            def tick(now):
                if state['ready'] and state['sent'] is None and now >= state['next']:
                    client.send(INPUT, b'z', stream=SIBLING)
                    state['sent'] = now
                    state['next'] = now + .05
            client.on_sibling = sibling
            client.send(ATTACH, {'pane': echo, 'mode': 'emulate', 'formats': [bench.ghostty], 'history': 0,
                                 'size': {'cols': 80, 'rows': 24}}, stream=SIBLING)
            assert loop([client], until=lambda: client.ready and state['ready']), 'streams did not attach'
            loop([client], .3)
            bench.go(pane)
            loop([client], 1)
            client.max_freeze, client.max_pty_frame = 0.0, 0
            samples.clear()
            seconds = args.seconds * 7
            overflows = client.overflows
            loop([client], seconds, tick=tick)
            emit(rows, scenario='frames', load=load, reader_kib_s=rate // KIB, seconds=seconds, max_pty_frame_kib=round(client.max_pty_frame / KIB, 1),
                 max_freeze_ms=round(client.max_freeze * 1000), overflows_per_s=round((client.overflows - overflows) / seconds, 2),
                 sibling_samples=len(samples), sibling_p50_ms=pct(samples, .5), sibling_max_ms=pct(samples, 1),
                 sibling_unanswered_ms=round((time.monotonic() - state['sent']) * 1000) if state['sent'] is not None else 0)


def stalled(args, rows):
    """What a client that lags, then stops reading, keeps until it disconnects.

    The load is a TUI on the alternate screen, so the pane itself barely grows,
    and a run with no slow clients is the control. With history, the clients
    stop right at READY, while the backfill still holds their snapshot.
    """
    for size, count, history in ((256 * KIB, 0, 0), (256 * KIB, 64, 0), (MIB, 0, 0), (MIB, 64, 0), (MIB, 0, 10000), (MIB, 64, 10000)):
        with Bench(args.exe, ring_bytes=size, client_backlog_bytes=size) as bench:
            pane = bench.gen('tui', history, 60)
            watcher = bench.client(pane)
            wait_gate(watcher, 60)
            clients = [bench.client(pane, history=history) for _ in range(count)]
            every = [watcher, *clients]
            assert loop(every, until=lambda: all(c.ready for c in every)), 'clients did not attach'
            for client in clients:
                client.paused = True
            bench.go(pane)
            end = time.monotonic() + args.seconds * 2
            while not history and time.monotonic() < end:
                # Read in bursts, so the backlog nears the ring before each frame.
                loop([watcher], .7)
                now = time.monotonic()
                for client in clients:
                    client.paused = False
                    client.pump(now)
                    client.paused = True
            loop([watcher], 2)
            emit(rows, scenario='stalled', ring=size, clients=count, history=history, rss_mib=round(bench.memory()['VmRSS'] / KIB, 1),
                 largest_frame_kib=round(max((c.max_pty_frame for c in clients), default=0) / KIB, 1), watcher_overflows=watcher.overflows)


def typist(seed, seconds):
    """Key times of one person: short gaps, with word and thinking pauses."""
    rnd = random.Random(seed)
    at, keys = rnd.uniform(0, .3), []
    while at < seconds:
        keys.append(at)
        roll = rnd.random()
        at += rnd.uniform(1, 3) if roll < .04 else rnd.uniform(.3, .7) if roll < .2 else rnd.lognormvariate(-2, .4)
    return keys


def hold(args, rows):
    sizes = {'a': (120, 40), 'b': (100, 30)}
    for hold_ms in (0, 250, 500, 1000, 2000, 5000):
        with Bench(args.exe, latest_hold_ms=hold_ms, resize_coalesce_ms=0) as bench:
            pane = bench.gen('winch', 0, size=sizes['a'])
            watcher = bench.client(pane, size=sizes['a'])
            wait_gate(watcher)
            a = bench.client(pane, writer=True, size=sizes['a'], claim=True)
            b = bench.client(pane, writer=True, size=sizes['b'])
            every = [watcher, a, b]
            loop(every, until=lambda: a.ready and b.ready)
            loop(every, .1)
            # Concurrent typing and turn taking, the same seeded traces per hold.
            traces = {
                'concurrent': sorted([(t, a) for t in typist(1, args.typing)] + [(t, b) for t in typist(2, args.typing)], key=lambda x: x[0]),
            }
            turns, at, who = [], 0.0, a
            rnd = random.Random(3)
            while at < args.typing:
                span = rnd.uniform(1.5, 4)
                turns += [(at + t, who) for t in typist(rnd.randrange(1 << 30), span)]
                at += span + rnd.uniform(.2, 1)
                who = b if who is a else a
            traces['turns'] = turns
            for name, trace in traces.items():
                watcher.resizes.clear()
                start_head, start = watcher.head, time.monotonic()
                index = [0]

                def tick(now):
                    while index[0] < len(trace) and now - start >= trace[index[0]][0]:
                        trace[index[0]][1].send(INPUT, b'z')
                        index[0] += 1
                loop(every, args.typing, tick=tick)
                loop(every, .2)
                emit(rows, scenario='hold', trace=name, hold_ms=hold_ms, seconds=args.typing, keys=len(trace), flips=len(watcher.resizes),
                     flips_per_min=round(len(watcher.resizes) / args.typing * 60, 1), redraw_kib=round((watcher.head - start_head) / KIB, 1))
            for gap in (.1, .5, 1, 3):
                # A has the size; A stops; B starts typing `gap` later.
                a.send(INPUT, b'z')
                loop(every, max(.05, hold_ms / 1000 + .05))
                a.send(INPUT, b'z')
                loop(every, .1)
                a.send(INPUT, b'z')
                loop(every, gap)
                target = {'cols': sizes['b'][0], 'rows': sizes['b'][1]}
                watcher.resizes.clear()
                began = time.monotonic()
                keys = [0]
                state = {'next': began}

                def tick(now):
                    if now >= state['next']:
                        b.send(INPUT, b'z')
                        keys[0] += 1
                        state['next'] = now + .15

                def moved():
                    return any(r['cols'] == target['cols'] and r['rows'] == target['rows'] for _, r in watcher.resizes)
                ok = loop(every, tick=tick, until=moved, limit=hold_ms / 1000 + 3)
                moved_at = next((t for t, r in watcher.resizes if r['cols'] == target['cols']), None)
                emit(rows, scenario='hold', trace='takeover', hold_ms=hold_ms, gap_ms=int(gap * 1000), moved=ok,
                     delay_ms=round((moved_at - began) * 1000, 1) if moved_at else None, keys_before_move=keys[0])
                # Give the size back to A for the next gap.
                loop(every, hold_ms / 1000 + .05)
                a.send(INPUT, b'z')
                loop(every, .1)


def coalesce(args, rows):
    for prefill in (0, 10000):
        for interval_ms in (8, 16):
            for window in (0, 8, 16, 30, 50, 100, 250):
                with Bench(args.exe, resize_coalesce_ms=window) as bench:
                    pane = bench.gen('winch', prefill, size=(120, 40))
                    watcher = bench.client(pane, size=(120, 40))
                    wait_gate(watcher, 60)
                    writer = bench.client(pane, writer=True, size=(120, 40), claim=True)
                    every = [watcher, writer]
                    loop(every, until=lambda: writer.ready, limit=20)
                    loop(every, .3)
                    state = {'cols': 120, 'step': 1}
                    settles, sent, applied, used, redraw, settled_all = [], 0, 0, 0.0, 0, True
                    rnd = random.Random(interval_ms)
                    drags = 4
                    for _ in range(drags):
                        # Varied lengths, so the end of a drag falls anywhere in the window.
                        duration = args.drag * rnd.uniform(.7, 1.3)
                        watcher.resizes.clear()
                        start = time.monotonic()
                        state.update(next=start, last=None, sent=0)

                        def tick(now):
                            if now - start < duration and now >= state['next']:
                                if not 110 <= state['cols'] + state['step'] <= 190:
                                    state['step'] = -state['step']
                                state['cols'] += state['step']
                                writer.send(RESIZE, {'cols': state['cols'], 'rows': 40})
                                state['sent'] += 1
                                state['last'] = now
                                state['next'] = now + interval_ms / 1000
                        head, cpu = watcher.head, bench.cpu()
                        loop(every, duration, tick=tick)
                        final = state['cols']
                        settled = loop(every, until=lambda: watcher.resizes and watcher.resizes[-1][1]['cols'] == final, limit=2)
                        used += bench.cpu() - cpu
                        settled_all = settled_all and settled
                        if settled:
                            settles.append(watcher.resizes[-1][0] - state['last'])
                        loop(every, .25)  # the final redraw counts as bytes
                        sent += state['sent']
                        applied += len(watcher.resizes)
                        redraw += watcher.head - head
                    wall = sent * interval_ms / 1000
                    emit(rows, scenario='coalesce', prefill_lines=prefill, drag_interval_ms=interval_ms, window_ms=window, drags=drags, sent=sent, applied=applied,
                         applied_per_s=round(applied / wall, 1), settled=settled_all, settle_median_ms=pct(settles, .5), settle_max_ms=pct(settles, 1),
                         redraw_mib=round(redraw / MIB, 2), daemon_cpu_pct=round(used / wall * 100, 1))


SCENARIOS = dict(rates=rates, ring=ring, resume=resume, real=real, trials=trials, memory=memory, snapshot=snapshot, overflow=overflow, hold=hold, coalesce=coalesce, frames=frames, stalled=stalled)


def machine(exe):
    def run(*argv):
        return subprocess.run(argv, capture_output=True, text=True, timeout=10).stdout.strip()
    model = next((l.split(':', 1)[1].strip() for l in Path('/proc/cpuinfo').read_text().splitlines() if l.startswith('model name')), '?')
    return dict(cpu=model, threads=os.cpu_count(), kernel=platform.release(), python=platform.python_version(), zig=run('zig', 'version'),
                commit=run('git', '-C', str(Path(__file__).resolve().parent), 'rev-parse', '--short', 'HEAD'),
                mem_gib=round(os.sysconf('SC_PAGE_SIZE') * os.sysconf('SC_PHYS_PAGES') / 2**30, 1), exe=Path(exe).name,
                shared_machine='other agents ran builds and tests in parallel; see load per scenario')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('exe', type=lambda p: str(Path(p).resolve()))
    parser.add_argument('--only', default=','.join(SCENARIOS), help='Comma-separated scenarios')
    parser.add_argument('--seconds', type=float, default=3, help='Length of each load run')
    parser.add_argument('--trials', type=int, default=5, help='Repeats per case of the trials scenario')
    parser.add_argument('--typing', type=float, default=60, help='Length of each typing trace')
    parser.add_argument('--drag', type=float, default=2, help='Length of each window drag')
    parser.add_argument('--report', type=Path, help='Merge results into this JSON file, replacing the scenarios run')
    parser.add_argument('--max-seconds', type=int, default=3000, help='Stop the whole run after this long')
    args = parser.parse_args()
    signal.signal(signal.SIGALRM, alarm)
    # `timeout` sends this one: unwind too, so the daemon of the current run stops.
    signal.signal(signal.SIGTERM, alarm)
    signal.alarm(args.max_seconds)
    report = {'scenarios': {}}
    if args.report and args.report.exists():
        report = json.loads(args.report.read_text())
    report['machine'] = machine(args.exe)
    report['params'] = dict(seconds=args.seconds, typing=args.typing, drag=args.drag)
    for name in args.only.split(','):
        rows = []
        print(f'# {name}', file=sys.stderr, flush=True)
        load = os.getloadavg()
        began = time.monotonic()
        try:
            SCENARIOS[name](args, rows)
        except Stop as stop:
            print(f'stopped during {name}: {stop}; its rows are not in the report', file=sys.stderr, flush=True)
            return 3
        report['scenarios'][name] = dict(loadavg_before=[round(x, 2) for x in load], loadavg_after=[round(x, 2) for x in os.getloadavg()],
                                         wall_s=round(time.monotonic() - began, 1), rows=rows)
        if args.report:
            args.report.write_text(json.dumps(report, indent=1) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
