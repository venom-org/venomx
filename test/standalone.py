#!/usr/bin/env python3
"""Standalone entry point: every conformance case.

Drives the real binary: interactive entry points run on PTYs (their screens
are not inspected here; test/attach.py covers rendering), headless checks
use the CLI with stdin on /dev/null. Each case has its own XDG runtime,
config and state root with the default socket inside it. Every daemon this
test starts is killed in `finally`, and the test fails if one is left.
"""
import fcntl
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time

EXE = str(Path(sys.argv[1]).resolve())
TIMEOUT = 15
ROOT = Path(tempfile.mkdtemp(prefix='vx-std-'))
PREFIX = b'\x02'  # the default leader, Ctrl-B
results = []


def ok(name):
    results.append(name)
    print(f'ok {name}', flush=True)


def until(fn, what='condition', timeout=TIMEOUT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError(f'{what} did not become true')


def daemons(root):
    """PIDs of live `serve` processes whose argv or environment names root."""
    found = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            argv = (entry / 'cmdline').read_bytes().split(b'\0')
            state = (entry / 'stat').read_text().rsplit(')', 1)[1].split()[0]
            environ = (entry / 'environ').read_bytes()
        except OSError:
            continue
        if state == 'Z' or b'serve' not in argv or b'venomx' not in argv[0]:
            continue
        if str(root).encode() in environ or any(str(root).encode() in a for a in argv):
            found.append(int(entry.name))
    return found


def children(pid):
    out = []
    for entry in Path('/proc').iterdir():
        if not entry.name.isdigit():
            continue
        try:
            stat = (entry / 'stat').read_text().rsplit(')', 1)[1].split()
            if int(stat[1]) == pid:
                out.append((int(entry.name), (entry / 'cmdline').read_bytes().split(b'\0')[:-1]))
        except OSError:
            continue
    return out


class Case:
    count = 0
    all = []

    def __init__(self, config=None, defaults=None):
        Case.count += 1
        self.root = ROOT / f'c{Case.count}'
        (self.root / 'run').mkdir(parents=True, mode=0o700)
        (self.root / 'cfg' / 'venomx').mkdir(parents=True)
        (self.root / 'work' / 'proj').mkdir(parents=True)
        self.cwd = self.root / 'work' / 'proj'
        self.socket = self.root / 'run' / 'venom' / 'venomx.sock'
        if config:
            (self.root / 'cfg' / 'venomx' / 'config.zon').write_text(config)
        self.defaults = self.root / 'cfg' / 'xdg' / 'venomx' / 'defaults.zon'
        if defaults:
            self.defaults.parent.mkdir(parents=True)
            self.defaults.write_text(defaults)
        env = {k: v for k, v in os.environ.items() if not k.startswith('VENOMX_') and not k.endswith('_TOKEN')}
        env.update(HOME=str(self.root), XDG_RUNTIME_DIR=str(self.root / 'run'), XDG_CONFIG_HOME=str(self.root / 'cfg'), XDG_CONFIG_DIRS=str(self.root / 'cfg' / 'xdg'),
                   XDG_STATE_HOME=str(self.root / 'state'), SHELL='/bin/sh', ENV='', PS1='$ ', TERM='xterm-256color')
        self.env = env
        self.owner = dict(env, VENOMX_TOKEN='@owner')
        self.ptys = []
        Case.all.append(self)

    def run(self, *args, env=None, code=0):
        r = subprocess.run([EXE, *args, '--json'], stdin=subprocess.DEVNULL, env=env or self.owner, cwd=self.cwd,
                           capture_output=True, text=True, timeout=TIMEOUT)
        assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
        return json.loads(r.stdout.splitlines()[-1]) if r.stdout else None

    def alive(self):
        return daemons(self.root)

    def lock_holders(self):
        """Live `serve` processes holding the flock on this case's lock file."""
        lock = str(self.socket.with_suffix('.lock'))
        held = []
        for pid in self.alive():
            try:
                for fd in Path(f'/proc/{pid}/fdinfo').iterdir():
                    if os.readlink(f'/proc/{pid}/fd/{fd.name}') == lock and 'FLOCK' in fd.read_text():
                        held.append(pid)
            except OSError:
                continue
        return held

    def serve(self):
        d = subprocess.Popen([EXE, 'serve', '--json'], stdin=subprocess.DEVNULL, env=self.env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
        until(lambda: self.socket.exists() or d.poll() is not None, 'socket')
        assert d.poll() is None, d.communicate()
        self.run('ping', env=self.env)
        return d

    def pty(self, *args, env=None):
        p = Pty([EXE, *args], env or self.env, self.cwd)
        self.ptys.append(p)
        return p

    def sessions(self):
        return self.run('session', 'list')['sessions']

    def checks(self):
        return {k['id']: k for k in self.run('doctor', env=self.env)['checks']}

    def close(self):
        """Stop clients, then every daemon of this case with SIGTERM."""
        for p in self.ptys:
            p.kill()
        for pid in self.alive():
            os.kill(pid, signal.SIGTERM)
        until(lambda: not self.alive(), 'case daemons stopped')


class Pty:
    """A process whose stdin/stdout are one PTY; stderr is captured."""

    def __init__(self, argv, env, cwd):
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
        self.proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=subprocess.PIPE, env=env, cwd=cwd,
                                     start_new_session=True)
        os.close(slave)
        os.set_blocking(master, False)
        self.master = master
        self.out = bytearray()
        self.err = b''
        # Drain continuously so a full PTY buffer never blocks the client.
        self.stop = False
        self.thread = threading.Thread(target=self.drain, daemon=True)
        self.thread.start()

    def drain(self):
        while not self.stop and self.master >= 0:
            try:
                chunk = os.read(self.master, 65536)
                if not chunk:
                    return
                self.out += chunk
            except BlockingIOError:
                time.sleep(.02)
            except OSError:
                return

    def type(self, data):
        os.write(self.master, data)

    def wait(self):
        code = self.proc.wait(timeout=TIMEOUT)
        self.thread.join(timeout=2)  # EIO once every slave end is closed
        self.err = self.proc.stderr.read()
        return code, self.err.decode()

    def running(self):
        return self.proc.poll() is None

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait(timeout=TIMEOUT)
        self.stop = True
        if self.master >= 0:
            os.close(self.master)
            self.master = -1


def shell_child(pid):
    """The login shell the daemon started: $SHELL running with argv ['-sh']."""
    for child, argv in children(pid):
        if argv == [b'-sh'] and os.path.realpath(f'/proc/{child}/exe') == os.path.realpath('/bin/sh'):
            return True
    return False


def replay(c, cursor, types):
    r = subprocess.run([EXE, 'events', '--follow=false', f'--after={cursor}', f'--types={json.dumps(types)}', '--json'],
                       stdin=subprocess.DEVNULL, env=c.env, capture_output=True, text=True, timeout=TIMEOUT)
    assert r.returncode == 0, r
    return [json.loads(line) for line in r.stdout.splitlines() if json.loads(line).get('type') in types]


def marker(c):
    m = c.run('events', '--follow=false', env=c.env)
    return f"{m['source']}:{m['seq']}"


def main():
    # No terminal, no entry point; nothing is started.
    c = Case()
    for args in ([], ['new'], ['new', '-d', '--name', 'x']):
        r = subprocess.run([EXE, *args, '--json'], stdin=subprocess.DEVNULL, env=c.env, cwd=c.cwd, capture_output=True, text=True, timeout=TIMEOUT)
        assert r.returncode == 10 and json.loads(r.stdout)['error']['code'] == 'unsupported.terminal', (args, r)
    assert not c.alive() and not c.socket.exists()
    ok('bare venomx and new without a terminal fail unsupported.terminal and start nothing')

    # One word starts an on-demand daemon, a login shell, attach.
    c = Case()
    p = c.pty()
    pid = until(lambda: c.alive(), 'on-demand daemon')[0]
    until(lambda: c.socket.exists() and c.sessions(), 'session')
    s = c.sessions()
    assert len(s) == 1 and s[0]['name'] == 'proj', s  # named after the cwd basename
    until(lambda: shell_child(pid), 'login shell child')
    checks = c.checks()
    assert checks['daemon.lifetime']['message'].startswith('on-demand'), checks['daemon.lifetime']
    assert checks['daemon.origin']['message'].startswith('origin interactive'), checks['daemon.origin']
    assert checks['daemon.interactive_start']['message'] == 'active true; persisted true'
    win = c.run('session', 'get', '--session', s[0]['session'])['windows']
    assert len(win) == 1
    events = subprocess.Popen([EXE, 'events', '--types=["pane.removed","window.removed","session.removed"]', '--json'],
                              stdin=subprocess.DEVNULL, env=c.env, stdout=subprocess.PIPE, text=True)
    time.sleep(.3)
    last = json.loads((c.root / 'state' / 'venomx' / 'last-session').read_text())
    assert last['session'] == s[0]['session'] and last['epoch'].startswith('venomx/'), last
    p.type(b'exit\r')
    code, err = p.wait()
    assert code == 0, (code, err)
    assert '[venomx: session s0 ended; server stopped]' in err, err
    until(lambda: not c.alive() and not c.socket.exists(), 'daemon exit')
    out, _ = events.communicate(timeout=TIMEOUT)
    kinds = [(e['type'], e['data'].get('reason')) for e in map(json.loads, out.splitlines()) if e.get('type', '').endswith('.removed')]
    assert kinds == [('pane.removed', 'on_exit'), ('window.removed', 'empty'), ('session.removed', 'empty')], kinds
    assert c.run('ping', env=c.env, code=6)['error']['code'] == 'unavailable.not_running'
    ok('venomx starts an on-demand daemon, a login shell and attaches; exit cascades and stops the daemon')
    ok('doctor reports lifetime on-demand and origin interactive')

    # Against a persistent daemon the session goes, the daemon stays.
    c = Case()
    d = c.serve()
    cursor = marker(c)
    p = c.pty('new', '--name', 'work')
    until(lambda: c.sessions(), 'session')
    sid = c.sessions()[0]['session']
    until(lambda: shell_child(d.pid), 'login shell child')
    p.type(b'exit\r')
    code, err = p.wait()
    assert code == 0 and f'[venomx: session {sid} ended]' in err and 'server stopped' not in err, (code, err)
    assert c.sessions() == [] and d.poll() is None
    kinds = [(e['type'], e['data'].get('reason')) for e in replay(c, cursor, ['pane.removed', 'window.removed', 'session.removed'])]
    assert kinds == [('pane.removed', 'on_exit'), ('window.removed', 'empty'), ('session.removed', 'empty')], kinds
    assert 'origin serve' in c.checks()['daemon.origin']['message']
    ok('exiting the last shell on a persistent daemon removes the session and keeps the daemon')

    # Managed-context guard before connecting; --nested with a token.
    for marker_env in ({'VENOMX_PANE': 'p0'}, {'VENOMX_PRINCIPAL': ''}):
        p = c.pty('new', '--json', env=dict(c.env, **marker_env))
        code, err = p.wait()
        assert code == 4, (marker_env, code, err)
    c2 = Case()
    p = c2.pty('new', env=dict(c2.env, VENOMX_PANE='p0'))
    assert p.wait()[0] == 4 and not c2.alive() and not c2.socket.exists()
    p = c2.pty('new', '--nested', env=dict(c2.env, VENOMX_PANE='p0', VENOMX_TOKEN='vxt_bogus'))
    assert p.wait()[0] == 6 and not c2.alive()  # never starts a daemon
    # With no daemon running, a manager's marker above the
    # caller refuses the launch and names the marker. This test holds the marker.
    c3 = Case()
    start = Path('/proc/self/stat').read_text().rpartition(')')[2].split()[19]
    c3.socket.parent.mkdir(mode=0o700)
    mark = c3.socket.parent / f'manager-{os.getpid()}-{start}'
    mark.touch(mode=0o600)
    for args in (['new'], []):
        p = c3.pty(*args)
        code, err = p.wait()
        assert code == 4 and str(mark) in err, (args, code, err)
        assert not c3.alive() and not c3.socket.exists() and list(c3.socket.parent.iterdir()) == [mark], args
    p = c3.pty('new', '--json')
    assert p.wait()[0] == 4
    assert b'denied.startup_context' in bytes(p.out), bytes(p.out)
    # With no marker above it, the same call starts one.
    mark.unlink()
    p = c3.pty('new', '-d', '--name', 'free')
    assert p.wait()[0] == 0
    assert len(c3.alive()) == 1 and [x['name'] for x in c3.sessions()] == ['free']
    c3.close()
    owner_token = (c.root / 'run' / 'venom' / 'venomx.owner').read_text().strip()
    nested = dict(c.env, VENOMX_PANE='p9', VENOMX_PRINCIPAL='g9', VENOMX_TOKEN=owner_token)
    p = c.pty('new', '--nested', '--name', 'inner', env=nested)
    until(lambda: [x for x in c.sessions() if x['name'] == 'inner'], 'nested session')
    time.sleep(.3)
    assert p.running()
    p.type(PREFIX + b'd')
    code, err = p.wait()
    assert code == 0 and '[venomx: detached from' in err and '(inner)' in err, (code, err)
    ok('new refuses managed contexts without connecting; --nested with a token attaches to a running daemon')

    # Selector-less attach picks the last-attached session, then detach.
    inner = [x for x in c.sessions() if x['name'] == 'inner'][0]['session']
    c.run('session', 'create', '--name', 'newer')
    p = c.pty('attach')
    time.sleep(.5)
    assert p.running()
    p.type(PREFIX + b'd')
    code, err = p.wait()
    assert code == 0 and f'detached from {inner}' in err, (code, err)
    assert 'live session' in c.checks()['attach.last_session']['message']
    (c.root / 'state' / 'venomx' / 'last-session').write_text(json.dumps({'epoch': 'venomx/stale', 'session': inner}) + '\n')
    assert c.checks()['attach.last_session']['status'] == 'warn'
    ok('selector-less attach uses the last-session file; doctor flags a stale one')

    # New -A attaches to the one match, creates when none, fails on two.
    before = len(c.sessions())
    p = c.pty('new', '-A', '-d', '--name', 'inner', '--json')
    code, _ = p.wait()
    assert code == 0 and len(c.sessions()) == before
    p = c.pty('new', '-A', '--name', 'inner')
    time.sleep(.5)
    assert p.running() and len(c.sessions()) == before
    p.type(PREFIX + b'd')
    assert p.wait()[0] == 0
    p = c.pty('new', '-A', '-d', '--name', 'fresh')
    assert p.wait()[0] == 0 and len(c.sessions()) == before + 1
    c.run('session', 'create', '--name', 'inner')
    p = c.pty('new', '-A', '-d', '--name', 'inner', '--json')
    code, _ = p.wait()
    assert code == 5, code
    out = bytes(p.out).decode(errors='replace')
    assert 'conflict.ambiguous_name' in out, out
    ok('new -A attaches with one match, creates with none, fails conflict.ambiguous_name with two')

    # on_exit keep (the default) survives exit; run panes ignore on_exit;
    # remove cascades only as far as it empties.
    sid = c.run('session', 'create', '--name', 'policies')['session']
    kept = c.run('window', 'create', '--session', sid, '--argv', '["/bin/sh","-c","echo kept; exit 3"]')['pane']
    until(lambda: c.run('pane', 'capture', '--pane', kept)['exited'], 'kept pane exit')
    cap = c.run('pane', 'capture', '--pane', kept)
    assert cap['exit_code'] == 3 and 'kept' in cap['text']
    cursor = marker(c)
    split = c.run('window', 'create', '--session', sid, '--argv', '["/bin/sh","-c","read x"]')
    gone = c.run('pane', 'split', '--pane', split['pane'], '--axis', 'cols', '--on-exit', 'remove', '--argv', '["/bin/sh","-c","exit 0"]')['pane']
    until(lambda: gone not in [x['pane'] for x in c.run('pane', 'list')['panes']], 'split pane removal')
    assert c.run('window', 'get', '--window', split['window'])['nodes'] == [{'kind': 'pane', 'pane': split['pane']}]
    kinds = [(e['type'], e['data'].get('reason')) for e in replay(c, cursor, ['pane.removed', 'window.removed', 'window.layout_changed', 'session.removed'])]
    assert ('pane.removed', 'on_exit') in kinds and ('window.removed', 'empty') not in kinds, kinds
    # A whole window empties, but the session (on_empty keep) stays.
    alone = c.run('window', 'create', '--session', sid, '--on-exit', 'remove', '--argv', '["/bin/sh","-c","exit 0"]')
    until(lambda: alone['window'] not in [w['window'] for w in c.run('session', 'get', '--session', sid)['windows']], 'window removal')
    assert sid in [x['session'] for x in c.sessions()]
    started = c.run('run', '--key', 'k1', '--session', sid, '--argv', '["/bin/sh","-c","echo ran"]')
    done = c.run('run', 'wait', '--run', started['run'])
    assert done['outcome'] == 'succeeded'
    assert started['pane'] in [x['pane'] for x in c.run('pane', 'list')['panes']]
    ok('on_exit=keep panes survive and can be captured; run panes ignore on_exit; cascades stop at non-empty containers')

    # Attach, session list, mcp never start a daemon (even when the
    # owner opted into on-demand session create).
    c = Case(config='.{ .daemon = .{ .startup = "on-demand" } }\n')
    p = c.pty('attach')
    assert p.wait()[0] == 6
    c.run('session', 'list', code=6)
    mcp = '\n'.join(json.dumps(m) for m in [
        {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 't', 'version': '1'}}},
        {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
        {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
        {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'session_dcreate', 'arguments': {'name': 'via-mcp'}}},
    ]) + '\n'
    r = subprocess.run([EXE, 'mcp'], input=mcp, env=c.owner, capture_output=True, text=True, timeout=TIMEOUT)
    lines = [json.loads(line) for line in r.stdout.splitlines()]
    tools = {t['name'] for t in [x for x in lines if x.get('id') == 2][0]['result']['tools']}
    assert 'new' not in tools and 'attach' not in tools, tools
    call = [x for x in lines if x.get('id') == 3][0]
    assert call['result']['isError'] and 'unavailable.not_running' in call['result']['content'][0]['text'], call
    assert not c.alive() and not c.socket.exists()
    # daemon.interactive_start = false: `new` gets unavailable.not_running.
    c3 = Case(config='.{ .daemon = .{ .interactive_start = false } }\n')
    p = c3.pty('new')
    assert p.wait()[0] == 6 and not c3.alive()
    ok('attach, session list and mcp never start a daemon; interactive_start=false refuses new')

    # Two concurrent starts produce one daemon.
    c = Case()
    a = c.pty('new', '-d', '--name', 'one')
    b = c.pty('new', '-d', '--name', 'two')
    assert a.wait()[0] == 0 and b.wait()[0] == 0
    # Each client may launch a candidate and only one gets the
    # lock. A client can finish on the winner while its own candidate has not
    # reached the lock yet, so the loser is awaited; a second holder never is.
    holder = c.lock_holders()
    assert len(holder) == 1, (holder, c.alive())
    until(lambda: len(c.alive()) == 1, 'the losing candidate exits')
    assert c.alive() == holder == c.lock_holders(), (holder, c.alive())
    assert sorted(x['name'] for x in c.sessions()) == ['one', 'two']
    ok('two concurrent venomx starts produce one daemon')

    # A loser whose launcher is gone has no reader for its termination record:
    # it exits at once, without an error trace.
    reader, writer = os.pipe()
    os.close(reader)
    r = subprocess.run([EXE, 'serve', '--lifetime=on-demand', '--json'], stdin=subprocess.DEVNULL, stdout=writer, stderr=subprocess.PIPE, env=c.env, timeout=TIMEOUT)
    os.close(writer)
    assert r.returncode == 1 and r.stderr == b'', (r.returncode, r.stderr[:500])
    assert c.alive() == holder, (holder, c.alive())
    ok('a losing candidate with no launcher left exits without an error trace')

    # attach.on_session_end = "next" moves to the next session.
    c = Case(config='.{ .attach = .{ .on_session_end = "next" } }\n')
    d = c.serve()
    other = c.run('session', 'create', '--name', 'other')['session']
    p = c.pty('new', '--name', 'first')
    until(lambda: len(c.sessions()) == 2, 'second session')
    until(lambda: shell_child(d.pid), 'login shell child')
    # The client may still be attaching here: its typeahead must survive the
    # raw-mode switch and the pane stream's attach.
    p.type(b'exit\r')
    until(lambda: len(c.sessions()) == 1, 'first session removal')
    time.sleep(.5)
    assert p.running(), p.wait()
    until(lambda: json.loads((c.root / 'state' / 'venomx' / 'last-session').read_text())['session'] == other, 'attached to the next session')
    p.type(PREFIX + b'd')
    code, err = p.wait()
    assert code == 0 and f'detached from {other}' in err, (code, err)
    ok('attach.on_session_end="next" attaches to the next session')

    # Keys typed while `new` is still starting reach the shell.
    # Typed right after spawning the client, before it has even connected.
    e = Case()
    ed = e.serve()
    p = e.pty('new', '--name', 'eager')
    p.type(b'exit\r')
    code, err = p.wait()
    assert code == 0 and '[venomx: session' in err and 'ended' in err, (code, err)
    assert e.sessions() == [], e.sessions()
    ed.terminate()
    ed.wait(timeout=TIMEOUT)
    ok('typeahead typed while venomx new starts reaches the pane')

    # Help and docs show the one-word start; skill and MCP omit new.
    r = subprocess.run([EXE, 'new', '--help'], stdin=subprocess.DEVNULL, env=c.env, capture_output=True, text=True, timeout=TIMEOUT)
    assert r.returncode == 0 and '--attach-existing' in r.stdout and '--detached' in r.stdout
    skill = c.run('skill', env=c.env)
    assert 'Agents must never run' in json.dumps(skill)
    ok('generated help documents new; the skill tells agents not to use it')

    # The venom-os defaults file.
    c = Case(defaults='.{ .daemon = .{ .interactive_start = false }, .status = .{ .position = .bottom } }\n')
    p = c.pty('new')
    assert p.wait()[0] == 6 and not c.alive(), 'interactive_start=false from defaults.zon must refuse new'
    d = c.serve()
    got = c.run('config', 'get', '--key', 'daemon.interactive_start', env=c.env)
    assert got['content'] == 'false' and got['source'] == 'defaults', got
    assert c.checks()['daemon.interactive_start']['message'] == 'active false; persisted false'
    # A user key replaces the same default; config set writes the user file only.
    c.run('config', 'set', '--key', 'status.position', '--value', '.off')
    got = c.run('config', 'get', '--key', 'status.position', env=c.env)
    assert got['content'] == '.off' and got['source'] == 'user', got
    assert '.bottom' in c.defaults.read_text() and '.off' in (c.root / 'cfg' / 'venomx' / 'config.zon').read_text()
    # An invalid defaults file fails config check like an invalid user file.
    c.defaults.write_text('.{ .daemon = .{ .interactive_start = 7 } }\n')
    bad = c.run('config', 'check', code=2)['error']
    assert bad['code'] == 'invalid_params.config_zon' and bad['data']['source'] == 'defaults', bad
    help_text = subprocess.run([EXE, '--help'], stdin=subprocess.DEVNULL, env=c.env, capture_output=True, text=True,
                               timeout=TIMEOUT).stdout + json.dumps(c.run('skill', env=c.env))
    assert 'defaults.zon' in help_text, 'help or skill must document the defaults file'
    d.terminate()
    d.wait(timeout=TIMEOUT)
    ok('defaults.zon: interactive_start=false refuses new, values report source defaults, user config wins, invalid defaults fail check')
    for case in Case.all:
        case.close()
    print(f'ok standalone entry point: {len(results)} cases', flush=True)


import traceback
failed = False
try:
    main()
except BaseException:
    traceback.print_exc()
    failed = True
finally:
    stray = daemons(ROOT)
    for pid in stray:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    subprocess.run(['rm', '-rf', str(ROOT)], check=False)
    if stray:
        print('stray daemons killed:', stray, file=sys.stderr)
    if failed or stray:
        sys.exit(1)
