#!/usr/bin/env python3
"""pane.capture_rows over a real headless daemon, real PTYs, CLI,
NDJSON, binary pane streams and MCP. Expected text is computed here from the
bytes written, never by asking the daemon. Output volumes stay small: Debug
emulation of short lines is slow."""
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import sys
import tempfile
import time

EXE = str(Path(sys.argv[1]).resolve())
TIMEOUT = 15
CANARY = 'CANARY-7f3a91-SECRET'


def until(fn, timeout=TIMEOUT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.03)
    raise AssertionError('condition did not become true')


class Wire:
    def __init__(self, path, token=None, binary=False, maximum=1048576):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(TIMEOUT)
        self.sock.connect(path)
        self.io = self.sock.makefile('rwb', buffering=0)
        self.n = 100
        params = {'proto': [1], 'caps': ['cancel', 'venomx.pane_stream'], 'max_frame': maximum}
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

    def raw(self):
        return self.io.readline()

    def read(self):
        return json.loads(self.raw())

    def call(self, verb, params=None):
        self.n += 1
        self.send({'id': self.n, 'verb': verb, 'params': params or {}})
        reply = self.read()
        assert reply['id'] == self.n, reply
        return reply

    def rows(self, **params):
        return self.call('pane.capture_rows', params)

    def frame(self, kind, stream, payload):
        if not isinstance(payload, bytes):
            payload = json.dumps(payload, separators=(',', ':')).encode()
        self.io.write(struct.pack('>HII', kind, stream, len(payload)) + payload)

    def exact(self, n):
        out = b''
        while len(out) < n:
            chunk = self.io.read(n - len(out))
            assert chunk, 'connection closed'
            out += chunk
        return out

    def recv(self):
        kind, stream, n = struct.unpack('>HII', self.exact(10))
        return kind, stream, self.exact(n)

    def attach(self, pane, size, mode='raw', history=0, stream=1):
        self.frame(0x100, stream, {'pane': pane, 'mode': mode, 'formats': ['vt'], 'size': size, 'history': history})
        while True:
            kind, _, data = self.recv()
            assert kind != 3, data
            if kind == 0x103:
                return

    def pending(self, wait=.3):
        """Frames that arrive within `wait` seconds."""
        frames = []
        deadline = time.monotonic() + wait
        while True:
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([self.sock], [], [], left)[0]:
                return frames
            frames.append(self.recv())

    def close(self):
        self.io.close()
        self.sock.close()


def padded(text, cols, width=None):
    return text + ' ' * (cols - (len(text) if width is None else width))


def clean(line):
    assert all(ord(ch) >= 0x20 and ord(ch) != 0x7f and not 0x80 <= ord(ch) < 0xa0 for ch in line), repr(line)


def check_page(p, cols=None):
    assert p['end'] - p['start'] >= len(p['lines'])
    assert p['bounds']['end'] - p['bounds']['active'] == p['rows'], p
    if p['done']:
        assert 'next' not in p and p['start'] + len(p['lines']) == p['end'], p
    else:
        assert p['next'] == p['start'] + len(p['lines']), p
    for line in p['lines']:
        clean(line)
    return p


with tempfile.TemporaryDirectory(prefix='vx-rows-') as root:
    root = Path(root)
    daemons = []
    clients = []

    def daemon(name, extra=None):
        path = str(root / f'{name}.sock')
        env = {k: v for k, v in os.environ.items() if not k.endswith('_TOKEN')}
        env.update(HOME=str(root / name), XDG_CONFIG_HOME=str(root / name / 'cfg'), XDG_CONFIG_DIRS=str(root / name / 'cfg' / 'xdg'), XDG_STATE_HOME=str(root / name / 'state'), **(extra or {}))
        os.makedirs(root / name, exist_ok=True)
        logs = open(root / f'{name}.log', 'w')
        d = subprocess.Popen([EXE, 'serve', '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=env, stdout=logs, stderr=subprocess.STDOUT)
        daemons.append((d, logs))
        until(lambda: Path(path).exists() or d.poll() is not None)
        assert d.poll() is None
        return path, env

    def tools(path, env):
        owner = dict(env, VENOMX_TOKEN='@owner')

        def cli(*args, code=0, token='@owner'):
            r = subprocess.run([EXE, *args, '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=dict(env, VENOMX_TOKEN=token) if token else env, capture_output=True, text=True, timeout=TIMEOUT)
            assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
            assert not r.stderr, r.stderr
            return json.loads(r.stdout)

        def events(*args):
            r = subprocess.run([EXE, 'events', '--follow=false', *args, '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=dict(env, VENOMX_TOKEN='@owner'), capture_output=True, text=True, timeout=TIMEOUT)
            assert r.returncode == 0 and not r.stderr, (r.stdout, r.stderr)
            return [json.loads(line) for line in r.stdout.splitlines()]
        cli.events = events

        def mcp(name, arguments, token='@owner'):
            msgs = [{'jsonrpc': '2.0', 'id': 0, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 't', 'version': '0'}}},
                    {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
                    {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call', 'params': {'name': name, 'arguments': arguments}}]
            r = subprocess.run([EXE, 'mcp', '--socket', path], input=''.join(json.dumps(m) + '\n' for m in msgs), capture_output=True, text=True, timeout=TIMEOUT, env=dict(env, VENOMX_TOKEN=token) if token else env)
            assert r.returncode == 0 and not r.stderr, (r.returncode, r.stderr)
            reply = [json.loads(line) for line in r.stdout.splitlines() if json.loads(line).get('id') == 1][0]['result']
            return json.loads(reply['content'][0]['text']), reply['isError']
        return cli, mcp, owner

    try:
        path, env = daemon('main')
        cli, mcp, owner = tools(path, env)
        token = Path(path).with_suffix('.owner').read_text().strip()
        w = Wire(path, token)
        clients.append(w)
        assert cli('session', 'create')['session'] == 's0'

        def window(argv, cols=20, rows=4):
            return cli('window', 'create', '--session=s0', f'--cols={cols}', f'--rows={rows}', f'--argv={json.dumps(argv)}')['pane']

        def settle(pane, check):
            return until(lambda: (v := w.rows(pane=pane, tail=1000000)).get('ok') and check(v['ok']) and v['ok'])

        # Seq 1 1000 in a 20x4 pane.
        p0 = window(['/bin/sh', '-c', 'seq 1 1000; exec sleep 1000'])
        settle(p0, lambda v: v['offset'] == 4893)
        t3 = cli('pane', 'capture-rows', f'--pane={p0}', '--tail=3')
        assert t3 == {'pane': p0, 'screen': 'primary', 'epoch': t3['epoch'], 'offset': 4893, 'cols': 20, 'rows': 4,
                      'bounds': {'oldest': 0, 'active': 997, 'end': 1001}, 'start': 998, 'end': 1001, 'done': True,
                      'lines': [padded('999', 20), padded('1000', 20), ' ' * 20]}, t3
        epoch = t3['epoch']
        # Default selection paged by 100 through the CLI: 11 pages.
        page = cli('pane', 'capture-rows', f'--pane={p0}', '--max-rows=100')
        got, pages = [], 0
        while True:
            check_page(page)
            pages += 1
            got += page['lines']
            if page['done']:
                break
            page = cli('pane', 'capture-rows', f'--pane={p0}', f'--epoch={page["epoch"]}', f'--start={page["next"]}', f'--end={page["end"]}', '--max-rows=100')
        assert pages == 11 and got == [padded(str(n), 20) for n in range(1, 1001)] + [' ' * 20], pages
        # MCP exposes the same verb and result.
        body, err = mcp('pane_dcapture__rows', {'pane': p0, 'tail': 3})
        assert not err and body == {'result': t3}, body
        body, err = mcp('pane_dcapture__rows', {'pane': p0, 'epoch': epoch, 'start': 990, 'end': 2000})
        assert err and body['error']['code'] == 'not_found.rows' and body['error']['data'] == {'reason': 'future', 'screen': 'primary', 'epoch': epoch, 'oldest': 0, 'end': 1001}, body
        # Wire example: tail 1.
        assert w.rows(pane=p0, tail=1)['ok']['lines'] == [' ' * 20]

        # Lines for [active, end) equal pane.capture's text.
        cap = cli('pane', 'capture', f'--pane={p0}')
        b = t3['bounds']
        same = cli('pane', 'capture-rows', f'--pane={p0}', f'--epoch={epoch}', f'--start={b["active"]}', f'--end={b["end"]}')
        assert same['lines'] == cap['text'].split('\n'), (same, cap)

        # Parameter rules and schema ranges.
        for args, reason in ([['--tail=1', f'--epoch={epoch}'], 'exclusive'], [['--start=0'], 'epoch_required'], [[f'--epoch={epoch}', '--start=5', '--end=4'], 'order']):
            e = cli('pane', 'capture-rows', f'--pane={p0}', *args, code=2)['error']
            assert e['code'] == 'invalid_params.rows' and e['data']['reason'] == reason, e
        e = cli('pane', 'capture-rows', f'--pane={p0}', '--tail=3', '--start=0', code=2)['error']
        assert e == {'code': 'invalid_params.rows', 'message': 'tail cannot be combined with epoch, start or end', 'data': {'param': 'tail', 'reason': 'exclusive'}}, e
        for bad in ('--max-rows=0', '--max-rows=10001', '--max-bytes=0', '--tail=0', '--start=-1'):
            e = cli('pane', 'capture-rows', f'--pane={p0}', bad, code=2)['error']
            assert e['code'] == 'invalid_params.range', (bad, e)
        e = cli('pane', 'capture-rows', f'--pane={p0}', '--epoch=0', '--start=0', '--end=10', code=5)['error'] if epoch != 0 else None
        if e:
            assert e == {'code': 'conflict.epoch', 'message': 'row epoch 0 is no longer current', 'data': {'screen': 'primary', 'epoch': epoch, 'oldest': 0, 'end': 1001}}, e
        e = cli('pane', 'capture-rows', f'--pane={p0}', f'--epoch={epoch}', '--start=990', '--end=2000', code=3)['error']
        assert e['message'] == 'rows 1001 to 1999 do not exist yet' and e['data']['reason'] == 'future', e
        e = cli('pane', 'capture-rows', f'--pane={p0}', f'--epoch={epoch}', '--end=1002', code=3)['error']
        assert e['data'] == {'reason': 'future', 'screen': 'primary', 'epoch': epoch, 'oldest': 0, 'end': 1001}, e
        empty = cli('pane', 'capture-rows', f'--pane={p0}', f'--epoch={epoch}', '--start=7', '--end=7')
        assert empty['lines'] == [] and empty['done'] and empty['start'] == 7 and 'next' not in empty
        assert cli('pane', 'capture-rows', '--pane=p99', '--tail=1', code=3)['error']['code'] == 'not_found.pane'

        # An exited pane stays readable.
        gone = window(['/bin/sh', '-c', 'printf "a\\nb\\n"'])
        until(lambda: cli('pane', 'capture', f'--pane={gone}')['exited'])
        done = cli('pane', 'capture-rows', f'--pane={gone}')
        assert done['lines'][:2] == [padded('a', 20), padded('b', 20)] and done['done'], done

        # Unicode, tab, quote and backslash; raw wire bytes unescaped.
        uni = window(['/bin/sh'], cols=20, rows=8)
        script = r"""printf 'START\n\303\251\ne\314\201\n\346\274\242\345\255\227\n\360\237\221\251\342\200\215\360\237\222\273\na\tb\n"\\%s\n' ''"""
        cli('pane', 'send', f'--pane={uni}', f'--text=clear; {script}; printf "%s\\n" "{CANARY}"\n')
        page = settle(uni, lambda v: any(l.startswith(CANARY) for l in v['lines']))
        lines = page['lines']
        at = max(i for i, l in enumerate(lines) if l.startswith('START'))
        assert lines[at + 1] == padded('\u00e9', 20), lines
        assert lines[at + 2] == padded('e\u0301', 20, 1), lines
        assert lines[at + 3] == padded('\u6f22\u5b57', 20, 4), lines
        assert lines[at + 4].startswith('\U0001f469'), lines
        assert lines[at + 5] == padded('a' + ' ' * 7 + 'b', 20), lines
        assert lines[at + 6] == padded('"\\', 20), lines
        w.n += 1
        w.send({'id': w.n, 'verb': 'pane.capture_rows', 'params': {'pane': uni, 'tail': 8}})
        raw = w.raw()
        assert '\u6f22\u5b57'.encode() in raw and b'\\u' not in raw and b'\\"\\\\' in raw, raw
        assert not any(b < 0x20 for b in raw[:-1]) and raw.endswith(b'\n')

        # Styles, hyperlinks, titles and clears never reach the text.
        cli('pane', 'send', f'--pane={uni}', "--text=printf '\\033[31mRED\\033[0m \\033]8;;http://x\\033\\\\LINK\\033]8;;\\033\\\\ \\033]2;T\\007\\n'; seq 1 10; printf '\\033[2J'; echo AFTER\n")
        page = settle(uni, lambda v: any(l.startswith('AFTER') for l in v['lines']))
        every = cli('pane', 'capture-rows', f'--pane={uni}')
        for line in every['lines']:
            clean(line)
            assert '\x1b' not in line
        assert any(l.startswith('RED LINK ') for l in every['lines']), every['lines']

        # 3-byte characters and max_bytes.
        euro = window(['/bin/sh', '-c', 'for i in 1 2 3 4 5; do printf "\\342\\202\\254%.0s" $(seq 1 20); done; exec sleep 1000'])
        rows15 = settle(euro, lambda v: v['lines'][:5] == ['\u20ac' * 20] * 5)
        e15 = rows15['epoch']
        two = w.rows(pane=euro, epoch=e15, start=0, end=5, max_bytes=150)['ok']
        assert two['lines'] == ['\u20ac' * 20] * 2 and two['next'] == 2 and not two['done'], two
        e = w.rows(pane=euro, epoch=e15, start=0, end=5, max_bytes=50)['error']
        assert e['code'] == 'unsupported.result_size' and e['data'] == {'row': 0, 'bytes': 60}, e
        assert cli('pane', 'capture-rows', f'--pane={euro}', '--tail=1', '--max-bytes=1', code=10)['error']['code'] == 'unsupported.result_size'

        # A 4096-byte frame still pages to completion; a row too
        # large for the frame fails.
        small = Wire(path, token, maximum=4096)
        clients.append(small)
        p80 = window(['/bin/sh', '-c', 'seq 1 200; exec sleep 1000'], cols=80, rows=4)
        settle(p80, lambda v: v['bounds']['end'] == 201)
        sel, got = {'pane': p80}, []
        while True:
            small.n += 1
            small.send({'id': small.n, 'verb': 'pane.capture_rows', 'params': sel})
            raw = small.raw()
            assert len(raw) <= 4096, len(raw)
            page = check_page(json.loads(raw)['ok'])
            got += page['lines']
            if page['done']:
                break
            sel = {'pane': p80, 'epoch': page['epoch'], 'start': page['next'], 'end': page['end']}
        assert got == [padded(str(n), 80) for n in range(1, 201)] + [' ' * 80]
        huge = window(['/bin/sh', '-c', 'printf "\\342\\202\\254%.0s" $(seq 1 2000); exec sleep 1000'], cols=2000, rows=2)
        settle(huge, lambda v: v['lines'][0].startswith('\u20ac' * 2000))
        e = small.rows(pane=huge, tail=2)['error']
        assert e['code'] == 'unsupported.result_size' and e['data']['bytes'] == 6000, e

        # The cell limit allows at most 64 rows of 65535 columns.
        big = Wire(path, token, maximum=16 << 20)
        clients.append(big)
        wide = window(['/bin/sh', '-c', 'seq 1 70; exec sleep 1000'], cols=65535, rows=4)
        until(lambda: big.rows(pane=wide, tail=1, max_bytes=1 << 20).get('ok', {}).get('bounds', {}).get('end') == 71)
        sel, total = {'pane': wide, 'max_bytes': 16 << 20}, 0
        while True:
            page = check_page(big.rows(**sel)['ok'])
            assert len(page['lines']) <= 64
            total += len(page['lines'])
            if page['done']:
                break
            sel = {'pane': wide, 'epoch': page['epoch'], 'start': page['next'], 'end': page['end'], 'max_bytes': 16 << 20}
        assert total == 71

        # History rows never change within an epoch.
        sh = window(['/bin/sh'], cols=30, rows=4)
        cli('pane', 'send', f'--pane={sh}', '--text=seq 1 40\n')
        first = settle(sh, lambda v: v['bounds']['end'] > 30)
        hist = w.rows(pane=sh, epoch=first['epoch'], start=first['bounds']['oldest'], end=first['bounds']['active'])['ok']
        cli('pane', 'send', f'--pane={sh}', '--text=seq 100 130\n')
        settle(sh, lambda v: any(l.startswith('130') for l in v['lines']))
        again = w.rows(pane=sh, epoch=first['epoch'], start=hist['start'], end=hist['end'])['ok']
        assert again['lines'] == hist['lines'] and again['epoch'] == first['epoch']

        # CSI 3 J and RIS start new epochs.
        for seq in ('\\033[3J', '\\033c'):
            before = w.rows(pane=sh, tail=1)['ok']
            cli('pane', 'send', f'--pane={sh}', f"--text=printf '{seq}'\n")
            until(lambda: w.rows(pane=sh, tail=1)['ok']['epoch'] != before['epoch'])
            e = w.rows(pane=sh, epoch=before['epoch'], start=before['bounds']['active'])['error']
            assert e['code'] == 'conflict.epoch' and e['data']['epoch'] != before['epoch'], e

        # The alternate screen has no history; leaving it is a new epoch.
        alt = window(['/bin/sh', '-c', 'seq 1 30 > /tmp/.vx-rows-$$; exec less /tmp/.vx-rows-$$'], cols=20, rows=4)
        page = until(lambda: (v := w.rows(pane=alt)['ok'])['screen'] == 'alternate' and any(l.startswith('1 ') for l in v['lines']) and v)
        assert page['bounds']['oldest'] == page['bounds']['active'] and len(page['lines']) == 4, page
        cli('pane', 'send', f'--pane={alt}', '--text=q')
        until(lambda: cli('pane', 'capture', f'--pane={alt}')['exited'])
        e = w.rows(pane=alt, epoch=page['epoch'], start=page['start'])['error']
        assert e['code'] == 'conflict.epoch' and e['data']['screen'] == 'primary', e
        after = w.rows(pane=alt)['ok']
        assert after['screen'] == 'primary' and after['epoch'] != page['epoch']

        # 100 pipelined calls while output streams continuously.
        flood = window(['/bin/sh', '-c', 'while :; do echo yyyyyyyyyy; done'], cols=20, rows=4)
        settle(flood, lambda v: v['bounds']['end'] > 20)
        for n in range(100):
            w.send({'id': 1000 + n, 'verb': 'pane.capture_rows', 'params': {'pane': flood, 'tail': 50}})
        last = 0
        for n in range(100):
            reply = w.read()
            assert reply['id'] == 1000 + n
            p = check_page(reply['ok'])
            assert len(p['lines']) == p['end'] - p['start'] and p['offset'] >= last
            assert all(len(l) == 20 for l in p['lines'])
            last = p['offset']
        cli('pane', 'kill', f'--pane={flood}', '--remove=true')

        # A writer attach with the latest policy resizes the pane.
        rz = window(['/bin/sh', '-c', 'i=0; while :; do i=$((i+1)); echo R$i; sleep 0.01; done'], cols=20, rows=4)
        settle(rz, lambda v: v['bounds']['end'] > 10)
        pinned = w.rows(pane=rz, tail=5)['ok']
        writer = Wire(path, token, binary=True)
        clients.append(writer)
        writer.attach(rz, {'cols': 20, 'rows': 4})
        writer.frame(0x107, 1, {'cols': 25, 'rows': 6})
        until(lambda: w.rows(pane=rz, tail=1)['ok']['cols'] == 25)
        e = w.rows(pane=rz, epoch=pinned['epoch'], start=pinned['start'], end=pinned['end'])['error']
        assert e['code'] == 'conflict.epoch', e
        t = w.rows(pane=rz, tail=3)['ok']
        assert (t['cols'], t['rows']) == (25, 6) and t['epoch'] != pinned['epoch']
        seen = {}
        for n in range(1000):
            w.send({'id': 5000 + n, 'verb': 'pane.capture_rows', 'params': {'pane': rz, 'tail': 2}})
            if n == 500:
                writer.frame(0x107, 1, {'cols': 22, 'rows': 5})
        for n in range(1000):
            p = check_page(w.read()['ok'])
            o, en = seen.get(p['epoch'], (0, 0))
            assert p['bounds']['oldest'] >= o and p['bounds']['end'] >= en, (p, o, en)
            seen[p['epoch']] = (p['bounds']['oldest'], p['bounds']['end'])
        assert len(seen) >= 2, seen
        writer.close()
        clients.remove(writer)

        # Attached viewports, streams and events are untouched.
        view = window(['/bin/sh', '-c', 'seq 1 60; exec sleep 1000'], cols=20, rows=4)
        settle(view, lambda v: v['bounds']['end'] == 61)
        one = Wire(path, token, binary=True)
        two = Wire(path, binary=True)
        clients += [one, two]
        one.attach(view, {'cols': 20, 'rows': 4}, mode='emulate', history=10)
        two.attach(view, {'cols': 20, 'rows': 4}, mode='emulate', history=40)
        one.pending()
        two.pending()
        mark = cli.events()[-1]
        cursor = f"{mark['source']}:{mark['seq']}"
        vb = w.rows(pane=view, tail=1)['ok']
        forms = [{'tail': 5}, {}, {'epoch': vb['epoch'], 'start': 3, 'end': 9}, {'epoch': vb['epoch'], 'start': 0, 'max_rows': 7},
                 {'tail': 1, 'start': 0}, {'epoch': vb['epoch'] + 1}, {'epoch': vb['epoch'], 'end': 999}, {'epoch': vb['epoch'], 'start': 0, 'end': 5, 'max_bytes': 1}]
        for n in range(50):
            for f in forms:
                w.rows(pane=view, **f)
        assert one.pending() == [] and two.pending() == []
        after = w.rows(pane=view, tail=1)['ok']
        assert (after['cols'], after['rows'], after['epoch'], after['offset']) == (vb['cols'], vb['rows'], vb['epoch'], vb['offset'])
        assert [e['type'] for e in cli.events(f'--after={cursor}')] == ['stream.checkpoint']

        # Per-pane read authorization; no bounds leak.
        scoped = cli('grant', 'issue', f'--grants={json.dumps([{"right": "read", "scope": "pane:" + view}])}')
        sw = Wire(path, scoped['token'])
        clients.append(sw)
        assert sw.rows(pane=view, tail=1)['ok']['lines'] == [' ' * 20]
        audit = root / 'main' / 'state' / 'venom' / 'venomx' / 'audit.ndjson'
        before_audit = audit.read_text().count('\n') if audit.exists() else 0
        denials = []
        for target in (p0, 'p9'):
            for params in ({'tail': 1}, {'tail': 1, 'start': 0}):
                e = sw.rows(pane=target, **params)['error']
                assert e['code'] == 'denied.read' and 'oldest' not in json.dumps(e), e
                denials.append(json.dumps(e).replace(target, 'X'))
        assert len(set(denials)) == 1, denials
        records = audit.read_text().splitlines()[before_audit:]
        assert len(records) == 4 and all('"start"' not in r and '"tail"' not in r for r in records), records
        body, err = mcp('pane_dcapture__rows', {'pane': p0, 'tail': 1}, token=scoped['token'])
        assert err and body['error']['code'] == 'denied.read'
        sess = cli('grant', 'issue', '--grants=[{"right":"read","scope":"session:s0"}]')
        assert 'ok' in Wire(path, sess['token']).rows(pane=view, tail=1)
        wild = cli('grant', 'issue', '--grants=[{"right":"read","scope":"window:*"}]')
        assert Wire(path, wild['token']).rows(pane=view, tail=1)['error']['code'] == 'denied.read'

        # Doctor counters; the canary appears only in results.
        doctor = cli('doctor')
        text = json.dumps(doctor)
        assert 'capture_rows' in text and CANARY not in text
        check = [c for c in doctor['checks'] if c['id'] == 'capture_rows'][0]
        calls = int(check['message'].split()[0])
        assert check['status'] in ('ok', 'warn') and calls > 1000 and ' 6 denied.read,' in check['message'], check
        print('doctor:', check['status'], check['message'])

        # On a daemon whose panes keep a tiny scrollback.
        tiny, tiny_env = daemon('tiny', {'VENOMX_TEST_SCROLLBACK_LINES': '5'})
        tcli, _, _ = tools(tiny, tiny_env)
        tcli('session', 'create')
        tw = Wire(tiny, Path(tiny).with_suffix('.owner').read_text().strip())
        clients.append(tw)
        tp = tcli('window', 'create', '--session=s0', '--cols=20', '--rows=4', '--argv=["/bin/sh","-c","i=0; while :; do i=$((i+1)); echo L$i; done"]')['pane']
        until(lambda: tw.rows(pane=tp, tail=1)['ok']['bounds']['oldest'] > 0)
        cur = tw.rows(pane=tp, tail=1)['ok']
        e = tw.rows(pane=tp, epoch=cur['epoch'], start=cur['bounds']['oldest'] - 1)['error']
        assert e['code'] == 'not_found.rows' and e['data']['reason'] == 'evicted' and e['data']['oldest'] >= cur['bounds']['oldest'], e
        e = tw.rows(pane=tp, epoch=cur['epoch'], end=cur['bounds']['end'] + 1000000)['error']
        assert e['data']['reason'] == 'future'
        evicted = complete = 0
        for attempt in range(20):
            start = tw.rows(pane=tp, tail=1000000)['ok']
            sel = {'pane': tp, 'epoch': start['epoch'], 'start': start['start'], 'end': start['end'], 'max_rows': 1}
            offset = None
            while True:
                r = tw.rows(**sel)
                if 'error' in r:
                    assert r['error']['code'] == 'not_found.rows' and r['error']['data']['reason'] == 'evicted', r
                    assert r['error']['data']['oldest'] > sel['start']
                    evicted += 1
                    break
                p = check_page(r['ok'])
                assert p['start'] == sel['start'] and len(p['lines']) == 1
                line = p['lines'][0].strip()
                if line.startswith('L') and p['start'] < p['bounds']['active']:
                    # Row content minus row address is constant: no shift.
                    k = int(line[1:]) - p['start']
                    assert offset is None or k == offset, (k, offset)
                    offset = k
                if p['done']:
                    complete += 1
                    break
                time.sleep(.02)
                sel['start'] = p['next']
        assert evicted > 0, (evicted, complete)
        print(f'ok capture_rows: CLI/MCP/NDJSON, paging, limits, epochs, eviction ({evicted} evicted, {complete} complete), grants, viewports')
    finally:
        for c in clients:
            try:
                c.close()
            except Exception:
                pass
        for d, logs in daemons:
            if d.poll() is None:
                d.terminate()
            try:
                d.wait(timeout=5)
            except subprocess.TimeoutExpired:
                d.kill()
                d.wait()
            logs.close()
        # No daemon log or audit record holds pane text.
        for f in root.rglob('*'):
            if f.is_file() and f.suffix in ('.log', '.ndjson'):
                assert CANARY not in f.read_text(errors='replace'), f
