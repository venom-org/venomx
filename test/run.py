#!/usr/bin/env python3
"""Trusted run/wait command execution results.

Runs run/wait conformance checks against real headless daemons built with the
test seam (`-Dtest-seams=true`): real PTYs and processes, through the CLI,
MCP and NDJSON, comparing CLI and MCP results for parity. A marker file appended by each command counts executions
independently of the daemon.

Not covered here: a tail taken after the history has dropped rows
(`oldest > 0`; the debug-build Vt emulates ~6 KB/s, so 100000 rows would take
minutes; 400 rows exercise the same tail selection and the `pane.capture_rows`
read-back); attaching to a run's split pane (pane-stream attach is covered by
test/attach.py).

Usage: run.py <venomx-seam>
"""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time

EXE = str(Path(sys.argv[1]).resolve())
TIMEOUT = 15
CANARY = 'cnry' + secrets.token_hex(8)
VOLATILE = {'run', 'key', 'pane', 'window', 'session', 'principal', 'pid', 'started_at', 'completed_at', 'duration_ms', 'source'}


def until(fn, timeout=TIMEOUT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('condition did not become true')


def clean_env():
    return {k: v for k, v in os.environ.items() if not (k.endswith('_TOKEN') or k.endswith('_PRINCIPAL') or k.startswith('VENOMX_') or 'vnt1.' in v)}


def stable(record):
    """A record without the fields that differ between two equal runs."""
    return {k: v for k, v in record.items() if k not in VOLATILE}


class Wire:
    """One persistent NDJSON connection."""

    def __init__(self, path, token=None, max_frame=1048576):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(TIMEOUT)
        self.sock.connect(path)
        self.io = self.sock.makefile('rwb', buffering=0)
        self.next = 1
        self.pending = []
        params = {'proto': [1], 'caps': ['cancel'], 'max_frame': max_frame}
        if token:
            params['auth'] = {'token': token}
        self.send({'id': 0, 'verb': 'hello', 'params': params})
        assert 'ok' in self.read(), 'hello failed'

    def send(self, value):
        self.io.write(json.dumps(value, separators=(',', ':')).encode() + b'\n')

    def read(self):
        line = self.io.readline()
        assert line, 'connection closed'
        return json.loads(line)

    def request(self, verb, params=None):
        n = self.next
        self.next += 1
        self.send({'id': n, 'verb': verb, 'params': params or {}})
        return n

    def reply(self, n):
        for i, m in enumerate(self.pending):
            if m.get('id') == n:
                return self.pending.pop(i)
        while True:
            m = self.read()
            if m.get('id') == n and ('ok' in m or 'error' in m):
                return m
            self.pending.append(m)

    def call(self, verb, params=None):
        return self.reply(self.request(verb, params))

    def close(self):
        self.io.close()
        self.sock.close()


class Daemon:
    def __init__(self, root, name, extra=None, reuse=False):
        self.root = Path(root) / name
        self.root.mkdir(mode=0o700, exist_ok=reuse)
        self.path = str(self.root / 'd.sock')
        self.siglog = self.root / 'signals.log'
        env = clean_env()
        env.update(HOME=str(self.root), XDG_CONFIG_HOME=str(self.root / 'cfg'), XDG_CONFIG_DIRS=str(self.root / 'cfg' / 'xdg'), XDG_STATE_HOME=str(self.root / 'state'), VENOMX_TEST_SIGNAL_LOG=str(self.siglog))
        # These cases test grants and namespaces, so isolation is on.
        (Path(self.root) / 'cfg' / 'xdg' / 'venomx').mkdir(parents=True, exist_ok=True); (Path(self.root) / 'cfg' / 'xdg' / 'venomx' / 'defaults.zon').write_text('.{ .grants = .{ .isolation = true } }\n')
        env.update(extra or {})
        self.env = env
        self.client_env = {k: v for k, v in env.items() if not k.startswith('VENOMX_')}
        self.stderr = open(self.root / 'daemon.err', 'w')
        self.proc = subprocess.Popen([EXE, 'serve', '--socket', self.path, '--json'], stdin=subprocess.DEVNULL, stdout=self.stderr, stderr=self.stderr, env=env, cwd=str(self.root))
        until(lambda: Path(self.path).exists() or self.proc.poll() is not None)
        assert self.proc.poll() is None, 'daemon failed to start'
        self.token = (self.root / 'd.owner').read_text().strip()
        self.outputs = []

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.stderr.close()

    def run(self, args, token='@owner'):
        environ = dict(self.client_env, VENOMX_TOKEN=token) if token else self.client_env
        r = subprocess.run([EXE, *args, '--socket', self.path, '--json'], stdin=subprocess.DEVNULL, env=environ, capture_output=True, text=True, timeout=TIMEOUT)
        self.outputs.append(r.stdout + r.stderr)
        return r

    def cli(self, *args, code=0, token='@owner'):
        r = self.run(args, token)
        assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
        assert not r.stderr, r.stderr
        return json.loads(r.stdout)

    def err(self, *args, code, token='@owner'):
        return self.cli(*args, code=code, token=token)['error']

    def mcp(self, name, arguments, token='@owner'):
        msgs = [{'jsonrpc': '2.0', 'id': 0, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 't', 'version': '0'}}},
                {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
                {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': name, 'arguments': arguments}}]
        environ = dict(self.client_env, VENOMX_TOKEN=token) if token else self.client_env
        r = subprocess.run([EXE, 'mcp', '--socket', self.path], input=''.join(json.dumps(m) + '\n' for m in msgs), capture_output=True, text=True, timeout=TIMEOUT, env=environ)
        assert r.returncode == 0 and not r.stderr, (r.returncode, r.stderr)
        reply = [json.loads(line) for line in r.stdout.splitlines() if json.loads(line).get('id') == 1][0]['result']
        self.outputs.append(reply['content'][0]['text'])
        body = json.loads(reply['content'][0]['text'])
        return (body['error'], True) if reply['isError'] else (body['result'], False)

    def via(self, how, verb, params, token='@owner'):
        """(ok, body, exit) through the CLI or MCP."""
        if how == 'cli':
            args = verb.split('.')
            for k, v in params.items():
                args.append(f'--{k.replace("_", "-")}={v if isinstance(v, str) else json.dumps(v)}')
            r = self.run(args, token)
            assert not r.stderr, r.stderr
            out = json.loads(r.stdout)
            if 'error' in out:
                return False, out['error'], r.returncode
            return True, out, r.returncode
        body, is_error = self.mcp(verb.replace('.', '_d'), params, token)
        return (not is_error), body, None

    def events(self):
        out = self.cli('events', '--follow=false')
        return out if isinstance(out, list) else []

    def event_lines(self, token='@owner', resources=None):
        """Every retained event, replayed from the start of this source."""
        source = self.cli('run', 'list')['source']
        args = ['events', '--follow=false', f'--after={source}:0']
        if resources:
            args.append('--resources=' + json.dumps(resources))
        r = self.run(args, token)
        # principal.* events are not run state.
        return [e for e in map(json.loads, filter(str.strip, r.stdout.splitlines())) if not e.get('type', '').startswith('principal.')]

    def signals(self):
        return self.siglog.read_text().splitlines() if self.siglog.exists() else []

    def config(self, key, value):
        self.cli('config', 'set', f'--key={key}', f'--value={value}')
        self.cli('config', 'reload')

    def issue(self, grants):
        return self.cli('grant', 'issue', f'--grants={json.dumps(grants)}')['token']


def marker(root, name):
    path = Path(root) / f'marker-{name}'
    return path, lambda: len(path.read_text().splitlines()) if path.exists() else 0


def counts(d):
    """Resources a failed run must not have created."""
    return len(d.cli('pane', 'list')['panes']), len(d.cli('run', 'list')['runs'])


def main():
    with tempfile.TemporaryDirectory(prefix='vxrun-', dir='/tmp') as root:
        root = Path(root)
        d = Daemon(root, 'main')
        try:
            cases(root, d)
        except BaseException:
            d.stop()
            sys.stderr.write((d.root / 'daemon.err').read_text()[-4000:])
            raise
        d.stop()
        canaries(d)
        drops(root)
        restart(root)
        recovered(root)
    print('run.py: all run/wait cases passed')


def start(d, key, how='cli', code=0, **params):
    params = dict({'key': key, 'session': 's0'}, **params)
    ok, body, exit_code = d.via(how, 'run', params)
    assert ok, body
    assert body['reused'] is False and body['run'].startswith('r') and body['key'] == key, body
    return body


def wait(d, run, how='cli', **params):
    ok, body, exit_code = d.via(how, 'run.wait', dict({'run': run}, **params))
    assert ok, body
    if how == 'cli':
        assert exit_code == body['status'], (exit_code, body)
    return body


def both(d, key, params, check):
    """Case through the CLI and MCP; returns the two (parity-checked) records."""
    out = []
    for how in ('cli', 'mcp'):
        r = start(d, f'{key}-{how}', how, **params)
        rec = wait(d, r['run'], how)
        check(rec)
        out.append(rec)
    assert stable(out[0]) == stable(out[1]), out
    return out


def cases(root, d):
    d.cli('session', 'create', '--name=main')

    # Exit zero.
    both(d, 'c1', {'argv': ['true']}, lambda r: r['outcome'] == 'succeeded' and r['exit_code'] == 0 and r['status'] == 0 and r['state'] == 'completed' or fail(r))
    # Nonzero exits, including the shell's own 127.
    for key, params, code in (('c2a', {'shell': 'exit 3'}, 3), ('c2b', {'argv': ['false']}, 1), ('c2c', {'shell': 'nosuchcmd'}, 127)):
        both(d, key, params, lambda r, code=code: (r['outcome'] == 'failed' and r['exit_code'] == code and r['status'] == code) or fail(r))

    # Exec failure: no run, no side effects, key reusable, marker unwritten.
    noexec = root / 'noexec'
    noexec.write_text('#!/bin/sh\necho >> x\n')
    noshebang = root / 'noshebang.sh'
    noshebang.write_text('echo >> x\n')
    noshebang.chmod(0o755)
    before = counts(d)
    high = len(d.event_lines())
    errors = []
    for how in ('cli', 'mcp'):
        for i, argv in enumerate((['/nonexistent/prog'], [str(noexec)], [str(noshebang)])):
            ok, body, code = d.via(how, 'run', {'key': f'c3-{i}', 'session': 's0', 'argv': argv})
            assert not ok and body['code'] == 'unavailable.spawn', body
            assert how == 'mcp' or code == 6
            errors.append(body)
    assert errors[:3] == errors[3:], errors
    assert counts(d) == before
    assert len(d.event_lines()) == high
    assert not (root / 'main' / 'x').exists()
    r = start(d, 'c3-0', argv=['true'])
    assert wait(d, r['run'])['outcome'] == 'succeeded'

    # Death by signal.
    both(d, 'c4', {'shell': 'kill -SEGV $$'}, lambda r: (r['outcome'] == 'signaled' and r['signal'] == 'SIGSEGV' and 'exit_code' not in r and r['status'] == 139) or fail(r))

    # Deadline: plain, HUP-trapping exit 0, HUP-ignoring (escalates).
    t0 = time.monotonic()
    r5 = [start(d, 'c5a', argv=['sleep', '100'], deadline_ms=300),
          start(d, 'c5b', shell='trap "exit 0" HUP; while :; do sleep 0.05; done', deadline_ms=300),
          start(d, 'c5c', shell='trap "" HUP; while :; do sleep 0.05; done', deadline_ms=300)]
    recs = [wait(d, x['run'], output='false') for x in r5]
    for rec in recs:
        assert rec['outcome'] == 'terminated' and rec['cause'] == 'deadline' and rec['status'] == 124, rec
    assert recs[0]['signal'] == 'SIGHUP', recs[0]
    assert recs[1]['exit_code'] == 0 and 'signal' not in recs[1], recs[1]
    assert recs[2]['signal'] == 'SIGKILL' and recs[2]['duration_ms'] >= 2000, recs[2]
    assert time.monotonic() - t0 < 10

    # Wait timeouts, cancelled and disconnected waits never touch the run.
    mpath, mcount = marker(root, 'c6')
    r6 = start(d, 'c6', shell=f'echo >> {mpath}; sleep 100')
    until(lambda: mcount() == 1)
    sent = len(d.signals())
    for how in ('cli', 'mcp'):
        ok, body, code = d.via(how, 'run.wait', {'run': r6['run'], 'timeout_ms': 100})
        assert not ok and body == {'code': 'timeout.wait', 'message': f'run {r6["run"]} is still running', 'data': {'run': r6['run'], 'state': 'running'}}, body
        assert how == 'mcp' or code == 7
    assert d.err('run', 'wait', f'--run={r6["run"]}', '--timeout-ms=0', code=7)['code'] == 'timeout.wait'
    w = Wire(d.path, d.token)
    n = w.request('run.wait', {'run': r6['run']})
    time.sleep(.2)
    w.call('cancel', {'id': n})
    assert w.reply(n)['error']['code'] == 'cancelled'
    n = w.request('run.wait', {'run': r6['run']})
    time.sleep(.2)
    w.close()
    time.sleep(.2)
    rec = d.cli('run', 'get', f'--run={r6["run"]}')
    assert rec['state'] == 'running' and mcount() == 1 and len(d.signals()) == sent, rec

    # Cancel; cancelling a completed run returns the identical record.
    first = d.cli('run', 'cancel', f'--run={r6["run"]}', '--signal=SIGTERM')
    assert first['state'] == 'completed' and first['outcome'] == 'terminated' and first['cause'] == 'cancel' and first['signal'] == 'SIGTERM' and first['status'] == 125, first
    sent = len(d.signals())
    again = d.cli('run', 'cancel', f'--run={r6["run"]}')
    assert again == first and len(d.signals()) == sent
    ok, body, _ = d.via('mcp', 'run.cancel', {'run': r6['run']})
    assert ok and body == first

    # A process whose SIGKILL is withheld: timeout.terminate, still
    # terminating, completes with cause cancel once it finally exits.
    stuck = root / 'venomx-stuck'
    stuck.symlink_to('/bin/sh')
    pidfile = root / 'c8.pid'
    r8 = start(d, 'c8', argv=[str(stuck), '-c', f'echo $$ > {pidfile}; trap "" HUP TERM INT; while :; do sleep 0.05; done'])
    until(pidfile.exists)
    e8 = d.err('run', 'cancel', f'--run={r8["run"]}', '--grace-ms=0', code=7)
    assert e8['code'] == 'timeout.terminate' and e8['data'] == {'panes': [r8['pane']]}, e8
    assert d.cli('run', 'get', f'--run={r8["run"]}')['state'] == 'terminating'
    doctor = {c['id']: c for c in d.cli('doctor')['checks']}
    assert doctor['run.stuck']['status'] == 'warn', doctor['run.stuck']
    os.killpg(int(pidfile.read_text()), 9)
    rec = wait(d, r8['run'], output='false')
    assert rec['outcome'] == 'terminated' and rec['cause'] == 'cancel' and rec['signal'] == 'SIGKILL', rec

    # pane.kill and recursive removal record their causes; waiters get it.
    r9 = start(d, 'c9a', argv=['sleep', '100'])
    w = Wire(d.path, d.token)
    n = w.request('run.wait', {'run': r9['run'], 'output': False})
    d.cli('pane', 'kill', f'--pane={r9["pane"]}')
    rec = w.reply(n)['ok']
    assert rec['cause'] == 'pane_kill' and rec['outcome'] == 'terminated' and rec['status'] == 125, rec
    r9b = start(d, 'c9b', argv=['sleep', '100'])
    n = w.request('run.wait', {'run': r9b['run'], 'output': False})
    d.cli('window', 'remove', f'--window={r9b["window"]}', '--recursive=true')
    rec = w.reply(n)['ok']
    assert rec['cause'] == 'removal' and rec['outcome'] == 'terminated', rec
    # The record outlives its removed pane.
    assert d.cli('run', 'get', f'--run={r9b["run"]}', '--output=false') == rec
    w.close()

    # Forged OSC 133/7501 markers and success text do not complete a run.
    forged = r'printf "\033]133;C\007\033]133;D;0\007\033]7501;state=done\007{\"outcome\":\"succeeded\",\"status\":0}\n"; sleep 1; exit 3'
    r10 = start(d, 'c10', shell=forged)
    rec = d.cli('run', 'get', f'--run={r10["run"]}')
    time.sleep(.4)
    rec = d.cli('run', 'get', f'--run={r10["run"]}')
    assert rec['state'] == 'running' and 'outcome' not in rec, rec
    evs = [e for e in d.event_lines() if e.get('data', {}).get('pane') == r10['pane'] or e.get('data', {}).get('run') == r10['run']]
    kinds = [e['type'] for e in evs]
    assert 'command.finished' in kinds and 'program.status_changed' in kinds and 'run.completed' not in kinds, kinds
    assert [e for e in evs if e['type'] == 'command.finished'][0]['data']['exit_code'] == 0
    rec = wait(d, r10['run'])
    assert rec['outcome'] == 'failed' and rec['exit_code'] == 3 and rec['status'] == 3, rec
    evs = [e['type'] for e in d.event_lines() if about(e, r10)]
    assert evs.index('pane.exited') < evs.index('run.completed'), evs
    # A failure marker does not make a zero exit fail.
    both(d, 'c11', {'shell': r'printf "\033]133;D;1\007"; exit 0'}, lambda r: r['outcome'] == 'succeeded' or fail(r))

    # Output beyond the row limit: the last 100 non-blank rows.
    r12 = start(d, 'c12', argv=['seq', '1', '400'], cols=40, rows=5)
    rec = wait(d, r12['run'])
    out = rec['output']
    assert len(out['lines']) == 100 and out['complete'] is False and out['start'] > 0, out
    assert [x.strip() for x in out['lines']] == [str(i) for i in range(301, 401)], out['lines'][:3]
    assert out['end'] - out['start'] == 100 and out['cols'] == 40 and out['rows'] == 5 and out['screen'] == 'primary'
    # The rows before the tail stay readable with pane.capture_rows.
    before = d.cli('pane', 'capture-rows', f'--pane={r12["pane"]}', f'--epoch={out["epoch"]}', f'--end={out["start"]}', '--max-rows=10000')
    assert [x.strip() for x in before['lines']][-3:] == ['298', '299', '300'] and before['start'] == out['oldest'], before['lines'][-3:]

    # Byte limits keep whole rows; zero rows; trailing blank rows.
    rows3 = r'printf "\342\202\254\342\202\254\342\202\254\n\342\202\254\342\202\254\342\202\254\n\342\202\254\342\202\254\342\202\254\n"'
    rec = wait(d, start(d, 'c13a', shell=rows3, cols=3, rows=10, output_bytes=22)['run'])
    assert rec['output']['lines'] == ['€€€', '€€€'] and rec['output']['complete'] is False, rec['output']
    rec = wait(d, start(d, 'c13b', shell=rows3, cols=3, rows=10, output_rows=0)['run'])
    assert rec['output']['lines'] == [] and rec['output']['start'] == rec['output']['end'], rec['output']
    rec = wait(d, start(d, 'c13c', shell=rows3, cols=3, rows=10)['run'])
    assert len(rec['output']['lines']) == 3 and rec['output']['end'] == rec['output']['oldest'] + 3 and rec['output']['complete'] is True, rec['output']

    # A reply over max_frame fails with its size; output=false fits.
    small = Wire(d.path, d.token, max_frame=4096)
    e = small.call('run.get', {'run': r12['run']})['error']
    assert e['code'] == 'unsupported.result_size' and e['data']['bytes'] > 4096, e
    assert 'output' not in small.call('run.get', {'run': r12['run'], 'output': False})['ok']
    small.close()

    # Same key and parameters: reused (also from another connection and
    # after completion); different argv: conflict; another principal: new run.
    mpath, mcount = marker(root, 'c16')
    params = {'key': 'K16', 'session': 's0', 'argv': ['sh', '-c', f'echo >> {mpath}']}
    a = Wire(d.path, d.token).call('run', params)['ok']
    b = Wire(d.path, d.token).call('run', params)['ok']
    assert b == dict(a, reused=True), (a, b)
    wait(d, a['run'])
    ok, c, _ = d.via('mcp', 'run', params)
    assert ok and c == b, c
    e = d.err('run', '--key=K16', '--session=s0', '--argv=["sh","-c","true"]', code=5)
    assert e == {'code': 'conflict.run_key', 'message': 'key is bound to a run with different parameters', 'data': {'run': a['run']}}, e
    other = d.issue([{'right': 'spawn', 'scope': '*'}, {'right': 'read', 'scope': '*'}])
    c = d.cli('run', '--key=K16', '--session=s0', f'--argv={json.dumps(params["argv"])}', token=other)
    assert c['run'] != a['run'] and c['reused'] is False, c
    wait(d, c['run'])
    assert mcount() == 2
    # The other principal's key namespace is its own.
    assert [x['run'] for x in d.cli('run', 'list', '--key=K16')['runs']] == [a['run']]
    assert [x['run'] for x in d.cli('run', 'list', '--key=K16', token=other)['runs']] == [c['run']]

    # Key syntax.
    before = counts(d)
    for key in ('bad key', 'k' * 129, ''):
        e = d.err('run', f'--key={key}', '--session=s0', '--argv=["true"]', code=2)
        assert e == {'code': 'invalid_params.key', 'message': 'key must be 1-128 bytes of [A-Za-z0-9._:-]', 'data': {'param': 'key', 'reason': 'syntax'}}, e
    # Command and target forms.
    w = Wire(d.path, d.token)
    for params, code, reason in (
            ({'session': 's0'}, 'invalid_params.command', 'missing'),
            ({'session': 's0', 'argv': ['true'], 'shell': 'true'}, 'invalid_params.command', 'exclusive'),
            ({'argv': ['true']}, 'invalid_params.target', 'missing'),
            ({'session': 's0', 'pane': 'p0', 'argv': ['true']}, 'invalid_params.target', 'exclusive'),
            ({'session': 's0', 'axis': 'cols', 'argv': ['true']}, 'invalid_params.target', 'misplaced'),
            ({'session': 's0', 'shell': 'a\u0000b'}, 'invalid_params.command', 'nul'),
            ({'session': 's0', 'shell': ''}, 'invalid_params.command', 'size')):
        e = w.call('run', dict(params, key='k19'))['error']
        assert e['code'] == code and e['data']['reason'] == reason, (params, e)
    w.close()
    assert counts(d) == before

    # Without spawn: identical denied.spawn for existing, missing and
    # invalid targets, with no side effects; audited.
    reader = d.issue([{'right': 'read', 'scope': '*'}])
    denials = []
    for args in (['--session=s0', '--argv=["true"]'], ['--session=s404', '--argv=["true"]'], ['--session=s0', '--shell=']):
        denials.append(d.err('run', '--key=k20', *args, code=4, token=reader))
    assert denials[0]['code'] == 'denied.spawn' and all(x['data']['right'] == 'spawn' for x in denials), denials
    unknown = [d.err('run', '--key=k20', *args, code=4, token=None) for args in (['--session=s0', '--argv=["true"]'], ['--session=s404', '--argv=["true"]'])]
    assert unknown[0] == unknown[1] and unknown[0]['code'] == 'denied.spawn', unknown
    # spawn scoped to one session cannot target another session or a pane outside it.
    d.cli('session', 'create', '--name=other')
    scoped = d.issue([{'right': 'spawn', 'scope': 'session:s1'}, {'right': 'read', 'scope': '*'}])
    e1 = d.err('run', '--key=k20', '--session=s0', '--argv=["true"]', code=4, token=scoped)
    e2 = d.err('run', '--key=k20', '--session=s404', '--argv=["true"]', code=4, token=scoped)
    assert e1['code'] == e2['code'] == 'denied.spawn' and e1['data']['resource'] == 'session:s0', (e1, e2)
    assert counts(d) == before
    audit = (root / 'main' / 'state' / 'venom' / 'venomx' / 'audit.ndjson').read_text()
    assert '"verb":"run"' in audit and 'denied.spawn' in audit

    # Delegation beyond the caller's own grants.
    e = d.err('run', '--key=k21', '--session=s1', '--argv=["true"]', '--grants=[{"right":"admin","scope":"*"}]', code=4, token=scoped)
    assert e['code'] == 'denied.delegation', e
    assert counts(d) == before

    # Result-read authority.
    r22 = start(d, 'c22', argv=['sleep', '100'])
    rid, pane22 = r22['run'], r22['pane']
    panes_only = d.issue([{'right': 'read', 'scope': 'pane:*'}])
    assert d.err('run', 'get', f'--run={rid}', code=4, token=panes_only)['code'] == 'denied.read'
    assert d.cli('run', 'list', token=panes_only)['runs'] == []
    sess = d.issue([{'right': 'read', 'scope': 'session:s0'}])
    assert d.cli('run', 'get', f'--run={rid}', token=sess)['state'] == 'running'
    assert rid in [x['run'] for x in d.cli('run', 'list', token=sess)['runs']]
    only = d.issue([{'right': 'read', 'scope': f'run:{rid}'}])
    assert d.cli('run', 'get', f'--run={rid}', token=only)['run'] == rid
    assert d.err('run', 'cancel', f'--run={rid}', code=4, token=only)['code'] == 'denied.write'
    # The run's own pane principal reads and cancels its own run.
    selfpath = root / 'c22-self.json'
    r22b = start(d, 'c22b', shell=f'sleep 0.3; "{EXE}" run get --run "$VENOMX_RUN" --json > {selfpath}.get; "{EXE}" run cancel --run "$VENOMX_RUN" --json > {selfpath}; sleep 100')
    rec = wait(d, r22b['run'], output='false')
    assert rec['cause'] == 'cancel' and json.loads(Path(f'{selfpath}.get').read_text())['run'] == r22b['run'], rec
    d.cli('run', 'cancel', f'--run={rid}')

    # max_active bounds concurrent runs.
    d.config('run.max_active', '4')
    w = Wire(d.path, d.token)
    ids = [w.request('run', {'key': f'c23-{i}', 'session': 's0', 'argv': ['sleep', '100'], 'output_rows': 1}) for i in range(50)]
    replies = [w.reply(n) for n in ids]
    started = [x['ok'] for x in replies if 'ok' in x]
    refused = [x['error'] for x in replies if 'error' in x]
    assert len(started) == 4 and len(refused) == 46, (len(started), refused[:1])
    assert all(x == {'code': 'unavailable.run_limit', 'message': 'too many runs not yet completed', 'data': {'max_active': 4}} for x in refused), refused[0]
    assert len({x['pane'] for x in started}) == 4
    for x in started:
        w.call('run.cancel', {'run': x['run'], 'grace_ms': 0})
    w.close()
    d.config('run.max_active', '64')

    # Retention: count, age, bytes; expiry, key reuse, paging.
    d.config('run.retain_count', '2')
    done = [wait(d, start(d, f'c24-{i}', argv=['echo', str(i)])['run']) for i in range(3)]
    listed = [x['run'] for x in d.cli('run', 'list')['runs']]
    assert listed == [done[1]['run'], done[2]['run']], listed
    e = d.err('run', 'get', f'--run={done[0]["run"]}', code=3)
    assert e == {'code': 'not_found.run', 'message': 'no such run', 'data': {'reason': 'expired'}}, e
    assert d.err('run', 'get', f'--run={done[0]["run"]}', code=4, token=sess)['code'] == 'denied.read'
    assert d.err('run', 'get', '--run=r999999', code=3)['data']['reason'] == 'unknown'
    reuse = start(d, 'c24-0', argv=['echo', '0'])
    assert reuse['run'] != done[0]['run']
    wait(d, reuse['run'])
    page = d.cli('run', 'list', '--limit=1')
    assert len(page['runs']) == 1 and 'next' in page, page
    rest = d.cli('run', 'list', '--limit=1', f'--after={page["next"]}')
    assert rest['runs'][0]['run'] != page['runs'][0]['run'] and 'next' not in rest, rest
    expired = [e for e in d.event_lines() if e['type'] == 'run.expired']
    assert {'run': done[0]['run']} in [e['data'] for e in expired], expired
    d.config('run.retain_count', '256')
    hung = start(d, 'c24-hung', argv=['sleep', '100'])
    d.config('run.retain_ms', '100')
    time.sleep(.5)
    listed = [x['run'] for x in d.cli('run', 'list')['runs']]
    assert listed == [hung['run']], listed  # running records are never evicted
    d.config('run.retain_ms', '3600000')
    d.config('run.retain_bytes', '10')
    # A record over the byte budget is evicted in its completion turn; a
    # waiter that was already waiting still receives it.
    w = Wire(d.path, d.token)
    for i in range(2):
        b = start(d, f'c24-b{i}', shell='sleep 0.2; echo twelve bytes')
        assert w.call('run.wait', {'run': b['run']})['ok']['outcome'] == 'succeeded'
    w.close()
    assert [x['run'] for x in d.cli('run', 'list')['runs']][0] == hung['run']
    assert len(d.cli('run', 'list')['runs']) == 1
    d.config('run.retain_bytes', '16777216')
    d.cli('run', 'cancel', f'--run={hung["run"]}')

    # Event order, snapshot entity, frozen grants after pane removal.
    sub = Wire(d.path, d.token)
    sub.request('events', {'follow': True})
    r25 = start(d, 'c25', argv=['sleep', '100'])
    snapshot = [x for x in d.run(['events', '--follow=false']).stdout.splitlines() if '"state.snapshot"' in x][0]
    ents = {e['resource']: json.loads(e['content']) for e in json.loads(snapshot)['data']['entities']}
    assert ents[f'run:{r25["run"]}'] == {'run': r25['run'], 'pane': r25['pane'], 'state': 'running'}, ents.get(f'run:{r25["run"]}')
    d.cli('run', 'cancel', f'--run={r25["run"]}')
    d.cli('pane', 'remove', f'--pane={r25["pane"]}')
    seen = []
    while 'pane.removed' not in seen:
        m = sub.read()
        if 'item' in m and about(m['item'], r25):
            seen.append(m['item']['type'])
    sub.close()
    i = seen.index
    assert i('window.created') < i('pane.created') < i('run.started') < i('pane.terminating') < i('run.terminating') < i('pane.exited') < i('run.completed') < i('pane.removed'), seen
    snapshot = [x for x in d.run(['events', '--follow=false']).stdout.splitlines() if '"state.snapshot"' in x][0]
    ents = {e['resource']: json.loads(e['content']) for e in json.loads(snapshot)['data']['entities']}
    assert ents[f'run:{r25["run"]}']['outcome'] == 'terminated' and ents[f'run:{r25["run"]}']['cause'] == 'cancel', ents
    assert d.cli('run', 'get', f'--run={r25["run"]}', '--output=false', token=sess)['run'] == r25['run']
    # After pane removal the session-scoped reader still sees the run's
    # retained events through the frozen containment data.
    kinds = [e['type'] for e in d.event_lines(token=sess, resources=[f'run:{r25["run"]}'])]
    assert 'run.completed' in kinds and 'run.started' in kinds, kinds
    hidden = d.event_lines(token=panes_only, resources=[f'run:{r25["run"]}'])
    assert all(e.get('error', {}).get('code') == 'denied.event_scope' or not e.get('type', '').startswith('run.') for e in hidden), hidden

    # A descendant that escapes the process group does not delay completion.
    late = root / 'c26.late'
    rec = wait(d, start(d, 'c26', shell=f'setsid sh -c "sleep 1; echo late; echo done > {late}" & sleep 0.2; echo early; exit 0')['run'])
    assert rec['outcome'] == 'succeeded' and rec['duration_ms'] < 1000 and not any('late' in x for x in rec['output']['lines']), rec
    until(late.exists)
    counters = {c['id']: c for c in d.cli('doctor')['checks']}['run.counters']['message']
    assert int(counters.rsplit(' ', 1)[1]) >= 1, counters

    # A run in a split pane that prompts, answered with pane.send.
    host = start(d, 'c27-host', argv=['sleep', '100'])
    ok, r27, _ = d.via('cli', 'run', {'key': 'c27', 'pane': host['pane'], 'axis': 'rows', 'shell': 'read x; exit $x'})
    assert ok and r27['window'] == host['window'], r27
    time.sleep(.3)
    d.cli('pane', 'send', f'--pane={r27["pane"]}', '--text=4\r')
    rec = wait(d, r27['run'], output='false')
    assert rec['outcome'] == 'failed' and rec['exit_code'] == 4, rec
    d.cli('run', 'cancel', f'--run={host["run"]}')

    # Canary inputs.
    rec = wait(d, start(d, f'c28-{CANARY}', argv=['echo', CANARY], name='canary')['run'])
    assert rec['output']['lines'][0].startswith(CANARY), rec
    rec = wait(d, start(d, 'c28-shell', shell=f'X={CANARY}; true')['run'])
    # A shell run's argv0 is `sh`, in pane.created and pane.list.
    created = [e for e in d.event_lines() if e['type'] == 'pane.created' and e['data']['pane'] == rec['pane']]
    assert [e['data'].get('argv0') for e in created] == ['sh'], created
    assert [p.get('argv0') for p in d.cli('pane', 'list')['panes'] if p['pane'] == rec['pane']] == ['sh']
    # The directory part of argv[0] and later argv elements never leave the daemon.
    prog = d.root / CANARY / 'prog'
    prog.parent.mkdir()
    prog.write_text('#!/bin/sh\nexit 0\n')
    prog.chmod(0o755)
    dir_run = wait(d, start(d, 'c28-dir', argv=[str(prog), CANARY])['run'])
    created = [e for e in d.event_lines() if e['type'] == 'pane.created' and e['data']['pane'] == dir_run['pane']]
    assert [e['data'].get('argv0') for e in created] == ['prog'], created
    assert [p.get('argv0') for p in d.cli('pane', 'list')['panes'] if p['pane'] == dir_run['pane']] == ['prog']
    listing = json.dumps(d.cli('pane', 'list'))
    assert CANARY not in listing, listing
    # The run record, run list/get and pane capture (there is no pane get verb) of the directory run.
    surfaces = {
        'run record': dir_run,
        'run list': [x for x in d.cli('run', 'list')['runs'] if x['run'] == dir_run['run']],
        'run get': d.cli('run', 'get', f'--run={dir_run["run"]}'),
        'pane capture': d.cli('pane', 'capture', f'--pane={dir_run["pane"]}'),
    }
    for name, body in surfaces.items():
        assert CANARY not in json.dumps(body), (name, json.dumps(body)[:200])
    snapshot = d.run(['events', '--follow=false']).stdout
    assert CANARY not in snapshot, snapshot[:200]
    for args in (['doctor'], ['events', '--follow=false', f'--after={rec["source"]}:0'], ['events', '--follow=false']):
        out = d.run(args).stdout
        assert out and CANARY not in out, (args, out[:200])
    assert CANARY not in d.run(['events', '--follow=false', f'--after={rec["source"]}:0']).stdout

    # 9 (shutdown): stopping the daemon terminates running runs; a waiter
    # receives the record or `cancelled` (best effort).
    r9c = start(d, 'c9c', argv=['sleep', '100'])
    w = Wire(d.path, d.token)
    n = w.request('run.wait', {'run': r9c['run']})
    time.sleep(.1)
    d.proc.terminate()
    reply = w.reply(n)
    assert reply.get('ok', {}).get('cause') == 'shutdown' or reply['error']['code'].startswith('cancelled'), reply
    w.close()
    d.proc.wait(timeout=10)


def about(event, run):
    """Whether an event concerns this run, its pane or its window."""
    data = event.get('data', {})
    return data.get('run') == run['run'] or data.get('pane') == run['pane'] or (data.get('window') == run['window'] and 'pane' not in data)


def fail(r):
    raise AssertionError(r)


def canaries(d):
    """28. Canaries appear only in results that return them."""
    logs = (d.root / 'daemon.err').read_text()
    audit = (d.root / 'state' / 'venom' / 'venomx' / 'audit.ndjson').read_text()
    assert CANARY not in logs and CANARY not in audit, 'canary leaked into logs or audit'
    for out in d.outputs:
        if CANARY in out:
            body = json.loads(out.splitlines()[0]) if out.strip().startswith('{') else {}
            text = json.dumps(body)
            assert '"type"' not in text and '"checks"' not in text, out[:200]


def drops(root):
    """15. A connection lost before / after the barrier."""
    for mode in ('before', 'after'):
        d = Daemon(root, f'drop-{mode}', {'VENOMX_TEST_RUN_DROP': mode})
        try:
            d.cli('session', 'create')
            mpath, mcount = marker(root, f'c15-{mode}')
            params = {'key': 'K15', 'session': 's0', 'argv': ['sh', '-c', f'echo >> {mpath}']}
            w = Wire(d.path, d.token)
            w.request('run', params)
            line = w.io.readline()
            w.close()
            if mode == 'before':
                assert not line or json.loads(line)['error']['code'] == 'cancelled', line
                time.sleep(.3)
                assert mcount() == 0 and d.cli('run', 'list')['runs'] == [] and d.cli('pane', 'list')['panes'] == []
                again = Wire(d.path, d.token).call('run', params)['ok']
                assert again['reused'] is False
            else:
                assert not line, line
                again = Wire(d.path, d.token).call('run', params)['ok']
                assert again['reused'] is True and again['run'] == 'r0', again
            until(lambda: mcount() >= 1)
            time.sleep(.3)
            assert mcount() == 1
        finally:
            d.stop()


def restart(root):
    """17. A retry that reaches a restarted daemon with `source` is refused."""
    d = Daemon(root, 'restart')
    mpath, mcount = marker(root, 'c17')
    try:
        d.cli('session', 'create')
        r = d.cli('run', '--key=K17', '--session=s0', f'--argv=["sh","-c","echo >> {mpath}"]')
        old = r['source']
    finally:
        d.stop()
    until(lambda: mcount() == 1)
    d = Daemon(root, 'restart2')
    try:
        d.cli('session', 'create')
        e = d.err('run', '--key=K17', '--session=s0', f'--argv=["sh","-c","echo >> {mpath}"]', f'--source={old}', code=5)
        assert e['code'] == 'conflict.source' and e['data']['source'] != old and e['data']['source'].startswith('venomx/'), e
        time.sleep(.3)
        assert mcount() == 1 and d.cli('run', 'list')['runs'] == []
    finally:
        d.stop()


def recovered(root):
    """Runs are memory-only: a recovery checkpoint carries no run, and
    a restored archive pane has none; run verbs stay well-defined."""
    def daemon(reuse):
        cfg = Path(root) / 'recovery' / 'cfg' / 'venomx'
        cfg.mkdir(parents=True, exist_ok=True)
        (cfg / 'config.zon').write_text('.{ .recovery = .{ .enabled = true, .interval_ms = 3600000 } }\n')
        return Daemon(root, 'rec', reuse=reuse, extra={'XDG_CONFIG_HOME': str(Path(root) / 'recovery' / 'cfg'), 'XDG_STATE_HOME': str(Path(root) / 'recovery' / 'state')})
    d = daemon(False)
    try:
        d.cli('session', 'create')
        done = d.cli('run', f'--key=rec-{CANARY}', '--session=s0', f'--argv=["echo","{CANARY}"]')
        wait(d, done['run'])
        live = d.cli('run', '--key=rec-live', '--session=s0', '--argv=["sleep","100"]')
    finally:
        d.stop()
    store = Path(root) / 'recovery' / 'state'
    for f in store.rglob('*.json'):
        raw = f.read_bytes()
        assert CANARY.encode() not in raw and b'rec-live' not in raw and b'"run"' not in raw, f
    d = daemon(True)
    try:
        [checkpoint] = [c['checkpoint'] for c in d.cli('recovery', 'list')['checkpoints'] if c.get('status', 'valid') == 'valid']
        restored = d.cli('recovery', 'restore', f'--checkpoint={checkpoint}')
        panes = {m['previous']: m['current'] for m in restored['panes']}
        assert d.cli('run', 'list')['runs'] == []
        for rid in (done['run'], live['run']):
            assert d.err('run', 'get', f'--run={rid}', code=3) == {'code': 'not_found.run', 'message': 'no such run', 'data': {'reason': 'unknown'}}
        archive = panes[live['pane']]
        e = d.err('run', '--key=rec-split', f'--pane={archive}', '--axis=cols', '--argv=["true"]', code=5)
        assert e['code'] == 'conflict.pane_exited', e
        assert d.cli('run', 'list', f'--pane={archive}')['runs'] == []
        # The archive pane cannot be cancelled through a run and stays removable.
        d.cli('pane', 'remove', f'--pane={archive}')
        fresh = d.cli('run', '--key=rec-live', f"--session={restored['sessions'][0]['current']}", '--argv=["true"]')
        assert fresh['reused'] is False and wait(d, fresh['run'])['outcome'] == 'succeeded'
    finally:
        d.stop()


if __name__ == '__main__':
    main()
