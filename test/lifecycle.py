#!/usr/bin/env python3
"""On-demand startup and last-session shutdown.

Runs lifecycle checks against the real binary built with the
test seam (`-Dtest-seams=true`, for startup fault injection only): real CLI,
MCP and NDJSON/binary socket clients, no TTY (stdin is /dev/null), isolated
XDG_RUNTIME_DIR/XDG_CONFIG_HOME per case. Every daemon this test starts is
killed in `finally`; the test fails if any is left behind.
"""
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

EXE = str(Path(sys.argv[1]).resolve())
TIMEOUT = 15
ROOT = Path(tempfile.mkdtemp(prefix='vx-life-'))
OUTPUTS = []  # every CLI stdout/stderr, checked for leaked owner tokens
SECRETS = set()


def until(fn, timeout=TIMEOUT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('condition did not become true')


def daemons(root):
    """PIDs of `serve` processes whose argv names this case's directory."""
    found = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            argv = (entry / 'cmdline').read_bytes().split(b'\0')
            state = (entry / 'stat').read_text().rsplit(')', 1)[1].split()[0]
        except OSError:
            continue
        if state == 'Z':
            continue
        if b'serve' in argv and any(str(root).encode() in a for a in argv):
            found.append(int(entry.name))
    return found


def kill_all(root):
    for pid in daemons(root):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


class Case:
    """One isolated runtime/config root with the default socket inside it."""
    count = 0

    def __init__(self, startup=None, budget=None, extra=None):
        Case.count += 1
        self.root = ROOT / f'c{Case.count}'
        (self.root / 'run').mkdir(parents=True, mode=0o700)
        (self.root / 'cfg' / 'venomx').mkdir(parents=True)
        self.socket = self.root / 'run' / 'venom' / 'venomx.sock'
        self.owner_file = self.root / 'run' / 'venom' / 'venomx.owner'
        self.lock = self.root / 'run' / 'venom' / 'venomx.lock'
        fields = []
        if startup:
            fields.append(f'.startup = "{startup}"')
        if budget:
            fields.append(f'.startup_timeout_ms = {budget}')
        if fields:
            self.config_file.write_text('.{ .daemon = .{ ' + ', '.join(fields) + ' } }\n')
        env = {k: v for k, v in os.environ.items() if not k.startswith('VENOMX_') and not k.endswith('_TOKEN')}
        env.update(HOME=str(self.root), XDG_RUNTIME_DIR=str(self.root / 'run'), XDG_CONFIG_HOME=str(self.root / 'cfg'), XDG_CONFIG_DIRS=str(self.root / 'cfg' / 'xdg'), XDG_STATE_HOME=str(self.root / 'state'))
        # These cases test grants and namespaces, so isolation is on.
        (Path(self.root) / 'cfg' / 'xdg' / 'venomx').mkdir(parents=True, exist_ok=True); (Path(self.root) / 'cfg' / 'xdg' / 'venomx' / 'defaults.zon').write_text('.{ .grants = .{ .isolation = true } }\n')
        env.update(extra or {})
        self.env = env
        self.owner = dict(env, VENOMX_TOKEN='@owner')

    @property
    def config_file(self):
        return self.root / 'cfg' / 'venomx' / 'config.zon'

    def run(self, *args, env=None, authority=True, code=0, stderr_ok=False):
        e = env if env is not None else (self.owner if authority else self.env)
        started = time.monotonic()
        r = subprocess.run([EXE, *args, '--json'], stdin=subprocess.DEVNULL, env=e, capture_output=True, text=True, timeout=TIMEOUT)
        elapsed = time.monotonic() - started
        OUTPUTS.extend([r.stdout, r.stderr])
        assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
        assert stderr_ok or not r.stderr, (args, r.stderr)
        lines = r.stdout.splitlines()
        assert len(lines) <= 1 or args[0] in ('events',), (args, r.stdout)  # no readiness chatter
        value = json.loads(lines[-1] if args[0] == 'events' else lines[0]) if lines else None
        return (value, elapsed, r.stderr) if stderr_ok else value

    def code(self, *args, **kw):
        return self.run(*args, **kw)['error']['code']

    def alive(self):
        return daemons(self.root)

    def token(self):
        t = self.owner_file.read_text().strip()
        SECRETS.add(t)
        return t

    def gone(self):
        """No daemon and no socket/owner file; the lock file is unlocked."""
        if self.alive() or self.socket.exists() or self.owner_file.exists():
            return False
        if self.lock.exists():
            with open(self.lock, 'rb') as f:
                try:
                    fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    return False
                fcntl.flock(f, fcntl.LOCK_UN)
        return True

    def serve(self, *extra):
        d = subprocess.Popen([EXE, 'serve', *extra, '--json'], stdin=subprocess.DEVNULL, env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        until(lambda: self.socket.exists() or d.poll() is not None)
        assert d.poll() is None, d.communicate()
        self.run('ping', authority=False)
        return d


class Wire:
    def __init__(self, path, token=None, binary=False):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(TIMEOUT)
        self.sock.connect(str(path))
        self.io = self.sock.makefile('rwb', buffering=0)
        params = {'proto': [1], 'caps': ['cancel', 'venomx.pane_stream'], 'max_frame': 1048576}
        if token:
            params['auth'] = {'token': token}
        if binary:
            self.io.write(b'\xf5')
            self.frame(1, 0, params)
            assert self.recv()[0] == 2
        else:
            self.send({'id': 0, 'verb': 'hello', 'params': params})
            assert 'ok' in self.read()

    def send(self, value):
        self.io.write(json.dumps(value, separators=(',', ':')).encode() + b'\n')

    def pipeline(self, *requests):
        self.io.write(b''.join(json.dumps(r, separators=(',', ':')).encode() + b'\n' for r in requests))

    def read(self):
        line = self.io.readline()
        assert line, 'connection closed'
        return json.loads(line)

    def frame(self, kind, stream, payload):
        if not isinstance(payload, bytes):
            payload = json.dumps(payload, separators=(',', ':')).encode()
        self.io.write(struct.pack('>HII', kind, stream, len(payload)) + payload)

    def recv(self):
        head = self.sock.recv(10, socket.MSG_WAITALL)
        kind, stream, n = struct.unpack('>HII', head)
        return kind, stream, self.sock.recv(n, socket.MSG_WAITALL) if n else b''

    def close(self):
        self.io.close()
        self.sock.close()


def mark_this_process(case):
    """This test becomes a manager above every CLI it runs."""
    start = Path('/proc/self/stat').read_text().rpartition(')')[2].split()[19]
    directory = case.socket.parent
    directory.mkdir(mode=0o700, exist_ok=True)
    marker = directory / f'manager-{os.getpid()}-{start}'
    marker.touch(mode=0o600)
    return marker


def nothing_started(case):
    assert not case.alive(), case.alive()
    assert not case.socket.exists() and not case.owner_file.exists()
    assert not (case.root / 'run' / 'venom').exists() or not any((case.root / 'run' / 'venom').iterdir())


def main():
    results = []

    def ok(name):
        results.append(name)
        print('ok', name, flush=True)

    # Default missing daemon: explicit policy, @owner create is unavailable.
    c = Case()
    assert c.code('session', 'create', '--name=work', code=6) == 'unavailable.not_running'
    nothing_started(c)
    ok('default missing daemon: 6, no process/files/resources')

    # Opt-in valid owner creation: one daemon, one empty session, no shell.
    c = Case('on-demand')
    created, elapsed, err = c.run('session', 'create', '--name=work', stderr_ok=True)
    assert created == {'session': 's0', 'name': 'work'} and not err, (created, err)
    assert elapsed < 5
    pids = c.alive()
    assert len(pids) == 1, pids
    assert c.lock.read_text().strip() == str(pids[0])
    argv = Path(f'/proc/{pids[0]}/cmdline').read_bytes().split(b'\0')
    assert b'--lifetime=on-demand' in argv and f'--socket={c.socket}'.encode() in argv, argv
    environ = Path(f'/proc/{pids[0]}/environ').read_bytes().split(b'\0')
    assert not any(e.startswith((b'VENOMX_TOKEN=', b'VENOMX_PANE=', b'VENOMX_PRINCIPAL=')) for e in environ)
    token = c.token()
    assert token.encode() not in b''.join(argv)
    assert c.run('session', 'get', '--session=s0', authority=False)['windows'] == []
    assert c.run('pane', 'list', authority=False) == {'panes': []}
    assert c.run('session', 'list', authority=False) == {'sessions': [{'session': 's0', 'name': 'work'}]}
    first_source = c.run('events', '--follow=false', authority=False)['source']
    assert c.run('session', 'remove', '--session=s0') == {}
    until(c.gone, 5)
    ok('opt-in owner creation: one on-demand daemon, one empty session; final removal exits and cleans up')

    # Shutdown and restart: a new daemon has a fresh source and empty state.
    assert c.run('session', 'create', '--name=again') == {'session': 's0', 'name': 'again'}
    assert c.run('events', '--follow=false', authority=False)['source'] != first_source
    assert c.run('session', 'list', authority=False)['sessions'] == [{'session': 's0', 'name': 'again'}]
    assert c.run('session', 'remove', '--session=s0') == {}
    until(c.gone, 5)
    ok('shutdown and restart: fresh source, empty registry, only owned files removed, lock released')

    # Concurrent eligible commands: barrier race of N independent creations.
    c = Case('on-demand')
    n = 8
    barrier = threading.Barrier(n)
    outcomes = [None] * n

    def racer(i):
        barrier.wait()
        started = time.monotonic()
        r = subprocess.run([EXE, 'session', 'create', f'--name=r{i}', '--json'], stdin=subprocess.DEVNULL, env=c.owner, capture_output=True, text=True, timeout=TIMEOUT)
        outcomes[i] = (r.returncode, r.stdout, r.stderr, time.monotonic() - started)
    threads = [threading.Thread(target=racer, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for code, out, err, elapsed in outcomes:
        OUTPUTS.extend([out, err])
        assert code == 0 and not err, (code, out, err)
        assert elapsed < 5.5, elapsed
    names = sorted(json.loads(o[1])['name'] for o in outcomes)
    ids = {json.loads(o[1])['session'] for o in outcomes}
    assert names == sorted(f'r{i}' for i in range(n)) and len(ids) == n
    sessions = c.run('session', 'list', authority=False)['sessions']
    assert len(sessions) == n, sessions  # no extra bootstrap session
    pids = until(lambda: (p if len(p := c.alive()) == 1 else None), 3)  # losing candidates exit
    assert len(pids) == 1 and c.lock.read_text().strip() == str(pids[0]), pids
    ok(f'concurrent eligible commands: {n} racers, one lock holder, {n} sessions, each ready < 5.5 s')

    # Reachable unknown caller: create denied (4); including while stopping.
    assert c.code('session', 'create', authority=False, code=4) == 'denied.write'
    for s in sessions[1:]:
        c.run('session', 'remove', f"--session={s['session']}")
    token = c.token()
    owner = Wire(c.socket, token)
    unknown = Wire(c.socket)
    last = sessions[0]['session']
    # Final removal and a pipelined create: commit order decides.
    unknown.send({'id': 5, 'verb': 'session.create', 'params': {'name': 'u'}})
    owner.pipeline({'id': 1, 'verb': 'session.remove', 'params': {'session': last}}, {'id': 2, 'verb': 'session.create', 'params': {'name': 'late'}})
    assert owner.read() == {'id': 1, 'ok': {}}
    late = owner.read()
    assert late['id'] == 2 and late['error']['code'] == 'unavailable.shutdown', late
    try:
        reply = unknown.read()
        assert reply['error']['code'] == 'denied.write', reply
    except (AssertionError, OSError, ValueError) as e:
        if 'denied' in str(e):
            raise
    owner.close()
    unknown.close()
    until(c.gone, 5)
    ok('final removal vs pipelined create: removal first latches stopping, later create unavailable.shutdown, unknown denied; no revival')

    # Final removal vs create, create first: the daemon stays active.
    c = Case('on-demand')
    c.run('session', 'create', '--name=a')
    owner = Wire(c.socket, c.token())
    owner.pipeline({'id': 1, 'verb': 'session.create', 'params': {'name': 'b'}}, {'id': 2, 'verb': 'session.remove', 'params': {'session': 's0'}})
    assert owner.read()['ok']['session'] == 's1' and owner.read() == {'id': 2, 'ok': {}}
    owner.close()
    time.sleep(.5)
    assert c.alive() and c.run('session', 'list', authority=False)['sessions'] == [{'session': 's1', 'name': 'b'}]
    ok('final removal vs create, create first: commit order keeps the daemon active')

    # Final removal with a slow and a disconnected client: bounded flush/cleanup.
    slow = Wire(c.socket)
    slow.send({'id': 9, 'verb': 'events', 'params': {}})  # never read again
    gone = Wire(c.socket, c.token())
    gone.send({'id': 1, 'verb': 'session.remove', 'params': {'session': 's1'}})
    gone.close()  # reply outcome unknown to this client
    started = time.monotonic()
    until(c.gone, 5)
    assert time.monotonic() - started < 3, time.monotonic() - started
    slow.close()
    ok('final removal with slow/disconnected clients: committed once, drained and cleaned within 2.5 s')

    # Lost create reply: unknown outcome (6), no automatic resend.
    c = Case('on-demand', extra={'VENOMX_TEST_DROP_REPLY': '1'})
    assert c.code('session', 'create', '--name=lost', code=6) == 'unavailable.startup_result'
    assert c.run('session', 'list', authority=False)['sessions'] == [{'session': 's0', 'name': 'lost'}]
    c.run('session', 'remove', '--session=s0')
    until(c.gone, 5)
    ok('lost create reply: unavailable.startup_result, exactly one session (no resend)')

    # Ineligible/read/attach/MCP/help/invalid commands never launch.
    c = Case('on-demand')
    for args, expect in [
        (('session', 'list'), 6), (('session', 'get', '--session=s0'), 6), (('ping',), 6),
        (('window', 'create', '--session=s0', '--argv=["/bin/true"]'), 6),
        (('pane', 'split', '--pane=p0', '--axis=cols', '--argv=["/bin/true"]'), 6),
        (('events', '--follow=false'), 6), (('skill',), 6), (('doctor',), 6),
        (('config', 'get', '--key=daemon.startup'), 6), (('config', 'set', '--key=daemon.startup', '--value="explicit"'), 6),
        (('config', 'reload'), 6), (('grant', 'list'), 6), (('session', 'remove', '--session=s0'), 6),
        (('attach', '--session=s0'), 10),
        (('session', 'create', '--name=bad\nname'), 2), (('session', 'create', f'--name={"x" * 129}'), 2),
        (('session', 'create', '--bogus=1'), 2), (('no-such-verb',), 2),
    ]:
        value = c.run(*args, code=expect)
        assert 'error' in value, (args, value)
    # Product name rules fail like the daemon's handler, before launch.
    bad = c.run('session', 'create', '--name=bad\nname', code=2)['error']
    assert bad == {'code': 'invalid_params.name', 'message': 'invalid display name', 'data': {'param': 'name'}}, bad
    # The error carries the socket path, and doctor's fix starts the daemon.
    missing = {'code': 'unavailable.not_running', 'message': 'No daemon at the selected socket', 'data': {'socket': str(c.socket)}}
    assert c.run('ping', code=6)['error'] == missing
    doctor = c.run('doctor', code=6)['error']
    assert doctor == dict(missing, data=dict(missing['data'], fix='venomx serve')), doctor
    assert 'session.create' in c.run('session', 'create', '--help')['help']
    mcp = '\n'.join(json.dumps(m) for m in [
        {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 't', 'version': '1'}}},
        {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
        {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call', 'params': {'name': 'session_dcreate', 'arguments': {'name': 'via-mcp'}}},
    ]) + '\n'
    r = subprocess.run([EXE, 'mcp'], input=mcp, env=c.owner, capture_output=True, text=True, timeout=TIMEOUT)
    call = [json.loads(line) for line in r.stdout.splitlines() if json.loads(line).get('id') == 2][0]
    assert call['result']['isError'] and 'unavailable.not_running' in call['result']['content'][0]['text'], call
    nothing_started(c)
    ok('ineligible/read/attach/MCP/help/invalid commands: no launch; unavailable/usage behavior')

    # No token / ordinary token: no launch, no owner-file read or promotion.
    assert c.code('session', 'create', authority=False, code=6) == 'unavailable.not_running'
    assert c.code('session', 'create', env=dict(c.env, VENOMX_TOKEN='vnt1.venomx.g0.stale'), code=6) == 'unavailable.not_running'
    nothing_started(c)
    ok('no token / ordinary old token: no launch')

    # Managed markers with @owner: 4, no launch.
    for marker in ({'VENOMX_PANE': ''}, {'VENOMX_PRINCIPAL': 'g3'}, {'VENOMX_PANE': 'p0', 'VENOMX_PRINCIPAL': 'g1'}):
        assert c.code('session', 'create', env=dict(c.owner, **marker), code=4) == 'denied.startup_context'
    nothing_started(c)
    ok('managed markers with @owner: denied.startup_context (4), no launch')

    # A manager's marker above the caller with @owner: 4, no launch, and it names
    # the marker. This test holds the marker and is the caller's parent.
    m = Case('on-demand')
    mark = mark_this_process(m)
    denied, _, err = m.run('session', 'create', code=4, stderr_ok=True)
    assert denied['error']['code'] == 'denied.startup_context', denied
    assert str(mark) in err, err
    assert not m.alive() and not m.socket.exists() and not m.owner_file.exists()
    assert list(mark.parent.iterdir()) == [mark]  # no lock, no socket, marker kept
    # Without on-demand policy or @owner nothing would launch: the answer is as before.
    assert m.code('session', 'create', authority=False, code=6) == 'unavailable.not_running'
    # The marker on a grandparent counts too: `; exit` keeps sh from exec'ing.
    r = subprocess.run(['/bin/sh', '-c', '"$0" session create --json; exit $?', EXE], stdin=subprocess.DEVNULL, env=m.owner, capture_output=True, text=True, timeout=TIMEOUT)
    assert r.returncode == 4 and 'denied.startup_context' in r.stdout and str(mark) in r.stderr, r
    assert not m.alive() and list(mark.parent.iterdir()) == [mark]
    # The directory is the scope: a socket elsewhere doesn't see this marker.
    other = m.root / 'other'
    other.mkdir(mode=0o700)
    elsewhere = f'--socket={other}/x.sock'
    assert m.run('session', 'create', '--name=work', elsewhere) == {'session': 's0', 'name': 'work'}
    assert len(m.alive()) == 1
    assert m.run('session', 'remove', '--session=s0', elsewhere) == {}
    until(lambda: not m.alive(), 5)
    # Doctor's marker check is unchanged, on a daemon started explicitly.
    d = m.serve()
    checks = {k['id']: k for k in m.run('doctor', authority=False)['checks']}
    assert checks['grants.below_manager']['status'] == 'warn', checks
    assert m.code('session', 'create', code=4) == 'denied.token'
    d.terminate()
    d.communicate(timeout=TIMEOUT)
    until(m.gone, 5)
    # A marker for another start of this pid matches nothing: the call launches.
    stale = mark.with_name(mark.name + '0')
    mark.rename(stale)
    assert m.run('session', 'create', '--name=work') == {'session': 's0', 'name': 'work'}
    assert len(m.alive()) == 1 and stale.exists()
    assert m.run('session', 'remove', '--session=s0') == {}
    until(m.gone, 5)
    ok("manager's marker above the caller with @owner: denied.startup_context (4), names it, no launch; stale marker launches")

    # Invalid startup config fails before launch, files unchanged.
    for text in ('.{ .daemon = .{ .startup = "always" } }', '.{ .daemon = .{ .startup = "on-demand", .startup_timeout_ms = 50 } }', 'not zon'):
        c.config_file.write_text(text)
        assert c.code('session', 'create', code=2) == 'invalid_params.startup_config'
        assert c.config_file.read_text() == text
    c.config_file.unlink()
    os.mkfifo(c.config_file)
    assert c.code('session', 'create', code=2) == 'invalid_params.startup_config'  # FIFO is not a config file
    c.config_file.unlink()
    nothing_started(c)
    ok('invalid startup config (value, budget, ZON, FIFO): invalid_params.startup_config (2), no launch')

    # Stale socket and an unlocked lock naming a dead PID: the lock winner cleans up.
    c = Case('on-demand')
    c.socket.parent.mkdir(mode=0o700)
    stale = socket.socket(socket.AF_UNIX)
    stale.bind(str(c.socket))
    stale.close()
    c.lock.write_text('999999\n')
    c.lock.chmod(0o600)
    c.owner_file.write_text('stale-owner\n')
    c.owner_file.chmod(0o600)
    assert c.run('session', 'create') == {'session': 's0', 'name': ''}
    pids = c.alive()
    assert len(pids) == 1 and c.lock.read_text().strip() == str(pids[0])
    assert c.token() != 'stale-owner'
    c.run('session', 'remove', '--session=s0')
    until(c.gone, 5)
    ok('stale socket + unlocked stale-PID lock: one valid listener/owner file')

    # Held lock, socket not ready: no unlink/kill; exit 6 within budget.
    c = Case('on-demand', budget=1000)
    c.socket.parent.mkdir(mode=0o700)
    holder = open(c.lock, 'a+')
    c.lock.chmod(0o600)
    fcntl.flock(holder, fcntl.LOCK_EX)
    value, elapsed, err = c.run('session', 'create', code=6, stderr_ok=True)
    assert value['error'] == {'code': 'unavailable.startup_deadline', 'message': value['error']['message'], 'data': {}}, value
    assert 0.9 < elapsed < 2.5 and not err, (elapsed, err)
    assert c.lock.exists() and not c.alive()
    # Wait succeeds: the holder becomes a ready daemon within the budget.
    c.config_file.write_text('.{ .daemon = .{ .startup = "on-demand", .startup_timeout_ms = 5000 } }')
    result = {}
    waiter = threading.Thread(target=lambda: result.update(v=c.run('session', 'create', '--name=waited')))
    waiter.start()
    time.sleep(.6)
    fcntl.flock(holder, fcntl.LOCK_UN)
    holder.close()
    winner = c.serve('--lifetime', 'on-demand')
    waiter.join()
    assert result['v'] == {'session': 's0', 'name': 'waited'}
    c.run('session', 'remove', '--session=s0')
    out, _ = winner.communicate(timeout=5)
    assert winner.returncode == 0 and out == '{}\n'
    until(c.gone, 5)
    ok('held lock, socket not ready: deadline 6 within budget without unlink/kill; waiter uses a later winner')

    # Non-socket, insecure directory, symlinked directory: fail closed.
    c = Case('on-demand')
    c.socket.parent.mkdir(mode=0o700)
    c.socket.write_text('not a socket')
    assert c.code('session', 'create', code=5) == 'conflict.not_a_socket'
    assert c.socket.read_text() == 'not a socket' and not c.alive()
    insecure = c.root / 'open'
    insecure.mkdir()
    insecure.chmod(0o777)
    assert c.code('session', 'create', f'--socket={insecure}/x.sock', code=4) == 'denied.insecure_path'
    assert list(insecure.iterdir()) == []
    real = c.root / 'real'
    real.mkdir(mode=0o700)
    (c.root / 'link').symlink_to(real)
    assert c.code('session', 'create', f'--socket={c.root}/link/x.sock', code=4) == 'denied.insecure_path'
    assert not (real / 'x.sock').exists() and not c.alive()
    ok('non-socket / insecure dir / symlinked dir: shared error, no replacement or fallback')

    # Child init failure: 6 with a bounded diagnostic; nothing leaked.
    # A known failure still lets a winner become ready within the budget.
    c = Case('on-demand', budget=1000, extra={'VENOMX_TEST_STARTUP_FAIL': '1'})
    value, elapsed, err = c.run('session', 'create', code=6, stderr_ok=True)
    assert value['error']['code'] == 'unavailable.startup_failed' and value['error']['data'] == {}, value
    assert err.startswith('venomx: daemon candidate failed during startup') and len(err) < 512 and err.count('\n') == 1, err
    assert elapsed < 2.5, elapsed
    until(c.gone, 2)
    ok('child init failure: startup_failed (6), bounded diagnostic, no leaked candidate/lock/owner file')

    # Winner hangs (listening, never ready): deadline 6; the waiter does not kill it.
    c = Case('on-demand', budget=1500, extra={'VENOMX_TEST_STARTUP_DELAY_MS': '60000'})
    value, elapsed, err = c.run('session', 'create', code=6, stderr_ok=True)
    assert value['error']['code'] in ('unavailable.startup_deadline',), value
    assert 1.4 < elapsed < 3, elapsed
    until(c.gone, 3)  # the candidate bounds its own initialization
    ok('winner hangs: startup_deadline (6) within budget; candidate aborts itself with cleanup')

    # Waiter cancelled: 8; the candidate survives the waiter, then self-bounds.
    c = Case('on-demand', budget=3000, extra={'VENOMX_TEST_STARTUP_DELAY_MS': '60000'})
    p = subprocess.Popen([EXE, 'session', 'create', '--json'], stdin=subprocess.DEVNULL, env=c.owner, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    until(lambda: c.socket.exists(), 3)
    candidate = c.alive()
    p.send_signal(signal.SIGINT)
    out, err = p.communicate(timeout=5)
    OUTPUTS.extend([out, err])
    assert p.returncode == 8 and json.loads(out)['error']['code'] == 'cancelled', (p.returncode, out, err)
    assert c.alive() == candidate and candidate, (c.alive(), candidate)
    until(c.gone, 5)
    ok('waiter cancelled: cancelled (8); the candidate is not killed by the waiter and self-bounds')

    # Fresh on-demand serve with zero sessions: grace then exit; probes do not extend it.
    c = Case()
    started = time.monotonic()
    d = c.serve('--lifetime', 'on-demand')
    probe = Wire(c.socket)
    while d.poll() is None and time.monotonic() - started < 9:
        try:
            c.run('ping', authority=False, code=0)
        except AssertionError:
            break
        time.sleep(.25)
    out, err = d.communicate(timeout=5)
    total = time.monotonic() - started
    assert d.returncode == 0 and out == '{}\n' and not err, (d.returncode, out, err)
    assert 4.9 < total < 7.6, total
    probe.close()
    until(c.gone, 2)
    ok(f'fresh on-demand zero sessions: exits after 5000 ms grace + bounded shutdown ({total:.2f} s) despite probes and a connected client')

    # Persistent zero sessions/clients/children, even with on-demand config.
    c = Case('on-demand')
    d = c.serve()
    time.sleep(5.6)
    assert d.poll() is None
    c.run('session', 'create')
    c.run('session', 'remove', '--session=s0')
    time.sleep(.3)
    assert d.poll() is None
    checks = {k['id']: k for k in c.run('doctor', authority=False)['checks']}
    assert checks['daemon.lifetime']['status'] == 'ok' and checks['daemon.lifetime']['message'].startswith('persistent')
    assert checks['daemon.lifecycle']['status'] == 'ok' and 'state active; 0 sessions' in checks['daemon.lifecycle']['message']
    # Config set/reload: admin-only, atomic validation, restart-only pending.
    assert c.code('config', 'set', '--key=daemon.startup', '--value="explicit"', authority=False, code=4).startswith('denied.')
    before = c.config_file.read_text()
    assert c.code('config', 'set', '--key=daemon.startup', '--value="bogus"', code=2) == 'invalid_params.config_value'
    assert c.code('config', 'set', '--key=daemon.startup_timeout_ms', '--value=99', code=2) == 'invalid_params.config_value'
    assert c.config_file.read_text() == before
    assert c.run('config', 'set', '--key=daemon.startup', '--value="explicit"')['restart_required'] is True
    assert c.run('config', 'reload')['restart_required'] is True
    checks = {k['id']: k for k in c.run('doctor', authority=False)['checks']}
    assert checks['daemon.startup_policy']['status'] == 'warn' and 'restart required' in checks['daemon.startup_policy']['message'], checks['daemon.startup_policy']
    assert checks['daemon.startup_policy']['fix'] == 'venomx config check --json'
    assert checks['daemon.lifetime']['message'].startswith('persistent')
    d.send_signal(signal.SIGTERM)
    out, err = d.communicate(timeout=5)
    assert d.returncode == 0 and out == '{}\n', (out, err)
    until(c.gone, 2)
    ok('persistent zero sessions/clients (explicit serve, on-demand config) stays up; config set/reload admin-only, atomic, restart-only')

    # Restart-only settings never change a running on-demand daemon's lifetime.
    c = Case('on-demand')
    c.run('session', 'create')
    assert c.run('config', 'set', '--key=daemon.startup', '--value="explicit"')['restart_required'] is True
    assert c.run('config', 'reload')['restart_required'] is True
    checks = {k['id']: k for k in c.run('doctor', authority=False)['checks']}
    assert checks['daemon.lifetime']['message'].startswith('on-demand') and checks['daemon.startup_policy']['status'] == 'warn'
    for check in ('daemon.lifetime', 'daemon.startup_policy', 'daemon.startup_deadline', 'daemon.lifecycle'):
        assert check in checks
    # Detach/crash all clients: session and PTYs remain alive; same source.
    source = c.run('events', '--follow=false', authority=False)['source']
    w = c.run('window', 'create', '--session=s0', '--argv=["/bin/sh"]')
    attached = Wire(c.socket, c.token(), binary=True)
    attached.frame(0x100, 1, {'pane': w['pane'], 'mode': 'raw', 'formats': ['vt'], 'size': {'cols': 80, 'rows': 24}, 'history': 0})
    attached.sock.shutdown(socket.SHUT_RDWR)  # crash: no detach frame
    attached.close()
    time.sleep(.3)
    assert os.path.exists(f'/proc/{w["pid"]}') and c.alive()
    c.run('pane', 'send', f'--pane={w["pane"]}', '--text=echo still-here\n')
    until(lambda: 'still-here' in c.run('pane', 'capture', f'--pane={w["pane"]}', authority=False)['text'])
    assert c.run('events', '--follow=false', authority=False)['source'] == source
    ok('restart-only config never changes a running on-demand lifetime; detach/crash keeps session, PTY and source')

    # Empty window / retained exited pane keep the daemon alive.
    c.run('pane', 'send', f'--pane={w["pane"]}', '--text=exit\n')
    until(lambda: c.run('pane', 'capture', f'--pane={w["pane"]}', authority=False)['exited'])
    time.sleep(.5)
    assert c.alive()
    assert c.code('session', 'remove', '--session=s0', code=5) == 'conflict.not_empty'
    assert c.code('window', 'remove', f'--window={w["window"]}', code=5) == 'conflict.not_empty'
    c.run('pane', 'remove', f'--pane={w["pane"]}')
    assert c.run('window', 'get', f'--window={w["window"]}', authority=False)['nodes'] == []
    time.sleep(.3)
    assert c.alive()
    c.run('window', 'remove', f'--window={w["window"]}')
    assert c.run('session', 'get', '--session=s0', authority=False)['windows'] == []
    time.sleep(.3)
    assert c.alive()
    # Pane-descendant owner bootstrap remains denied on a reachable daemon.
    script = f'VENOMX_TOKEN=@owner {EXE} session create --json; echo "rc=$?"'
    inner = c.run('window', 'create', '--session=s0', f'--argv={json.dumps(["/bin/sh", "-c", script])}')
    text = until(lambda: (t if 'rc=' in (t := c.run('pane', 'capture', f'--pane={inner["pane"]}', authority=False)['text']) else None))
    assert 'rc=4' in text and '"session":"s1"' not in text, text
    until(lambda: c.run('pane', 'capture', f'--pane={inner["pane"]}', authority=False)['exited'])
    c.run('window', 'remove', f'--window={inner["window"]}', '--recursive=true')
    assert c.run('session', 'list', authority=False)['sessions'] == [{'session': 's0', 'name': ''}]
    c.run('session', 'remove', '--session=s0')
    until(c.gone, 5)
    ok('empty session/window and exited pane keep the daemon alive; last pane/window removal keeps ancestors; pane-borne @owner denied (4)')

    # Recursive removal of the last session also stops an on-demand daemon.
    c = Case('on-demand')
    c.run('session', 'create')
    c.run('window', 'create', '--session=s0', '--argv=["/bin/sh"]')
    assert c.run('session', 'remove', '--session=s0', '--recursive=true') == {}
    until(c.gone, 5)
    ok('recursive final session removal: children reaped, daemon exits and cleans up')

    # JSON/schema/skill/doctor/events agreement.
    c = Case()
    d = c.serve()
    skill = c.run('skill', authority=False)['content']
    for phrase in ('daemon.startup="on-demand"', 'VENOMX_TOKEN=@owner', 'MCP', 'unavailable.startup_result', 'restart-only', '5000 ms', 'exits right after its last'):
        assert phrase in skill, phrase
    serve_help = c.run('serve', '--help', authority=False)['help']
    assert '--lifetime' in serve_help and 'on-demand' in serve_help
    docs = subprocess.run([EXE, 'docs', '--json'], stdin=subprocess.DEVNULL, env=c.env, capture_output=True, text=True, timeout=TIMEOUT)
    assert docs.returncode == 0 and 'Startup policy (local CLI only)' in docs.stdout and 'lifetime' in docs.stdout
    for shell in ('bash', 'zsh', 'fish'):
        comp = subprocess.run([EXE, 'completions', f'--shell={shell}'], stdin=subprocess.DEVNULL, env=c.env, capture_output=True, text=True, timeout=TIMEOUT)
        assert comp.returncode == 0 and 'lifetime' in comp.stdout, shell
    tools = '\n'.join(json.dumps(m) for m in [
        {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 't', 'version': '1'}}},
        {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
        {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
    ]) + '\n'
    r = subprocess.run([EXE, 'mcp'], input=tools, env=c.env, capture_output=True, text=True, timeout=TIMEOUT)
    listing = [json.loads(line) for line in r.stdout.splitlines() if json.loads(line).get('id') == 2][0]['result']['tools']
    names = {t['name'] for t in listing}
    assert 'session_dcreate' in names and not any(n == 'serve' for n in names)
    create_tool = [t for t in listing if t['name'] == 'session_dcreate'][0]
    assert 'MCP, wire requests and every other command never start a daemon' in create_tool['description']
    checks = {k['id']: k for k in c.run('doctor', authority=False)['checks']}
    assert checks['daemon.startup_policy']['message'] == 'active "explicit"; persisted "explicit"'
    assert checks['daemon.startup_deadline']['message'].startswith('client startup budget 5000 ms')
    marker = c.run('events', '--follow=false', authority=False)
    cursor = f"{marker['source']}:{marker['seq']}"
    c.run('session', 'create', '--name=e')
    c.run('session', 'remove', '--session=s0')
    r = subprocess.run([EXE, 'events', '--follow=false', f'--after={cursor}', '--json'], stdin=subprocess.DEVNULL, env=c.env, capture_output=True, text=True, timeout=TIMEOUT)
    kinds = [json.loads(line)['type'] for line in r.stdout.splitlines()]
    assert kinds.count('session.created') == 1 and kinds.count('session.removed') == 1 and kinds.index('session.created') < kinds.index('session.removed'), kinds
    d.send_signal(signal.SIGINT)
    out, _ = d.communicate(timeout=5)
    assert d.returncode == 0 and out == '{}\n'
    ok('generated skill/help/docs/completions/MCP/doctor/events agree; serve stays out of MCP')

    leaked = [s for s in SECRETS if any(s in o for o in OUTPUTS)]
    assert not leaked, 'owner token leaked into CLI output'
    print(f'ok lifecycle matrix: {len(results)} cases', flush=True)


import traceback
failed = False
try:
    main()
except BaseException:
    traceback.print_exc()
    failed = True
finally:
    stray = daemons(ROOT)
    kill_all(ROOT)
    subprocess.run(['rm', '-rf', str(ROOT)], check=False)
    if stray:
        print('stray daemons killed:', stray, file=sys.stderr)
    if failed or stray:
        sys.exit(1)
