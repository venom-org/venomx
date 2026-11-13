#!/usr/bin/env python3
"""`venomx shell init` snippets in real zsh, bash and fish panes.

Each installed shell runs interactively in a venomx pane, loads its snippet
twice through the printed `eval` / `source` line, and runs a command. The
daemon must report the OSC 133 `cmdline` on `command.started` and the
real exit status on `command.finished`. Shells that are not installed are
skipped and named.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

EXE = str(Path(sys.argv[1]).resolve())
TIMEOUT = 10

SHELLS = {
    'zsh': (['zsh', '-f', '-i'], f'eval "$({EXE} shell init --shell=zsh)"'),
    'bash': (['bash', '--norc', '--noprofile', '-i'], f'eval "$({EXE} shell init --shell=bash)"'),
    'fish': (['fish', '--no-config', '-i'], f'{EXE} shell init --shell=fish | source'),
}


def until(fn, what='condition'):
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError(f'{what} did not become true')


with tempfile.TemporaryDirectory(prefix='vx-shell-') as root:
    root = Path(root)
    path = str(root / 'd.sock')
    env = {k: v for k, v in os.environ.items() if not k.endswith('_TOKEN') and not k.startswith('VENOMX_')}
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / 'cfg'), XDG_STATE_HOME=str(root / 'state'))
    owner = dict(env, VENOMX_TOKEN='@owner')

    def cli(*args):
        r = subprocess.run([EXE, *args, '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=owner, capture_output=True, text=True, timeout=TIMEOUT)
        assert r.returncode == 0, (args, r.returncode, r.stdout, r.stderr)
        return json.loads(r.stdout)

    def events(after=None):
        args = [EXE, 'events', '--follow=false', *([f'--after={after}'] if after else []), '--socket', path, '--json']
        r = subprocess.run(args, stdin=subprocess.DEVNULL, env=owner, capture_output=True, text=True, timeout=TIMEOUT)
        assert r.returncode == 0, (r.stdout, r.stderr)
        items = [json.loads(x) for x in r.stdout.splitlines()]
        return items if after is None else [e for e in items if e['type'] not in ('stream.checkpoint', 'state.snapshot')]

    # Without --json the command prints only the script; outside a pane it does nothing.
    plain = subprocess.run([EXE, 'shell', 'init', '--shell=bash'], env=env, capture_output=True, text=True, timeout=TIMEOUT)
    assert plain.returncode == 0 and plain.stdout.startswith('# venomx shell integration for bash'), plain
    outside = subprocess.run(['bash', '--norc', '-c', plain.stdout + '\necho "[${PS0-}]"'], env=env, capture_output=True, text=True, timeout=TIMEOUT)
    assert outside.stdout.strip() == '[]', outside
    assert json.loads(subprocess.run([EXE, 'shell', 'init', '--shell=fish', '--json'], env=env, capture_output=True, text=True, timeout=TIMEOUT).stdout)['shell'] == 'fish'

    d = subprocess.Popen([EXE, 'serve', '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        until(lambda: Path(path).exists() or d.poll() is not None, 'daemon socket')
        assert d.poll() is None, d.communicate()
        sid = cli('session', 'create')['session']
        ran = []
        for shell, (argv, load) in SHELLS.items():
            if shutil.which(argv[0]) is None:
                print(f'skip {shell}: not installed')
                continue
            argv = [shutil.which(argv[0]), *argv[1:]]
            created = cli('window', 'create', f'--session={sid}', f'--argv={json.dumps(argv)}')
            pane = created['pane']
            mark = events()[-1]  # the checkpoint names the current position
            after = f"{mark['source']}:{mark['seq']}"
            for _ in range(2):  # a second load adds no second set of marks
                cli('pane', 'send', f'--pane={pane}', f'--text={load}\n')
            cli('pane', 'send', f'--pane={pane}', '--text=echo "hi there"; false\n')

            def finished():
                evs = [e for e in events(after) if e['data'].get('pane') == pane]
                done = [e for e in evs if e['type'] == 'command.finished']
                return evs if any(e.get('data', {}).get('exit_code') == 1 for e in done) else None
            evs = until(finished, f'{shell}: command.finished with status 1')
            started = [e['data'].get('cmdline') for e in evs if e['type'] == 'command.started']
            assert started[-1] == 'echo "hi there"; false', (shell, started)
            assert started.count('echo "hi there"; false') == 1, (shell, started)
            if shell == 'bash':
                # A line history leaves out has no cmdline, never the previous one.
                mark = events()[-1]
                after = f"{mark['source']}:{mark['seq']}"
                cli('pane', 'send', f'--pane={pane}', '--text=HISTCONTROL=ignorespace\n')
                cli('pane', 'send', f'--pane={pane}', '--text= echo hidden; true\n')
                evs = until(lambda: [e for e in events(after) if e['type'] == 'command.finished' and e['data'].get('pane') == pane and e['data'].get('exit_code') == 0][1:] and events(after), 'bash: hidden command finished')
                last = [e['data'] for e in evs if e['type'] == 'command.started' and e['data'].get('pane') == pane][-1]
                assert 'cmdline' not in last, last
            cli('pane', 'kill', f'--pane={pane}', '--remove=true')
            ran.append(shell)
        assert ran, 'no shell to test'
        print(f'ok shell init snippets report cmdline and status in {", ".join(ran)}')
    finally:
        if d.poll() is None:
            d.send_signal(signal.SIGINT)
        d.communicate(timeout=10)
