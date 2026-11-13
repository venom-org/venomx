#!/usr/bin/env python3
"""Keystroke-to-echo latency through an emulating `venomx attach`.

One window runs a raw echo program that answers every byte with `\\r` and
that byte, so each keystroke changes one cell: the typing case. The attach
client runs on a PTY of --cols x --rows. Each trial writes one key to the
client and times until the echoed key appears on the client's stdout.
Startup, the snapshot and the first frames are excluded.

    python3 test/echo_bench.py zig-out/bin/venomx --cols 200 --rows 50

--max-ms fails the run when the median exceeds it (regression gate).
--split N splits the window into N panes so the host shows several panes.
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

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('exe', type=lambda p: str(Path(p).resolve()))
parser.add_argument('--cols', type=int, default=200)
parser.add_argument('--rows', type=int, default=50)
parser.add_argument('--trials', type=int, default=60)
parser.add_argument('--split', type=int, default=1, help='Panes in the window (filled with text)')
parser.add_argument('--raw', action='store_true', help='Measure `attach --pane --raw=true` instead')
parser.add_argument('--max-ms', type=float, help='Fail when the median exceeds this')
args = parser.parse_args()

# Bytes that never occur in vaxis cursor/SGR/mode sequences, so the first
# one after a write is the echoed key and not part of an escape sequence.
KEYS = b'abcdefgijknopsvwxyz'
ECHO = ("import os,sys,tty; tty.setraw(0); os.write(1,b'ECHO-READY')\n"
        "while True:\n b=os.read(0,1)\n if not b: break\n os.write(1,b'\\r'+b)\n")
FILL = "import sys,time; sys.stdout.write(('filler text '*40+'\\n')*200); sys.stdout.flush(); time.sleep(1e9)"


def wait_for(fd, marker, timeout=20):
    data = bytearray()
    deadline = time.monotonic() + timeout
    while marker not in data:
        left = deadline - time.monotonic()
        if left <= 0:
            raise TimeoutError(marker)
        if select.select([fd], [], [], left)[0]:
            data += os.read(fd, 65536)
    return data


def drain(fd, quiet=.3):
    while select.select([fd], [], [], quiet)[0]:
        if not os.read(fd, 65536):
            return


with tempfile.TemporaryDirectory(prefix='vx-echo-bench-') as root:
    root = Path(root)
    path = str(root / 'd.sock')
    env = {k: v for k, v in os.environ.items() if not k.endswith('_TOKEN')}
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / 'cfg'), XDG_CONFIG_DIRS=str(root / 'cfg' / 'xdg'),
               XDG_STATE_HOME=str(root / 'state'), TERM='xterm-256color')
    owner = dict(env, VENOMX_TOKEN='@owner')
    daemon = subprocess.Popen([args.exe, 'serve', '--socket', path], env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)

    def cli(*argv):
        return json.loads(subprocess.check_output([args.exe, *argv, '--socket', path, '--json'], env=owner))

    proc = fd = None
    try:
        deadline = time.monotonic() + 10
        while not Path(path).exists():
            assert time.monotonic() < deadline and daemon.poll() is None, 'daemon did not start'
            time.sleep(.01)
        session = cli('session', 'create')['session']
        created = cli('window', 'create', '--session', session, '--cols', str(args.cols), '--rows', str(args.rows),
                      '--argv', json.dumps([sys.executable, '-c', ECHO]))
        pane = created['pane']
        for i in range(args.split - 1):
            cli('pane', 'split', '--pane', pane, '--axis', 'cols' if i % 2 == 0 else 'rows', '--argv', json.dumps([sys.executable, '-c', FILL]))
        argv = ['attach', '--pane', pane, '--raw=true'] if args.raw else ['attach', '--session', session]
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', args.rows, args.cols, 0, 0))
        proc = subprocess.Popen([args.exe, *argv, '--socket', path], stdin=slave, stdout=slave,
                                stderr=subprocess.PIPE, env=env, start_new_session=True)
        os.close(slave)
        fd = master
        if args.raw:
            wait_for(fd, b'ECHO-READY')
        drain(fd, 1.0)
        samples = []
        for i in range(args.trials):
            key = KEYS[i % len(KEYS):][:1]
            start = time.perf_counter()
            os.write(fd, key)
            wait_for(fd, key, timeout=10)
            samples.append((time.perf_counter() - start) * 1000)
            drain(fd, .02)
        median = statistics.median(samples)
        report = dict(mode='raw' if args.raw else 'session', size=[args.cols, args.rows], panes=args.split,
                      trials=len(samples), median_ms=round(median, 3),
                      p90_ms=round(sorted(samples)[int(len(samples) * .9) - 1], 3), max_ms=round(max(samples), 3))
        print(json.dumps(report))
    finally:
        if proc is not None and proc.poll() is None:
            proc.kill()
            proc.wait()
        if fd is not None:
            os.close(fd)
        daemon.send_signal(signal.SIGINT)
        try:
            daemon.wait(timeout=10)
        except subprocess.TimeoutExpired:
            daemon.kill()
if args.max_ms is not None and median > args.max_ms:
    sys.exit(f'median echo latency {median:.2f} ms exceeds {args.max_ms} ms')
