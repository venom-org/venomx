#!/usr/bin/env python3
"""tmux shim: replays the subcommands Claude Code's agent teams use
(test/tmux_calls.json, recorded from Claude Code 2.1.319's TmuxBackend)
against the real daemon, as the lead pane's own principal, with the binary
symlinked as `tmux`. Also checks that everything else fails clearly and
leaves the daemon untouched.
"""
import json, os, shlex, subprocess, sys, tempfile, time
from pathlib import Path

EXE = str(Path(sys.argv[1]).resolve())
CALLS = json.loads((Path(__file__).parent / 'tmux_calls.json').read_text())
T = 15


def until(fn, what, timeout=T):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        v = fn()
        if v:
            return v
        time.sleep(.05)
    raise AssertionError(what)


with tempfile.TemporaryDirectory(prefix='vx-tmux-') as root:
    root = Path(root)
    (root / 'run').mkdir(mode=0o700)
    (root / 'bin').mkdir()
    os.symlink(EXE, root / 'bin' / 'tmux')
    env = {k: v for k, v in os.environ.items() if not k.startswith('VENOMX_') and not k.endswith('_TOKEN')}
    env.update(HOME=str(root), XDG_RUNTIME_DIR=str(root / 'run'), XDG_CONFIG_HOME=str(root / 'cfg'),
               XDG_CONFIG_DIRS=str(root / 'cfg' / 'xdg'), XDG_STATE_HOME=str(root / 'state'), SHELL='/bin/sh')
    owner = dict(env, VENOMX_TOKEN='@owner')
    sock = root / 'run' / 'venom' / 'venomx.sock'

    def cli(*a):
        r = subprocess.run([EXE, *a, '--json'], env=owner, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=T)
        assert r.returncode == 0, (a, r.stdout, r.stderr)
        return json.loads(r.stdout)

    d = subprocess.Popen([EXE, 'serve', '--json'], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        until(lambda: sock.exists() or d.poll() is not None, 'socket')
        cli('ping')
        cli('session', 'create', '--name=lead')
        grants = json.dumps([{'right': r, 'scope': '*'} for r in ('read', 'write', 'spawn')])
        lead = cli('window', 'create', '--session=s0', '--name=lead', '--argv=["/bin/sh"]', f'--grants={grants}')
        # The shim runs inside the lead pane's shell: its token is bound to that process tree.
        lp0 = lead['pane']
        pdir = root / 'io'
        pdir.mkdir()
        counter = [0]

        def inpane(cmd, prefix=''):
            counter[0] += 1
            n = pdir / str(counter[0])
            line = f'{prefix}{cmd} >{n}.out 2>{n}.err </dev/null; echo $? >{n}.tmp; mv {n}.tmp {n}.rc\n'
            cli('pane', 'send', f'--pane={lp0}', f'--text={line}')
            until(lambda: (pdir / f'{n.name}.rc').exists(), f'{cmd} finished')
            return int((pdir / f'{n.name}.rc').read_text()), (pdir / f'{n.name}.out').read_text(), (pdir / f'{n.name}.err').read_text()

        inpane(f'export PATH={root}/bin:$PATH')

        def tmux(*a, code=0, via='tmux', env=''):
            rc, out, err = inpane(' '.join(shlex.quote(x) for x in [*via.split(), *a]), env)
            assert rc == code, (a, rc, out, err)
            return out, err

        def panes():
            return {p['pane']: p for p in cli('pane', 'list')['panes']}

        def fill(call, **kv):
            return [x.format(**kv) if '{' in x and not x.startswith('#') else x for x in call]

        out, _ = tmux('-V'); assert out.startswith('tmux ')
        # --- external path: no $TMUX; a session of its own
        ext = CALLS['external']
        _, err = tmux(*ext[1], code=1); assert "can't find session" in err, err
        first = tmux(*ext[2])[0].strip(); assert first.startswith('%')
        tmux(*ext[3])
        assert tmux(*ext[4])[0].split() == [first]
        second = tmux(*fill(ext[5], FIRST=first))[0].strip()
        assert second != first
        sess = [s for s in cli('session', 'list')['sessions'] if s['name'] == 'claude-swarm']
        assert len(sess) == 1
        wins = cli('session', 'get', f'--session={sess[0]["session"]}')['windows']
        assert [w['name'] for w in wins] == ['swarm-view']
        _, err = tmux(*ext[2], code=1); assert 'duplicate session' in err
        # --- inside path: the lead pane's window
        ins = CALLS['inside']
        lp = '%' + lead['pane'][1:]
        lw = '@' + lead['window'][1:]
        assert tmux(*ins[0])[0].strip() == lp
        assert tmux(*fill(ins[1], PANE=lp))[0].strip() == lw
        assert tmux(*fill(ins[2], WINDOW=lw))[0].split() == [lp]
        t1 = tmux(*fill(ins[3], PANE=lp))[0].strip()
        assert tmux(*fill(ins[4], WINDOW=lw))[0].split() == [lp, t1]
        win = cli('window', 'get', f'--window={lead["window"]}')
        assert win['nodes'][0]['axis'] == 'cols'
        ratio = win['nodes'][0].get('ratio')
        assert ratio is not None and ratio < 5000, win  # the lead keeps about 30 percent
        t2 = tmux(*fill(ins[5], SECOND=t1))[0].strip()
        assert cli('window', 'get', f'--window={lead["window"]}')['nodes'][2]['axis'] == 'rows'
        # --- per teammate: title, respawn, drive, capture, close
        for new in (t1, t2):
            calls = [fill(c, NEW=new) for c in CALLS['per_teammate']]
            title, respawn, lit, enter, cap, caphist, kill = calls
            vid = 'p' + new[1:]
            tmux(*title)
            assert tmux('display-message', '-t', new, '-p', '#{pane_title}')[0].strip() == 'researcher'
            tmux(*respawn)
            until(lambda: 'teammate-ran' in cli('pane', 'capture', f'--pane={vid}')['text'], 'respawned command ran')
            _, err = tmux(*respawn, code=1); assert 'cannot replace' in err
            tmux(*lit); tmux(*enter)
            tmux('send-keys', '-t', new, 'C-c')
            screen = tmux(*cap)[0]
            assert 'teammate-ran' in screen and all(l == l.rstrip() for l in screen.split('\n'))
            assert 'teammate-ran' in tmux(*caphist)[0]
            tmux(*kill)
            until(lambda: vid not in panes(), 'pane closed')
            tmux(*kill, code=1)
        assert tmux('list-panes', '-t', lw, '-F', '#{pane_id}')[0].split() == [lp]
        # the swarm session goes away with its last pane, as in tmux
        for pid in tmux('list-panes', '-t', 'claude-swarm:swarm-view', '-F', '#{pane_id}')[0].split():
            tmux('kill-pane', '-t', pid)
        until(lambda: not [s for s in cli('session', 'list')['sessions'] if s['name'] == 'claude-swarm'], 'swarm session gone')
        tmux('-L', 'x', 'has-session', '-t', 'claude-swarm', code=1)
        # --- no command: a login shell that actually starts, in new-session and split-window
        nc = tmux('new-session', '-d', '-s', 'nocmd', '-P', '-F', '#{pane_id}')[0].strip()
        ns = tmux('split-window', '-d', '-t', nc, '-P', '-F', '#{pane_id}')[0].strip()
        for pid in (nc, ns):
            tmux('send-keys', '-t', pid, '-l', 'echo shell-up-$((1+1))')
            tmux('send-keys', '-t', pid, 'Enter')
            until(lambda: 'shell-up-2' in tmux('capture-pane', '-p', '-t', pid)[0].replace('echo shell-up-$((1+1))', ''), 'login shell ran')
            assert not cli('pane', 'list')['panes'][[p['pane'] for p in cli('pane', 'list')['panes']].index('p' + pid[1:])]['exited']
        # a bad -F creates nothing
        n0 = len(cli('pane', 'list')['panes'])
        tmux('split-window', '-t', nc, '-P', '-F', '#{nope}', code=1)
        tmux('new-session', '-d', '-s', 'badfmt', '-P', '-F', '#{nope}', code=1)
        assert len(cli('pane', 'list')['panes']) == n0
        assert not [x for x in cli('session', 'list')['sessions'] if x['name'] == 'badfmt']
        tmux('capture-pane', '-p', '-S', '-9223372036854775808', '-t', nc, code=1)
        for pid in (nc, ns):
            tmux('kill-pane', '-t', pid)
        # two concurrent respawns of one parked pane: exactly one wins
        cp = tmux('new-session', '-d', '-s', 'race', '-P', '-F', '#{pane_id}', '--', 'cat')[0].strip()
        rc = pdir / 'race'
        cmd = (f'(tmux respawn-pane -k -t {cp} -- "echo raced; sleep 20" 2>/dev/null; echo $? >{rc}1) & '
               f'(tmux respawn-pane -k -t {cp} -- "echo raced; sleep 20" 2>/dev/null; echo $? >{rc}2) & wait')
        inpane(cmd)
        codes = sorted(int((pdir / f'race{i}').read_text()) for i in (1, 2))
        assert codes == [0, 1], codes
        tmux('kill-pane', '-t', cp)
        # --- everything else fails clearly and changes nothing
        # The sampled foreground follows the panes' own jobs, not these calls.
        def topology():
            panes = [{k: v for k, v in x.items() if k not in ('process', 'title_current')} for x in cli('pane', 'list')['panes']]
            return json.dumps(panes) + json.dumps(cli('window', 'get', f'--window={lead["window"]}'))
        before = topology()
        for call in CALLS['rejected']:
            _, err = tmux(*fill(call, PANE=lp, WINDOW=lw), code=1)
            assert err.startswith('venomx tmux: ') or 'venomx tmux' in err, (call, err)
        assert before == topology()
        # `venomx tmux ...` is the same shim; a principal without rights is refused by the daemon
        out, _ = tmux('display-message', '-p', '#{pane_id}', via=f'{EXE} tmux')
        assert out.strip() == lp, out
        ro = cli('grant', 'issue', '--grants=[{"right":"read","scope":"*"}]')
        _, err = tmux('kill-pane', '-t', lp, code=1, env=f'VENOMX_TOKEN={ro["token"]} ')
        assert 'denied' in err, err
        assert lead['pane'] in panes()
        print('ok tmux shim replay', flush=True)
    finally:
        d.terminate()
        try:
            d.wait(timeout=T)
        except subprocess.TimeoutExpired:
            d.kill()
