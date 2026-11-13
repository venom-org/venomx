#!/usr/bin/env python3
"""End to end: two real `venomx attach` clients on PTYs, one session.

Each client's host-terminal output is replayed into a fresh venom-term Vt by
the vt-screen helper, so assertions read exactly what a user would see.
"""
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

EXE = str(Path(sys.argv[1]).resolve())
SCREEN = str(Path(sys.argv[2]).resolve())
TIMEOUT = 10
COLS, ROWS = 100, 30
PREFIX = b'\x02'  # the default leader, Ctrl-B
PAGE_UP = b'\x1b[5~'


def until(fn, what='condition'):
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError(f'{what} did not become true')


class Client:
    """One attach process whose stdin/stdout are a PTY of COLS x ROWS."""

    def __init__(self, args, env):
        master, slave = os.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
        self.proc = subprocess.Popen([EXE, 'attach', *args], stdin=slave, stdout=slave,
                                     stderr=subprocess.PIPE, env=env, start_new_session=True)
        os.close(slave)
        os.set_blocking(master, False)
        self.master = master
        self.out = bytearray()

    def pump(self):
        while True:
            try:
                chunk = os.read(self.master, 65536)
            except BlockingIOError:
                return
            except OSError:  # EIO once the process has exited
                return
            if not chunk:
                return
            self.out += chunk

    def screen(self):
        self.pump()
        r = subprocess.run([SCREEN, str(COLS), str(ROWS)], input=bytes(self.out), capture_output=True, timeout=TIMEOUT)
        assert r.returncode == 0, r.stderr
        return r.stdout.decode()

    def shows(self, text, what=None):
        return until(lambda: text in self.screen(), what or f'screen showing {text!r}')

    def hides(self, text):
        return until(lambda: text not in self.screen(), f'screen hiding {text!r}')

    def type(self, data):
        os.write(self.master, data)

    def wait(self):
        try:
            code = self.proc.wait(timeout=TIMEOUT)
        finally:
            self.pump()
        return code, self.proc.stderr.read().decode()

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()
            self.proc.wait(timeout=TIMEOUT)
        self.close()

    def close(self):
        if self.master >= 0:
            os.close(self.master)
            self.master = -1


with tempfile.TemporaryDirectory(prefix='vx-attach-') as root:
    root = Path(root)
    path = str(root / 'd.sock')
    env = {k: v for k, v in os.environ.items() if not k.endswith('_TOKEN') and not k.startswith('VENOMX_')}
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / 'cfg'), XDG_CONFIG_DIRS=str(root / 'cfg' / 'xdg'), XDG_STATE_HOME=str(root / 'state'), PS1='$ ', ENV='', TERM='xterm-256color', SHELL='/bin/sh')
    owner = dict(env, VENOMX_TOKEN='@owner')

    def cli(*args, code=0):
        r = subprocess.run([EXE, *args, '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=owner, capture_output=True, text=True, timeout=TIMEOUT)
        assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
        return json.loads(r.stdout)

    def attach(*args):
        # No VENOMX_TOKEN: presentation clients default to the owner file.
        return Client([*args, '--socket', path], env)

    # Generated human surfaces include attach; agent surfaces omit it.
    def offline(*args):
        r = subprocess.run([EXE, *args], stdin=subprocess.DEVNULL, env=env,
                           capture_output=True, text=True, timeout=TIMEOUT)
        assert r.returncode == 0, (args, r.returncode, r.stdout, r.stderr)
        return r.stdout

    assert 'attach' in offline('--help')
    help_text = offline('attach', '--help')
    assert all(flag in help_text for flag in ('--session', '--pane', '--history', '--raw'))
    # Help names the defaults as defaults.
    assert 'default ctrl+b, see keys.leader' in help_text and 'default ctrl+alt+b, see keys.unlock' in help_text, help_text
    assert 'Ctrl-Space' not in help_text and 'o/Tab' not in help_text and '%' not in help_text, help_text
    docs = offline('docs')
    assert 'attach' in docs and 'MCP tool: none (local command)' in docs
    assert 'Interactive: needs a terminal on stdin and stdout' in docs
    for shell in ('bash', 'zsh', 'fish'):
        assert 'attach' in offline('completions', '--shell', shell)
    requests = [
        {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'},
        {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/call',
         'params': {'name': 'attach', 'arguments': {'session': 's0'}}},
    ]
    r = subprocess.run([EXE, 'mcp'], input=''.join(json.dumps(v) + '\n' for v in requests),
                       env=env, capture_output=True, text=True, timeout=TIMEOUT)
    assert r.returncode == 0 and not r.stderr, (r.returncode, r.stderr)
    replies = [json.loads(line) for line in r.stdout.splitlines()]
    assert 'attach' not in {t['name'] for t in replies[0]['result']['tools']}
    assert replies[1]['error']['code'] == -32602, replies[1]

    # The shared runtime validates flags before its terminal check.
    for args in (['--history=-1'], ['--history=nope'], ['--unknown=1']):
        assert cli('attach', *args, code=2)['error']['code'].startswith('invalid_params')
    assert cli('attach', '--session=s0', code=10)['error']['code'] == 'unsupported.terminal'
    # Selector constraints belong to the local handler, after terminal checks.
    # No selector is valid (the last-used session) and needs a daemon.
    for args in (['--session=s0', '--pane=p0'], ['--session=s0', '--raw=true']):
        invalid = attach(*args, '--json')
        code, err = invalid.wait()
        invalid.close()
        assert code == 2 and not err, (code, err)
        assert json.loads(invalid.out)['error']['code'] == 'invalid_params.selector', (args, invalid.out)
    assert not Path(path).exists()

    lonely_json = attach('--session=s0', '--json')
    code, err = lonely_json.wait()
    lonely_json.close()
    assert code == 6 and not err, (code, err)
    assert json.loads(lonely_json.out)['error']['code'] == 'unavailable'
    # No daemon: exit 6 without starting one.
    lonely = attach('--session', 's0')
    code, err = lonely.wait()
    lonely.close()
    assert code == 6 and 'no venomx daemon' in err, (code, err)
    # Agents and pipes get a clear refusal rather than a broken TUI.
    r = subprocess.run([EXE, 'attach', '--session', 's0', '--socket', path], stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env, timeout=TIMEOUT)
    assert r.returncode == 10 and 'terminal' in r.stderr, (r.returncode, r.stderr)

    d = subprocess.Popen([EXE, 'serve', '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    clients = []
    try:
        until(lambda: Path(path).exists() or d.poll() is not None, 'daemon socket')
        assert d.poll() is None, d.communicate()
        assert 'attach' not in cli('skill')['content']
        missing = attach('--session', 's9')
        code, err = missing.wait()
        missing.close()
        assert code == 3 and 'no such session' in err, (code, err)

        missing_json = attach('--session=s9', '--json')
        code, err = missing_json.wait()
        missing_json.close()
        assert code == 3 and not err, (code, err)
        assert json.loads(missing_json.out)['error']['code'] == 'not_found.session'

        cli('session', 'create', '--name', 'work')
        created = cli('window', 'create', '--session=s0', '--argv=["/bin/sh"]')
        pane = created['pane']
        # History that the clients backfill after READY.
        cli('pane', 'send', f'--pane={pane}', '--text', 'i=0; while [ $i -lt 400 ]; do echo history-$i; i=$((i+1)); done; echo done-$i\n')
        until(lambda: 'done-400' in cli('pane', 'capture', f'--pane={pane}')['text'], 'history output')

        issued = cli('grant', 'issue', '--grants=[{"right":"read","scope":"pane:p999"}]')
        denied = Client(['--session=s0', '--json', '--socket', path],
                        dict(env, VENOMX_TOKEN=issued['token']))
        code, err = denied.wait()
        denied.close()
        assert code == 4 and not err, (code, err)
        assert json.loads(denied.out)['error']['code'] == 'denied.read'

        a = attach('--session', 's0'); clients.append(a)
        b = attach('--session', 's0'); clients.append(b)
        a.shows('done-400'); b.shows('done-400')
        # With default config the status line is the
        # top row and the pane area starts on row 2. The session block
        # shows the session's name, not its ID.
        rows = a.screen().split('\n')
        # The pane is a block with its process, not its ID.
        assert rows[0].startswith(' work ◤  ▸1 │  sh '), rows
        assert 'done-400' in rows[ROWS - 1] or 'done-400' in rows[ROWS - 2], rows
        assert not any(' work ◤' in line for line in rows[1:]), rows
        # `config set` moves it to the bottom on running clients, no restart.
        def status_row(c):
            return [i for i, line in enumerate(c.screen().split('\n')) if line.startswith(' work ◤  ▸1')]
        cli('config', 'set', '--key=status.position', '--value=.bottom')
        until(lambda: status_row(a) == [ROWS - 1] and status_row(b) == [ROWS - 1], 'status line at the bottom')
        cli('config', 'set', '--key=status.position', '--value=.top')
        until(lambda: status_row(a) == [0] and status_row(b) == [0], 'status line back at the top')
        print('ok status line on the top row by default; config set moves it live')
        # A command that sets no title shows by its
        # sampled process name in the middle, and the shell's name after it exits.
        def middle(c):
            return c.screen().split('\n')[0]
        cli('pane', 'send', f'--pane={pane}', '--text', 'sleep 2\n')
        until(lambda: ' sleep ' in middle(a) and ' sleep ' in middle(b), 'sleep in the status line')
        until(lambda: ' sh ' in middle(a) and ' sleep ' not in middle(a), 'sh back in the status line')
        print('ok the sampled foreground process names the pane in the status line')
        # A segment and attention published with
        # verbs show on both clients; the connection-bound segment of the
        # CLI call is gone once its connection closes.
        cli('status', 'set', '--id=user.e2e', '--text=e2e segment', '--bind=daemon', '--style=ok')
        cli('status', 'set', '--id=user.gone', '--text=gone with conn')
        cli('pane', 'attention', f'--pane={pane}', '--level=warn', '--reason=look here')
        for c in (a, b):
            c.shows('● e2e segment'); c.shows('▲ 1 attention')
            # A lone pane has no title line; its
            # process and mark are in its block in the status line.
            until(lambda: re.search(r'▸1 │  sh ▲  │ look here ', c.screen().split('\n')[0]), 'lone pane in its block with its mark')
            assert 'warn' not in ''.join(c.screen().split('\n')[1:]), c.screen()
            assert 'gone with conn' not in c.screen()
        cli('status', 'clear', '--id=user.e2e')
        cli('pane', 'attention', f'--pane={pane}', '--clear=true')
        a.hides('e2e segment'); b.hides('e2e segment'); a.hides('1 attention'); b.hides('1 attention')
        assert b'\x1b[?2004h' in a.out, 'host bracketed paste was not enabled'
        assert b'\x1b[?1003h' in a.out, 'host any-motion reports were not enabled'
        assert b'\x1b[>31u' in a.out, 'host Kitty keyboard reporting was not requested'

        # Typing in one client reaches the shared PTY and shows in both.
        a.type(b'echo typed-in-a\r')
        a.shows('\ntyped-in-a'); b.shows('\ntyped-in-a')

        # Scrolling is client-local: A moves back, B stays on the live screen.
        for _ in range(4):
            a.type(PREFIX + PAGE_UP)
        a.hides('typed-in-a')
        a.shows('history-270'); a.shows(' -112 ')
        screen_b = b.screen()
        assert 'typed-in-a' in screen_b and 'history-270' not in screen_b, screen_b
        # Mouse selection in B is local too and is copied through OSC 52.
        b.type(b'\x1b[<0;1;2M\x1b[<32;9;2M\x1b[<0;9;2m')
        until(lambda: (b.pump(), b'\x1b]52;c;' in b.out)[1], 'OSC 52 copy')
        a.pump()
        assert b'\x1b]52;c;' not in a.out

        # Killing one client affects neither the pane nor the other client.
        a.kill(); clients.remove(a)
        b.type(b'echo from-b\r')
        b.shows('\nfrom-b')
        assert 'from-b' in cli('pane', 'capture', f'--pane={pane}')['text']

        # Reattaching restores the screen from a fresh snapshot.
        a2 = attach('--session', 's0'); clients.append(a2)
        a2.shows('\nfrom-b'); a2.shows('typed-in-a')
        # Restored history is scrollable after backfill.
        a2.type(PREFIX + PAGE_UP)
        a2.hides('from-b')

        # Topology changes from any client appear in every client.
        cli('pane', 'split', f'--pane={pane}', '--axis=cols', '--argv=["/bin/sh"]')
        until(lambda: all(re.search('[│┃]', x.screen()) for x in (a2, b)), 'the split shows')
        # pane.list carries argv0, and a pane with no
        # OSC 2 title shows it on its title line.
        for p in cli('pane', 'list')['panes']:
            if p['pane'] == pane:
                assert p.get('argv0') == 'sh', p
        # The title line has no pane ID.
        until(lambda: all(re.match('[━─] sh ', x.screen().split('\n')[1]) for x in (a2, b)), 'title line shows argv0')
        # A binding is a schema verb: split again from inside the client.
        b.type(PREFIX + b'-')
        until(lambda: len([n for n in cli('window', 'get', '--window=w0')['nodes'] if n['kind'] == 'pane']) == 3, 'binding split')
        b.shows('─'); a2.shows('─')
        # Removal of a focused pane falls back locally; empty windows show a state.
        cli('window', 'create', '--session=s0', '--name=logs', '--argv=["/bin/sh","-c","exit 3"]')
        b.shows('▸1 2:logs')
        # A client attaching later learns the name from the stream snapshot.
        a3 = attach('--session', 's0'); clients.append(a3)
        a3.shows('2:logs')
        b.type(PREFIX + b'n')
        b.shows('exited 3')
        cli('pane', 'remove', '--pane=p3')
        b.shows('window w1 is empty')
        b.type(PREFIX + b'p')
        b.shows('from-b')

        # Detach exits cleanly and leaves the session running.
        a2.type(PREFIX + b'd')
        code, err = a2.wait()
        # A session detach says so after the terminal is restored.
        assert code == 0 and err == '[venomx: detached from s0 (work)]\n', (code, err)
        assert b'\x1b[<u' in a2.out, 'host Kitty flags were not popped'
        assert b'\x1b[?2004l' in a2.out, 'host bracketed paste was not disabled'
        assert b'\x1b[?1003l' in a2.out, 'host mouse tracking was not disabled'
        clients.remove(a2); a2.close()
        assert len(cli('pane', 'list')['panes']) == 3
        # Raw uses the whole host terminal, with no client status
        # line or alternate screen. Reattach replays the retained screen.
        raw_pane = cli('window', 'create', '--session=s0', '--cols=100', '--rows=30',
                       '--argv=["/bin/sh"]')['pane']
        cli('pane', 'send', f'--pane={raw_pane}', '--text=stty -echo; echo RAW-BEFORE\n')
        until(lambda: 'RAW-BEFORE' in cli('pane', 'capture', f'--pane={raw_pane}')['text'])
        raw = attach('--pane', raw_pane, '--raw=true'); clients.append(raw)
        raw.shows('RAW-BEFORE')
        assert b'\x1b[?1049h' not in raw.out, 'raw entered alternate screen'
        assert cli('pane', 'capture', f'--pane={raw_pane}')['rows'] == ROWS
        raw.type(b"printf '\\033[31mRAW-LIVE\\033[0m\\n'\r")
        raw.shows('RAW-LIVE')
        assert b'\x1b[31mRAW-LIVE\x1b[0m' in raw.out, 'raw bytes were rendered'
        raw.type(b"printf '\\033[6nRAW-FILTERED\\n'\r")
        raw.shows('RAW-FILTERED')
        assert b'\x1b[6n' not in raw.out, 'query reached host'
        raw.type(PREFIX + b'd')
        code, err = raw.wait()
        assert code == 0 and not err, (code, err)
        clients.remove(raw); raw.close()
        restored = attach('--pane', raw_pane, '--raw=true'); clients.append(restored)
        restored.shows('RAW-LIVE'); restored.shows('RAW-FILTERED')
        # SIGWINCH makes the host diverge immediately. The client discards
        # raw bytes until an emulating snapshot is ready, then draws again.
        fcntl.ioctl(restored.master, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, 80, 0, 0))
        restored.proc.send_signal(signal.SIGWINCH)
        time.sleep(.2)
        restored.type(b'\x15echo FALLBACK-ALIVE\r')
        def fallback_screen():
            restored.pump()
            r = subprocess.run([SCREEN, '80', str(ROWS)], input=bytes(restored.out), capture_output=True, timeout=TIMEOUT)
            assert r.returncode == 0, r.stderr
            return r.stdout.decode()
        until(lambda: 'FALLBACK-ALIVE' in fallback_screen(), 'fallback rendering')
        restored.type(PREFIX + b'd')
        code, err = restored.wait()
        assert code == 0 and not err, (code, err)
        assert restored.out.endswith(b'\x1b[=0u'), 'raw fallback left host keyboard flags active'
        clients.remove(restored); restored.close()
        # A raw client snapshots the host's colors without waiting for
        # them, and puts them back on detach. The replies come mixed with typing.
        theme_pane = cli('window', 'create', '--session=s0', f'--cols={COLS}', f'--rows={ROWS}',
                         '--argv=["/bin/sh"]')['pane']
        cli('pane', 'send', f'--pane={theme_pane}', '--text=stty -echo; echo THEME-READY; cat -v\n')
        until(lambda: 'THEME-READY' in cli('pane', 'capture', f'--pane={theme_pane}')['text'])
        themed = attach('--pane', theme_pane, '--raw=true'); clients.append(themed)
        # The host hasn't answered anything and the pane is already painted.
        themed.shows('THEME-READY')
        assert themed.out.startswith(b'\x1bP$q q\x1b\\'), 'probe was not written first'
        assert b'\x1b[c' in themed.out, 'probe has no sentinel'
        # This pane set no palette entry or tab stop, so the host keeps its own.
        assert not re.search(rb'\x1b\]4;\d+;rgb', themed.out), 'replay wrote the palette'
        assert b'\x1b[3g' not in themed.out, 'replay cleared the tab stops'
        # Replies arrive late, split up and with keys between them.
        for piece in (b'TYPED1', b'\x1b]11;rgb:12', b'/34/56\x1b\\', b'TYPED2\x1b]4;3;rgb:1/2/3\x07',
                      b'\x1bP1$r5 q\x1b\\', b'\x1b[?62;22c', b'TYPED3\r'):
            themed.type(piece)
            time.sleep(.02)
        def shown():
            return cli('pane', 'capture', f'--pane={theme_pane}')['text']
        until(lambda: 'TYPED3' in shown(), 'typed bytes around the replies reach the pane')
        assert 'TYPED1TYPED2TYPED3' in shown(), shown()
        for leak in ('rgb:', '$r', '[?62'):
            assert leak not in shown(), ('reply reached the pane', leak, shown())
        # A pane program changes the host's background and cursor style.
        themed.type(b'\x04')
        time.sleep(.2)
        themed.type(b"printf '\\033]11;#ffffff\\007\\033[2 qPANE-SET\\n'\r")
        themed.shows('PANE-SET')
        themed.type(PREFIX + b'd')
        code, err = themed.wait()
        assert code == 0 and not err, (code, err)
        tail = bytes(themed.out[themed.out.rindex(b'\x1b]11;#ffffff\x07'):])
        assert b'\x1b]11;rgb:12/34/56\x1b\\' in tail, ('theme color not restored', tail)
        assert b'\x1b[5 q' in tail, ('cursor style not restored', tail)
        assert b'\x1b]111' not in tail, ('reset to default instead of the theme', tail)
        clients.remove(themed); themed.close()
        # A host that answers nothing: nothing hangs, typing works, and detach
        # within the probe's window is bounded and falls back to the default.
        mute = attach('--pane', theme_pane, '--raw=true'); clients.append(mute)
        mute.shows('PANE-SET')
        mute.type(b"printf '\\033]11;#000000\\007MUTE-SET\\n'\r")
        mute.shows('MUTE-SET')
        started = time.monotonic()
        mute.type(PREFIX + b'd')
        code, err = mute.wait()
        assert code == 0 and not err, (code, err)
        assert time.monotonic() - started < 2, 'detach waited too long on a mute host'
        assert b'\x1b]111\x1b\\' in mute.out, 'mute host did not fall back to the default'
        clients.remove(mute); mute.close()
        print('ok raw attach restores the host theme, keeps typing, leaks no replies, bounded on a mute host')
        print('ok raw replay, whole-host size, unchanged live bytes, filtering, detach/reattach, resize fallback')
        print('ok two attach clients: shared input, local scroll/selection, kill/reattach restore, topology')
    finally:
        for c in clients:
            c.kill()
        if d.poll() is None:
            d.send_signal(signal.SIGINT)
        out, err = d.communicate(timeout=10)
        assert d.returncode == 0, (d.returncode, out, err)

# A restored archive pane shows its status in the
# client chrome (the status line), never inside its terminal cells.
with tempfile.TemporaryDirectory(prefix='vx-attach-archive-') as root:
    root = Path(root)
    path = str(root / 'd.sock')
    (root / 'cfg' / 'venomx').mkdir(parents=True)
    (root / 'cfg' / 'venomx' / 'config.zon').write_text('.{ .recovery = .{ .enabled = true, .interval_ms = 3600000, .terminal_text = .plain } }\n')
    env = {k: v for k, v in os.environ.items() if not k.endswith('_TOKEN') and not k.startswith('VENOMX_')}
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / 'cfg'), XDG_CONFIG_DIRS=str(root / 'cfg' / 'xdg'), XDG_STATE_HOME=str(root / 'state'), PS1='$ ', ENV='', TERM='xterm-256color', SHELL='/bin/sh')
    owner = dict(env, VENOMX_TOKEN='@owner')

    def cli(*args, code=0):
        r = subprocess.run([EXE, *args, '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=owner, capture_output=True, text=True, timeout=TIMEOUT)
        assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
        return json.loads(r.stdout)

    def attach(*args):
        return Client([*args, '--socket', path], env)

    def serve():
        p = subprocess.Popen([EXE, 'serve', '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        until(lambda: Path(path).exists() or p.poll() is not None, 'daemon socket')
        assert p.poll() is None, p.communicate()
        return p

    def stop(p):
        if p.poll() is None:
            p.send_signal(signal.SIGINT)
        out, err = p.communicate(timeout=10)
        assert p.returncode == 0, (p.returncode, out, err)

    d = serve()
    try:
        cli('session', 'create', '--name', 'archive')
        pane = cli('window', 'create', '--session=s0', '--argv=["/bin/sh","-c","echo ARCHIVED-TEXT; exec sleep 60"]')['pane']
        until(lambda: 'ARCHIVED-TEXT' in cli('pane', 'capture', f'--pane={pane}')['text'], 'archived text')
    finally:
        stop(d)  # the clean shutdown writes the final checkpoint
    d = serve()
    clients = []
    try:
        [final] = [c['checkpoint'] for c in cli('recovery', 'list')['checkpoints'] if c['status'] == 'valid']
        archive = cli('recovery', 'restore', f'--checkpoint={final}')['panes'][0]['current']
        marker = 'archive: exited, text plain'
        for args in (('--session', 's0'), ('--pane', archive)):
            c = attach(*args); clients.append(c)
            c.shows('ARCHIVED-TEXT'); c.shows(marker)
            rows = c.screen().split('\n')
            status = [i for i, line in enumerate(rows) if marker in line]
            # The status line is the top row by default.
            assert status == [0], (args, status, rows)
            assert not any('archive' in line for line in rows[1:]), (args, rows)
            c.type(PREFIX + b'd')
            code, err = c.wait()
            # Session attaches report the detach; pane attaches do not.
            assert code == 0 and err == ('[venomx: detached from s0 (archive)]\n' if args[0] == '--session' else ''), (code, err)
            clients.remove(c); c.close()
        print('ok restored archive status in the attach status line, outside pane cells')
    finally:
        for c in clients:
            c.kill()
        stop(d)

# The key grammar in a real client on a real PTY.
with tempfile.TemporaryDirectory(prefix='vx-keys-') as root:
    root = Path(root)
    path = str(root / 'd.sock')
    (root / 'cfg' / 'venomx').mkdir(parents=True)
    # The defaults: nothing about keys in the config.
    (root / 'cfg' / 'venomx' / 'config.zon').write_text('.{}\n')
    env = {k: v for k, v in os.environ.items() if not k.endswith('_TOKEN') and not k.startswith('VENOMX_')}
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / 'cfg'), XDG_CONFIG_DIRS=str(root / 'cfg' / 'xdg'), XDG_STATE_HOME=str(root / 'state'), PS1='$ ', ENV='', TERM='xterm-256color', SHELL='/bin/sh')
    owner = dict(env, VENOMX_TOKEN='@owner')

    def cli(*args, code=0):
        r = subprocess.run([EXE, *args, '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=owner, capture_output=True, text=True, timeout=TIMEOUT)
        assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
        return json.loads(r.stdout)

    def capture(pane):
        return cli('pane', 'capture', f'--pane={pane}')['text']

    d = subprocess.Popen([EXE, 'serve', '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    c = None
    try:
        until(lambda: Path(path).exists() or d.poll() is not None, 'daemon socket')
        assert d.poll() is None, d.communicate()
        cli('session', 'create', '--name', 'keys')
        # Programs that show every byte they get. p1 turns on the Kitty protocol.
        left = cli('window', 'create', '--session=s0', '--argv=' + json.dumps(['/bin/sh', '-c', 'stty -icanon -echo; exec cat -v']))['pane']
        right = cli('pane', 'split', f'--pane={left}', '--axis=cols', '--argv=' + json.dumps(['/bin/sh', '-c', "stty -icanon -echo; printf '\\033[>1u'; exec cat -v"]))['pane']
        time.sleep(.2)
        listed = cli('keys', 'list')
        assert (listed['leader'], listed['unlock'], listed['popup_delay_ms'], listed['timeout_ms']) == ('ctrl+b', 'ctrl+alt+b', 200, 0), listed
        cli('keys', 'register', '--name=venom', '--prefix=v', '--label=venom', '--when=[{"key":"thread","value":"t7"}]', '--bindings=[{"key":"s","label":"settings","local":"zoom"}]', '--bind=daemon')
        cli('keys', 'register', '--name=tools', '--prefix=y', '--label=tools', '--groups=[{"key":"a","label":"agents"}]', '--bindings=[{"key":"a z","label":"zoom it","local":"zoom"},{"key":"u","label":"lock it","local":"lock"}]', '--bind=daemon')

        c = Client(['--session', 's0', '--socket', path], env)

        def top():
            return c.screen().split('\n')[0]

        def focused(pane):
            # The status line shows no pane IDs; the focused
            # pane's title line (row 1) is the heavy one.
            def heavy():
                title = c.screen().split('\n')[1]
                return title.startswith('━') if pane == left else (not title.startswith('━') and '┏' in title)
            until(heavy, f'focus on {pane}')

        def row(keys, label, plus=False):
            # Columns pad to their widest key, and to a `+` when one has any.
            return re.compile(re.escape(keys) + (r' +\+ ' if plus else r' +') + re.escape(label))

        def shows_row(keys, label, plus=False):
            until(lambda: row(keys, label, plus).search(c.screen()), f'popup row {keys} {label}')

        def since(mark):
            c.pump()
            return bytes(c.out[mark:])

        focused(left)
        time.sleep(.2)  # the client's keys.list answer

        # A key within the delay runs with no popup.
        mark = len(c.out)
        c.type(PREFIX + b'\t')
        focused(right)
        time.sleep(.4)
        assert b'send-leader' not in since(mark), since(mark)
        c.type(PREFIX + b'\t')
        focused(left)
        # Otherwise it appears after the delay and stays until a key.
        mark = len(c.out)
        started = time.monotonic()
        c.type(PREFIX)
        c.shows('send-leader')
        assert time.monotonic() - started >= .15, time.monotonic() - started
        time.sleep(.6)
        screen = c.screen()
        assert 'send-leader' in screen and 'LEADER' in top(), screen
        # Active tables only, with labels and groups; one row per direction.
        assert row('y', 'tools', plus=True).search(screen), screen
        assert not row('v', 'venom', plus=True).search(screen), screen
        assert row('h ←', 'focus-left').search(screen), screen
        assert row('[', 'scroll', plus=True).search(screen), screen
        assert row('esc', 'clear-selection').search(screen), screen
        assert '╭ venomx' in screen, screen
        # The panes keep their size and the popup is the bottom of the pane area.
        assert 'hint' not in top() and 'send-leader' not in top(), top()
        last_rows = screen.split('\n')[ROWS - 1]
        assert '╰' in last_rows, screen
        print('ok key popup after the delay, active tables, labels and groups')

        # Esc cancels.
        c.type(b'\x1b')
        c.hides('send-leader')
        until(lambda: 'LEADER' not in top(), 'leader ended')
        # Backspace goes up one level, then out.
        c.type(PREFIX + b'y')
        c.shows('venomx › tools')
        shows_row('a', 'agents', plus=True)
        c.type(b'a')
        c.shows('venomx › tools › agents')
        shows_row('z', 'zoom it')
        c.type(b'\x7f')
        shows_row('u', 'lock it')
        c.type(b'\x7f')
        c.shows('send-leader')
        c.type(b'\x7f')
        c.hides('send-leader')
        until(lambda: 'LEADER' not in top(), 'backspace out of leader mode')
        # An unbound key cancels, and reaches neither the pane nor a binding.
        c.type(PREFIX + b'Y')
        until(lambda: 'LEADER' not in top(), 'unbound key cancels')
        c.type(PREFIX + b'yq')
        until(lambda: 'LEADER' not in top(), 'unbound key under a prefix cancels')
        c.type(b'P')
        until(lambda: 'P' in capture(left), 'key after the cancel')
        assert 'Y' not in capture(left) and 'q' not in capture(left), capture(left)
        assert 'no binding' not in top(), top()
        print('ok key esc, backspace and unbound keys in leader mode')

        # h j k l and the arrows move focus alike.
        for keys_lr in ((b'l', b'h'), (b'\x1b[C', b'\x1b[D'), (b'\x1b[1;1C', b'\x1b[1;1D')):
            c.type(PREFIX + keys_lr[0])
            focused(right)
            c.type(PREFIX + keys_lr[1])
            focused(left)
        for key in (b'j', b'k', b'\x1b[A', b'\x1b[B', b'h'):  # edges keep focus
            c.type(PREFIX + key)
            focused(left)
        # A sticky group stays after a binding, with the popup down, until esc.
        cli('pane', 'send', f'--pane={left}', '--text', ''.join(f'scrolled-{i}\n' for i in range(120)))
        until(lambda: 'scrolled-119' in capture(left), 'history')
        c.shows('scrolled-119')
        c.type(PREFIX + b'[')
        c.shows('venomx › scroll')
        shows_row('j ↓', 'scroll-line-down')
        c.type(b'k')
        c.hides('venomx › scroll')
        c.shows(' -1 ')
        until(lambda: 'LEADER scroll' in top(), 'mode names the group')
        for key, want in ((b'k', ' -2 '), (b'\x1b[A', ' -3 '), (b'\x1b[B', ' -2 '), (b'j', ' -1 ')):
            c.type(key)
            c.shows(want)
        time.sleep(.4)
        assert 'venomx › scroll' not in c.screen()
        c.type(b'?')  # shows the popup again, and the group goes on
        c.shows('venomx › scroll')
        c.type(b'k')
        c.hides('venomx › scroll')
        c.shows(' -2 ')
        c.type(b'\x1b')
        until(lambda: 'LEADER' not in top(), 'esc ends the group')
        assert ' -2 ' in c.screen()  # what it scrolled stays scrolled
        c.type(PREFIX + b']')
        c.hides(' -2 ')
        # `?` opens the list of every key; typing filters it.
        c.type(PREFIX + b'?')
        c.shows('type to filter')
        c.shows('focus-left')
        c.type(b'resize')
        c.shows('resize › resize-left')
        c.hides('focus-left')
        c.type(b'\x1b')
        c.hides('resize › resize-left')
        print('ok key directions, shared rows and a sticky scroll group')

        # `r` resizes a split with pane.resize, for every client.
        def divider(client):
            return re.search('[│┃]', client.screen().split('\n')[3]).start()

        def ratio():
            return cli('window', 'get', '--window=w0')['nodes'][0].get('ratio')

        other = Client(['--session', 's0', '--socket', path], env)
        try:
            until(lambda: re.search('[│┃]', other.screen().split('\n')[3]), 'the second client draws the split')
            at = divider(c)
            assert divider(other) == at and ratio() is None
            c.type(PREFIX + b'r')
            c.shows('venomx › resize')
            shows_row('h ←', 'resize-left')
            c.type(b'l')
            c.hides('venomx › resize')
            until(lambda: divider(c) == at + 1, 'l moves the divider')
            until(lambda: divider(other) == at + 1, 'the other client follows')
            assert ratio() is not None
            until(lambda: 'LEADER resize' in top(), 'mode names the group')
            for key, want in ((b'l', 2), (b'\x1b[C', 3), (b'h', 2), (b'\x1b[D', 1)):
                c.type(key)
                until(lambda: divider(c) == at + want and divider(other) == at + want, f'{key!r} moves it to +{want}')
            # The panes' real size follows on the PTY.
            cols = cli('pane', 'capture', f'--pane={right}')['cols']
            until(lambda: cli('pane', 'capture', f'--pane={left}')['cols'] == at + 1, 'left PTY width')
            before = capture(right)
            c.type(b'\x1b')
            until(lambda: 'LEADER' not in top(), 'esc ends the group')
            c.type(b'l')  # now an ordinary key for the pane
            until(lambda: capture(left).rstrip().endswith('l'), 'l reaches the pane after esc')
            assert divider(c) == at + 1 and capture(right) == before and cols == COLS - at - 2, (cols, at)
            # The verb, from the CLI and MCP.
            moved = cli('pane', 'resize', f'--pane={left}', '--direction=left', '--cells=1')
            assert moved['moved'] == 1 and moved['window'] == 'w0', moved
            until(lambda: divider(c) == at and divider(other) == at, 'the CLI moves it back')
            assert ratio() is None
            assert cli('pane', 'resize', f'--pane={left}', '--direction=up', '--cells=1')['moved'] == 0
            assert cli('pane', 'resize', f'--pane={left}', '--direction=sideways', '--cells=1', code=2)['error']['code'].startswith('invalid_params')
            mcp = [
                {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2024-11-05', 'capabilities': {}, 'clientInfo': {'name': 't', 'version': '0'}}},
                {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
                {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'pane_dresize', 'arguments': {'pane': left, 'direction': 'right', 'cells': 2}}},
            ]
            r = subprocess.run([EXE, 'mcp', '--socket', path], input=''.join(json.dumps(m) + '\n' for m in mcp), env=owner, capture_output=True, text=True, timeout=TIMEOUT)
            assert r.returncode == 0, (r.returncode, r.stderr)
            replies = {m['id']: m for m in map(json.loads, r.stdout.splitlines())}
            assert 'pane_dresize' in {t['name'] for t in replies[2]['result']['tools']}
            assert not replies[3]['result'].get('isError'), replies[3]
            until(lambda: divider(c) == at + 2 and divider(other) == at + 2, 'MCP moves it')
            cli('pane', 'resize', f'--pane={left}', '--direction=left', '--cells=2')
            until(lambda: divider(c) == at, 'back to equal shares')
            print('ok sticky resize keys and pane.resize for every client, from CLI and MCP')
        finally:
            other.kill()

        # keys.prefixes moves a table, and keeps it there.
        cli('config', 'set', '--key=keys.prefixes', '--value=.{ .{ .name = "tools", .prefix = "e" } }')

        def prefix_of(name):
            return next(t for t in cli('keys', 'list')['tables'] if t['name'] == name).get('prefix')

        until(lambda: prefix_of('tools') == 'e', 'moved prefix')
        moved = cli('keys', 'register', '--name=tools', '--prefix=y', '--label=tools', '--bindings=[{"key":"u","label":"lock it","local":"lock"}]', '--bind=daemon')
        assert moved['prefix'] == 'e', moved
        assert prefix_of('tools') == 'e'
        time.sleep(.2)
        c.type(PREFIX + b'e')
        c.shows('venomx › tools')
        c.type(b'\x1b')
        c.hides('venomx › tools')
        c.type(PREFIX + b'y')
        until(lambda: 'LEADER' not in top(), 'the old prefix is unbound')
        print('ok key keys.prefixes moves a table and survives keys.register')
        # The other keys apply at once too, and the popup prints the leader
        # it has, with no delay when that is 0.
        cli('config', 'set', '--key=keys.leader', '--value="ctrl+a"')
        cli('config', 'set', '--key=keys.popup_delay_ms', '--value=0')
        until(lambda: cli('keys', 'list')['leader'] == 'ctrl+a', 'changed leader')
        time.sleep(.2)
        c.type(b'\x01')
        shows_row('ctrl+a', 'send-leader')
        c.type(b'\x1b')
        c.hides('send-leader')
        cli('config', 'set', '--key=keys.leader', '--value="ctrl+b"')
        cli('config', 'set', '--key=keys.popup_delay_ms', '--value=200')
        until(lambda: cli('keys', 'list')['leader'] == 'ctrl+b', 'default leader')
        time.sleep(.2)

        # Leader leader, from legacy and Kitty host input, into a legacy
        # and a Kitty pane. Lock mode's unlock key works in legacy input too.
        before = capture(left).count('^B')
        c.type(PREFIX + PREFIX)
        until(lambda: capture(left).count('^B') == before + 1, 'ctrl+b in a legacy pane')
        c.type(b'\x1b[98;5u\x1b[98;5u')
        until(lambda: capture(left).count('^B') == before + 2, 'kitty ctrl+b in a legacy pane')
        c.type(PREFIX + b'\t')
        focused(right)
        c.type(PREFIX + PREFIX)
        until(lambda: capture(right).count('[98;5u') == 1, 'ctrl+b in a Kitty pane')
        c.type(b'\x1b[98;5u\x1b[98;5u')
        until(lambda: capture(right).count('[98;5u') == 2, 'kitty ctrl+b in a Kitty pane')
        c.type(PREFIX + b'L')
        until(lambda: 'LOCK' in top(), 'lock mode')
        c.type(PREFIX)
        until(lambda: capture(right).count('[98;5u') == 3, 'locked leader reaches the pane')
        c.type(b'\x1b\x02')
        until(lambda: 'LOCK' not in top(), 'legacy ctrl+alt+b unlocks')
        print('ok key ctrl+b ctrl+b with and without the Kitty keyboard protocol')

        # A stalled client reads a popup's removal and the keys typed
        # after it in one turn. The sequence must use the pane focus returns to.
        ran = root / 'stalled-binding-ran'
        cli('pane', 'tag', f'--pane={right}', '--set=[{"key":"thread","value":"t130"}]')
        cli('keys', 'register', '--name=opener', '--prefix=q', '--bindings=' + json.dumps([{'key': 'p', 'verb': 'pane.popup', 'args': json.dumps({'argv': ['/bin/sh', '-c', 'echo STALLED-POPUP; exec cat']})}]), '--bind=daemon')
        cli('keys', 'register', '--name=scoped', '--prefix=a', '--when=[{"key":"thread","value":"t130"}]', '--bindings=' + json.dumps([{'key': 's', 'exec': ['touch', str(ran)]}]), '--bind=daemon')
        time.sleep(.3)  # the client refreshes its keys
        c.type(PREFIX + b'qp')
        c.shows('STALLED-POPUP', 'the popup')
        popup = next(p['pane'] for p in cli('pane', 'list')['panes'] if p['layer'] == 'popup')
        c.proc.send_signal(signal.SIGSTOP)
        until(lambda: Path(f'/proc/{c.proc.pid}/stat').read_text().rsplit(')', 1)[1].split()[0] == 'T', 'the client to stop')
        cli('pane', 'kill', f'--pane={popup}', '--remove=true')
        c.type(PREFIX + b'as')
        c.proc.send_signal(signal.SIGCONT)
        until(ran.exists, 'the binding of the pane focus returned to')
        until(lambda: 'LEADER' not in top(), 'leader mode to end')
        print('ok a stalled client runs a sequence typed after a popup closed')

        c.type(PREFIX + b'd')
        code, err = c.wait()
        assert code == 0, (code, err)
        c.close()
        c = None
    finally:
        if c is not None:
            c.kill()
        if d.poll() is None:
            d.send_signal(signal.SIGINT)
        out, err = d.communicate(timeout=10)
        assert d.returncode == 0, (d.returncode, out, err)

# `config set theme` then `config reload` changes the host
# colours (OSC 11) a program in a newly attached pane is told, and an unknown
# theme is rejected by `config check`.
with tempfile.TemporaryDirectory(prefix='vx-attach-theme-') as root:
    root = Path(root)
    path = str(root / 'd.sock')
    env = {k: v for k, v in os.environ.items() if not k.endswith('_TOKEN') and not k.startswith('VENOMX_')}
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / 'cfg'), XDG_CONFIG_DIRS=str(root / 'cfg' / 'xdg'), XDG_STATE_HOME=str(root / 'state'), PS1='$ ', ENV='', TERM='xterm-256color', SHELL='/bin/sh')
    owner = dict(env, VENOMX_TOKEN='@owner')

    def cli(*args, code=0):
        r = subprocess.run([EXE, *args, '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=owner, capture_output=True, text=True, timeout=TIMEOUT)
        assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
        return json.loads(r.stdout) if r.stdout.strip() else {}

    def probe(tag):
        """A pane that asks for the background (OSC 11) once `go-<tag>` exists."""
        # Background (OSC 11) and cursor (OSC 12): the cursor has no libghostty default to match by luck.
        script = (f'echo ready-{tag}; while [ ! -e {root}/go-{tag} ]; do sleep 0.05; done; stty raw -echo; '
                  f"printf '\\033]11;?\\033\\\\\\033]12;?\\033\\\\'; dd bs=1 count=50 2>/dev/null > {root}/answer-{tag}; sleep 30")
        return cli('window', 'create', '--session=s0', f'--argv={json.dumps(["/bin/sh", "-c", script])}')['pane']

    def answer(tag, client):
        client.shows(f'ready-{tag}', 'the client to be attached to the pane')
        (root / f'go-{tag}').touch()
        until(lambda: (root / f'answer-{tag}').exists() and (root / f'answer-{tag}').stat().st_size >= 50, f'the OSC 11/12 answers {tag}')
        return (root / f'answer-{tag}').read_text()

    d = subprocess.Popen([EXE, 'serve', '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    c = None
    try:
        until(lambda: Path(path).exists() or d.poll() is not None, 'daemon socket')
        assert d.poll() is None, d.communicate()
        cli('session', 'create', '--name', 'work')
        cli('config', 'set', '--key=theme', '--value=.bone')
        cli('config', 'reload')
        c = Client([f'--pane={probe("bone")}', '--socket', path], env)
        got = answer('bone', c)
        assert 'rgb:f3f3/f2f2/f2f2' in got and 'rgb:aeae/0202/0000' in got, got
        c.kill(); c.close(); c = None
        cli('config', 'set', '--key=theme', '--value=.trve')
        cli('config', 'reload')
        c = Client([f'--pane={probe("trve")}', '--socket', path], env)
        got = answer('trve', c)
        assert 'rgb:0000/0000/0000' in got and 'rgb:fcfc/3030/2e2e' in got, got
        # An unknown theme never becomes effective.
        r = subprocess.run([EXE, 'config', 'set', '--key=theme', '--value=.nope', '--socket', path], stdin=subprocess.DEVNULL, env=owner, capture_output=True, text=True, timeout=TIMEOUT)
        assert r.returncode != 0, (r.stdout, r.stderr)
        assert cli('config', 'get', '--key=theme')['content'] == '.trve'
        (root / 'cfg' / 'venomx').mkdir(parents=True, exist_ok=True)
        (root / 'cfg' / 'venomx' / 'config.zon').write_text('.{ .theme = .nope }\n')
        r = subprocess.run([EXE, 'config', 'check', '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=owner, capture_output=True, text=True, timeout=TIMEOUT)
        assert r.returncode != 0 or '"valid":false' in r.stdout.replace(' ', ''), (r.returncode, r.stdout, r.stderr)
        print('ok config set theme + reload changes the OSC 11 answer of a new attach; an unknown theme is rejected')
    finally:
        if c is not None:
            c.kill()
        if d.poll() is None:
            d.send_signal(signal.SIGINT)
        out, err = d.communicate(timeout=10)
        assert d.returncode == 0, (d.returncode, out, err)
