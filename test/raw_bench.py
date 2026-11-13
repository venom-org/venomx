#!/usr/bin/env python3
"""Compare cat through raw attach and directly through the same host sink.

Run a ReleaseFast binary. --render forwards both paths into the invoking
terminal; without it, this is only a PTY transport benchmark, not host
rendering acceptance. Each trial gates cat on one input byte after attach
READY; startup, snapshot and detach are excluded. No rate limiting.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import select
import signal
import statistics
import struct
import subprocess
import sys
import tempfile
import termios
import time
import tty

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('exe', type=lambda p: str(Path(p).resolve()))
parser.add_argument('--mib', type=int, default=8)
parser.add_argument('--trials', type=int, default=3)
parser.add_argument('--line-width', type=int, default=79, help='Printable bytes per CRLF line')
parser.add_argument('--render', action='store_true')
parser.add_argument('--report', type=Path, help='Save the measured JSON report')
parser.add_argument('--ring-mib', type=int, default=0, help='Override ring/backlog MiB (0 uses product defaults)')
args = parser.parse_args()
if min(args.mib, args.trials, args.line_width) < 1:
    parser.error('mib, trials and line-width must be positive')
if args.render and not os.isatty(1):
    parser.error('--render needs a host terminal on stdout')
cols, rows = os.get_terminal_size(1) if args.render else (100, 30)
READY, END = b'BENCH-READY', b'BENCH-END'
runner = "import os,subprocess,sys,tty; tty.setraw(0); os.write(1,b'BENCH-READY'); os.read(0,1); subprocess.run(['cat',sys.argv[1]],check=True); os.write(1,b'BENCH-END')"


def host_write(data):
    if args.render:
        while data:
            data = data[os.write(1, data):]


def spawn(argv, env):
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))
    p = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=subprocess.PIPE,
                         env=env, start_new_session=True)
    os.close(slave)
    return p, master


def read_until(fd, marker):
    data = bytearray()
    deadline = time.monotonic() + 300
    at = -1
    while at < 0:
        if time.monotonic() > deadline:
            raise TimeoutError((marker, len(data)))
        if not select.select([fd], [], [], .2)[0]:
            continue
        chunk = os.read(fd, 65536)
        if not chunk:
            raise EOFError(marker)
        host_write(chunk)
        search_from = max(0, len(data) - len(marker) + 1)
        data += chunk
        at = data.find(marker, search_from)
    if marker == END:
        # Extra output would make byte equality fail rather than hide loss.
        assert at + len(marker) == len(data), data[at + len(marker):]
    return data[:at]


with tempfile.TemporaryDirectory(prefix='vx-raw-bench-') as root:
    root = Path(root)
    path = str(root / 'd.sock')
    env = {k: v for k, v in os.environ.items() if not k.endswith('_TOKEN')}
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / 'cfg'), XDG_CONFIG_DIRS=str(root / 'cfg' / 'xdg'),
               XDG_STATE_HOME=str(root / 'state'), TERM='xterm-256color')
    owner = dict(env, VENOMX_TOKEN='@owner')
    if args.ring_mib:
        config = root / 'cfg' / 'venomx' / 'config.zon'
        config.parent.mkdir(parents=True)
        size = args.ring_mib * 1024 * 1024
        config.write_text(f'.{{ .pane_stream = .{{ .ring_bytes = {size}, .client_backlog_bytes = {size} }} }}')
    line = b'x' * args.line_width + b'\r\n'
    payload = (line * ((args.mib * 1024 * 1024 // len(line)) + 1))[:args.mib * 1024 * 1024]
    file = root / 'large.txt'
    file.write_bytes(payload)
    daemon = subprocess.Popen([args.exe, 'serve', '--socket', path], env=env,
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    def cli(*argv):
        return json.loads(subprocess.check_output([args.exe, *argv, '--socket', path, '--json'], env=owner))
    saved = termios.tcgetattr(1) if args.render else None
    try:
        if saved:
            attr = termios.tcgetattr(1)
            attr[1] &= ~termios.OPOST
            termios.tcsetattr(1, termios.TCSANOW, attr)
        deadline = time.monotonic() + 10
        while not Path(path).exists():
            assert time.monotonic() < deadline and daemon.poll() is None
            time.sleep(.01)
        session = cli('session', 'create')['session']
        results = {'direct': [], 'raw': []}
        for trial in range(args.trials):
            for mode in ('direct', 'raw') if trial % 2 == 0 else ('raw', 'direct'):
                if mode == 'direct':
                    proc, fd = spawn([sys.executable, '-c', runner, str(file)], env)
                else:
                    pane = cli('window', 'create', '--session', session, '--cols', str(cols), '--rows', str(rows),
                               '--argv', json.dumps([sys.executable, '-c', runner, str(file)]))['pane']
                    # Ensure READY is in the snapshot or live stream.
                    proc, fd = spawn([args.exe, 'attach', '--pane', pane, '--raw=true', '--history=0', '--socket', path], env)
                try:
                    read_until(fd, READY)
                    # READY can occur inside the VT replay rather than in a
                    # live frame. Drain its trailing state before timing cat.
                    while select.select([fd], [], [], .05)[0]:
                        host_write(os.read(fd, 65536))
                    cpu_before = sum(map(int, Path(f'/proc/{daemon.pid}/stat').read_text().split()[13:15])) / os.sysconf('SC_CLK_TCK')
                    start = time.perf_counter()
                    os.write(fd, b'x')
                    got = read_until(fd, END)
                    elapsed = time.perf_counter() - start
                    assert got == payload, (mode, len(got), len(payload))
                    results[mode].append(elapsed)
                    print(f'{mode} trial {trial + 1}: {elapsed:.6f}s daemon CPU {sum(map(int, Path(f"/proc/{daemon.pid}/stat").read_text().split()[13:15])) / os.sysconf("SC_CLK_TCK") - cpu_before:.3f}s', file=sys.stderr, flush=True)
                    if mode == 'raw':
                        os.write(fd, b'\x02d')
                    proc.wait(timeout=10)
                    assert proc.returncode == 0, proc.stderr.read()
                finally:
                    if proc.poll() is None:
                        proc.kill(); proc.wait()
                    os.close(fd)
        medians = {mode: statistics.median(times) for mode, times in results.items()}
        report = dict(bytes=len(payload), size=[cols, rows], line_width=args.line_width, ring_mib=args.ring_mib or None, render=args.render,
                      seconds=results, median_seconds=medians,
                      slowdown_percent=(medians['raw'] / medians['direct'] - 1) * 100)
    finally:
        if saved:
            termios.tcsetattr(1, termios.TCSANOW, saved)
        daemon.send_signal(signal.SIGINT)
        _, err = daemon.communicate(timeout=10)
        assert daemon.returncode == 0, err
if args.report:
    args.report.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
