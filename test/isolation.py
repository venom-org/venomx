#!/usr/bin/env python3
"""grants.isolation, venomx's default (off), and turning it on.

With isolation off (the default) the user's own processes drive the daemon
with nothing set, like tmux: from a shell outside venomx with no token, and
from a pane with the token venomx gave it. `respond`, `files` and `admin`
stay the owner's, and `venomx.*` stays reserved. Turning
isolation on brings back the read-only default.

Only an isolating venomx marks itself as a process manager next to its
socket: with isolation off, other venom daemons treat its panes as the
user's terminal. Its own owner token stays refused inside its panes.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

EXE = str(Path(sys.argv[1]).resolve())
TIMEOUT = 10


def until(fn, timeout=TIMEOUT):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('condition did not become true')


with tempfile.TemporaryDirectory(prefix='vx-iso-') as root:
    root = Path(root)
    path = str(root / 'd.sock')
    env = {k: v for k, v in os.environ.items() if not (k.endswith('_TOKEN') or k.endswith('_PRINCIPAL') or k.startswith('VENOMX_'))}
    env.update(HOME=str(root), XDG_CONFIG_HOME=str(root / 'cfg'), XDG_CONFIG_DIRS=str(root / 'cfg' / 'xdg'), XDG_STATE_HOME=str(root / 'state'))
    owner = dict(env, VENOMX_TOKEN='@owner')

    def run(args, environ):
        return subprocess.run([EXE, *args, '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=environ, capture_output=True, text=True, timeout=TIMEOUT)

    def cli(*args, code=0, environ=None):
        r = run(args, environ or env)
        assert r.returncode == code, (args, r.returncode, r.stdout, r.stderr)
        return json.loads(r.stdout) if r.stdout.strip() else {}

    def err(*args, code=4, environ=None):
        return cli(*args, code=code, environ=environ)['error']['code']

    d = subprocess.Popen([EXE, 'serve', '--socket', path, '--json'], stdin=subprocess.DEVNULL, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        until(lambda: Path(path).exists() or d.poll() is not None)
        assert d.poll() is None, d.communicate()

        def marked():
            return bool(list(root.glob(f'manager-{d.pid}-*')))

        def marker_check():
            return [c for c in cli('doctor')['checks'] if c['id'] == 'grants.manager_marker'][0]

        # Isolation off: no manager marker.
        assert not marked(), list(root.iterdir())
        assert 'not marked' in marker_check()['message'], marker_check()

        # Outside venomx, no token: the user's script just works.
        who = cli('whoami')
        assert who['principal'] == 'unknown' and {'right': 'write', 'scope': '*'} in who['grants'], who
        s0 = cli('session', 'create', '--name=main')['session']
        shell = cli('window', 'create', f'--session={s0}', '--argv=["/bin/sh"]')
        cli('notify', 'post', '--text=deploy done')
        assert any(n['text'] == 'deploy done' for n in cli('notify', 'list')['notifications'])
        # With ttl_ms, bind defaults to daemon: the segment outlives the call.
        cli('status', 'set', '--id=user.build', '--text=build ok', '--style=ok', '--ttl-ms=60000')
        seg = [s for s in cli('status', 'list')['segments'] if s['id'] == 'user.build']
        assert seg and seg[0]['bind'] == 'daemon', seg
        # Without ttl_ms it still ends with the connection.
        cli('status', 'set', '--id=user.flash', '--text=x')
        assert not [s for s in cli('status', 'list')['segments'] if s['id'] == 'user.flash']
        cli('pane', 'send', f'--pane={shell["pane"]}', '--text=echo HELLO-FROM-SCRIPT\r')
        until(lambda: 'HELLO-FROM-SCRIPT' in cli('pane', 'capture', f'--pane={shell["pane"]}')['text'])
        # Namespaces are names only, but venomx.* stays reserved.
        cli('status', 'set', '--id=venom.other', '--text=x', '--ttl-ms=60000')
        assert err('status', 'set', '--id=venomx.session', '--text=x', '--ttl-ms=60000') == 'denied.namespace'
        # The owner's rights stay the owner's.
        assert err('config', 'set', '--key=grants.isolation', '--value=true').startswith('denied.')
        assert err('grant', 'issue', '--grants=[{"right":"respond","scope":"*"}]') == 'denied.delegation'

        # In a pane the owner made: its own token, the same rights.
        script = ('import json,subprocess,sys\n'
                  f'S={path!r}\n'
                  'def r(*a):\n'
                  f'    p=subprocess.run([{EXE!r},*a,"--socket",S,"--json"],capture_output=True,text=True)\n'
                  '    return p.returncode\n'
                  f'codes=[r("notify","post","--text=from pane"),r("pane","send","--pane={shell["pane"]}","--text=echo PANE-WROTE\\r"),'
                  'r("status","set","--id=venom.pane","--text=x","--ttl-ms=60000"),r("status","set","--id=venomx.x","--text=x","--ttl-ms=60000"),'
                  'r("config","set","--key=grants.isolation","--value=true")]\n'
                  'print("CODES:"+json.dumps(codes,separators=(",",":")),flush=True)\n')
        pane = cli('window', 'create', f'--session={s0}', f'--argv={json.dumps([sys.executable, "-c", script])}', environ=owner)['pane']
        text = until(lambda: (v['text'] if 'CODES:' in (v := cli('pane', 'capture', f'--pane={pane}'))['text'] else None))
        codes = json.loads(text.split('CODES:')[1].split()[0])
        assert codes == [0, 0, 0, 4, 4], codes
        until(lambda: 'PANE-WROTE' in cli('pane', 'capture', f'--pane={shell["pane"]}')['text'])
        # venomx's own owner token stays refused in its panes.
        probe = (f'VENOMX_TOKEN=@owner {EXE} whoami --socket {path} --json; echo OWNER-RC=$?')
        refused = cli('window', 'create', f'--session={s0}', f'--argv={json.dumps(["/bin/sh", "-c", probe + "; sleep 30"])}')['pane']
        text = until(lambda: (v['text'] if 'OWNER-RC=' in (v := cli('pane', 'capture', f'--pane={refused}'))['text'] else None))
        assert 'OWNER-RC=4' in text and 'owner_context' in text, text

        # Turning isolation on: unknown is read-only again, the segment stays.
        cli('config', 'set', '--key=grants.isolation', '--value=true', environ=owner)
        cli('config', 'reload', environ=owner)
        until(marked)
        assert 'marked as a process manager' in marker_check()['message'] and 'not marked' not in marker_check()['message'], marker_check()
        assert err('notify', 'post', '--text=again').startswith('denied.')
        assert err('status', 'set', '--id=user.build', '--text=x', '--ttl-ms=60000').startswith('denied.')
        assert any(s['id'] == 'user.build' for s in cli('status', 'list')['segments'])
        assert cli('whoami')['grants'] == [{'right': 'read', 'scope': '*'}]
        # And off again: the default comes back on reload.
        cli('config', 'set', '--key=grants.isolation', '--value=false', environ=owner)
        cli('config', 'reload', environ=owner)
        until(lambda: not marked())
        cli('notify', 'post', '--text=open again')
    finally:
        d.terminate()
        d.communicate(timeout=TIMEOUT)
print('isolation: ok')
