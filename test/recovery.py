#!/usr/bin/env python3
"""Durable session restore and crash recovery.

Runs recovery checks against the real binary built with the
test seam (`-Dtest-seams=true`): real CLI and socket clients, no TTY (stdin is
/dev/null), isolated XDG_RUNTIME_DIR/XDG_CONFIG_HOME/XDG_STATE_HOME per case.
The seam injects interrupted writes (VENOMX_TEST_RECOVERY_FAULT), offsets the
wall clock (VENOMX_TEST_CLOCK_OFFSET_MS) and logs every signal the daemon
sends (VENOMX_TEST_SIGNAL_LOG). Every daemon and helper process this test
starts is killed in `finally`; the test fails if a daemon is left behind.
"""
import hashlib
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
ROOT = Path(os.path.realpath(tempfile.mkdtemp(prefix='vx-rec-')))
HELPERS = []  # helper PIDs we started; only these are ever signalled
TEXT = 'ready-é✓'


def until(fn, timeout=TIMEOUT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('condition did not become true')


def alive(pid):
    try:
        state = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()[0]
    except OSError:
        return False
    return state != 'Z'


def daemons(root):
    found = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            argv = (entry / 'cmdline').read_bytes().split(b'\0')
            environ = (entry / 'environ').read_bytes()
        except OSError:
            continue
        if b'serve' in argv and str(root).encode() in environ and alive(int(entry.name)):
            found.append(int(entry.name))
    return found


class Case:
    count = 0

    def __init__(self, recovery=None, extra=None):
        Case.count += 1
        self.root = ROOT / f'c{Case.count}'
        (self.root / 'run').mkdir(parents=True, mode=0o700)
        (self.root / 'cfg' / 'venomx').mkdir(parents=True)
        self.socket = self.root / 'run' / 'venom' / 'venomx.sock'
        self.signals = self.root / 'signals.log'
        if recovery is not None:
            self.write_config(recovery)
        env = {k: v for k, v in os.environ.items() if not k.startswith('VENOMX_') and not k.endswith('_TOKEN')}
        env.update(HOME=str(self.root), XDG_RUNTIME_DIR=str(self.root / 'run'), XDG_CONFIG_HOME=str(self.root / 'cfg'), XDG_CONFIG_DIRS=str(self.root / 'cfg' / 'xdg'),
                   XDG_STATE_HOME=str(self.root / 'state'), VENOMX_TEST_SIGNAL_LOG=str(self.signals),
                   SECRET_ENV_MARKER='env-secret-5f1c')
        self.env = env
        self.extra = extra or {}
        self.daemon = None

    def write_config(self, recovery):
        fields = ', '.join(f'.{k} = {v}' for k, v in recovery.items())
        (self.root / 'cfg' / 'venomx' / 'config.zon').write_text('.{ .recovery = .{ ' + fields + ' } }\n')

    @property
    def store(self):
        key = hashlib.sha256(str(self.socket).encode()).hexdigest()
        return self.root / 'state' / 'venomx' / 'recovery' / key

    def files(self, temporary=False):
        """The store's file names. A running daemon writes each checkpoint to a
        `.tmp-` file and renames it into place, so a listing can catch one in
        flight; those are left out unless `temporary` asks for them."""
        if not self.store.exists():
            return []
        return sorted(p.name for p in self.store.iterdir() if temporary or not p.name.startswith('.tmp-'))

    def run(self, *args, code=0, token='@owner', env=None):
        e = dict(env or self.env)
        if token:
            e['VENOMX_TOKEN'] = token
        r = subprocess.run([EXE, *args, '--json'], stdin=subprocess.DEVNULL, env=e, capture_output=True, text=True, timeout=TIMEOUT)
        assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
        assert not r.stderr, (args, r.stderr)
        if args[0] == 'events':
            return [json.loads(line) for line in r.stdout.splitlines()]
        return json.loads(r.stdout) if r.stdout.strip() else None

    def err(self, *args, code, **kw):
        return self.run(*args, code=code, **kw)['error']['code']

    def serve(self, **extra):
        env = dict(self.env, **self.extra, **extra)
        self.daemon = subprocess.Popen([EXE, 'serve', '--json'], stdin=subprocess.DEVNULL, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        # A SIGKILLed predecessor leaves a stale socket path: wait for a reply.
        def ready():
            if self.daemon.poll() is not None:
                return True
            r = subprocess.run([EXE, 'ping', '--json'], stdin=subprocess.DEVNULL, env=self.env, capture_output=True, timeout=TIMEOUT)
            return r.returncode == 0
        until(ready)
        assert self.daemon.poll() is None, self.daemon.communicate()
        self.token = (self.root / 'run' / 'venom' / 'venomx.owner').read_text().strip()
        return self.daemon

    def stop(self, sig=signal.SIGTERM, expect=0):
        """Stops only the daemon this case started; returns elapsed seconds."""
        started = time.monotonic()
        self.daemon.send_signal(sig)
        out, err = self.daemon.communicate(timeout=TIMEOUT)
        self.last_stderr = err
        elapsed = time.monotonic() - started
        if expect is not None:
            assert self.daemon.returncode == expect, (self.daemon.returncode, out, err)
        until(lambda: not self.socket.exists() or sig == signal.SIGKILL)
        self.daemon = None
        return elapsed

    def kill(self):
        if self.daemon and self.daemon.poll() is None:
            self.daemon.kill()
            self.daemon.wait()

    def signal_log(self):
        return self.signals.read_text().split('\n')[:-1] if self.signals.exists() else []

    def window(self, session, argv, **kw):
        args = ['window', 'create', f'--session={session}', f'--argv={json.dumps(argv)}'] + [f'--{k}={v}' for k, v in kw.items()]
        return self.run(*args)

    def envelope(self, payload, fmt=1):
        text = json.dumps(payload, ensure_ascii=False, separators=(',', ':'))
        return json.dumps({'format': fmt, 'payload': text, 'sha256': hashlib.sha256(text.encode()).hexdigest()}, ensure_ascii=False, separators=(',', ':')) + '\n'

    def fixture(self, ident, generation, captured=None, mutate=None, raw=None, mode=0o600):
        self.store.mkdir(parents=True, exist_ok=True, mode=0o700)
        for d in (self.store, self.store.parent, self.store.parent.parent):
            d.chmod(0o700)
        payload = {'checkpoint': ident, 'generation': generation, 'socket': str(self.socket), 'uid': os.getuid(),
                   'captured_at': captured or iso(time.time() - 60), 'shutdown': 'open',
                   'sessions': [{'session': 's0', 'name': 'fixture'}],
                   'windows': [{'window': 'w0', 'session': 's0', 'name': 'shell', 'revision': 1, 'nodes': [{'kind': 'pane', 'pane': 'p0'}]}],
                   'panes': [{'pane': 'p0', 'window': 'w0', 'session': 's0', 'cols': 80, 'rows': 24, 'state': 'running', 'text': {'availability': 'omitted'}}]}
        if mutate:
            mutate(payload)
        path = self.store / f'{ident}.json'
        path.write_text(raw if raw is not None else self.envelope(payload))
        path.chmod(mode)
        return path


def iso(t):
    return time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(t)) + '.%03dZ' % int((t % 1) * 1000)


def ident(n):
    return 'c%08x-0000-4000-8000-%012x' % (n, n)


def payload_of(path):
    return json.loads(json.loads(path.read_text())['payload'])


def cid(listing, status='valid'):
    return [c['checkpoint'] for c in listing['checkpoints'] if c['status'] == status]


def helper(argv):
    p = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    HELPERS.append(p.pid)
    return p


class Stream:
    """Minimal binary pane-stream client."""

    def __init__(self, path, token):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(TIMEOUT)
        self.sock.connect(str(path))
        self.io = self.sock.makefile('rwb', buffering=0)
        self.io.write(b'\xf5')
        self.frame(1, 0, {'proto': [1], 'caps': ['cancel', 'venomx.pane_stream'], 'max_frame': 1048576, 'auth': {'token': token}})
        assert self.recv()[0] == 2

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
        params = {'pane': pane, 'mode': 'emulate', 'formats': ['vt'], 'size': {'cols': 80, 'rows': 24}, 'history': 0}
        if resume:
            params['resume'] = resume
        self.frame(0x100, 1, params)
        kinds = []
        attached = None
        while True:
            kind, _, data = self.recv()
            assert kind != 3, data
            kinds.append(kind)
            if kind == 0x101:
                attached = json.loads(data)
            if kind == 0x109:
                return attached, kinds, json.loads(data)

    def close(self):
        self.io.close()
        self.sock.close()


ENABLED = {'enabled': 'true', 'interval_ms': 3600000}
cases = []


def case(**kw):
    c = Case(**kw)
    cases.append(c)
    return c


try:
    # ---- Defaults / disabled: no writes, no restore, persistent zero-session unchanged.
    c = case()
    c.serve()
    c.run('session', 'create', '--name=plain')
    assert c.run('recovery', 'list') == {'checkpoints': []}
    assert c.err('recovery', 'checkpoint', code=6) == 'unavailable.recovery_disabled'
    assert c.err('recovery', 'restore', f'--checkpoint={ident(1)}', code=6) == 'unavailable.recovery_disabled'
    # Grants: unknown callers cannot reach any recovery verb or learn existence.
    for args in (['list'], ['checkpoint'], ['inspect', f'--checkpoint={ident(1)}'], ['restore', f'--checkpoint={ident(1)}'], ['forget', f'--checkpoint={ident(1)}']):
        assert c.err('recovery', *args, code=4, token=None) == 'denied.admin', args
    assert c.err('recovery', 'inspect', '--checkpoint=../../etc/passwd', code=2) == 'invalid_params.checkpoint'
    c.stop()
    assert not (c.root / 'state' / 'venomx').exists(), 'disabled daemon created a store'
    print('ok defaults/disabled')

    # ---- Untouched empty start: enabled, no mutation -> no checkpoint on shutdown.
    c = case(recovery=dict(ENABLED, interval_ms=1000))
    c.serve()
    time.sleep(1.3)
    c.stop()
    assert c.files() == [], c.files()
    # After the first mutation the interval writes open checkpoints by itself.
    c.serve()
    c.run('session', 'create', '--name=periodic')
    until(lambda: c.files(), timeout=5)
    [f] = c.files()
    assert payload_of(c.store / f)['shutdown'] == 'open'
    time.sleep(1.2)
    assert c.files() == [f], 'an unchanged tree is not rewritten'
    c.stop(signal.SIGKILL, expect=None)
    print('ok untouched empty start / periodic')

    # ---- Clean restart: topology, known exits, empty containers; zero processes on restore.
    c = case(recovery=ENABLED)
    c.serve()
    exe = c.root / 'vanishing-sleep'
    exe.write_bytes(Path('/bin/sleep').read_bytes())
    exe.chmod(0o700)
    c.run('session', 'create', '--name=work')                       # s0
    c.run('session', 'create', '--name=empty')                      # s1 stays empty
    shell = c.window('s0', ['/bin/sh'], name='shell')               # w0 p0 (running)
    c.run('pane', 'split', f"--pane={shell['pane']}", '--axis=cols', '--argv=["/bin/sh","-c","exit 3"]')       # p1 exits 3
    c.run('pane', 'split', f"--pane={shell['pane']}", '--axis=rows', f'--argv={json.dumps([str(exe), "100", "argv-secret-9a2b"])}')  # p2
    c.window('s0', ['/bin/sh', '-c', 'exit 0'], name='gone')        # w1 p3, removed below -> empty window
    until(lambda: all(p['exited'] for p in c.run('pane', 'list')['panes'] if p['pane'] in ('p1', 'p3')))
    c.run('pane', 'remove', '--pane=p3')
    before = {w: c.run('window', 'get', f'--window={w}') for w in ('w0', 'w1')}
    old_token = c.token
    old_event = c.run('events', '--follow=false', token=None)[-1]
    elapsed = c.stop()
    assert elapsed < 4.5, elapsed  # enabled budget: 2000 ms termination + 2000 ms persistence
    for pid in (shell['pid'],):
        assert not alive(pid), 'child survived clean shutdown'
    files = c.files()
    assert len(files) == 1 and files[0].endswith('.json'), files
    clean = payload_of(c.store / files[0])
    assert clean['shutdown'] == 'clean' and all(p['state'] == 'exited' for p in clean['panes'])
    raw = (c.store / files[0]).read_bytes()
    for secret in (old_token.encode(), b'argv-secret-9a2b', b'env-secret-5f1c', str(c.root / 'cfg').encode(), b'VENOMX_TOKEN'):
        assert secret not in raw, secret
    assert oct((c.store / files[0]).stat().st_mode & 0o777) == '0o600' and oct(c.store.stat().st_mode & 0o777) == '0o700'
    # Restart: nothing is restored implicitly; vanished executables do not matter.
    exe.unlink()
    c.signals.write_text('')
    c.serve()
    assert c.run('session', 'list') == {'sessions': []}
    listing = c.run('recovery', 'list')
    [checkpoint] = cid(listing)
    assert c.run('recovery', 'inspect', f'--checkpoint={checkpoint}') == {'checkpoint': checkpoint, 'generation': 1, 'shutdown': 'clean', 'sessions': 2, 'windows': 2, 'panes': 3, 'text_panes': 0, 'expired_text_panes': 0}
    assert c.err('recovery', 'restore', f'--checkpoint={checkpoint}', code=4, token=old_token) == 'denied.token'
    # Fresh daemon source: the old cursor gets a source_changed snapshot.
    stale = c.run('events', '--follow=false', f"--after={old_event['source']}:{old_event['seq']}", token=None)
    assert stale[0]['type'] == 'state.snapshot' and 'source_changed' in json.dumps(stale[0]) and stale[0]['source'] != old_event['source']
    c.run('session', 'create', '--name=burn')                       # consumes s0 in the new daemon
    c.run('session', 'remove', '--session=s0')
    mark = c.run('events', '--follow=false', token=None)[-1]
    restored = c.run('recovery', 'restore', f'--checkpoint={checkpoint}')
    assert restored['sessions'] == [{'previous': 's0', 'current': 's1'}, {'previous': 's1', 'current': 's2'}], restored
    assert [m['previous'] for m in restored['panes']] == ['p0', 'p1', 'p2']
    pmap = {m['previous']: m['current'] for m in restored['panes']}
    wmap = {m['previous']: m['current'] for m in restored['windows']}
    assert c.run('session', 'list')['sessions'] == [{'session': 's1', 'name': 'work'}, {'session': 's2', 'name': 'empty'}]
    for old, new in wmap.items():
        got = c.run('window', 'get', f'--window={new}')
        assert got['revision'] == 1 and got['name'] == before[old]['name']
        want = [dict(n, pane=pmap[n['pane']]) if n['kind'] == 'pane' else n for n in before[old]['nodes']]
        assert got['nodes'] == want, (got, want)
    panes = {p['pane']: p for p in c.run('pane', 'list')['panes']}
    assert all(p['exited'] for p in panes.values())
    meta = panes[pmap['p1']]['recovery']
    assert meta == {'checkpoint': checkpoint, 'previous_pane': 'p1', 'process_state': 'exited', 'text_state': 'omitted', 'cut_rows': 0}
    cap = c.run('pane', 'capture', f"--pane={pmap['p1']}")
    assert cap['exit_code'] == 3 and cap['recovery']['process_state'] == 'exited'
    cap = c.run('pane', 'capture', f"--pane={pmap['p0']}")
    assert cap['signal'] == 'SIGHUP' and 'exit_code' not in cap  # killed by the clean shutdown
    # Restore executed and signalled nothing.
    assert c.signal_log() == [], c.signal_log()
    events = [e for e in c.run('events', '--follow=false', f"--after={mark['source']}:{mark['seq']}", token=None) if e['type'] != 'stream.checkpoint']
    types = [e['type'] for e in events]
    assert types == ['session.created'] * 2 + ['window.created'] * 2 + ['pane.created'] * 3 + ['pane.exited'] * 3 + ['recovery.restored'], types
    # Checkpoints keep no argv, so a restored pane has no argv0.
    assert all('argv0' not in p for p in panes.values()), panes
    assert all('argv0' not in e['data'] for e in events if e['type'] == 'pane.created'), events
    snap = c.run('events', '--follow=false', token=None)[0]
    assert all('argv0' not in json.loads(e['content']) for e in snap['data']['entities'] if e['entity_type'] == 'pane'), snap
    assert events[-1]['data'] == {'checkpoint': checkpoint, 'cleanup_unverified': True}, events[-1]
    assert [e['data'].get('exit_code') for e in events if e['type'] == 'pane.exited'] == [None, 3, 1], events  # p2's sleep rejects its marker argument
    # Old stream offsets: no resume into a mapped archive; snapshot, READY, EXIT.
    s = Stream(c.socket, c.token)
    attached, kinds, exit_frame = s.attach(pmap['p1'], resume={'source': old_event['source'], 'offset': 0})
    assert attached['resumed'] is False and 0x103 in kinds and exit_frame.get('exit_code') == 3, (attached, kinds, exit_frame)
    s.close()
    # Duplicate restore (a retried lost reply) fails on the nonempty tree.
    assert c.err('recovery', 'restore', f'--checkpoint={checkpoint}', code=5) == 'conflict.not_empty'
    report = c.run('doctor', code=0)
    blob = json.dumps(report)
    assert 'cleanup_unverified=true' in blob and 'argv-secret' not in blob and c.token not in blob
    c.stop()
    print('ok clean restart')

    # ---- Forced SIGKILL: last durable generation restores; later mutations lost.
    c = case(recovery=ENABLED)
    c.serve()
    pidfile = c.root / 'escaped.pid'
    c.run('session', 'create', '--name=crash')
    w = c.window('s0', ['/bin/sh', '-c', f'setsid sleep 60 </dev/null >/dev/null 2>&1 & echo $! > {pidfile}; exec sleep 60'])
    c.run('pane', 'split', f"--pane={w['pane']}", '--axis=rows', '--argv=["/bin/sh","-c","exit 7"]')
    until(lambda: pidfile.exists() and pidfile.read_text().strip())
    escaped = int(pidfile.read_text())
    HELPERS.append(escaped)
    until(lambda: c.run('pane', 'list')['panes'][1]['exited'])
    first = c.run('recovery', 'checkpoint')
    assert first['generation'] == 1
    c.run('session', 'create', '--name=lost')
    unrelated = helper(['sleep', '60'])
    c.stop(signal.SIGKILL, expect=None)
    c.signals.write_text('')
    c.serve()
    [only] = cid(c.run('recovery', 'list'))
    assert only == first['checkpoint']
    assert payload_of(c.store / f'{only}.json')['shutdown'] == 'open'
    restored = c.run('recovery', 'restore', f'--checkpoint={only}')
    assert [x['name'] for x in c.run('session', 'list')['sessions']] == ['crash']
    panes = c.run('pane', 'list')['panes']
    assert [p['recovery']['process_state'] for p in panes] == ['interrupted', 'exited']
    cap = c.run('pane', 'capture', f"--pane={panes[0]['pane']}")
    assert cap['exited'] and 'exit_code' not in cap and 'signal' not in cap
    assert c.run('pane', 'capture', f"--pane={panes[1]['pane']}")['exit_code'] == 7
    s = Stream(c.socket, c.token)
    _, kinds, exit_frame = s.attach(panes[0]['pane'])
    assert set(exit_frame) == {'offset'}, exit_frame
    s.close()
    # Escaped descendants and unrelated processes are never adopted or signalled.
    time.sleep(.3)
    assert alive(escaped) and alive(unrelated.pid)
    assert c.signal_log() == [], c.signal_log()
    c.stop(signal.SIGKILL, expect=None)
    print('ok forced SIGKILL / orphans')

    # ---- Interrupted writes: the prior generation survives, nothing false is acknowledged.
    c = case(recovery=ENABLED)
    c.serve()
    c.run('session', 'create', '--name=durable')
    good = c.run('recovery', 'checkpoint')['checkpoint']
    c.stop(signal.SIGKILL, expect=None)
    for fault in ('before_write', 'short_write', 'fsync', 'rename', 'dir_fsync'):
        c.serve(VENOMX_TEST_RECOVERY_FAULT=fault)
        c.run('session', 'create', '--name=attempt')
        assert c.err('recovery', 'checkpoint', code=6) == 'unavailable.recovery_io', fault
        assert not [f for f in c.files(temporary=True) if f.startswith('.tmp-')], (fault, c.files(temporary=True))
        valid = cid(c.run('recovery', 'list'))
        assert good in valid, (fault, valid)
        assert len(valid) == (2 if fault == 'dir_fsync' else 1), (fault, valid)  # visible-but-unsynced may survive
        blob = json.dumps(c.run('doctor', code=1))
        assert 'unavailable.recovery_io' in blob, blob
        c.stop(signal.SIGKILL, expect=None)
        if fault == 'dir_fsync':
            for extra in valid:
                if extra != good:
                    (c.store / f'{extra}.json').unlink()
    # A failed final checkpoint is an operational shutdown failure.
    c.serve(VENOMX_TEST_RECOVERY_FAULT='rename')
    c.run('session', 'create', '--name=final')
    daemon = c.daemon
    c.stop(expect=None)
    assert daemon.returncode != 0, 'a failed final checkpoint must fail shutdown'
    assert [f[:-5] for f in c.files()] == [good], c.files()
    print('ok interrupted writes')

    # ---- A failed text export omits that pane's text only: the checkpoint (topology) is still
    # written by explicit, periodic and final checkpoints, and doctor reports it.
    exp = dict(ENABLED, interval_ms=1000, terminal_text='.plain')
    c = case(recovery=exp)
    c.serve(VENOMX_TEST_RECOVERY_FAULT='text_export')
    c.run('session', 'create', '--name=exportfail')
    w = c.window('s0', ['/bin/sh', '-c', f"printf '%s\\n' '{TEXT}'; exec sleep 60"], cols=20, rows=4)
    until(lambda: TEXT in c.run('pane', 'capture', f"--pane={w['pane']}")['text'])
    until(lambda: c.files())  # the periodic writer wrote despite the failing export
    explicit = c.run('recovery', 'checkpoint')['checkpoint']
    body = payload_of(c.store / f'{explicit}.json')
    assert [p['pane'] for p in body['panes']] == [w['pane']] and body['windows'] and body['sessions'], body
    assert body['panes'][0]['text'] == {'availability': 'omitted'}, body['panes'][0]['text']
    assert TEXT not in json.dumps(body)
    doc = c.run('doctor', code=0)
    blob = json.dumps(doc)
    assert '1 pane(s) export failed' in blob and 'text last omitted at' in blob and 'last error none' in blob, blob
    assert any(r['id'] == 'recovery.writes' and r['status'] == 'warn' for r in (doc.get('results') or doc.get('checks') or [])), blob
    time.sleep(3.5)  # several periodic captures with the same failing pane
    before = set(c.files())
    c.stop()  # SIGTERM: exits 0 and writes the final clean checkpoint
    final = [f for f in c.files() if f not in before]
    assert final, ('no final checkpoint', c.files())
    last = max(final, key=lambda f: payload_of(c.store / f)['generation'])
    fin = payload_of(c.store / last)
    assert fin['shutdown'] == 'clean' and fin['panes'][0]['text'] == {'availability': 'omitted'}, fin
    # A one-off failure is not silent: the daemon log names the pane and the error.
    assert 'text export failed' in c.last_stderr and w['pane'] in c.last_stderr and 'Backend' in c.last_stderr, c.last_stderr
    assert c.last_stderr.count('text export failed') == 1, ('a persistent failure logs once', c.last_stderr)
    # Over-budget text is omitted too: counted, logged once, sticky in doctor after the budget is raised.
    c = case(recovery=dict(exp, text_max_rows=1))
    c.serve()
    c.run('session', 'create', '--name=budget')
    w = c.window('s0', ['/bin/sh', '-c', f"printf '%s\\n' '{TEXT}'; exec sleep 60"], cols=20, rows=4)
    first = c.run('recovery', 'checkpoint')['checkpoint']
    assert payload_of(c.store / f'{first}.json')['panes'][0]['text'] == {'availability': 'omitted'}
    doc = c.run('doctor', code=0)
    assert any(r['id'] == 'recovery.writes' and r['status'] == 'warn' and '1 over budget' in r['message'] for r in (doc.get('results') or doc.get('checks') or [])), doc
    time.sleep(2.5)
    c.run('config', 'set', '--key=recovery.text_max_rows', '--value=100')
    c.run('config', 'reload')
    time.sleep(1.5)  # settings reach the recovery module on the next tick
    good = c.run('recovery', 'checkpoint')['checkpoint']
    assert payload_of(c.store / f'{good}.json')['panes'][0]['text']['availability'] == 'plain', (payload_of(c.store / f'{good}.json')['panes'][0]['text'], c.run('config', 'get', '--key=recovery.text_max_rows'))
    doc = c.run('doctor', code=0)
    rw = [r for r in (doc.get('results') or doc.get('checks') or []) if r['id'] == 'recovery.writes'][0]
    assert rw['status'] == 'ok' and 'text last omitted at' in rw['message'] and 'text omitted now' not in rw['message'], rw
    c.stop()
    assert c.last_stderr.count('over budget') == 1, ('over budget logs once', c.last_stderr)
    # Healthy writes carry no omitted-text clause.
    c = case(recovery=ENABLED)
    c.serve()
    c.run('session', 'create', '--name=healthy')
    c.run('recovery', 'checkpoint')
    assert 'text omitted' not in json.dumps(c.run('doctor', code=0))
    c.stop()
    print('ok failed text export')

    # ---- Floats are checkpointed and restored as float archives; popups never are.
    c = case(recovery=ENABLED)
    c.serve()
    c.run('session', 'create', '--name=floats')                                         # s0
    tiled = c.window('s0', ['/bin/sleep', '100'], name='main')                          # w0 p0
    HELPERS.append(tiled['pid'])
    for argv, extra in ((['/bin/sleep', '101'], ['--preset=venom.settings', '--width=50%', '--anchor=top_left', '--x=-2', '--title=logs', '--tags=[{"key":"role","value":"log"}]']),  # p1
                        (['/bin/sleep', '102'], [])):                                     # p2
        made = c.run('pane', 'float', '--window=w0', f'--argv={json.dumps(argv)}', *extra)
        HELPERS.append(made['pid'])
    c.run('pane', 'raise', '--pane=p1')                                                 # p1 above p2
    # A popup through a presentation client's own ticket.
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(TIMEOUT)
    client.connect(str(c.socket))
    rpc = client.makefile('rwb', buffering=0)

    def call(verb, params):
        rpc.write(json.dumps({'id': 1, 'verb': verb, 'params': params}).encode() + b'\n')
        return json.loads(rpc.readline())
    assert 'ok' in call('hello', {'proto': [1], 'caps': ['cancel'], 'max_frame': 1048576, 'auth': {'token': c.token}})
    ticket = call('popup.ticket', {'session': 's0'})['ok']['ticket']
    popup = call('pane.popup', {'ticket': ticket, 'argv': ['/bin/sleep', '103']})['ok']   # p3
    HELPERS.append(popup['pid'])
    assert {p['pane']: p['layer'] for p in c.run('pane', 'list')['panes']} == {'p0': 'tile', 'p1': 'float', 'p2': 'float', 'p3': 'popup'}
    written = c.run('recovery', 'checkpoint')['checkpoint']
    saved = json.loads((c.store / f'{written}.json').read_text())
    assert saved['format'] == 3, saved['format']
    body = json.loads(saved['payload'])
    assert [p['pane'] for p in body['panes']] == ['p0', 'p1', 'p2'], 'a popup was written'
    by = {p['pane']: p for p in body['panes']}
    assert 'layer' not in by['p0'] and 'float' not in by['p0']
    assert by['p1']['layer'] == 'float' and by['p1']['float'] == {'preset': 'venom.settings', 'width': '50%', 'anchor': 'top_left', 'x': -2, 'title': 'logs', 'z': by['p1']['float']['z']}, by['p1']
    assert by['p2']['float'] == {'z': by['p2']['float']['z']} and by['p2']['float']['z'] < by['p1']['float']['z']
    assert body['windows'][0]['nodes'] == [{'kind': 'pane', 'pane': 'p0'}]
    # Tags are written, the daemon-set owner included.
    assert by['p1']['tags'] == [{'key': 'owner', 'value': 'venomx'}, {'key': 'role', 'value': 'log'}], by['p1']
    assert by['p0']['tags'] == [{'key': 'owner', 'value': 'venomx'}], by['p0']
    client.close()
    c.stop()
    # The restored spec resolves against the restoring daemon's presets.
    fields = ', '.join(f'.{k} = {v}' for k, v in ENABLED.items())
    (c.root / 'cfg' / 'venomx' / 'config.zon').write_text('.{ .recovery = .{ ' + fields + ' }, .floats = .{ .presets = .{ .@"venom.settings" = .{ .height = "70%" } } } }\n')
    c.serve()
    c.run('session', 'create', '--name=burn')                                           # consumes s0
    c.window('s0', ['/bin/sh', '-c', 'exit 0'])
    c.run('pane', 'float', '--window=w0', '--argv=["/bin/sh","-c","exit 0"]')          # consumes z 1
    c.run('session', 'remove', '--session=s0', '--recursive=true')
    until(lambda: c.run('session', 'list') == {'sessions': []})
    newest = max((x for x in c.run('recovery', 'list')['checkpoints'] if x['status'] == 'valid'), key=lambda x: x['generation'])
    restored = c.run('recovery', 'restore', f"--checkpoint={newest['checkpoint']}")
    pmap = {m['previous']: m['current'] for m in restored['panes']}
    assert sorted(pmap) == ['p0', 'p1', 'p2'], pmap
    snapshot = c.run('events', '--follow=false', token=None)[0]
    assert snapshot['type'] == 'state.snapshot', snapshot

    def entity(pane):
        [e] = [e for e in snapshot['data']['entities'] if e['resource'] == f'pane:{pane}']
        return e['content'] if isinstance(e['content'], dict) else json.loads(e['content'])
    tile, top, low = (entity(pmap[k]) for k in ('p0', 'p1', 'p2'))
    assert tile['layer'] == 'tile' and 'float' not in tile
    assert top['layer'] == 'float' and low['layer'] == 'float' and top['recovery']['previous_pane'] == 'p1'
    tags = {p['pane']: p['tags'] for p in c.run('pane', 'list')['panes']}
    assert tags[pmap['p1']] == [{'key': 'owner', 'value': 'venomx'}, {'key': 'role', 'value': 'log'}], tags
    assert top['float']['preset'] == 'venom.settings' and top['float']['width'] == '50%' and top['float']['anchor'] == 'top_left' and top['float']['x'] == -2 and top['float']['title'] == 'logs'
    assert top['float']['height'] == '70%' and low['float']['width'] == '60%', (top, low)  # fields not saved come from the current config
    assert (low['float']['z'], top['float']['z']) == (2, 3), (low, top)  # fresh, above the live counter, saved order
    window = c.run('window', 'get', f"--window={restored['windows'][0]['current']}")
    assert window['nodes'] == [{'kind': 'pane', 'pane': pmap['p0']}], window
    assert c.err('pane', 'place', f"--pane={pmap['p1']}", '--tile={}', code=5) == 'conflict.layer'
    # Relaunch keeps a float archive in the float layer with its spec and z.
    mark = c.run('events', '--follow=false')[-1]
    relaunched = c.run('pane', 'relaunch', f"--pane={pmap['p1']}", '--argv=["/bin/sleep","104"]', '--ack-orphans=true')
    HELPERS.append(relaunched['pid'])
    after = [e for e in c.run('events', '--follow=false', f"--after={mark['source']}:{mark['seq']}") if e['type'] not in ('stream.checkpoint', 'pane.process_changed')]
    # principal.created announces the new pane's principal after its events.
    assert [e['type'] for e in after] == ['pane.removed', 'pane.created', 'principal.created'], [e['type'] for e in after]  # no window.layout_changed
    created = after[1]['data']
    assert created['layer'] == 'float' and created['float']['preset'] == 'venom.settings' and created['float']['z'] == top['float']['z'], created
    assert c.run('window', 'get', f"--window={restored['windows'][0]['current']}")['nodes'] == window['nodes']
    assert {p['pane']: p['layer'] for p in c.run('pane', 'list')['panes']}[relaunched['pane']] == 'float'
    c.stop(signal.SIGKILL, expect=None)
    print('ok floats restore as float archives; popups are never written')

    # ---- A resized split keeps its ratio across checkpoint and restore (format 3).
    c = case(recovery=ENABLED)
    c.serve()
    c.run('session', 'create', '--name=ratios')                                         # s0
    left = c.window('s0', ['/bin/sleep', '100'])                                        # w0 p0
    HELPERS.append(left['pid'])
    right = c.run('pane', 'split', f"--pane={left['pane']}", '--axis=cols', '--argv=["/bin/sleep","101"]')  # p1
    HELPERS.append(right['pid'])
    assert c.run('pane', 'resize', f"--pane={left['pane']}", '--direction=right', '--cells=10')['moved'] > 0
    nodes = c.run('window', 'get', '--window=w0')['nodes']
    ratio = nodes[0]['ratio']
    written = c.run('recovery', 'checkpoint')['checkpoint']
    saved = json.loads((c.store / f'{written}.json').read_text())
    assert saved['format'] == 3, saved['format']
    assert json.loads(saved['payload'])['windows'][0]['nodes'] == nodes, saved
    c.stop()
    c.serve()
    newest = max((x for x in c.run('recovery', 'list')['checkpoints'] if x['status'] == 'valid'), key=lambda x: x['generation'])
    restored = c.run('recovery', 'restore', f"--checkpoint={newest['checkpoint']}")
    pmap = {m['previous']: m['current'] for m in restored['panes']}
    window = c.run('window', 'get', f"--window={restored['windows'][0]['current']}")
    assert window['nodes'] == [{'kind': 'split', 'axis': 'cols', 'first': 1, 'second': 2, 'ratio': ratio}, {'kind': 'pane', 'pane': pmap['p0']}, {'kind': 'pane', 'pane': pmap['p1']}], window
    c.stop()
    print('ok split ratios survive checkpoint and restore')

    # ---- Corrupt / partial / version / limits / filesystem security.
    c = case(recovery=dict(ENABLED, max_checkpoint_bytes=65536, max_checkpoints=100))
    good = c.fixture(ident(1), 1)
    c.fixture(ident(2), 2, raw=c.envelope({'x': 1}).replace('"format":1', '"format":4'))
    trunc = c.fixture(ident(3), 3)
    trunc.write_text(trunc.read_text()[:40])
    bad = c.fixture(ident(4), 4)
    bad.write_text(bad.read_text().replace('fixture', 'Fixture'))  # checksum mismatch
    c.fixture(ident(5), 5)
    c.fixture(ident(6), 5)  # duplicate generation
    c.fixture(ident(7), 7, captured=iso(time.time() + 3600))
    c.fixture(ident(8), 8, raw='[' * 40 + ']' * 40)
    c.fixture(ident(9), 9, mutate=lambda p: p['sessions'].append({'session': 's0', 'name': 'dup'}))
    c.fixture(ident(10), 10, mutate=lambda p: p['panes'][0].update(argv=['sh']))
    c.fixture(ident(11), 11, raw='x' * 70000)
    c.fixture(ident(12), 12, mode=0o644)
    c.fixture(ident(13), 13, mutate=lambda p: p['windows'][0]['nodes'].append({'kind': 'pane', 'pane': 'p0'}))
    os.symlink(good, c.store / f'{ident(14)}.json')
    os.link(c.fixture(ident(15), 15), c.store / 'hardlink-other-name')
    (c.store / '.tmp-00000000-0000-4000-8000-000000000000').write_text('partial')
    (c.store / '.tmp-00000000-0000-4000-8000-000000000000').chmod(0o600)
    c.serve()
    assert not any(f.startswith('.tmp-') for f in c.files(temporary=True)), 'safe temporary not removed at startup'
    statuses = {x['checkpoint']: x['status'] for x in c.run('recovery', 'list')['checkpoints']}
    want = {1: 'valid', 2: 'incompatible', 3: 'corrupt', 4: 'corrupt', 5: 'corrupt', 6: 'corrupt', 7: 'future', 8: 'corrupt', 9: 'corrupt', 10: 'corrupt', 11: 'corrupt', 12: 'unsafe', 13: 'corrupt', 14: 'unsafe', 15: 'unsafe'}
    assert statuses == {ident(k): v for k, v in want.items()}, statuses
    order = [x['checkpoint'] for x in c.run('recovery', 'list')['checkpoints']]
    assert order[0] == ident(1)  # decodable generations first
    for n, code, exit_code in ((4, 'conflict.checkpoint_corrupt', 5), (5, 'conflict.checkpoint_corrupt', 5), (2, 'unsupported.checkpoint_format', 10),
                               (7, 'conflict.checkpoint_expired', 5), (8, 'unsupported.checkpoint_size', 10), (11, 'unsupported.checkpoint_size', 10),
                               (12, 'unavailable.recovery_io', 6), (14, 'unavailable.recovery_io', 6)):
        assert c.err('recovery', 'restore', f'--checkpoint={ident(n)}', code=exit_code) == code, n
        assert c.run('session', 'list') == {'sessions': []}  # failed restore publishes nothing
    assert c.err('recovery', 'inspect', f'--checkpoint={ident(99)}', code=3) == 'not_found.checkpoint'
    # The corrupt newest file never silently selects an older one; explicit selection works.
    assert c.run('recovery', 'restore', f'--checkpoint={ident(1)}')['sessions'] == [{'previous': 's0', 'current': 's0'}]
    # A format-1 archive has no saved tags: it gets the restoring caller's owner.
    assert [p['tags'] for p in c.run('pane', 'list')['panes']] == [[{'key': 'owner', 'value': 'venomx'}]]
    assert c.run('recovery', 'forget', f'--checkpoint={ident(4)}') == {}
    assert c.err('recovery', 'forget', f'--checkpoint={ident(14)}', code=6) == 'unavailable.recovery_io'
    assert (c.store / f'{ident(14)}.json').is_symlink() and good.exists()
    assert oct((c.store / f'{ident(12)}.json').stat().st_mode & 0o777) == '0o644'  # never chmodded into safety
    c.stop(signal.SIGKILL, expect=None)
    # A permissive store directory is unsafe: no traversal, no repair.
    c.store.chmod(0o755)
    c.serve()
    assert c.err('recovery', 'list', code=6) == 'unavailable.recovery_io'
    assert oct(c.store.stat().st_mode & 0o777) == '0o755'
    c.stop(signal.SIGKILL, expect=None)
    print('ok corrupt/version/limits/filesystem')

    # ---- Valid checkpoint rows can still fail literal hydration.
    # A leading combining mark is plain UTF-8, but cannot become a cell.
    # Exercise rejection in either screen or history, after a good pane has
    # already hydrated, and pin the blank fallback's public archive metadata.
    for bad_part in ('screen', 'history'):
        c = case(recovery=dict(ENABLED, terminal_text='.plain'))

        def rejected_text(p):
            p['windows'][0]['nodes'] = [
                {'kind': 'split', 'axis': 'cols', 'first': 1, 'second': 2},
                {'kind': 'pane', 'pane': 'p0'}, {'kind': 'pane', 'pane': 'p1'}]
            saved = iso(time.time() - 60)
            expires = iso(time.time() + 3600)
            p['panes'] = [dict(p['panes'][0], pane=f'p{i}', cols=20, rows=2,
                               text={'availability': 'plain', 'saved_at': saved,
                                     'expires_at': expires, 'screen': [TEXT, ''],
                                     'history': ['old output']}) for i in range(2)]
            p['panes'][1]['text'][bad_part][0] = '\u0301a'

        path = c.fixture(ident(1), 1, mutate=rejected_text)
        original = path.read_bytes()
        c.serve()
        restored = c.run('recovery', 'restore', f'--checkpoint={ident(1)}')
        pmap = {m['previous']: m['current'] for m in restored['panes']}
        assert set(pmap) == {'p0', 'p1'}, restored
        window = c.run('window', 'get', f"--window={restored['windows'][0]['current']}")
        assert window['nodes'] == [
            {'kind': 'split', 'axis': 'cols', 'first': 1, 'second': 2},
            {'kind': 'pane', 'pane': pmap['p0']}, {'kind': 'pane', 'pane': pmap['p1']}], window
        for old, state in (('p0', 'plain'), ('p1', 'omitted')):
            cap = c.run('pane', 'capture', f'--pane={pmap[old]}')
            assert (cap['cols'], cap['rows']) == (20, 2), cap
            assert cap['recovery']['text_state'] == state, cap
            assert TEXT in cap['text'] if old == 'p0' else not cap['text'].strip(), cap
        listed = {p['pane']: p for p in c.run('pane', 'list')['panes']}
        assert listed[pmap['p1']]['recovery']['text_state'] == 'omitted', listed
        snapshot = c.run('events', '--follow=false')[0]
        entity = next(e for e in snapshot['data']['entities'] if e['resource'] == f"pane:{pmap['p1']}")
        content = entity['content']
        if isinstance(content, str):
            content = json.loads(content)
        assert content['recovery']['text_state'] == 'omitted', content
        assert path.read_bytes() == original, 'restore rewrote the checkpoint'
        again = c.run('recovery', 'checkpoint')['checkpoint']
        panes = payload_of(c.store / f'{again}.json')['panes']
        assert panes[0]['text']['availability'] == 'plain', panes
        assert panes[1]['text'] == {'availability': 'omitted'}, panes
        c.stop(signal.SIGKILL, expect=None)
    print('ok rejected text restores blank; other panes and topology survive')

    # ---- Mixed-mode rows hydrate with cuts, reported outside cells.
    for history in (False, True):
        c = case(recovery=dict(ENABLED, terminal_text='.plain'))

        def cut_text(p):
            p['windows'][0]['nodes'] = [
                {'kind': 'split', 'axis': 'cols', 'first': 1, 'second': 2},
                {'kind': 'pane', 'pane': 'p0'}, {'kind': 'pane', 'pane': 'p1'}]
            # venom-term's bounded mixed-mode fixture: flag, Hangul vowel,
            # emoji and spaces, from a row that switched mode 2027 mid-row.
            row = '🇺🇸ᅡ👩   '
            p['panes'] = [dict(p['panes'][0], pane=f'p{i}', cols=7, rows=1,
                               text={'availability': 'plain', 'saved_at': iso(time.time() - 60),
                                     'expires_at': iso(time.time() + 3600),
                                     'screen': [row if i == 0 else 'exact'],
                                     'history': [row] if history and i == 0 else []})
                          for i in range(2)]

        path = c.fixture(ident(1), 1, mutate=cut_text)
        original = path.read_bytes()
        c.serve()
        restored = c.run('recovery', 'restore', f'--checkpoint={ident(1)}')
        pmap = {m['previous']: m['current'] for m in restored['panes']}
        expected = 2 if history else 1
        listed = {p['pane']: p for p in c.run('pane', 'list')['panes']}
        for old, count in (('p0', expected), ('p1', 0)):
            cap = c.run('pane', 'capture', f'--pane={pmap[old]}')
            assert cap['recovery']['text_state'] == 'plain', cap
            assert cap['recovery']['cut_rows'] == count, cap
            assert listed[pmap[old]]['recovery']['cut_rows'] == count, listed
            assert cap['text'].strip(), cap
        snapshot = c.run('events', '--follow=false')[0]
        entity = next(e for e in snapshot['data']['entities'] if e['resource'] == f"pane:{pmap['p0']}")
        content = entity['content']
        if isinstance(content, str):
            content = json.loads(content)
        assert content['recovery']['cut_rows'] == expected, content
        check = next(r for r in c.run('doctor')['checks'] if r['id'] == 'recovery.archives')
        assert check['status'] == 'warn' and f'cut_rows={expected}' in check['message'], check
        assert path.read_bytes() == original, 'restore rewrote the checkpoint'
        c.stop(signal.SIGKILL, expect=None)
    print('ok cut rows reported in archive metadata and doctor')

    # ---- Text / expiry / retention / off transition.
    text = dict(ENABLED, terminal_text='.plain', max_checkpoints=2)
    c = case(recovery=text)
    c.serve()
    c.run('session', 'create', '--name=text')
    w = c.window('s0', ['/bin/sh', '-c', f"printf '%s\\n' '{TEXT}'; exec sleep 60"], cols=20, rows=4)
    until(lambda: TEXT in c.run('pane', 'capture', f"--pane={w['pane']}")['text'])
    ids = [c.run('recovery', 'checkpoint')['checkpoint'] for _ in range(3)]
    assert sorted(cid(c.run('recovery', 'list'))) == sorted(ids[1:]), 'count retention keeps the newest generations'
    cp = ids[-1]
    assert c.run('recovery', 'inspect', f'--checkpoint={cp}')['text_panes'] == 1
    original = payload_of(c.store / f'{cp}.json')['panes'][0]['text']
    assert original['availability'] == 'plain' and len(original['screen']) == 4 and original['screen'][0].rstrip() == TEXT
    c.stop(signal.SIGKILL, expect=None)
    c.serve()
    restored = c.run('recovery', 'restore', f'--checkpoint={cp}')
    pane = restored['panes'][0]['current']
    cap = c.run('pane', 'capture', f'--pane={pane}')
    assert TEXT in cap['text'] and cap['recovery']['text_state'] == 'plain' and cap['cols'] == 20 and cap['rows'] == 4
    # Recheckpointing an archive never renews its text lifetime.
    again = c.run('recovery', 'checkpoint')['checkpoint']
    rechk = payload_of(c.store / f'{again}.json')['panes'][0]
    assert rechk['text']['saved_at'] == original['saved_at'] and rechk['text']['expires_at'] == original['expires_at'] and rechk['previous_state'] == 'interrupted'
    c.stop(signal.SIGKILL, expect=None)
    # Expired text (clock two days ahead): topology restores, text discarded.
    c.serve(VENOMX_TEST_CLOCK_OFFSET_MS=str(2 * 86400 * 1000))
    assert c.run('recovery', 'inspect', f'--checkpoint={cp}')['expired_text_panes'] == 1
    restored = c.run('recovery', 'restore', f'--checkpoint={cp}')
    cap = c.run('pane', 'capture', f"--pane={restored['panes'][0]['current']}")
    assert TEXT not in cap['text'] and cap['recovery']['text_state'] == 'expired'
    c.stop(signal.SIGKILL, expect=None)
    # Backward clock: a future capture time makes the whole checkpoint unavailable.
    c.serve(VENOMX_TEST_CLOCK_OFFSET_MS=str(-3600 * 1000))
    assert c.err('recovery', 'restore', f'--checkpoint={cp}', code=5) == 'conflict.checkpoint_expired'
    c.stop(signal.SIGKILL, expect=None)
    # Off transition: a failed purge fails the reload and keeps active policy.
    c.serve(VENOMX_TEST_RECOVERY_FAULT='prune')
    c.run('config', 'set', '--key=recovery.terminal_text', '--value=.off')
    failure = c.run('config', 'reload', code=1)['error']
    assert failure['code'] == 'failed.config_activation' and failure['data'] == {'reason': 'io', 'partial': False}, failure
    assert c.run('config', 'get', '--key=recovery.terminal_text') is not None
    c.stop(signal.SIGKILL, expect=None)
    c.serve()
    assert c.run('recovery', 'list') == {'checkpoints': []}, 'startup must enforce the persisted text-off policy'
    c.stop(signal.SIGKILL, expect=None)
    # A live reload from plain to off deletes text checkpoints before success.
    c = case(recovery=text)
    c.serve()
    c.run('session', 'create', '--name=t')
    c.window('s0', ['/bin/sh', '-c', 'echo hi; exec sleep 60'])
    c.run('recovery', 'checkpoint')
    c.run('config', 'set', '--key=recovery.terminal_text', '--value=.off')
    c.run('config', 'reload')
    assert c.run('recovery', 'list') == {'checkpoints': []}
    # Text off stores no terminal bytes.
    cp = c.run('recovery', 'checkpoint')['checkpoint']
    assert payload_of(c.store / f'{cp}.json')['panes'][0]['text'] == {'availability': 'omitted'}
    # Disabling stops writes but never deletes topology archives.
    c.run('config', 'set', '--key=recovery.enabled', '--value=false')
    c.run('config', 'reload')
    assert cid(c.run('recovery', 'list')) == [cp]
    assert c.err('recovery', 'checkpoint', code=6) == 'unavailable.recovery_disabled'
    c.stop()
    assert [f[:-5] for f in c.files()] == [cp]
    print('ok text/expiry/retention/config')

    # ---- Off-reactor writer. The seam delays each write before its
    # temp file (a slow fsync); the reactor keeps answering meanwhile.
    c = case(recovery=dict(ENABLED, max_checkpoints=100))
    c.serve(VENOMX_TEST_RECOVERY_DELAY_MS='1500')
    c.run('session', 'create', '--name=slow')
    owner_env = dict(c.env, VENOMX_TOKEN='@owner')

    def explicit():
        return subprocess.Popen([EXE, 'recovery', 'checkpoint', '--json'], stdin=subprocess.DEVNULL, env=owner_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    first = explicit()
    time.sleep(.4)
    started = time.monotonic()
    assert c.err('recovery', 'checkpoint', code=5) == 'conflict.recovery_busy'
    assert c.run('session', 'list')['sessions'][0]['name'] == 'slow'
    assert c.run('recovery', 'list') == {'checkpoints': []}  # nothing acknowledged or visible yet
    assert time.monotonic() - started < 1.0, 'reactor waited for the disk write'
    out, err = first.communicate(timeout=TIMEOUT)
    assert first.returncode == 0 and not err, (first.returncode, out, err)
    written = json.loads(out)
    assert written['generation'] == 1 and (c.store / f"{written['checkpoint']}.json").exists()
    assert c.run('recovery', 'checkpoint')['generation'] == 2  # idle again: no stale busy
    c.stop(signal.SIGKILL, expect=None)
    # Shutdown during an in-flight write: it completes, then the final clean
    # one, both inside the 2000 ms persistence budget.
    c.serve(VENOMX_TEST_RECOVERY_DELAY_MS='700')
    pending = explicit()
    time.sleep(.3)
    assert c.stop() < 4.5
    pending.communicate(timeout=TIMEOUT)
    gens = sorted((payload_of(c.store / f)['generation'], payload_of(c.store / f)['shutdown']) for f in c.files())
    assert gens == [(1, 'open'), (2, 'open'), (3, 'open'), (4, 'clean')], gens
    assert not [f for f in c.files(temporary=True) if f.startswith('.tmp-')]
    # Periodic ticks (1 s) while a 2.5 s write is in flight coalesce into one
    # later capture: never more than one write in flight, no queue, no
    # duplicate generations, and the last capture has the latest tree.
    c = case(recovery=dict(ENABLED, interval_ms=1000, max_checkpoints=100))
    c.serve(VENOMX_TEST_RECOVERY_DELAY_MS='2500')
    t0 = time.monotonic()
    names = []
    while time.monotonic() - t0 < 6:
        names.append(f'n{len(names)}')
        c.run('session', 'create', f'--name={names[-1]}')
        time.sleep(.3)
    mutated = time.monotonic() - t0
    until(lambda: len(c.files()) >= 2, timeout=10)
    time.sleep(2.5 + 1 + 2.5 + .5)  # an in-flight write, one coalesced capture and its write
    payloads = [payload_of(c.store / f) for f in c.files()]
    generations = sorted(p['generation'] for p in payloads)
    assert generations == list(range(1, len(generations) + 1)), generations
    assert len(generations) <= int(mutated / 2.5) + 2, (generations, mutated)  # one at a time, ticks coalesced
    latest = max(payloads, key=lambda p: p['generation'])
    assert [x['name'] for x in latest['sessions']] == names, 'the coalesced capture missed the latest tree'
    settled = c.files()
    time.sleep(2)
    assert c.files() == settled, 'an unchanged tree was rewritten'
    c.stop(signal.SIGKILL, expect=None)
    print('ok off-reactor writer: busy, responsiveness, shutdown drain, coalescing')

    # ---- On-demand: a nonempty restore activates; the last removal checkpoints.
    c = case(recovery=ENABLED)
    c.fixture(ident(1), 1)
    env = dict(c.env)
    c.daemon = subprocess.Popen([EXE, 'serve', '--lifetime=on-demand', '--json'], stdin=subprocess.DEVNULL, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    until(lambda: subprocess.run([EXE, 'ping', '--json'], stdin=subprocess.DEVNULL, env=env, capture_output=True).returncode == 0)
    c.run('recovery', 'restore', f'--checkpoint={ident(1)}')
    time.sleep(5.5)  # past the 5000 ms first-session grace
    assert c.daemon.poll() is None, 'restored sessions keep an on-demand daemon alive'
    c.run('session', 'remove', '--session=s0', '--recursive=true')
    c.daemon.wait(timeout=TIMEOUT)
    assert c.daemon.returncode == 0
    final = [f for f in c.files() if f[:-5] != ident(1)]
    assert len(final) == 1 and payload_of(c.store / final[0])['sessions'] == [] and payload_of(c.store / final[0])['shutdown'] == 'clean'
    c.daemon = None
    # Recovery verbs never start a daemon.
    c = case(recovery=ENABLED)
    c.root.joinpath('cfg', 'venomx', 'config.zon').write_text('.{ .daemon = .{ .startup = "on-demand" }, .recovery = .{ .enabled = true } }\n')
    r = subprocess.run([EXE, 'recovery', 'list', '--json'], stdin=subprocess.DEVNULL, env=dict(c.env, VENOMX_TOKEN='@owner'), capture_output=True, text=True, timeout=TIMEOUT)
    assert r.returncode != 0 and not daemons(c.root), (r.returncode, r.stdout)
    print('ok on-demand')
finally:
    for c in cases:
        c.kill()
    for pid in HELPERS:
        # Only our own helpers, and only while they are still the sleep we started.
        try:
            if b'sleep' not in Path(f'/proc/{pid}/cmdline').read_bytes():
                continue
        except OSError:
            continue
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    left = daemons(ROOT)
    subprocess.run(['rm', '-rf', str(ROOT)])
    assert not left, f'daemons left behind: {left}'
print('recovery: all cases passed')
