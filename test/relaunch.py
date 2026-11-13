#!/usr/bin/env python3
"""`pane.relaunch` of restored archive panes.

Runs relaunch checks against the real
binary: real CLI and socket clients, no TTY (stdin is /dev/null), isolated
XDG_RUNTIME_DIR/XDG_CONFIG_HOME/XDG_STATE_HOME. Archives come from a real
clean checkpoint and an explicit restore. Every daemon this test starts is
killed in `finally`; the test fails if a daemon or a relaunched child of ours
is left behind.
"""
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

EXE = str(Path(sys.argv[1]).resolve())
TIMEOUT = 15
ROOT = Path(os.path.realpath(tempfile.mkdtemp(prefix='vx-relaunch-')))
RUN = ROOT / 'run'
SOCKET = RUN / 'venom' / 'venomx.sock'


def until(fn, timeout=TIMEOUT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('condition did not become true')


def ours():
    """Live processes (daemon or children) that carry this test's root."""
    found = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            environ = (entry / 'environ').read_bytes()
            state = (entry / 'stat').read_text().rsplit(')', 1)[1].split()[0]
        except OSError:
            continue
        if str(ROOT).encode() in environ and state != 'Z':
            found.append(int(entry.name))
    return found


def children():
    """Processes started by the daemon as pane children (they carry a pane token)."""
    out = []
    for pid in ours():
        try:
            if b'VENOMX_PRINCIPAL=' in Path(f'/proc/{pid}/environ').read_bytes():
                out.append(pid)
        except OSError:
            pass
    return out


RUN.mkdir(mode=0o700)
(ROOT / 'cfg' / 'venomx').mkdir(parents=True)
(ROOT / 'cfg' / 'venomx' / 'config.zon').write_text('.{ .recovery = .{ .enabled = true, .interval_ms = 3600000 } }\n')
ENV = {k: v for k, v in os.environ.items() if not k.startswith('VENOMX_') and not k.endswith('_TOKEN')}
ENV.update(HOME=str(ROOT), XDG_RUNTIME_DIR=str(RUN), XDG_CONFIG_HOME=str(ROOT / 'cfg'), XDG_CONFIG_DIRS=str(ROOT / 'cfg' / 'xdg'), XDG_STATE_HOME=str(ROOT / 'state'))
# These cases test grants and namespaces, so isolation is on.
(Path(ROOT) / 'cfg' / 'xdg' / 'venomx').mkdir(parents=True, exist_ok=True); (Path(ROOT) / 'cfg' / 'xdg' / 'venomx' / 'defaults.zon').write_text('.{ .grants = .{ .isolation = true } }\n')


def cli(*args, code=0, token='@owner'):
    e = dict(ENV)
    if token:
        e['VENOMX_TOKEN'] = token
    r = subprocess.run([EXE, *args, '--json'], stdin=subprocess.DEVNULL, env=e, capture_output=True, text=True, timeout=TIMEOUT)
    assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
    if args[0] == 'events':
        return [json.loads(line) for line in r.stdout.splitlines()]
    return json.loads(r.stdout) if r.stdout.strip() else None


def err(*args, code, **kw):
    return cli(*args, code=code, **kw)['error']


def relaunch(pane, argv, *extra, **kw):
    return ['pane', 'relaunch', f'--pane={pane}', f'--argv={json.dumps(argv)}', *extra]


def token(grants):
    return cli('grant', 'issue', f'--grants={json.dumps(grants)}')['token']


def events_after(mark):
    return [e for e in cli('events', '--follow=false', f"--after={mark['source']}:{mark['seq']}") if e['type'] != 'stream.checkpoint']


def last_event():
    return cli('events', '--follow=false')[-1]


def principals():
    return sorted(p['principal'] for p in cli('grant', 'list')['principals'])


class Wire:
    def __init__(self, tok, binary=False):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(TIMEOUT)
        self.sock.connect(str(SOCKET))
        self.io = self.sock.makefile('rwb', buffering=0)
        params = {'proto': [1], 'caps': ['cancel', 'venomx.pane_stream'], 'max_frame': 1048576, 'auth': {'token': tok}}
        if binary:
            self.io.write(b'\xf5')
            self.frame(1, 0, params)
            assert self.recv()[0] == 2
        else:
            self.send({'id': 0, 'verb': 'hello', 'params': params})
            assert 'ok' in json.loads(self.io.readline())

    def send(self, value):
        self.io.write(json.dumps(value, separators=(',', ':')).encode() + b'\n')

    def frame(self, kind, stream, payload):
        payload = json.dumps(payload, separators=(',', ':')).encode()
        self.io.write(struct.pack('>HII', kind, stream, len(payload)) + payload)

    def exact(self, n):
        out = b''
        while len(out) < n:
            chunk = self.io.read(n - len(out))
            assert chunk, 'closed'
            out += chunk
        return out

    def recv(self):
        kind, stream, n = struct.unpack('>HII', self.exact(10))
        return kind, stream, self.exact(n)

    def attach(self, pane, resume=None):
        """Returns the frame kinds up to EXIT, or the error frame's payload."""
        params = {'pane': pane, 'mode': 'emulate', 'formats': ['vt'], 'size': {'cols': 80, 'rows': 24}, 'history': 0}
        if resume:
            params['resume'] = resume
        self.frame(0x100, 1, params)
        kinds = []
        while True:
            kind, _, data = self.recv()
            if kind == 3:
                return json.loads(data)
            kinds.append(kind)
            if kind == 0x109:
                return kinds

    def close(self):
        self.io.close()
        self.sock.close()


daemon = None


def serve():
    global daemon
    daemon = subprocess.Popen([EXE, 'serve', '--json'], stdin=subprocess.DEVNULL, env=ENV, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    until(lambda: daemon.poll() is not None or subprocess.run([EXE, 'ping', '--json'], stdin=subprocess.DEVNULL, env=ENV, capture_output=True, timeout=TIMEOUT).returncode == 0)
    assert daemon.poll() is None, daemon.communicate()
    return (RUN / 'venom' / 'venomx.owner').read_text().strip()


def stop():
    global daemon
    daemon.send_signal(signal.SIGTERM)
    out, errs = daemon.communicate(timeout=TIMEOUT)
    assert daemon.returncode == 0, (daemon.returncode, out, errs)
    daemon = None


try:
    # ---- Archives from a real clean checkpoint, restored into a fresh daemon.
    serve()
    cli('session', 'create', '--name=work')
    first = cli('window', 'create', '--session=s0', '--name=shell', '--argv=["/bin/sh"]')
    for axis in ('cols', 'rows', 'cols', 'rows'):
        cli('pane', 'split', f"--pane={first['pane']}", f'--axis={axis}', '--argv=["/bin/sh"]')
    stop()
    owner = serve()
    [checkpoint] = [c['checkpoint'] for c in cli('recovery', 'list')['checkpoints'] if c['status'] == 'valid']
    restored = cli('recovery', 'restore', f'--checkpoint={checkpoint}')
    archives = [m['current'] for m in restored['panes']]
    assert len(archives) == 5, restored
    wid = restored['windows'][0]['current']
    before = cli('window', 'get', f'--window={wid}')
    assert before['revision'] == 1
    # An ordinary exited pane in the same daemon.
    plain = cli('window', 'create', '--session=s0', '--argv=["/bin/sh","-c","exit 0"]')
    until(lambda: {p['pane']: p for p in cli('pane', 'list')['panes']}[plain['pane']]['exited'])
    print('ok setup: restored archives', archives)

    # ---- Parameters and grants: spawn AND write, both before archive lookup.
    a0 = archives[0]
    e = err(*relaunch(a0, ['/bin/true'], '--ack-orphans=false'), code=2)
    assert e['code'] == 'invalid_params.ack_orphans' and e['data'] == {'param': 'ack_orphans'}, e
    assert err(*relaunch('p999', ['/bin/true'], '--ack-orphans=false'), code=2)['code'] == 'invalid_params.ack_orphans'
    assert err(*relaunch(a0, ['/bin/true']), code=2)['code'].startswith('invalid_params')
    assert err(*relaunch(a0, ['/bin/true'], '--ack-orphans=true'), code=4, token=None)['code'] == 'denied.spawn'
    only_spawn = token([{'right': 'spawn', 'scope': f'pane:{a0}'}])
    only_write = token([{'right': 'write', 'scope': f'pane:{a0}'}])
    assert err(*relaunch(a0, ['/bin/true'], '--ack-orphans=true'), code=4, token=only_spawn)['code'] == 'denied.write'
    assert err(*relaunch(a0, ['/bin/true'], '--ack-orphans=true'), code=4, token=only_write)['code'] == 'denied.spawn'
    # write is checked before lookup: a missing pane outside the write scope is denied, not disclosed.
    wide_spawn = token([{'right': 'spawn', 'scope': '*'}, {'right': 'write', 'scope': f'pane:{a0}'}])
    assert err(*relaunch('p999', ['/bin/true'], '--ack-orphans=true'), code=4, token=wide_spawn)['code'] == 'denied.write'
    both = token([{'right': 'spawn', 'scope': f'pane:{a0}'}, {'right': 'write', 'scope': f'pane:{a0}'}])
    # Excessive child grants: the caller cannot delegate more than it holds.
    mark = last_event()
    assert err(*relaunch(a0, ['/bin/true'], '--ack-orphans=true', '--grants=[{"right":"admin","scope":"*"}]'), code=4, token=both)['code'] == 'denied.delegation'
    assert err(*relaunch(a0, ['/bin/true'], '--ack-orphans=true', f'--grants=[{{"right":"write","scope":"pane:{archives[1]}"}}]'), code=4, token=both)['code'] == 'denied.delegation'
    assert events_after(mark) == []
    # Ordinary exited panes are not archives.
    assert err(*relaunch(plain['pane'], ['/bin/true'], '--ack-orphans=true'), code=5)['code'] == 'conflict.not_archive'
    assert err(*relaunch('p999', ['/bin/true'], '--ack-orphans=true'), code=3)['code'] == 'not_found.pane'
    print('ok params / spawn and write checks / delegation / not_archive')

    # ---- Vanished executable: unavailable.spawn, archive and tree intact, no leak.
    gone = ROOT / 'vanished-program'
    gone.write_bytes(Path('/bin/true').read_bytes())
    gone.chmod(0o700)
    gone.unlink()
    mark = last_event()
    held = principals()
    kids = children()
    e = err(*relaunch(a0, [str(gone)], '--ack-orphans=true'), code=6)
    assert e['code'] == 'unavailable.spawn', e
    assert str(gone) not in json.dumps(e)
    assert cli('window', 'get', f'--window={wid}') == before
    listing = {p['pane']: p for p in cli('pane', 'list')['panes']}
    assert listing[a0]['recovery']['checkpoint'] == checkpoint and listing[a0]['exited']
    assert events_after(mark) == [], events_after(mark)
    assert principals() == held, (principals(), held)
    assert children() == kids
    print('ok vanished executable')

    # ---- Success: new pane in place, new principal and token, one commit.
    watch = Wire(owner, binary=True)
    assert watch.attach(a0)[-1] == 0x109  # an archive reports EXIT
    marker = ROOT / 'launched-a0'
    who = ROOT / 'whoami-a0'
    script = f'echo x >> {marker}; "{EXE}" whoami --json > {who}.tmp && mv {who}.tmp {who}; exec sleep 60'
    mark = last_event()
    got = cli(*relaunch(a0, ['/bin/sh', '-c', script], '--ack-orphans=true'), token=both)
    assert set(got) == {'pane', 'window', 'session', 'principal', 'pid'}, got
    new = got['pane']
    assert new not in archives and new != plain['pane'] and got['window'] == wid and got['session'] == before['session']
    assert got['principal'] not in held
    me = json.loads(until(lambda: who.exists() and who.read_text()))
    assert me['principal'] == got['principal'] and me['kind'] == 'pane' and me['pane'] == new, me
    after = cli('window', 'get', f'--window={wid}')
    assert after['revision'] == before['revision'] + 1
    assert after['nodes'] == [dict(n, pane=new) if n.get('pane') == a0 else n for n in before['nodes']], after
    # The relaunched pane's sampled process follows in a later tick.
    evs = [e for e in events_after(mark) if e['type'] != 'pane.process_changed']
    assert [e['type'] for e in evs] == ['pane.removed', 'pane.created', 'window.layout_changed', 'principal.created'], evs
    assert [e['seq'] for e in evs] == list(range(evs[0]['seq'], evs[0]['seq'] + 4))
    assert evs[3]['data']['pane'] == new and evs[3]['data']['kind'] == 'pane'
    assert evs[0]['data']['pane'] == a0 and evs[1]['data']['pane'] == new and evs[2]['data']['revision'] == after['revision']
    listing = {p['pane']: p for p in cli('pane', 'list')['panes']}
    assert a0 not in listing and 'recovery' not in listing[new] and not listing[new]['exited']
    # A relaunch creates a pane with its own argv0.
    assert listing[new]['argv0'] == 'sh' and evs[1]['data']['argv0'] == 'sh', (listing[new], evs[1])
    cap = cli('pane', 'capture', f'--pane={new}')
    assert 'recovery' not in cap and cap['cols'] == 80 and cap['rows'] == 24
    # The archive's stream closes with pane_removed.
    while True:
        kind, _, data = watch.recv()
        if kind == 6:
            assert json.loads(data) == {'reason': 'pane_removed'}, data
            break
    watch.close()
    # Retry after success names the removed archive and cannot launch again.
    assert err(*relaunch(a0, ['/bin/sh', '-c', script], '--ack-orphans=true'), code=3, token=both)['code'] == 'not_found.pane'
    assert err(*relaunch(new, ['/bin/true'], '--ack-orphans=true'), code=5)['code'] == 'conflict.not_archive'
    # The old pane ID cannot resume (or reach) the new process.
    s = Wire(owner, binary=True)
    failure = s.attach(a0, resume={'source': mark['source'], 'offset': 0})
    assert isinstance(failure, dict) and 'not_found.pane' in json.dumps(failure), failure
    s.close()
    time.sleep(.3)
    assert marker.read_text() == 'x\n'
    print('ok relaunch / new principal / one commit / pane_removed / retry / no resume')

    # ---- Rapid exit, then retry: still at most one launch.
    a1 = archives[1]
    rapid = ROOT / 'launched-a1'
    got = cli(*relaunch(a1, ['/bin/sh', '-c', f'echo x >> {rapid}'], '--ack-orphans=true'))
    until(lambda: {p['pane']: p for p in cli('pane', 'list')['panes']}[got['pane']]['exited'])
    assert err(*relaunch(a1, ['/bin/sh', '-c', f'echo x >> {rapid}'], '--ack-orphans=true'), code=3)['code'] == 'not_found.pane'
    assert rapid.read_text() == 'x\n'
    print('ok rapid exit')

    # ---- Concurrent relaunch of one archive: exactly one launch.
    a2 = archives[2]
    racer = ROOT / 'launched-a2'
    e = dict(ENV, VENOMX_TOKEN='@owner')
    procs = [subprocess.Popen([EXE, *relaunch(a2, ['/bin/sh', '-c', f'echo x >> {racer}; exec sleep 60'], '--ack-orphans=true'), '--json'], stdin=subprocess.DEVNULL, env=e, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for _ in range(8)]
    outcomes = []
    for p in procs:
        out, _ = p.communicate(timeout=TIMEOUT)
        outcomes.append((p.returncode, json.loads(out)))
    wins = [o for rc, o in outcomes if rc == 0]
    assert len(wins) == 1, outcomes
    assert all(rc == 3 and o['error']['code'] == 'not_found.pane' for rc, o in outcomes if rc != 0), outcomes
    time.sleep(.3)
    assert racer.read_text() == 'x\n'
    print('ok concurrent')

    # ---- Lost reply: the client goes away before reading; a retry cannot launch again.
    a3 = archives[3]
    lost = ROOT / 'launched-a3'
    w = Wire(owner)
    w.send({'id': 1, 'verb': 'pane.relaunch', 'params': {'pane': a3, 'argv': ['/bin/sh', '-c', f'echo x >> {lost}; exec sleep 60'], 'ack_orphans': True}})
    w.close()
    until(lambda: a3 not in {p['pane'] for p in cli('pane', 'list')['panes']})
    assert err(*relaunch(a3, ['/bin/sh', '-c', f'echo x >> {lost}'], '--ack-orphans=true'), code=3)['code'] == 'not_found.pane'
    time.sleep(.3)
    assert lost.read_text() == 'x\n'
    assert archives[4] in {p['pane'] for p in cli('pane', 'list')['panes']}  # untouched archive remains
    print('ok lost reply')

    stop()
    assert not children(), 'relaunched children survived a clean shutdown'
finally:
    if daemon and daemon.poll() is None:
        daemon.kill()
        daemon.wait()
    left = ours()
    for pid in left:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    subprocess.run(['rm', '-rf', str(ROOT)])
    assert not left, f'processes left behind: {left}'
print('relaunch: all cases passed')
