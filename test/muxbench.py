#!/usr/bin/env python3
"""Black-box benchmark of venomx against tmux, zellij and tuios.

Every multiplexer is driven the same way a user drives it: its real client
runs on a PTY that this script owns and plays the host terminal (it drains
output continuously and answers the usual terminal queries). Each pane runs
the same tiny program, so the only variable is the multiplexer.

Scenarios (each trial starts every multiplexer from scratch):
  startup   spawn client -> pane's READY text visible on the host
  memory    PSS of all the multiplexer's processes, idle and after flood
  echo      keystroke -> echoed glyph visible on the host (typing latency)
  flood     pane writes --mib MiB of text -> END marker visible (throughput),
            plus CPU seconds the multiplexer spent doing it

    zig build bench-compare -Doptimize=ReleaseFast -- --trials 5 --report out.json
    python3 test/muxbench.py --venomx zig-out/bin/venomx --data sgr
    python3 test/muxbench.py --compare old.json new.json

The host side does no rendering, so this measures the multiplexer, not your
terminal emulator. Each tool runs with its default config and layout; the pane
program is set through $SHELL. Multiplexers that are not installed are skipped.
Timing-based, so not part of `zig build test`. Use a ReleaseFast venomx.
"""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import platform
import re
import select
import shutil
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import uuid

READY, END = b'VXB-READY', b'VXB-END'

PANE = r'''
import os, sys, tty, time
mode, data = sys.argv[1], sys.argv[2]
tty.setraw(0)
os.write(1, b'\x1b[2J\x1b[H' + b'VXB-READY\r\n')
if mode == 'echo':
    n = 0
    while True:
        if not os.read(0, 1):
            break
        n += 1
        os.write(1, b'\r\nK%05d' % n)  # fresh row, unique token: no renderer can elide it
elif mode == 'flood':
    os.read(0, 1)  # gate: the harness starts the clock when it sends this byte
    with open(data, 'rb') as f:
        while chunk := f.read(65536):
            os.write(1, chunk)
    os.write(1, b'\r\n\x1b[0mVXB-END\r\n')
time.sleep(1e9)
'''


# ---------------------------------------------------------------- host side

class Host:
    """The PTY master: drains output on a thread and answers queries."""

    REPLIES = [
        (re.compile(rb'\x1b\[0?c'), b'\x1b[?62;22c'),                 # DA1
        (re.compile(rb'\x1b\[>0?c'), b'\x1b[>1;10;0c'),               # DA2
        (re.compile(rb'\x1b\[6n'), b'\x1b[1;1R'),                      # CPR
        (re.compile(rb'\x1b\[5n'), b'\x1b[0n'),                        # DSR
        (re.compile(rb'\x1b\]10;\?(\x07|\x1b\\)'), b'\x1b]10;rgb:cccc/cccc/cccc\x1b\\'),
        (re.compile(rb'\x1b\]11;\?(\x07|\x1b\\)'), b'\x1b]11;rgb:0000/0000/0000\x1b\\'),
        (re.compile(rb'\x1b\[14t'), None),                             # pixel size: filled below
        (re.compile(rb'\x1b\[16t'), b'\x1b[6;20;10t'),
        (re.compile(rb'\x1b\[18t'), None),
        (re.compile(rb'\x1b\[\?(\d+)\$p'), 'decrqm'),
    ]

    def __init__(self, fd, cols, rows):
        self.fd, self.cols, self.rows = fd, cols, rows
        self.buf = bytearray()
        self.cond = threading.Condition()
        self.closed = False
        self.t = threading.Thread(target=self._run, daemon=True)
        self.t.start()

    def _reply(self, chunk):
        for pat, rep in self.REPLIES:
            for m in pat.finditer(chunk):
                if rep is None:
                    rep_b = (b'\x1b[4;%d;%dt' % (self.rows * 20, self.cols * 10) if b'14t' in m.group(0)
                             else b'\x1b[8;%d;%dt' % (self.rows, self.cols))
                elif rep == 'decrqm':
                    rep_b = b'\x1b[?%s;0$y' % m.group(1)  # "not recognized"
                else:
                    rep_b = rep
                try:
                    os.write(self.fd, rep_b)
                except OSError:
                    pass

    def _run(self):
        while True:
            try:
                r, _, _ = select.select([self.fd], [], [], 0.5)
                if not r:
                    continue
                chunk = os.read(self.fd, 1 << 16)
            except OSError:
                chunk = b''
            if not chunk:
                with self.cond:
                    self.closed = True
                    self.cond.notify_all()
                return
            # queries can straddle reads; look at a small overlap
            self._reply(bytes(self.buf[-32:]) + chunk if len(self.buf) else chunk)
            with self.cond:
                self.buf += chunk
                self.cond.notify_all()

    def mark(self):
        with self.cond:
            return len(self.buf)

    def wait(self, token, since=0, timeout=30):
        """Seconds (monotonic perf_counter) when token appeared after offset `since`."""
        deadline = time.perf_counter() + timeout
        with self.cond:
            while True:
                i = self.buf.find(token, max(0, since - len(token)))
                if i >= 0:
                    return time.perf_counter(), i + len(token)
                left = deadline - time.perf_counter()
                if left <= 0 or self.closed:
                    tail = bytes(self.buf[-400:])
                    raise TimeoutError(f'{token!r} not seen (closed={self.closed}); tail={tail!r}')
                self.cond.wait(left)

    def send(self, data):
        os.write(self.fd, data)


# ---------------------------------------------------------- process ledger

def tagged(tag, names):
    """PIDs of multiplexer processes started by this trial (env tag + exe name)."""
    out = []
    needle = f'VXB_TAG={tag}'.encode()
    for d in os.listdir('/proc'):
        if not d.isdigit():
            continue
        try:
            with open(f'/proc/{d}/environ', 'rb') as f:
                if needle not in f.read().split(b'\0'):
                    continue
            exe = os.path.basename(os.readlink(f'/proc/{d}/exe'))
        except OSError:
            continue
        if any(exe.startswith(n) for n in names):
            out.append(int(d))
    return out


def cpu_seconds(pids):
    """On-CPU time of every thread, in ns resolution (stat's utime is 10 ms ticks)."""
    total = 0
    for p in pids:
        try:
            tasks = os.listdir(f'/proc/{p}/task')
        except OSError:
            continue
        for t in tasks:
            try:
                with open(f'/proc/{p}/task/{t}/schedstat') as f:
                    total += int(f.read().split()[0])
            except OSError:
                pass
    return total / 1e9


def pss_mib(pids):
    total = 0
    for p in pids:
        try:
            with open(f'/proc/{p}/smaps_rollup') as f:
                for line in f:
                    if line.startswith('Pss:'):
                        total += int(line.split()[1])
        except OSError:
            pass
    return total / 1024


# ---------------------------------------------------------------- adapters

class Mux:
    name = '?'
    exe_names = ()

    def __init__(self, exe, root):
        self.exe, self.root = exe, root
        self.cache = root / 'cache'  # survives trials: warm caches, like a real user's
        self.cache.mkdir(parents=True, exist_ok=True)

    def version(self):
        return subprocess.run([self.exe, '--version'], capture_output=True, text=True).stdout.strip()

    def env(self, trial_dir, prog):
        env = {k: v for k, v in os.environ.items()
               if not (k.startswith(('TMUX', 'ZELLIJ', 'VENOMX', 'TUIOS', 'XDG_')) or k.endswith('_TOKEN'))}
        run = trial_dir / 'run'
        run.mkdir(mode=0o700, exist_ok=True)
        env.update(HOME=str(trial_dir / 'home'), XDG_RUNTIME_DIR=str(run), XDG_CONFIG_HOME=str(trial_dir / 'cfg'),
                   XDG_STATE_HOME=str(trial_dir / 'state'), XDG_DATA_HOME=str(trial_dir / 'data'),
                   XDG_CACHE_HOME=str(self.cache), TMPDIR=str(run), TERM='xterm-256color', COLORTERM='truecolor',
                   SHELL=prog)  # every multiplexer's default program is the pane program
        for k in ('home', 'cfg', 'state', 'data'):
            (trial_dir / k).mkdir(exist_ok=True)
        return env

    def argv(self, prog, trial_dir, env):
        raise NotImplementedError


class Venomx(Mux):
    name, exe_names = 'venomx', ('venomx',)

    def version(self):
        return f'venomx ({self.exe})'

    def argv(self, prog, trial_dir, env):
        return [self.exe, 'new', '--name', 'bench', '--', prog]


class Tmux(Mux):
    name, exe_names = 'tmux', ('tmux',)

    def version(self):
        return subprocess.run([self.exe, '-V'], capture_output=True, text=True).stdout.strip()

    def env(self, trial_dir, prog):
        env = super().env(trial_dir, prog)
        env['TMUX_TMPDIR'] = env['XDG_RUNTIME_DIR']
        return env

    def argv(self, prog, trial_dir, env):
        return [self.exe, '-f', '/dev/null', '-L', 'bench', 'new-session', '-s', 'bench', prog]


class Zellij(Mux):
    name, exe_names = 'zellij', ('zellij',)

    def env(self, trial_dir, prog):
        env = super().env(trial_dir, prog)
        env['ZELLIJ_SOCKET_DIR'] = env['XDG_RUNTIME_DIR']
        return env

    def argv(self, prog, trial_dir, env):
        cfg = trial_dir / 'zellij.kdl'
        cfg.write_text('show_startup_tips false\nshow_release_notes false\nsession_serialization false\n'
                       'disable_session_metadata true\n')
        # Default layout (tab bar + status bar); the pane runs $SHELL.
        return [self.exe, '--config', str(cfg)]


class Tuios(Mux):
    name, exe_names = 'tuios', ('tuios',)

    def argv(self, prog, trial_dir, env):
        # An attached `tuios new` opens on a welcome screen with no window; a
        # detached one gets an initial $SHELL window. Startup covers both steps.
        return ['/bin/sh', '-c', f'"{self.exe}" new bench --detach >/dev/null && exec "{self.exe}" attach bench']


ADAPTERS = {'venomx': Venomx, 'tmux': Tmux, 'zellij': Zellij, 'tuios': Tuios}


# ------------------------------------------------------------------ trials

class Instance:
    def __init__(self, mux, mode, data, args, root):
        self.mux, self.args = mux, args
        self.tag = uuid.uuid4().hex[:12]
        self.dir = Path(tempfile.mkdtemp(prefix='t-', dir=root))
        prog = self.dir / f'pane-{mode}'
        prog.write_text(f'#!/bin/sh\nexec {sys.executable} {root / "pane.py"} {mode} {data}\n')
        prog.chmod(0o755)
        self.env = self._env(prog)
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', args.rows, args.cols, args.rows * 20, args.cols * 10))
        self.t0 = time.perf_counter()
        self.proc = subprocess.Popen(mux.argv(str(prog), self.dir, self.env), stdin=slave, stdout=slave,
                                     stderr=open(self.dir / 'client.err', 'wb'), env=self.env,
                                     start_new_session=True)
        os.close(slave)
        self.fd = master
        self.host = Host(master, args.cols, args.rows)

    def _env(self, prog):
        env = self.mux.env(self.dir, str(prog))
        env['VXB_TAG'] = self.tag
        return env

    def pids(self):
        return tagged(self.tag, self.mux.exe_names)

    def ready(self):
        try:
            t, off = self.host.wait(READY, timeout=self.args.timeout)
        except TimeoutError as e:
            err = (self.dir / 'client.err').read_bytes()[-600:]
            raise TimeoutError(f'{e}; client exit={self.proc.poll()} stderr={err!r}') from None
        return t - self.t0, off

    def settle(self, quiet=0.3, limit=5):
        """Wait until the host has seen no output for `quiet` seconds."""
        end = time.perf_counter() + limit
        last = self.host.mark()
        while time.perf_counter() < end:
            time.sleep(quiet)
            now = self.host.mark()
            if now == last:
                return
            last = now

    def close(self):
        pids = self.pids()
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for p in [self.proc.pid, *pids]:
                try:
                    os.kill(p, sig)
                except ProcessLookupError:
                    pass
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline and (self.proc.poll() is None or self.pids()):
                time.sleep(.05)
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        # pane programs (python) carry the tag too; reap them
        for p in tagged(self.tag, ('python', 'sh')):
            try:
                os.kill(p, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            os.close(self.fd)
        except OSError:
            pass
        shutil.rmtree(self.dir, ignore_errors=True)


def pct(xs, q):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(q * (len(xs) - 1))))]


def run_echo(mux, args, root, data):
    inst = Instance(mux, 'echo', data, args, root)
    try:
        startup, _ = inst.ready()
        inst.settle()
        idle = pss_mib(inst.pids())
        samples = []
        for i in range(1, args.keys + 1):
            mark = inst.host.mark()
            t = time.perf_counter()
            inst.host.send(b'a')
            seen, _ = inst.host.wait(b'K%05d' % i, since=mark, timeout=10)
            samples.append((seen - t) * 1000)
            time.sleep(args.key_gap / 1000)
        return dict(startup_ms=startup * 1000, idle_pss_mib=idle, echo_ms=samples)
    finally:
        inst.close()


def run_flood(mux, args, root, data):
    inst = Instance(mux, 'flood', data, args, root)
    try:
        inst.ready()
        inst.settle()
        pids = inst.pids()
        c0 = cpu_seconds(pids)
        mark = inst.host.mark()
        t = time.perf_counter()
        inst.host.send(b'g')
        seen, _ = inst.host.wait(END, since=mark, timeout=args.timeout * 4)
        wall = seen - t
        inst.settle(quiet=.2)
        cpu = cpu_seconds(inst.pids()) - c0
        return dict(flood_s=wall, flood_mib_s=args.mib / wall, flood_cpu_s=cpu, flood_pss_mib=pss_mib(inst.pids()))
    finally:
        inst.close()


def make_data(path, mib, kind, cols):
    target = mib << 20
    out = bytearray()
    i = 0
    width = max(20, cols - 8)
    while len(out) < target:
        if kind == 'sgr':
            words = ' '.join(f'\x1b[38;5;{(i + k) % 216 + 16}m\x1b[{1 + k % 2}mw{k:03d}\x1b[0m' for k in range(width // 6))
            out += f'{i:08d} {words}\r\n'.encode()
        else:
            out += (f'{i:08d} ' + ('lorem ipsum dolor sit amet ' * 10)[:width]).encode() + b'\r\n'
        i += 1
    path.write_bytes(bytes(out[:target]).rsplit(b'\r\n', 1)[0] + b'\r\n')


def summarize(trials):
    agg = {}
    keys = {k for t in trials for k in t}
    for k in sorted(keys):
        vals = []
        for t in trials:
            v = t.get(k)
            if isinstance(v, list):
                vals += v
            elif v is not None:
                vals.append(v)
        if vals:
            agg[k] = dict(median=statistics.median(vals), p90=pct(vals, .9), min=min(vals), max=max(vals), n=len(vals))
    return agg


METRICS = [  # key, label, unit, lower-is-better
    ('startup_ms', 'startup', 'ms', True),
    ('echo_ms', 'echo latency', 'ms', True),
    ('flood_mib_s', 'flood throughput', 'MiB/s', False),
    ('flood_cpu_s', 'flood CPU', 's', True),
    ('idle_pss_mib', 'idle memory (PSS)', 'MiB', True),
    ('flood_pss_mib', 'memory after flood', 'MiB', True),
]


def table(report, stat='median'):
    names = list(report['results'])
    w = max(18, *(len(n) for n in names)) + 2
    lines = [f'{"metric":<24}' + ''.join(f'{n:>{w}}' for n in names)]
    for key, label, unit, _ in METRICS:
        row = f'{label + " (" + unit + ")":<24}'
        for n in names:
            m = report['results'][n].get('summary', {}).get(key)
            if m is None:
                cell = report['results'][n].get('error', '—')[:w - 2] if 'error' in report['results'][n] else '—'
            elif key == 'echo_ms':
                cell = f'{m["median"]:.2f} / p90 {m["p90"]:.2f}'
            else:
                cell = f'{m[stat]:.2f}'
            row += f'{cell:>{w}}'
        lines.append(row)
    return '\n'.join(lines)


def compare(old, new):
    print(f'old: {old["when"]}  new: {new["when"]}')
    diff = {k: (old['config'].get(k), v) for k, v in new['config'].items() if old['config'].get(k) != v}
    if diff:
        print(f'WARNING: different configs, not like for like: {diff}')
    print(f'{"mux":<8}{"metric":<24}{"old":>12}{"new":>12}{"change":>10}')
    for n in new['results']:
        for key, label, unit, lower in METRICS:
            a = old['results'].get(n, {}).get('summary', {}).get(key)
            b = new['results'][n].get('summary', {}).get(key)
            if not a or not b:
                continue
            d = (b['median'] - a['median']) / a['median'] * 100 if a['median'] else 0
            worse = d > 0 if lower else d < 0
            flag = ' !' if worse and abs(d) > 10 else ''
            print(f'{n:<8}{label:<24}{a["median"]:>12.2f}{b["median"]:>12.2f}{d:>+9.1f}%{flag}')


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--mux', default='venomx,tmux,zellij,tuios', help='Comma-separated multiplexers')
    p.add_argument('--venomx', default=shutil.which('venomx'), help='venomx binary (use ReleaseFast)')
    p.add_argument('--tmux', default=shutil.which('tmux'))
    p.add_argument('--zellij', default=shutil.which('zellij'))
    p.add_argument('--tuios', default=shutil.which('tuios'))
    p.add_argument('--trials', type=int, default=5)
    p.add_argument('--keys', type=int, default=40, help='Keystrokes per echo trial')
    p.add_argument('--key-gap', type=float, default=15, help='ms between keystrokes')
    p.add_argument('--mib', type=int, default=16)
    p.add_argument('--data', choices=['ascii', 'sgr'], default='ascii')
    p.add_argument('--cols', type=int, default=200)
    p.add_argument('--rows', type=int, default=50)
    p.add_argument('--timeout', type=float, default=20)
    p.add_argument('--report', type=Path, help='Write the JSON report here')
    p.add_argument('--compare', nargs=2, type=Path, metavar=('OLD', 'NEW'), help='Diff two reports and exit')
    args = p.parse_args()
    if args.compare:
        compare(*(json.loads(f.read_text()) for f in args.compare))
        return

    # Short base path: Unix socket paths are limited to 108 bytes.
    root = Path(tempfile.mkdtemp(prefix='vxb-', dir='/tmp'))
    (root / 'pane.py').write_text(PANE)
    data = root / f'flood-{args.data}-{args.mib}.txt'
    make_data(data, args.mib, args.data, args.cols)
    report = dict(when=datetime.datetime.now().isoformat(timespec='seconds'),
                  host=dict(kernel=platform.release(), cpu=next((l.split(':', 1)[1].strip() for l in open('/proc/cpuinfo') if l.startswith('model name')), '?'),
                            cpus=os.cpu_count()),
                  config={k: v for k, v in vars(args).items() if k in ('trials', 'keys', 'key_gap', 'mib', 'data', 'cols', 'rows')},
                  results={})
    try:
        for name in args.mux.split(','):
            exe = getattr(args, name)
            if not exe:
                print(f'[{name}] not installed, skipped', file=sys.stderr)
                report['results'][name] = dict(error='not installed')
                continue
            mux = ADAPTERS[name](str(Path(exe).resolve()), root / name)
            res = report['results'][name] = dict(exe=str(exe), version=mux.version(), trials=[])
            print(f'[{name}] {res["version"]}: warmup', file=sys.stderr)
            try:
                run_echo(mux, with_args(args, keys=3), root, data)  # warm caches, first-run work
                for i in range(args.trials):
                    print(f'[{name}] trial {i + 1}/{args.trials}', file=sys.stderr)
                    t = run_echo(mux, args, root, data)
                    t.update(run_flood(mux, args, root, data))
                    res['trials'].append(t)
            except Exception as e:  # keep going with the other multiplexers
                res['error'] = f'{type(e).__name__}: {e}'
                print(f'[{name}] FAILED: {res["error"]}', file=sys.stderr)
            res['summary'] = summarize(res['trials'])
    finally:
        shutil.rmtree(root, ignore_errors=True)
    print(f'\n{args.cols}x{args.rows}, {args.trials} trials, flood {args.mib} MiB {args.data}; medians\n')
    print(table(report))
    if args.report:
        args.report.write_text(json.dumps(report, indent=1))
        print(f'\nreport: {args.report}')


def with_args(ns, **over):
    return argparse.Namespace(**{**vars(ns), **over})


if __name__ == '__main__':
    main()
