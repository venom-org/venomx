#!/usr/bin/env python3
"""Explicit pane termination and recursive removal.

Runs termination conformance checks against a real headless daemon built with the
test seam (`-Dtest-seams=true`): real processes, PTYs and process groups,
through the CLI, MCP, NDJSON and binary streams. Termination in on-demand
mode and after a restore is not covered here.
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
TIMEOUT = 10
IGNORE = 'trap "" HUP TERM INT; echo ready; while :; do sleep 1; done'
SIG = {1: 'HUP', 2: 'INT', 9: 'KILL', 15: 'TERM', 18: 'CONT'}


def until(fn, timeout=TIMEOUT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('condition did not become true')


class Wire:
    def __init__(self, path, token=None, binary=False):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(TIMEOUT)
        self.sock.connect(path)
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

    def read(self):
        return json.loads(self.io.readline())

    def call(self, verb, params=None, id=1):
        self.send({'id': id, 'verb': verb, 'params': params or {}})
        return self.read()

    def frame(self, kind, stream, payload):
        if not isinstance(payload, bytes):
            payload = json.dumps(payload, separators=(',', ':')).encode()
        self.io.write(struct.pack('>HII', kind, stream, len(payload)) + payload)

    def exact(self, n):
        result = b''
        while len(result) < n:
            chunk = self.io.read(n - len(result))
            assert chunk, 'binary connection closed'
            result += chunk
        return result

    def recv(self):
        kind, stream, n = struct.unpack('>HII', self.exact(10))
        return kind, stream, self.exact(n)

    def attach(self, pane, stream=1):
        self.frame(0x100, stream, {'pane': pane, 'mode': 'raw', 'formats': ['vt'], 'size': {'cols': 80, 'rows': 24}, 'history': 0})
        while True:
            kind, number, data = self.recv()
            assert kind != 3, data
            if kind == 0x103:
                return

    def close(self):
        self.io.close()
        self.sock.close()


with tempfile.TemporaryDirectory(prefix='vx-term-') as root:
    root = Path(root)
    path = str(root / 'd.sock')
    siglog = root / 'signals.log'
    stuck = root / 'venomx-stuck'
    stuck.symlink_to('/bin/sh')
    env = {k: v for k, v in os.environ.items() if not k.endswith('_TOKEN')}
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / 'cfg'), XDG_CONFIG_DIRS=str(root / 'cfg' / 'xdg'), XDG_STATE_HOME=str(root / 'state'), VENOMX_TEST_SIGNAL_LOG=str(siglog))
    # These cases test grants and namespaces, so isolation is on.
    (Path(root) / 'cfg' / 'xdg' / 'venomx').mkdir(parents=True, exist_ok=True); (Path(root) / 'cfg' / 'xdg' / 'venomx' / 'defaults.zon').write_text('.{ .grants = .{ .isolation = true } }\n')
    owner = dict(env, VENOMX_TOKEN='@owner')

    def run(args, environ):
        return subprocess.run([EXE, *args, '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=environ, capture_output=True, text=True, timeout=TIMEOUT)

    def cli(*args, code=0, token='@owner'):
        r = run(args, dict(env, VENOMX_TOKEN=token) if token else env)
        assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
        assert not r.stderr, r.stderr
        return json.loads(r.stdout)

    def err(*args, code, token='@owner'):
        return cli(*args, code=code, token=token)['error']

    def mcp(name, arguments, token='@owner'):
        msgs = [{'jsonrpc': '2.0', 'id': 0, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 't', 'version': '0'}}},
                {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
                {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': name, 'arguments': arguments}}]
        r = subprocess.run([EXE, 'mcp', '--socket', path], input=''.join(json.dumps(m) + '\n' for m in msgs), capture_output=True, text=True, timeout=TIMEOUT, env=dict(env, VENOMX_TOKEN=token) if token else env)
        assert r.returncode == 0 and not r.stderr, (r.returncode, r.stderr)
        reply = [json.loads(line) for line in r.stdout.splitlines() if json.loads(line).get('id') == 1][0]['result']
        return json.loads(reply['content'][0]['text']), reply['isError']

    def events(after=None, token=None):
        args = ['events', '--follow=false'] + ([f'--after={after}'] if after else [])
        r = run(args, dict(env, VENOMX_TOKEN=token) if token else owner)
        assert r.returncode == 0, (r.stdout, r.stderr)
        return [json.loads(line) for line in r.stdout.splitlines()]

    def cursor():
        e = events()[-1]
        return f"{e['source']}:{e['seq']}"

    def since(c, pred=lambda e: True, token=None):
        return [e for e in events(c, token) if e['type'] not in ('stream.checkpoint',) and e['type'] != 'principal.denied' and pred(e)]

    def terminating(c, pane):
        until(lambda: any(e['type'] == 'pane.terminating' and e['data']['pane'] == pane for e in events(c)))

    def signals():
        if not siglog.exists():
            return []
        return [tuple(map(int, line.split())) for line in siglog.read_text().splitlines()]

    def capture(p):
        return cli('pane', 'capture', f'--pane={p}')

    def ready(p):
        until(lambda: 'ready' in capture(p)['text'])

    def gone(pid):
        return not Path(f'/proc/{pid}').exists() or 'zombie' in Path(f'/proc/{pid}/status').read_text().lower()

    def session(name):
        return cli('session', 'create', f'--name={name}')['session']

    def window(s, argv):
        return cli('window', 'create', f'--session={s}', f'--argv={json.dumps(argv)}')

    def split(p, argv, axis='cols'):
        return cli('pane', 'split', f'--pane={p}', f'--axis={axis}', f'--argv={json.dumps(argv)}')

    def tree_valid():
        for s in cli('session', 'list')['sessions']:
            for w in cli('session', 'get', f'--session={s["session"]}')['windows']:
                nodes = cli('window', 'get', f'--window={w["window"]}')['nodes']
                panes = [n['pane'] for n in nodes if n['kind'] == 'pane']
                assert len(panes) == len(set(panes)), nodes
        return True

    # Detached from our pipes, so a failure can never leave a reader hanging.
    sentinel = subprocess.Popen(['sleep', '1000'], start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    d = subprocess.Popen([EXE, 'serve', '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    clients = []
    try:
        until(lambda: Path(path).exists() or d.poll() is not None)
        assert d.poll() is None, d.communicate()
        token = (root / 'd.owner').read_text().strip()
        s0 = session('main')

        # Cooperative shell; response after reap; terminating then exited; EXIT frame.
        w = window(s0, ['/bin/sh'])
        p, pid = w['pane'], w['pid']
        watcher = Wire(path, token, binary=True); clients.append(watcher)
        watcher.attach(p)
        c = cursor()
        got = cli('pane', 'kill', f'--pane={p}')
        assert got == {'pane': p, 'outcome': 'terminated', 'removed': False, 'escalated': False, 'signal': 'SIGHUP'}, got
        assert gone(pid)
        kinds = [e['type'] for e in since(c, lambda e: e['data'].get('pane') == p)]
        assert kinds.index('pane.terminating') < kinds.index('pane.exited'), kinds
        term = [e for e in since(c) if e['type'] == 'pane.terminating'][0]
        assert term['data'] == {'pane': p, 'requested_signal': 'SIGHUP'}, term
        while True:
            kind, _, data = watcher.recv()
            if kind == 0x109:
                assert json.loads(data)['signal'] == 'SIGHUP'
                break
        assert (-pid, 1) in signals() and (-pid, 18) in signals()

        # 20 (kill part) + 6: exited pane; nothing is sent, then removal with its events.
        before = len(signals())
        assert cli('pane', 'kill', f'--pane={p}')['outcome'] == 'already_exited'
        c = cursor()
        got = cli('pane', 'kill', f'--pane={p}', '--remove=true')
        assert got == {'pane': p, 'outcome': 'already_exited', 'removed': True, 'escalated': False, 'signal': 'SIGHUP'}, got
        assert len(signals()) == before, signals()[before:]
        assert [e['type'] for e in since(c)] == ['pane.removed', 'window.layout_changed']
        assert err('pane', 'kill', f'--pane={p}', '--remove=true', code=3)['code'] == 'not_found.pane'

        # 2 + 5: a signal-ignoring pane escalates at the deadline, and the
        # reactor keeps serving everyone in the meantime. The grace is long
        # enough that a loaded machine finishes the other requests inside
        # it; "served meanwhile" is that the kill is still pending.
        grace = 3.0
        w = window(s0, ['/bin/sh', '-c', IGNORE]); hung = w['pane']; ready(hung)
        other = window(s0, ['/bin/sh'])['pane']
        kill = subprocess.Popen([EXE, 'pane', 'kill', f'--pane={hung}', f'--grace-ms={int(grace * 1000)}', '--socket', path, '--json'], env=owner, stdout=subprocess.PIPE, text=True)
        started = time.monotonic()
        time.sleep(.1)
        for _ in range(3):
            t = time.monotonic()
            cli('ping'); cli('pane', 'send', f'--pane={other}', '--text=echo hi\n'); events()
            assert time.monotonic() - t < grace / 2
        stream = Wire(path, token, binary=True); clients.append(stream); stream.attach(other)
        assert kill.poll() is None and time.monotonic() - started < grace, 'the reactor must serve others during the grace'
        got = json.loads(kill.communicate(timeout=TIMEOUT)[0]); took = time.monotonic() - started
        assert got == {'pane': hung, 'outcome': 'terminated', 'removed': False, 'escalated': True, 'signal': 'SIGKILL'}, got
        assert grace <= took < grace + 1.0 + .5, took
        # Every published tree is valid.
        assert tree_valid()

        # The pinned sweep kills a member the leader left behind.
        w = window(s0, ['/bin/sh', '-c', '(trap "" HUP; exec sleep 1000) & echo bg=$!; wait'])
        until(lambda: 'bg=' in capture(w['pane'])['text'])
        bg = int(capture(w['pane'])['text'].split('bg=')[1].split()[0])
        assert cli('pane', 'kill', f'--pane={w["pane"]}')['outcome'] == 'terminated'
        until(lambda: gone(bg))
        # gone() accepts a zombie, which pgrep still lists until the reaper's next turn.
        until(lambda: subprocess.run(['pgrep', '-g', str(w['pid'])], capture_output=True).returncode == 1)

        # A stopped group is continued and acts on the requested signal.
        w = window(s0, ['/bin/sh', '-c', 'echo ready; exec sleep 1000']); ready(w['pane'])
        os.killpg(w['pid'], signal.SIGSTOP)
        got = cli('pane', 'kill', f'--pane={w["pane"]}', '--signal=SIGTERM', '--grace-ms=5000')
        assert got['escalated'] is False and got['signal'] == 'SIGTERM', got

        # A terminating pane freezes input; send/split/remove are refused.
        w = window(s0, ['/bin/sh', '-c', IGNORE]); t13 = w['pane']; ready(t13)
        writer = Wire(path, token, binary=True); clients.append(writer); writer.attach(t13)
        control = Wire(path, token); clients.append(control)
        c_t = cursor()
        control.send({'id': 5, 'verb': 'pane.kill', 'params': {'pane': t13, 'grace_ms': 800}})
        terminating(c_t, t13)
        assert err('pane', 'send', f'--pane={t13}', '--text=MARK\n', code=5)['code'] == 'conflict.pane_terminating'
        assert err('pane', 'split', f'--pane={t13}', '--axis=cols', '--argv=["/bin/sh"]', code=5)['code'] == 'conflict.pane_terminating'
        assert err('pane', 'remove', f'--pane={t13}', code=5)['code'] == 'conflict.pane_running'
        writer.frame(0x106, 1, b'echo LEAKED\n')
        assert cli('ping') == {}
        reply = control.read()
        assert reply['ok']['escalated'] is True, reply
        assert 'LEAKED' not in capture(t13)['text']

        # Concurrent kills: one requested signal, deadline shortened, same result.
        w = window(s0, ['/bin/sh', '-c', IGNORE]); t19 = w['pane']; ready(t19)
        a, b = Wire(path, token), Wire(path, token); clients += [a, b]
        started = time.monotonic()
        a.send({'id': 7, 'verb': 'pane.kill', 'params': {'pane': t19, 'grace_ms': 5000}})
        time.sleep(.05)
        b.send({'id': 8, 'verb': 'pane.kill', 'params': {'pane': t19, 'grace_ms': 200, 'signal': 'SIGTERM'}})
        ra, rb = a.read()['ok'], b.read()['ok']
        assert ra == rb and ra['escalated'] is True, (ra, rb)
        assert time.monotonic() - started < 2
        assert [s for s in signals() if s[0] == -w['pid'] and s[1] in (1, 15)] == [(-w['pid'], 1)], signals()

        # A pane kills itself with `write self`.
        script = f'echo ready; exec {EXE} pane kill --pane "$VENOMX_PANE" --socket "$VENOMX_SOCKET" --json'
        w = cli('window', 'create', f'--session={s0}', f'--argv={json.dumps(["/bin/sh", "-c", script])}', '--grants=[{"right":"write","scope":"self"}]')
        until(lambda: capture(w['pane'])['exited'])
        assert gone(w['pid']) and cli('ping') == {}
        live = lambda: {x['principal'] for x in cli('grant', 'list')['principals']}
        until(lambda: w['principal'] not in live())  # grant revocation on root exit

        # Missing targets and denied callers.
        for args in (['pane', 'kill', '--pane=p999'], ['window', 'remove', '--window=w999', '--recursive=true'], ['session', 'remove', '--session=s999', '--recursive=true']):
            assert err(*args, code=3)['code'].startswith('not_found.')
            denied_missing = err(*args, code=4, token=None)
            assert denied_missing['code'] == 'denied.write'
        # The dispatch gate and the named-target check (before lookup) both
        # answer identically for existing and missing targets.
        gate = [err('pane', 'kill', f'--pane={x}', code=4, token=None) for x in (other, 'p999')]
        assert gate[0] == gate[1] and gate[0]['code'] == 'denied.write', gate
        elsewhere = cli('grant', 'issue', '--grants=[{"right":"write","scope":"pane:p9999"}]')['token']
        existing = err('pane', 'kill', f'--pane={other}', code=4, token=elsewhere)
        missing = err('pane', 'kill', '--pane=p999', code=4, token=elsewhere)
        assert existing['code'] == missing['code'] == 'denied.write'
        assert existing['data']['resource'] == f'pane:{other}' and missing['data']['resource'] == 'pane:p999'
        # MCP is denied and allowed the same way.
        body, is_error = mcp('pane_dkill', {'pane': other}, token=None)
        assert is_error and body['error']['code'] == 'denied.write', body
        body, is_error = mcp('pane_dkill', {'pane': other, 'grace_ms': 1000}, token=token)
        assert not is_error and body['result']['outcome'] == 'terminated', body

        # No opt-in: conflicts, no side effects.
        s9 = session('nine'); w9 = window(s9, ['/bin/sh']); before = len(signals()); c = cursor()
        assert err('window', 'remove', f'--window={w9["window"]}', code=5)['code'] == 'conflict.not_empty'
        assert err('pane', 'remove', f'--pane={w9["pane"]}', code=5)['code'] == 'conflict.pane_running'
        assert err('session', 'remove', f'--session={s9}', code=5)['code'] == 'conflict.not_empty'
        assert since(c) == [] and len(signals()) == before

        # Only `write window:*`, and `write self` over another principal's pane.
        wildcard = cli('grant', 'issue', '--grants=[{"right":"write","scope":"window:*"}]')
        e = err('window', 'remove', f'--window={w9["window"]}', '--recursive=true', code=4, token=wildcard['token'])
        assert e['code'] == 'denied.write' and 'resource' not in e['data'] and e['data']['right'] == 'write', e
        # An owner window holding the caller's own pane and a foreign one: the
        # caller passes the target (window:*) and its own pane (self), then
        # fails on the foreign descendant.
        s11 = session('eleven')
        spawner = cli('grant', 'issue', f'--grants=[{{"right":"spawn","scope":"session:{s11}"}},{{"right":"read","scope":"*"}}]')
        w11 = cli('window', 'create', f'--session={s11}', '--argv=["/bin/sh"]')
        own = cli('pane', 'split', f'--pane={w11["pane"]}', '--axis=cols', '--argv=["/bin/sh"]', '--grants=[{"right":"write","scope":"self"},{"right":"write","scope":"window:*"}]')
        own_token = None
        mine = cli('grant', 'issue', '--grants=[{"right":"write","scope":"self"},{"right":"write","scope":"window:*"}]')
        # The caller's principal owns `mine_pane`; the owner owns w11["pane"].
        mine_pane = cli('pane', 'split', f'--pane={w11["pane"]}', '--axis=rows', '--argv=["/bin/sh"]', token=cli('grant', 'issue', f'--grants=[{{"right":"spawn","scope":"window:{w11["window"]}"}}]')['token'])
        foreign = {'pane': w11['pane']}
        c = cursor(); before = len(signals())
        e = err('window', 'remove', f'--window={w11["window"]}', '--recursive=true', code=4, token=mine['token'])
        assert e['code'] == 'denied.write' and 'resource' not in e['data'], e
        assert since(c) == [] and len(signals()) == before
        assert not capture(w11['pane'])['exited'] and not capture(own['pane'])['exited']
        cli('session', 'remove', f'--session={s11}', '--recursive=true', '--grace-ms=0')

        # `write session:<id>` covers the whole subtree.
        scoped = cli('grant', 'issue', f'--grants=[{{"right":"write","scope":"session:{s9}"}}]')
        assert cli('session', 'remove', f'--session={s9}', '--recursive=true', token=scoped['token']) == {}
        assert gone(w9['pid'])

        # 8 + 16 + 26: nested session removal: exact event order, IDs not reused,
        # scoped subscribers see removal events; unrelated ones never do.
        s8 = session('eight')
        wa = window(s8, ['/bin/sh']); pb = split(wa['pane'], ['/bin/sh', '-c', 'exit 3'])['pane']
        pc = split(wa['pane'], ['/bin/sh', '-c', IGNORE], axis='rows')['pane']
        wb = window(s8, ['/bin/sh', '-c', 'exit 0'])
        until(lambda: capture(pb)['exited'] and capture(wb['pane'])['exited']); ready(pc)
        r_pane = cli('grant', 'issue', f'--grants=[{{"right":"read","scope":"pane:{pc}"}}]')['token']
        r_sess = cli('grant', 'issue', f'--grants=[{{"right":"read","scope":"session:{s8}"}}]')['token']
        r_other = cli('grant', 'issue', '--grants=[{"right":"read","scope":"pane:p9999"}]')['token']
        ptys_before = len([f for f in os.listdir(f'/proc/{d.pid}/fd') if os.readlink(f'/proc/{d.pid}/fd/{f}') == '/dev/ptmx'])
        c = cursor()
        got, is_error = mcp('session_dremove', {'session': s8, 'recursive': True, 'grace_ms': 300}, token=token)
        assert not is_error and got == {'result': {}}, got
        order = [(e['type'], e['data'].get('pane') or e['data'].get('window') or e['data'].get('session')) for e in since(c) if e['type'] not in ('pane.exited', 'pane.title_changed', 'program.status_changed', 'command.finished', 'principal.revoked')]
        expect = [('pane.terminating', wa['pane']), ('pane.terminating', pc), ('pane.removed', wa['pane']), ('pane.removed', pb), ('pane.removed', pc), ('window.removed', wa['window']), ('pane.removed', wb['pane']), ('window.removed', wb['window']), ('session.removed', s8)]
        assert order == expect, order
        assert err('session', 'get', f'--session={s8}', code=3)['code'] == 'not_found.session'
        assert all(p['session'] != s8 for p in cli('pane', 'list')['panes'])
        ptys_after = len([f for f in os.listdir(f'/proc/{d.pid}/fd') if os.readlink(f'/proc/{d.pid}/fd/{f}') == '/dev/ptmx'])
        assert ptys_after == ptys_before - 4, (ptys_before, ptys_after)
        assert int(session('after')[1:]) > int(s8[1:])
        assert {e['type'] for e in since(c, token=r_pane)} >= {'pane.removed', 'pane.terminating', 'pane.exited'}
        assert 'session.removed' in {e['type'] for e in since(c, token=r_sess)}
        assert since(c, token=r_other) == []
        # 20 (recursive part): a repeat after success sees not_found.
        assert err('session', 'remove', f'--session={s8}', '--recursive=true', code=3)['code'] == 'not_found.session'

        # 12 + 14: a sealed subtree refuses mutations; kill without remove joins.
        s14 = session('fourteen'); w14 = window(s14, ['/bin/sh', '-c', IGNORE]); ready(w14['pane'])
        ex = split(w14['pane'], ['/bin/sh', '-c', 'exit 0'])['pane']; until(lambda: capture(ex)['exited'])
        remover = Wire(path, token); clients.append(remover)
        c_t = cursor()
        remover.send({'id': 9, 'verb': 'window.remove', 'params': {'window': w14['window'], 'recursive': True, 'grace_ms': 1500}})
        terminating(c_t, w14['pane'])
        assert err('pane', 'split', f'--pane={w14["pane"]}', '--axis=cols', '--argv=["/bin/sh"]', code=5)['code'] == 'conflict.removing'
        assert err('pane', 'remove', f'--pane={ex}', code=5)['code'] == 'conflict.removing'
        assert err('pane', 'kill', f'--pane={ex}', '--remove=true', code=5)['code'] == 'conflict.removing'
        assert err('window', 'remove', f'--window={w14["window"]}', '--recursive=true', code=5)['code'] == 'conflict.removing'
        assert err('window', 'remove', f'--window={w14["window"]}', code=5)['code'] == 'conflict.removing'
        joined = cli('pane', 'kill', f'--pane={w14["pane"]}')
        assert joined['outcome'] == 'terminated' and joined['escalated'] is True, joined
        assert remover.read() == {'id': 9, 'ok': {}}
        # The other order of 12: a creation committed before the seal is part
        # of the subtree and removed with it.
        w12 = window(s14, ['/bin/sh']); p12 = split(w12['pane'], ['/bin/sh'])
        assert cli('window', 'remove', f'--window={w12["window"]}', '--recursive=true') == {}
        assert gone(p12['pid']) and gone(w12['pid'])

        # A stream that never reads cannot hold up kill and removal.
        # An unbounded producer fills the stalled reader's backlog .
        w15 = window(s14, ['/bin/sh', '-c', 'yes FLOOD'])
        slow = Wire(path, token, binary=True); clients.append(slow)
        slow.frame(0x100, 1, {'pane': w15['pane'], 'mode': 'raw', 'formats': ['vt'], 'size': {'cols': 80, 'rows': 24}, 'history': 0})
        until(lambda: 'FLOOD' in capture(w15['pane'])['text'])
        t = time.monotonic()
        assert cli('pane', 'kill', f'--pane={w15["pane"]}', '--remove=true')['removed'] is True
        assert time.monotonic() - t < 2
        slow.sock.settimeout(TIMEOUT)
        try:
            while True:
                kind, _, data = slow.recv()
                if kind == 6:  # CLOSE
                    assert json.loads(data) == {'reason': 'pane_removed'}
                    break
        except AssertionError as closed:
            assert 'closed' in str(closed), closed  # closed by overflow instead

        # Cancel, and separately a closed connection: cancelled; the
        # process is still killed by the deadline; nothing removed; seal lifted.
        for how in ('cancel', 'close'):
            s17 = session('seventeen'); w17 = window(s17, ['/bin/sh', '-c', IGNORE]); ready(w17['pane'])
            conn = Wire(path, token)
            c_t = cursor()
            conn.send({'id': 11, 'verb': 'session.remove', 'params': {'session': s17, 'recursive': True, 'grace_ms': 400}})
            terminating(c_t, w17['pane'])
            # window.create into a sealed session.
            assert err('window', 'create', f'--session={s17}', '--argv=["/bin/sh"]', code=5)['code'] == 'conflict.removing'
            if how == 'cancel':
                conn.send({'id': 12, 'verb': 'cancel', 'params': {'id': 11}})
                replies = [conn.read(), conn.read()]
                assert any(r.get('error', {}).get('code') == 'cancelled' for r in replies), replies
            conn.close()
            until(lambda: capture(w17['pane'])['exited'])
            assert gone(w17['pid'])
            assert cli('session', 'get', f'--session={s17}')['windows'] != []
            assert cli('window', 'create', f'--session={s17}', '--argv=["/bin/sh","-c","exit 0"]')['pane']
            assert cli('session', 'remove', f'--session={s17}', '--recursive=true') == {}

        # The seam withholds one leader's exit: timeout.terminate, nothing
        # removed, seal lifted, doctor reports it; its late exit leaves an exited,
        # unremoved pane; a retry then succeeds.
        s18 = session('eighteen')
        w18 = window(s18, [str(stuck), '-c', IGNORE]); ready(w18['pane'])
        fine = split(w18['pane'], ['/bin/sh'])
        started = time.monotonic()
        e = err('session', 'remove', f'--session={s18}', '--recursive=true', '--grace-ms=200', code=7)
        took = time.monotonic() - started
        assert e == {'code': 'timeout.terminate', 'message': 'pane did not exit after SIGKILL', 'data': {'panes': [w18['pane']]}}, e
        assert 1.2 <= took < 2.5, took
        assert capture(fine['pane'])['exited'] and not capture(w18['pane'])['exited']
        checks = {r['id']: r for r in cli('doctor')['checks']}
        assert checks['panes.stuck']['status'] == 'warn' and w18['pane'] in checks['panes.stuck']['message'], checks['panes.stuck']
        assert err('window', 'remove', f'--window={w18["window"]}', code=5)['code'] == 'conflict.not_empty'  # seal lifted
        os.killpg(w18['pid'], signal.SIGKILL)
        until(lambda: capture(w18['pane'])['exited'])
        assert cli('session', 'get', f'--session={s18}')['windows'] != []
        assert {r['id']: r for r in cli('doctor')['checks']}['panes.stuck']['status'] == 'ok'
        assert cli('session', 'remove', f'--session={s18}', '--recursive=true') == {}

        # No sentinel, no daemon group, no reaped leader was ever signalled.
        for target, _ in signals():
            assert abs(target) not in (sentinel.pid, d.pid, os.getpgid(d.pid), 0, 1), target
        assert sentinel.poll() is None

        # No zombies, no stray PTYs, removed principals revoked.
        children = subprocess.run(['ps', '-o', 'stat=', '--ppid', str(d.pid)], capture_output=True, text=True).stdout.split()
        assert not any(s.startswith('Z') for s in children), children
        checks = {r['id']: r for r in cli('doctor')['checks']}
        assert 'panes.termination' in checks and 'events.removed_records' in checks, checks.keys()
        assert checks['panes.terminating']['message'] == '0 panes terminating', checks['panes.terminating']
        assert ' 0 kills' not in checks['panes.termination']['message'], checks['panes.termination']
        # Removed panes' principals are gone; only live panes keep one.
        listed = {x['principal'] for x in cli('grant', 'list')['principals']}
        for gone_principal in (w9['principal'], wa['principal'], w18['principal']):
            assert gone_principal not in listed, gone_principal

        # An escaped descendant is reaped when it exits, and
        # the pane's exit status is still the leader's own.
        escaped_file, hold = root / 'escaped.pid', root / 'escaped.hold'
        hold.touch()
        c_e = cursor()
        # The leader waits for the setsid: its exit hangs up its own session.
        escapee = f'echo $$ > {escaped_file}; while [ -e {hold} ]; do sleep 0.02; done'
        w_e = window(s0, ['/bin/sh', '-c', f"(setsid /bin/sh -c '{escapee}' >/dev/null 2>&1 </dev/null &); until [ -s {escaped_file} ]; do sleep 0.01; done; exit 7"])
        until(lambda: capture(w_e['pane'])['exited'])
        exits = [e for e in since(c_e) if e['type'] == 'pane.exited' and e['data']['pane'] == w_e['pane']]
        assert exits[0]['data']['exit_code'] == 7, exits
        escaped = int(escaped_file.read_text())
        ppid = Path(f'/proc/{escaped}/stat').read_text().rsplit(')', 1)[1].split()[1]
        assert int(ppid) == d.pid, ppid
        hold.unlink()
        until(lambda: not Path(f'/proc/{escaped}').exists())
        termination = {r['id']: r for r in cli('doctor')['checks']}['panes.termination']['message']
        assert ' 0 escaped' not in termination, termination

        # Shutdown during an escalation: in-flight cancelled; the bound holds.
        w23 = window(s0, ['/bin/sh', '-c', IGNORE]); ready(w23['pane'])
        pending = Wire(path, token)
        c_t = cursor()
        pending.send({'id': 13, 'verb': 'pane.kill', 'params': {'pane': w23['pane'], 'grace_ms': 30000}})
        terminating(c_t, w23['pane'])
        started = time.monotonic(); d.send_signal(signal.SIGTERM)
        reply = pending.read()
        assert reply['error']['code'].startswith('cancelled'), reply
        pending.close()
        out, errout = d.communicate(timeout=6)
        assert d.returncode == 0 and out == '{}\n' and not errout, (d.returncode, out, errout)
        assert time.monotonic() - started < 3.5
        assert gone(w23['pid'])
        print('ok terminate: kill, escalation, sweep, joining, sealing, cancel, timeout, events, grants and shutdown')
    finally:
        for c in clients:
            try:
                c.close()
            except OSError:
                pass
        sentinel.kill()
        if d.poll() is None:
            d.terminate()
            d.communicate(timeout=5)
