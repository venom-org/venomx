#!/usr/bin/env python3
"""Per-request cwd and environment for pane creation.

Runs spawn conformance checks against real headless daemons built with the
test seam (`-Dtest-seams=true`): real PTYs and processes, through the CLI and
MCP (and NDJSON where a value cannot travel in argv).

Usage: spawn.py <venomx-seam> <venom-echo>
"""
import json
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import sys
import tempfile
import time

EXE = str(Path(sys.argv[1]).resolve())
ECHO = str(Path(sys.argv[2]).resolve())
PY = sys.executable
TIMEOUT = 10
EXIT = {'invalid_params': 2, 'not_found': 3, 'denied': 4, 'conflict': 5, 'unavailable': 6}
CANARY = 'cnry' + secrets.token_hex(12)
SECRET43 = lambda: secrets.token_urlsafe(32)[:43]
PROBE = '''import os,sys,json
t=sys.argv[1]
open(t+".tmp","w").write(json.dumps({"cwd":os.getcwd(),"env":dict(os.environ)}))
os.rename(t+".tmp",t)
import time
time.sleep(1000)'''


def until(fn, timeout=TIMEOUT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('condition did not become true')


def clean_env():
    env = {k: v for k, v in os.environ.items() if not (k.endswith('_TOKEN') or k.endswith('_PRINCIPAL') or k.startswith('VENOMX_') or 'vnt1.' in v)}
    env.pop('LANG', None)
    return env


class Daemon:
    """One headless daemon in its own runtime directory."""

    def __init__(self, root, name, extra=None, cwd=None, path_prefix=None):
        self.root = root / name
        self.root.mkdir(mode=0o700)
        self.path = str(self.root / 'd.sock')
        self.seam_log = self.root / 'seam.log'
        env = clean_env()
        env.update(HOME=str(self.root), XDG_CONFIG_HOME=str(self.root / 'cfg'), XDG_CONFIG_DIRS=str(self.root / 'cfg' / 'xdg'), XDG_STATE_HOME=str(self.root / 'state'), VENOMX_TEST_SEAM_LOG=str(self.seam_log))
        # These cases test grants and namespaces, so isolation is on.
        (Path(self.root) / 'cfg' / 'xdg' / 'venomx').mkdir(parents=True, exist_ok=True); (Path(self.root) / 'cfg' / 'xdg' / 'venomx' / 'defaults.zon').write_text('.{ .grants = .{ .isolation = true } }\n')
        if path_prefix:
            env['PATH'] = path_prefix + ':' + env.get('PATH', '/usr/bin:/bin')
        env.update(extra or {})
        self.env = env
        self.client_env = {k: v for k, v in env.items() if not k.startswith('VENOMX_') and not k.endswith('_TOKEN')}
        self.outputs = []
        self.proc = subprocess.Popen([EXE, 'serve', '--socket', self.path, '--json'], stdin=subprocess.DEVNULL, env=env, cwd=cwd or str(self.root), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        until(lambda: Path(self.path).exists() or self.proc.poll() is not None)
        assert self.proc.poll() is None, self.proc.communicate()
        self.token = (self.root / 'd.owner').read_text().strip()

    def run(self, args, token='@owner', record=True):
        environ = dict(self.client_env, VENOMX_TOKEN=token) if token else self.client_env
        r = subprocess.run([EXE, *args, '--socket', self.path, '--json'], stdin=subprocess.DEVNULL, env=environ, capture_output=True, text=True, timeout=TIMEOUT)
        if record:
            self.outputs.append(r.stdout + r.stderr)
        return r

    def cli(self, *args, code=0, token='@owner'):
        r = self.run(args, token)
        assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
        assert not r.stderr, r.stderr
        return json.loads(r.stdout)

    def mcp(self, name, arguments, token='@owner'):
        msgs = [{'jsonrpc': '2.0', 'id': 0, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 't', 'version': '0'}}},
                {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
                {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': name, 'arguments': arguments}}]
        environ = dict(self.client_env, VENOMX_TOKEN=token) if token else self.client_env
        r = subprocess.run([EXE, 'mcp', '--socket', self.path], input=''.join(json.dumps(m) + '\n' for m in msgs), capture_output=True, text=True, timeout=TIMEOUT, env=environ)
        assert r.returncode == 0 and not r.stderr, (r.returncode, r.stderr)
        reply = [json.loads(line) for line in r.stdout.splitlines() if json.loads(line).get('id') == 1][0]['result']
        self.outputs.append(reply['content'][0]['text'])
        return json.loads(reply['content'][0]['text']), reply['isError']

    def wire(self, verb, params, keep=False):
        """One NDJSON request on a fresh connection (values argv cannot carry).
        With keep=True the open connection is returned with the reply."""
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(TIMEOUT)
        s.connect(self.path)
        io = s.makefile('rwb', buffering=0)
        try:
            io.write(json.dumps({'id': 0, 'verb': 'hello', 'params': {'proto': [1], 'caps': [], 'max_frame': 1048576, 'auth': {'token': self.token}}}).encode() + b'\n')
            assert 'ok' in json.loads(io.readline())
            io.write(json.dumps({'id': 1, 'verb': verb, 'params': params}).encode() + b'\n')
            line = io.readline().decode()
            self.outputs.append(line)
            if keep:
                keep, s, io = (s, io), None, None
                return json.loads(line), keep
            return json.loads(line)
        finally:
            if io is not None:
                io.close()
                s.close()

    def call(self, via, verb, params, token='@owner'):
        """(ok, body, cli exit code or None)."""
        if via == 'cli':
            args = verb.split('.')
            for k, v in params.items():
                args.append(f'--{k.replace("_", "-")}={v if isinstance(v, str) else json.dumps(v)}')
            r = self.run(args, token)
            assert not r.stderr, r.stderr
            out = json.loads(r.stdout)
            if 'error' in out:
                return False, out['error'], r.returncode
            assert r.returncode == 0, r
            return True, out, 0
        if via == 'mcp':
            body, is_error = self.mcp(verb.replace('.', '_d'), params, token)
            return (False, body['error'], None) if is_error else (True, body['result'], 0)
        assert token == '@owner'
        reply = self.wire(verb, params)
        return ('ok' in reply), reply.get('ok', reply.get('error')), None

    def error(self, via, verb, params, code, data=None, token='@owner'):
        ok, body, exit_code = self.call(via, verb, params, token)
        assert not ok, (via, verb, body)
        assert body['code'] == code, (via, verb, body)
        if exit_code is not None:
            assert exit_code == EXIT[code.split('.')[0]], (code, exit_code)
        if data is not None:
            assert body.get('data') == data, (via, verb, body)
        return body

    def events(self, after=None):
        args = ['events', '--follow=false'] + ([f'--after={after}'] if after else [])
        r = self.run(args)
        assert r.returncode == 0, (r.stdout, r.stderr)
        return [json.loads(line) for line in r.stdout.splitlines()]

    def cursor(self):
        e = self.events()[-1]
        return f"{e['source']}:{e['seq']}"

    def children(self):
        out = subprocess.run(['ps', '-o', 'pid=,stat=', '--ppid', str(self.proc.pid)], capture_output=True, text=True).stdout.split('\n')
        return sorted(int(line.split()[0]) for line in out if line.strip() and not line.split()[1].startswith('Z'))

    def ptys(self):
        fds = f'/proc/{self.proc.pid}/fd'
        return len([f for f in os.listdir(fds) if os.readlink(f'{fds}/{f}') == '/dev/ptmx'])

    def state(self):
        return (self.cli('session', 'list')['sessions'], self.cli('pane', 'list')['panes'], self.cli('grant', 'list')['principals'], self.children(), self.ptys())

    def snapshot(self):
        return self.state(), self.cursor()

    def unchanged(self, before):
        """No session, window, pane, principal, PTY, child or event."""
        state, c = before
        until(lambda: self.state() == state)
        assert [e for e in self.events(c) if e['type'] != 'stream.checkpoint' and e['type'] != 'principal.denied'] == []

    def realpaths(self):
        return self.seam_log.read_text().count('realpath\n') if self.seam_log.exists() else 0

    def doctor(self):
        return {r['id']: r for r in self.cli('doctor')['checks']}

    def stop(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
        out, err = self.proc.communicate(timeout=8)
        self.outputs.append(out + err)
        return self.proc.returncode, out, err


with tempfile.TemporaryDirectory(prefix='vx-spawn-') as tmp:
    root = Path(os.path.realpath(tmp))
    outdir = root / 'out'
    outdir.mkdir()
    n = [0]

    def outfile():
        n[0] += 1
        return outdir / f'probe{n[0]}'

    def read_probe(out):
        until(lambda: out.exists())
        return json.loads(out.read_text())

    # Fixture directories and programs.
    D = root / 'daemon-cwd'; D.mkdir()
    A = root / 'path-a'; A.mkdir()
    B = root / 'path-b'; B.mkdir()
    C = root / 'cwd-tool'; C.mkdir()
    N = root / 'noexec'; N.mkdir()
    E = root / 'exec'; E.mkdir()
    T = root / f'target-{CANARY}'; T.mkdir()
    L = root / 'link'; L.symlink_to(T)
    for directory, label in ((A, 'A'), (B, 'B'), (C, 'C'), (E, 'E')):
        tool = directory / 'tool'
        tool.write_text(f'#!/bin/sh\necho {label} > "$1"\nexec sleep 1000\n')
        tool.chmod(0o755)
    (N / 'tool').write_text('#!/bin/sh\necho N > "$1"\n')
    (N / 'tool').chmod(0o644)
    shebangless = root / 'no-shebang'
    shebangless.write_text('echo must-not-run\n')
    shebangless.chmod(0o755)
    P = root / 'probe-bin'; P.mkdir()
    (P / 'probe-tool').symlink_to(os.path.realpath(PY))
    plain_file = root / 'regular-file'
    plain_file.write_text('x')
    locked = root / 'locked'; locked.mkdir(); (locked / 'inner').mkdir(); locked.chmod(0o000)

    owner_shaped = 'vnt1.venomx.owner.' + SECRET43()
    base_extra = {'BASE': '1', 'LANG': 'C', 'X_TOKEN': 'base-secret', 'VENOM_PRINCIPAL': 'g9', 'VENOMX_DEBUG': '1', 'FOO': owner_shaped, 'VENOMX_TOKEN': '@owner'}
    daemons = []
    echo = None
    try:
        d = Daemon(root, 'main', base_extra, cwd=str(D), path_prefix=str(A)); daemons.append(d)
        start = d.cursor()
        s0 = d.cli('session', 'create', '--name=main')['session']

        def probe(via, extra=None, verb='window.create', target=None):
            out = outfile()
            params = {'session': s0} if verb == 'window.create' else {'pane': target, 'axis': 'cols'}
            params.update(argv=[PY, '-I', '-c', PROBE, str(out)], **(extra or {}))
            ok, res, _ = d.call(via, verb, params)
            assert ok, (via, res)
            data = read_probe(out)
            return res, data['cwd'], data['env']

        def done(res):
            d.cli('pane', 'kill', f'--pane={res["pane"]}', '--remove=true')

        child_tokens = []
        for via in ('cli', 'mcp'):
            # 1 + 26: defaults; daemon variables name the new pane and this daemon.
            res, cwd, env = probe(via)
            assert cwd == str(D), cwd
            assert env['BASE'] == '1' and env['LANG'] == 'C' and env['TERM'] == 'xterm-256color'
            assert env['VENOMX_TOKEN'].startswith('vnt1.venomx.' + res['principal'] + '.'), env['VENOMX_TOKEN']
            assert env['VENOMX_PRINCIPAL'] == res['principal'] and env['VENOMX_PANE'] == res['pane'] and env['VENOMX_SOCKET'] == d.path
            child_tokens.append(env['VENOMX_TOKEN'])
            # Inherited credentials and identity are stripped.
            for k in ('X_TOKEN', 'VENOM_PRINCIPAL', 'VENOMX_DEBUG', 'FOO', 'VENOMX_TEST_SEAM_LOG'):
                assert k not in env, k
            assert owner_shaped not in json.dumps(env)
            done(res)

            # cwd is resolved physically; PWD is the resolved path.
            for given in (T, L):
                res, cwd, env = probe(via, {'cwd': str(given)})
                assert cwd == str(T) and env['PWD'] == str(T), (given, cwd, env.get('PWD'))
                done(res)
            # The caller's PWD choice wins.
            res, cwd, env = probe(via, {'cwd': str(T), 'env': [{'name': 'PWD', 'value': '/elsewhere'}]})
            assert env['PWD'] == '/elsewhere' and cwd == str(T); done(res)
            res, cwd, env = probe(via, {'cwd': str(T), 'env_unset': ['PWD']})
            assert 'PWD' not in env; done(res)
            # Replacement and unset; an absent name is not an error.
            res, cwd, env = probe(via, {'env': [{'name': 'BASE', 'value': '2'}, {'name': 'NEW', 'value': CANARY}], 'env_unset': ['LANG', 'ABSENT']})
            assert env['BASE'] == '2' and env['NEW'] == CANARY and 'LANG' not in env; done(res)
            # Split takes the same parameters and does not inherit the source cwd.
            host = d.cli('window', 'create', f'--session={s0}', '--argv=["/bin/sh","-c","exec sleep 1000"]', f'--cwd={T}')
            res, cwd, env = probe(via, {'env': [{'name': 'NEW', 'value': CANARY}]}, verb='pane.split', target=host['pane'])
            assert cwd == str(D) and env['NEW'] == CANARY; done(res)
            res, cwd, env = probe(via, {'cwd': str(T)}, verb='pane.split', target=host['pane'])
            assert cwd == str(T); done(res)
            d.cli('pane', 'kill', f'--pane={host["pane"]}', '--remove=true')

        # The child's own CLI reaches this daemon through VENOMX_SOCKET.
        out = outfile()
        res = d.cli('window', 'create', f'--session={s0}', f'--argv={json.dumps(["/bin/sh", "-c", EXE + " whoami --json > \"$1.tmp\"; mv \"$1.tmp\" \"$1\"; exec sleep 1000", "x", str(out)])}')
        until(lambda: out.exists())
        assert json.loads(out.read_text())['principal'] == res['principal'], out.read_text()
        done(res)

        # 2 (doctor): counts by rule, never names or values.
        checks = d.doctor()
        assert checks['spawn.base_env']['message'] == 'inherited variables stripped: 2 *_TOKEN, 1 *_PRINCIPAL, 2 VENOMX_*, 1 token-shaped values', checks['spawn.base_env']
        assert checks['spawn.path']['status'] == 'ok' and checks['spawn.cwd']['status'] == 'ok', checks

        argv_sh = ['/bin/sh', '-c', 'exec sleep 1000']
        wc = lambda **kw: dict({'session': s0, 'argv': argv_sh}, **kw)
        for via in ('cli', 'mcp'):
            # cwd syntax, before any filesystem access.
            before = d.snapshot(); paths = d.realpaths()
            d.error(via, 'window.create', wc(cwd='.'), 'invalid_params.cwd', {'param': 'cwd', 'reason': 'relative'})
            d.error(via, 'window.create', wc(cwd=''), 'invalid_params.cwd', {'param': 'cwd', 'reason': 'relative'})
            d.error(via, 'window.create', wc(cwd='/' + 'a' * 4095), 'invalid_params.cwd', {'param': 'cwd', 'reason': 'size'})
            if via == 'mcp':
                d.error(via, 'window.create', wc(cwd='/tmp\0x'), 'invalid_params.cwd', {'param': 'cwd', 'reason': 'nul'})
            assert d.realpaths() == paths
            # Missing, a regular file, and inside a mode-000 directory.
            d.error(via, 'window.create', wc(cwd=str(root / 'missing')), 'not_found.cwd', {})
            d.error(via, 'window.create', wc(cwd=str(plain_file)), 'not_found.cwd', {})
            d.error(via, 'window.create', wc(cwd=str(locked / 'inner')), 'unavailable.cwd', {'reason': 'permission'})
            d.unchanged(before)

            # The directory disappears between resolution and chdir.
            vanish = root / f'venomx-vanish-{via}'; vanish.mkdir()
            before = d.snapshot()
            d.error(via, 'window.create', wc(cwd=str(vanish), env=[{'name': 'NEW', 'value': CANARY}]), 'unavailable.cwd', {'reason': 'changed'})
            assert not vanish.exists()
            d.unchanged(before)

            # The child's final PATH chooses the program.
            out = outfile(); res = d.cli('window', 'create', f'--session={s0}', f'--argv={json.dumps(["tool", str(out)])}')
            assert until(lambda: out.exists() and out.read_text().strip()) == 'A'; done(res)
            out = outfile(); ok, res, _ = d.call(via, 'window.create', wc(argv=['tool', str(out)], env=[{'name': 'PATH', 'value': str(B)}]))
            assert ok and until(lambda: out.exists() and out.read_text().strip()) == 'B'; done(res)
            # Empty and relative PATH entries are skipped; ./tool is cwd-relative.
            before = d.snapshot()
            d.error(via, 'window.create', wc(argv=['tool', 'x'], cwd=str(C), env=[{'name': 'PATH', 'value': ':.:cwd-tool:'}]), 'unavailable.spawn', {'reason': 'not_found'})
            d.unchanged(before)
            out = outfile(); ok, res, _ = d.call(via, 'window.create', wc(argv=['./tool', str(out)], cwd=str(C), env=[{'name': 'PATH', 'value': ':.'}]))
            assert ok and until(lambda: out.exists() and out.read_text().strip()) == 'C'; done(res)
            # No PATH at all resolves through confstr(_CS_PATH).
            out = outfile(); ok, res, _ = d.call(via, 'window.create', wc(argv=['sh', '-c', 'echo ok > "$1"; exec sleep 1000', 'x', str(out)], env_unset=['PATH']))
            assert ok and until(lambda: out.exists() and out.read_text().strip()) == 'ok'; done(res)
            # EACCES is skipped; only-EACCES, ENOEXEC (no shell) and missing.
            out = outfile(); ok, res, _ = d.call(via, 'window.create', wc(argv=['tool', str(out)], env=[{'name': 'PATH', 'value': f'{N}:{E}'}]))
            assert ok and until(lambda: out.exists() and out.read_text().strip()) == 'E'; done(res)
            before = d.snapshot()
            d.error(via, 'window.create', wc(argv=['tool', 'x'], env=[{'name': 'PATH', 'value': str(N)}]), 'unavailable.spawn', {'reason': 'permission'})
            d.error(via, 'window.create', wc(argv=[str(shebangless)]), 'unavailable.spawn', {'reason': 'exec_format'})
            d.error(via, 'window.create', wc(argv=['venomx-no-such-program']), 'unavailable.spawn', {'reason': 'not_found'})
            d.unchanged(before)

            # program names the file, by path or on the final PATH, and
            # argv[0] reaches the program exactly as given.
            def named(extra, verb='window.create', target=None):
                out = outfile()
                params = {'session': s0} if verb == 'window.create' else {'pane': target, 'axis': 'cols'}
                params.update(argv=['-tool', '-I', '-c', 'import sys; open(sys.argv[1], "wb").write(open("/proc/self/cmdline", "rb").read())', str(out)], **extra)
                ok, res, _ = d.call(via, verb, params)
                assert ok, (via, res)
                until(lambda: out.exists() and out.read_bytes())
                assert out.read_bytes().split(b'\0')[0] == b'-tool', out.read_bytes()
                return res
            done(named({'program': str(P / 'probe-tool')}))
            done(named({'program': 'probe-tool', 'env': [{'name': 'PATH', 'value': str(P)}]}))
            ok, source, _ = d.call(via, 'window.create', wc())
            assert ok, (via, source)
            done(named({'program': str(P / 'probe-tool')}, 'pane.split', source['pane']))
            done(source)
            # A relative program is cwd-relative; the usual PATH search rules apply.
            out = outfile(); ok, res, _ = d.call(via, 'window.create', wc(program='./tool', argv=['-tool', str(out)], cwd=str(C)))
            assert ok and until(lambda: out.exists() and out.read_text().strip()) == 'C'; done(res)
            before = d.snapshot()
            d.error(via, 'window.create', wc(program='tool', argv=['-tool'], cwd=str(C), env=[{'name': 'PATH', 'value': ':.:cwd-tool:'}]), 'unavailable.spawn', {'reason': 'not_found'})
            d.error(via, 'window.create', wc(program='venomx-no-such-program', argv=['-tool']), 'unavailable.spawn', {'reason': 'not_found'})
            d.error(via, 'window.create', wc(argv=['-tool']), 'unavailable.spawn', {'reason': 'not_found'})
            # program syntax, after argv's.
            d.error(via, 'window.create', wc(program=''), 'invalid_params.argv', {'param': 'program'})
            if via == 'mcp':
                d.error(via, 'window.create', wc(program='sh\0x'), 'invalid_params.argv', {'param': 'program'})
            d.error(via, 'window.create', wc(program='sh', argv=[]), 'invalid_params.argv', {'param': 'argv'})
            d.unchanged(before)

        # 13-16, 18 through MCP (JSON carries NUL) and, where argv can, the CLI.
        g3 = json.loads(d.run(['grant', 'issue', '--grants=[{"right":"read","scope":"*"}]'], record=False).stdout)['token']
        split_host = d.cli('window', 'create', f'--session={s0}', '--argv=["/bin/sh","-c","exec sleep 1000"]')
        venom = 'vnt1.venom.g7.' + SECRET43()
        e1 = lambda name, value: [{'name': name, 'value': value}]
        bad = [
            ({'env': e1('1X', '')}, 'env.0.name', 'syntax'),
            ({'env': e1('A-B', '')}, 'env.0.name', 'syntax'),
            ({'env': e1('A' * 256, '')}, 'env.0.name', 'syntax'),
            ({'env': e1('V', 'v' * 65537)}, 'env.0.value', 'size'),
            ({'env': e1('A\0B', '')}, 'env.0.name', 'nul'),
            ({'env': e1('V', CANARY + '\0')}, 'env.0.value', 'nul'),
            ({'env': [{'name': f'V{i}', 'value': ''} for i in range(257)]}, 'env', 'count'),
            ({'env': [{'name': f'V{i}', 'value': 'v' * 65530} for i in range(4)] + [{'name': 'V4', 'value': 'v' * 143}]}, 'env', 'size'),
            ({'env': e1('DUP', '1') + e1('DUP', '2')}, 'env.1.name', 'duplicate'),
            ({'env': e1('DUP', '1'), 'env_unset': ['DUP']}, 'env_unset.0', 'duplicate'),
            # Reserved names, in env and env_unset.
            ({'env': e1('VENOMX_TOKEN', 'x')}, 'env.0.name', 'reserved'),
            ({'env': e1('VENOMX_SOCKET', '/x')}, 'env.0.name', 'reserved'),
            ({'env': e1('VENOMX_ANYTHING', '1')}, 'env.0.name', 'reserved'),
            ({'env_unset': ['VENOMX_TOKEN']}, 'env_unset.0', 'reserved'),
            ({'env_unset': ['VENOMX_SOCKET']}, 'env_unset.0', 'reserved'),
            ({'env_unset': ['VENOMX_ANYTHING']}, 'env_unset.0', 'reserved'),
            # Another venomx principal's token.
            ({'env': e1('VENOMX_TOKEN', g3)}, 'env.0.name', 'reserved'),
            ({'env': e1('OTHER', g3)}, 'env.0.value', 'credential'),
            # Owner credentials never enter children.
            ({'env': e1('VENOM_TOKEN', '@owner')}, 'env.0.value', 'owner_credential'),
            ({'env': e1('VENOM_TOKEN', 'vnt1.venom.owner.' + SECRET43())}, 'env.0.value', 'owner_credential'),
            ({'env': e1('NOTE', 'prefix vnt1.venom-desk.owner.' + SECRET43())}, 'env.0.value', 'owner_credential'),
            # A token under another tool's name, or not alone.
            ({'env': e1('VENOM_DESK_TOKEN', venom)}, 'env.0.value', 'credential'),
            ({'env': e1('VENOM_TOKEN', venom + ' trailing')}, 'env.0.value', 'credential'),
        ]
        before = d.snapshot()
        for params, param, reason in bad:
            for via in ('mcp', 'cli'):
                text = json.dumps(params)
                if via == 'cli' and ('\\u0000' in text or len(text) > 100000):
                    continue
                d.error(via, 'window.create', dict({'session': s0}, argv=argv_sh, **params), 'invalid_params.env', {'param': param, 'reason': reason})
                if via == 'mcp':
                    d.error(via, 'pane.split', dict({'pane': split_host['pane'], 'axis': 'rows'}, argv=argv_sh, **params), 'invalid_params.env', {'param': param, 'reason': reason})
        d.unchanged(before)
        counters = d.doctor()['spawn.failures']['message']
        assert 'reserved 21' in counters and 'owner_credential 9' in counters, counters
        done(split_host)

        # An explicitly passed cross-product token reaches the child unchanged,
        # and the receiving daemon (venom-echo as the stand-in) resolves it.
        echo_root = root / 'echo'; echo_root.mkdir(mode=0o700)
        echo_sock = str(echo_root / 'e.sock')
        echo_env = dict(clean_env(), HOME=str(echo_root), XDG_CONFIG_HOME=str(echo_root / 'cfg'), XDG_CONFIG_DIRS=str(echo_root / 'cfg' / 'xdg'), XDG_STATE_HOME=str(echo_root / 'state'))
        echo = subprocess.Popen([ECHO, 'serve', '--socket', echo_sock, '--json'], stdin=subprocess.DEVNULL, env=echo_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        until(lambda: Path(echo_sock).exists())
        issued = json.loads(subprocess.run([ECHO, 'grant', 'issue', '--grants=[{"right":"read","scope":"*"}]', '--socket', echo_sock, '--json'], env=dict(echo_env, VENOM_ECHO_TOKEN='@owner'), capture_output=True, text=True, timeout=TIMEOUT).stdout)
        echo_token = issued['token']
        assert echo_token.startswith('vnt1.venom-echo.' + issued['principal'] + '.'), issued
        for via in ('cli', 'mcp'):
            out = outfile(); who = outfile()
            script = f'{ECHO} whoami --socket {echo_sock} --json > "$2.tmp"; mv "$2.tmp" "$2"; exec {PY} -I -c "$3" "$1"'
            ok, res, _ = d.call(via, 'window.create', wc(argv=['/bin/sh', '-c', script, 'x', str(out), str(who), PROBE], env=[{'name': 'VENOM_ECHO_TOKEN', 'value': echo_token}, {'name': 'VENOM_TOKEN', 'value': venom}, {'name': 'VENOM_PRINCIPAL', 'value': 'g7'}, {'name': 'GITHUB_TOKEN', 'value': CANARY}]))
            assert ok, res
            env = read_probe(out)['env']
            assert env['VENOM_ECHO_TOKEN'] == echo_token and env['VENOM_TOKEN'] == venom and env['VENOM_PRINCIPAL'] == 'g7' and env['GITHUB_TOKEN'] == CANARY
            child_tokens.append(env['VENOMX_TOKEN'])
            until(lambda: who.exists())
            assert json.loads(who.read_text())['principal'] == issued['principal'], who.read_text()
            done(res)

        # Denied callers learn nothing and touch no path.
        paths = d.realpaths(); before = d.snapshot()
        invalid = {'env': e1('1X', ''), 'cwd': str(root / 'missing')}
        for via in ('cli', 'mcp'):
            for target in (s0, 's999'):
                e = d.error(via, 'window.create', dict(invalid, session=target, argv=argv_sh), 'denied.spawn', token=None)
            selfspawn = json.loads(d.run(['grant', 'issue', '--grants=[{"right":"spawn","scope":"self"},{"right":"read","scope":"*"}]'], record=False).stdout)['token']
            host = d.cli('window', 'create', f'--session={s0}', '--argv=["/bin/sh","-c","exec sleep 1000"]')
            before = d.snapshot()
            got = [d.error(via, 'pane.split', dict(invalid, pane=p, axis='cols', argv=argv_sh), 'denied.spawn', token=selfspawn) for p in (host['pane'], 'p999')]
            assert got[0]['code'] == got[1]['code'] and set(got[0]['data']) == set(got[1]['data']), got
            d.unchanged(before)
            done(host)
        assert d.realpaths() == paths

        # Delegation precedes env syntax.
        spawner = json.loads(d.run(['grant', 'issue', f'--grants=[{{"right":"spawn","scope":"session:{s0}"}},{{"right":"read","scope":"*"}}]'], record=False).stdout)['token']
        for via in ('cli', 'mcp'):
            d.error(via, 'window.create', wc(grants=[{'right': 'admin', 'scope': '*'}], env=e1('1X', '')), 'denied.delegation', token=spawner)

        # An exited source pane conflicts before any filesystem access.
        ex = d.cli('window', 'create', f'--session={s0}', '--argv=["/bin/true"]')
        until(lambda: d.cli('pane', 'capture', f'--pane={ex["pane"]}')['exited'])
        paths = d.realpaths()
        for via in ('cli', 'mcp'):
            d.error(via, 'pane.split', {'pane': ex['pane'], 'axis': 'cols', 'argv': argv_sh, 'cwd': str(T)}, 'conflict.pane_exited')
        assert d.realpaths() == paths

        # argv plus env beyond the OS limit (one string over MAX_ARG_STRLEN).
        before = d.snapshot()
        d.error('mcp', 'window.create', wc(argv=['/bin/true', 'x' * 200000], env=e1('NEW', CANARY)), 'unavailable.spawn', {'reason': 'too_large'})
        d.unchanged(before)

        # A connection that stays open after a spawn with canaries.
        reply, held = d.wire('window.create', wc(cwd=str(T), env=e1('NEW', CANARY)), keep=True)
        assert 'ok' in reply, reply
        done(reply['ok'])

        checks = d.doctor()
        counters = checks['spawn.failures']['message']
        for expect in ('not_found.cwd 4', 'changed 2', 'permission 2', 'exec_format 2', 'too_large 1'):
            assert expect in counters, (expect, counters)

        # Neither the canaries nor any child token survive in the
        # daemon's heap (live or freed). Thread stacks are not heap.
        def heap_hits(pid, needles):
            sps = set()
            for tid in os.listdir(f'/proc/{pid}/task'):
                fields = Path(f'/proc/{pid}/task/{tid}/syscall').read_text().split()
                if len(fields) >= 3 and fields[0] != 'running':
                    sps.add(int(fields[-2], 16))
            hits = []
            with open(f'/proc/{pid}/maps') as maps, open(f'/proc/{pid}/mem', 'rb', 0) as mem:
                for line in maps:
                    parts = line.split()
                    lo, hi = (int(x, 16) for x in parts[0].split('-'))
                    label = parts[5] if len(parts) > 5 else ''
                    if not parts[1].startswith('rw') or label not in ('', '[heap]') or any(lo <= sp < hi for sp in sps):
                        continue
                    try:
                        mem.seek(lo)
                        chunk = mem.read(hi - lo)
                    except (OSError, ValueError, OverflowError):
                        continue
                    hits += [n for n in needles if n.encode() in chunk]
            return hits
        needles = [CANARY, venom, echo_token, g3] + child_tokens
        # Positive control: the scan does see live daemon heap data.
        # (Set semantics: the path may live in several allocations, e.g. the
        # recovery store identity keeps its own resolved copy.)
        assert set(heap_hits(d.proc.pid, [d.path])) == {d.path}
        assert heap_hits(d.proc.pid, needles) == [], 'secret found in daemon heap (held-connection residue needs a venom-std fix)'
        held[1].close(); held[0].close()

        # An injected failure at each preparation step after cwd resolution
        # rolls back: no ghost pane, PTY, principal, child or event.
        for step in ('prepare', 'adopt', 'stat', 'start'):
            f = Daemon(root, f'fail-{step}', {'VENOMX_TEST_SPAWN_FAIL': step}); daemons.append(f)
            fs = f.cli('session', 'create')['session']
            before = f.snapshot()
            for via in ('cli', 'mcp'):
                reason = 'resource' if step in ('prepare', 'adopt') else 'other'
                f.error(via, 'window.create', {'session': fs, 'argv': argv_sh, 'cwd': str(T), 'env': e1('NEW', CANARY)}, 'unavailable.spawn', {'reason': reason})
            f.unchanged(before)
            assert f.realpaths() == 2
            assert heap_hits(f.proc.pid, [CANARY]) == [], step

        # No canary, request token, or explicit name anywhere observable.
        replay = d.run(['events', '--follow=false', f'--after={start}'], record=False).stdout
        docs = d.run(['docs'], record=False).stdout + d.run(['docs', '--format=man'], record=False).stdout + d.run(['skill'], record=False).stdout + d.run(['completions'], record=False).stdout
        skill = json.loads(d.run(['skill'], record=False).stdout)['content']
        for phrase in ('--cwd "$PWD"', 'VENOMX_*', 'no shell', 'MCP'):
            assert phrase in skill, phrase
        doctor_text = json.dumps(d.doctor())
        stopped = []
        for x in daemons:
            code, out, err = x.stop()
            assert code == 0 and out == '{}\n' and not err, (code, out, err)
            stopped.append(out + err)
        os.chmod(locked, 0o755)
        files = ''
        for path in root.rglob('*'):
            if path.is_file() and outdir not in path.parents and not path.name.endswith('.sock') and 'echo' not in path.parts:
                files += path.read_text(errors='replace')
        observed = [replay, docs, doctor_text, files] + stopped + [o for x in daemons for o in x.outputs]
        for text in observed:
            for needle in [CANARY, venom, echo_token] + child_tokens + ['NEW=', 'GITHUB_TOKEN', 'VENOM_ECHO_TOKEN']:
                assert needle not in text, (needle, text[:400])
        assert 'vnt1.' not in replay + docs + doctor_text
        print('ok spawn cwd, environment, PATH, validation, credentials, grants, rollback, redaction and retention')
    finally:
        os.chmod(locked, 0o755)
        if echo is not None and echo.poll() is None:
            echo.terminate()
            echo.communicate(timeout=5)
        for x in daemons:
            if x.proc.poll() is None:
                x.proc.kill()
                x.proc.communicate(timeout=5)
