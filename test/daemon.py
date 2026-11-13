#!/usr/bin/env python3
"""Headless daemon acceptance over real CLI, MCP, NDJSON and binary sockets."""
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
TIMEOUT = 8

def until(fn):
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError('condition did not become true')

class Wire:
    def __init__(self, path, token=None, binary=False, maximum=1048576):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(TIMEOUT)
        self.sock.connect(path)
        self.io = self.sock.makefile('rwb', buffering=0)
        self.binary = binary
        params = {'proto':[1], 'caps':['cancel','venomx.pane_stream'], 'max_frame':maximum}
        if token:
            params['auth'] = {'token':token}
        if binary:
            self.io.write(b'\xf5')
            self.frame(1,0,params)
            assert self.recv()[0] == 2
        else:
            self.send({'id':0,'verb':'hello','params':params})
            assert 'ok' in self.read()
    def send(self, value):
        self.io.write(json.dumps(value,separators=(',',':')).encode()+b'\n')
    def read(self):
        return json.loads(self.io.readline())
    def call(self, verb, params=None):
        self.send({'id':1,'verb':verb,'params':params or {}})
        return self.read()
    def frame(self, kind, stream, payload):
        if not isinstance(payload,bytes):
            payload=json.dumps(payload,separators=(',',':')).encode()
        self.io.write(struct.pack('>HII',kind,stream,len(payload))+payload)
    def exact(self, n):
        result=b''
        while len(result)<n:
            chunk=self.io.read(n-len(result))
            assert chunk, 'binary connection closed'
            result+=chunk
        return result
    def recv(self):
        kind, stream, n=struct.unpack('>HII',self.exact(10))
        return kind,stream,self.exact(n)
    def attach(self, pane, stream=1):
        self.frame(0x100,stream,{'pane':pane,'mode':'raw','formats':['vt'],'size':{'cols':80,'rows':24},'history':0})
        prefix=b''
        while True:
            kind, number, data=self.recv()
            assert number == stream
            assert kind != 3, data
            if kind==0x101:
                attached=json.loads(data)
            elif kind==0x102:
                prefix+=data[12:]
            elif kind==0x103:
                return attached,prefix
    def close(self):
        self.io.close(); self.sock.close()

with tempfile.TemporaryDirectory(prefix='vx-test-') as root:
    root=Path(root); path=str(root/'d.sock')
    env={k:v for k,v in os.environ.items() if not k.endswith('_TOKEN')}
    env.update(HOME=str(root),XDG_CONFIG_HOME=str(root/'cfg'), XDG_CONFIG_DIRS=str(root/'cfg' / 'xdg'),XDG_STATE_HOME=str(root/'state'),BORROWED_TOKEN='must-not-leak')
    # These cases test grants and namespaces, so isolation is on.
    (Path(root) / 'cfg' / 'xdg' / 'venomx').mkdir(parents=True, exist_ok=True); (Path(root) / 'cfg' / 'xdg' / 'venomx' / 'defaults.zon').write_text('.{ .grants = .{ .isolation = true } }\n')
    owner=dict(env,VENOMX_TOKEN='@owner')
    def cli(*args, code=0, authority=True):
        r=subprocess.run([EXE,*args,'--socket',path,'--json'],stdin=subprocess.DEVNULL,env=owner if authority else env,capture_output=True,text=True,timeout=TIMEOUT)
        assert r.returncode==code,(args,r.returncode,r.stdout,r.stderr)
        assert not r.stderr,r.stderr
        return json.loads(r.stdout)
    def events(**options):
        args=['events','--follow=false']+[f'--{k}={json.dumps(v) if isinstance(v,list) else v}' for k,v in options.items()]
        r=subprocess.run([EXE,*args,'--socket',path,'--json'],stdin=subprocess.DEVNULL,env=env,capture_output=True,text=True,timeout=TIMEOUT)
        assert r.returncode==0,(r.stdout,r.stderr)
        return [json.loads(line) for line in r.stdout.splitlines()]
    def start():
        d=subprocess.Popen([EXE,'serve','--socket',path,'--json'],stdin=subprocess.DEVNULL,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        until(lambda: Path(path).exists() or d.poll() is not None)
        assert d.poll() is None,d.communicate()
        cli('ping'); return d
    d=start()
    clients=[]
    try:
        token=(root/'d.owner').read_text().strip()
        source=events()[-1]['source']
        # Two independent ordinary clients share one daemon and resource tree.
        one=Wire(path,token); two=Wire(path); clients += [one,two]
        assert one.call('session.create',{'name':'work'})['ok']=={'session':'s0','name':'work'}
        assert two.call('session.get',{'session':'s0'})['ok']['windows']==[]
        assert cli('session','create','--name=bad\nname',code=2)['error']['code']=='invalid_params.name'
        assert cli('pane','send','--pane=absent','--text=x',authority=False,code=4)['error']['code']=='denied.write'
        assert cli('window','get','--window=absent',code=3)['error']['code']=='not_found.window'
        checkpoint=events()[-1]; cursor=f"{checkpoint['source']}:{checkpoint['seq']}"
        # Failed exec consumes IDs but cannot publish a pane/window or event.
        before_principals=cli('grant','list')['principals']
        assert cli('window','create','--session=s0','--argv=["/no/such/executable"]',code=6)['error']['code']=='unavailable.spawn'
        assert cli('session','get','--session=s0')['windows']==[]
        assert cli('pane','list')['panes']==[]
        assert cli('grant','list')['principals']==before_principals
        assert [e['type'] for e in events(after=cursor)]==['stream.checkpoint']
        assert cli('window','create','--session=s0','--argv=[]',code=2)['error']['code']=='invalid_params.argv'
        assert cli('window','create','--session=s0','--argv=["/bin/sh"]','--rows=0',code=2)['error']['code']=='invalid_params.size'
        # Main shell stays alive and continues collecting output with no clients.
        live=Wire(path); clients.append(live)
        live.send({'id':17,'verb':'events','params':{'types':['window.*']}})
        snapshot=live.read()['item']
        assert snapshot['type']=='state.snapshot' and snapshot['data']['entities']==[]
        assert live.read()['item']['type']=='stream.checkpoint'
        created=cli('window','create','--session=s0','--argv=["/bin/sh"]')
        announced=live.read()['item']
        assert announced['type']=='window.created' and announced['data']['window']==created['window']
        current=[e for item in events(types=['window.*']) if item['type']=='state.snapshot' for e in item['data']['entities']]
        assert len(current)==1 and json.loads(current[0]['content'])==announced['data']
        pane=created['pane']; window=created['window']; pid=created['pid']
        # The delegation step precedes argv syntax, so the
        # rejected empty argv above consumed p1.
        assert pane=='p2' and window=='w1'
        script_file=root/'not-a-script'
        script_file.write_text("echo must-not-run\n")
        script_file.chmod(0o700)
        assert cli('pane','split',f'--pane={pane}','--axis=cols',f'--argv={json.dumps([str(script_file)])}',code=6)['error']['code']=='unavailable.spawn'
        assert cli('pane','remove',f'--pane={pane}',code=5)['error']['code']=='conflict.pane_running'
        assert cli('window','remove',f'--window={window}',code=5)['error']['code']=='conflict.not_empty'
        assert cli('session','remove','--session=s0',code=5)['error']['code']=='conflict.not_empty'
        binary=Wire(path,token,binary=True); watcher=Wire(path,binary=True); clients += [binary,watcher]
        attached,_=binary.attach(pane); watch,_=watcher.attach(pane)
        assert attached['input'] and not watch['input'] and attached['source']==source
        # CONTROL uses the same socket as pane bytes.
        binary.frame(0x10,0,{'id':91,'verb':'session.get','params':{'session':'s0'}})
        while True:
            kind,_,payload=binary.recv()
            if kind==0x10:
                assert json.loads(payload)['ok']['session']=='s0'; break
        binary.frame(0x106,1,b"printf 'FROM-BINARY\\n'\n")
        until(lambda:'FROM-BINARY' in cli('pane','capture',f'--pane={pane}')['text'])
        for c in clients: c.close()
        clients=[]
        cli('pane','send',f'--pane={pane}',"--text=sleep .1; printf 'DETACHED-OUTPUT\\n'\n")
        capture=until(lambda:(v if 'DETACHED-OUTPUT' in v['text'] else None) if (v:=cli('pane','capture',f'--pane={pane}')) else None)
        assert not capture['exited']
        assert os.path.exists(f'/proc/{pid}')
        reattached=Wire(path,binary=True); clients.append(reattached)
        _,prefix=reattached.attach(pane)
        assert b'DETACHED-OUTPUT' in prefix
        cli('pane','send',f'--pane={pane}',"--text=printf '\\033]2;shared title\\007'\n")
        until(lambda:cli('pane','list')['panes'][0]['title']=='shared title')
        # The sampled foreground process, its event and
        # title_current; OSC 133 C's cmdline.
        def fg(): return next(x for x in cli('pane','list')['panes'] if x['pane']==pane)
        assert fg()['process']=='sh' and fg()['title_current'] is True, fg()
        mark=events()[-1]; after=f"{mark['source']}:{mark['seq']}"
        cli('pane','send',f'--pane={pane}',"--text=sleep 1.5\n")  # silent: only the timer sees it
        until(lambda:fg().get('process')=='sleep')
        assert fg()['title_current'] is False
        until(lambda:fg().get('process')=='sh')
        cli('pane','send',f'--pane={pane}',"""--text=python3 -c 'import sys,time; sys.stdout.write("\\033]2;PY\\007"); sys.stdout.flush(); time.sleep(1.5)'\n""")
        until(lambda:(v:=fg()).get('process')=='python3' and v['title']=='PY')
        assert fg()['title_current'] is True, fg()
        until(lambda:fg().get('process')=='sh')
        assert fg()['title_current'] is False
        mine=[e for e in events(after=after) if e['data'].get('pane')==pane and e['type'] in ('pane.process_changed','pane.title_changed')]
        seen=[(e['type'][5:],e['data'].get('process',e['data'].get('title'))) for e in mine]
        assert seen==[('process_changed','sleep'),('process_changed','sh'),('process_changed','python3'),('title_changed','PY'),('process_changed','sh')], seen
        cli('pane','send',f'--pane={pane}',"--text=printf '\\033]133;C;cmdline_url=ping%%20x%%1b\\007'; printf '\\033]133;D;0\\007'\n")
        started=until(lambda:[e for e in events(after=after) if e['type']=='command.started' and e['data']['pane']==pane])
        assert started[-1]['data']['cmdline']=='ping x�', started[-1]
        # A small negotiated frame must reject full capture without truncation.
        small=Wire(path,maximum=4096); clients.append(small)
        large=cli('pane','split',f'--pane={pane}','--axis=cols','--cols=200','--rows=30','--argv=["/bin/sh","-c","exit 0"]')['pane']
        until(lambda:cli('pane','capture',f'--pane={large}')['exited'])
        assert small.call('pane.capture',{'pane':large})['error']['code']=='unsupported.result_size'
        cli('pane','remove',f'--pane={large}')
        # Nested split topology and exited-only removal, including exit 127.
        p2=cli('pane','split',f'--pane={pane}','--axis=cols','--argv=["/bin/sh","-c","printf \'exit-127\'; exit 127"]')['pane']
        p3=cli('pane','split',f'--pane={pane}','--axis=rows','--argv=["/bin/sh","-c","kill -TERM $$"]')['pane']
        def exited(p):
            value=cli('pane','capture',f'--pane={p}')
            return value if value['exited'] else None
        def attention(p):
            return next(x['attention'] for x in cli('pane','list')['panes'] if x['pane']==p)
        assert until(lambda:exited(p2))['exit_code']==127
        signaled=until(lambda:exited(p3)); assert signaled['signal']=='SIGTERM' and 'exit_code' not in signaled,signaled
        nodes=cli('window','get',f'--window={window}')['nodes']
        assert nodes[0]['axis']=='cols' and nodes[1]['axis']=='rows' and len(nodes)==5,nodes
        cli('pane','remove',f'--pane={p3}'); cli('pane','remove',f'--pane={p2}')
        assert cli('window','get',f'--window={window}')['nodes']==[{'kind':'pane','pane':pane}]
        # Pane-scoped discovery does not require read on the parent session.
        issued=cli('grant','issue',f'--grants={json.dumps([{"right":"read","scope":"pane:"+pane}])}')
        scoped=Wire(path,issued['token']); clients.append(scoped)
        assert scoped.call('session.list')['ok']=={'sessions':[]}
        assert len(scoped.call('pane.list')['ok']['panes'])==1
        assert scoped.call('pane.list',{'session':'s0'})['error']['code']=='denied.read'
        assert scoped.call('window.get',{'window':window})['error']['code']=='denied.read'
        revoked=Wire(path,issued['token'],binary=True); clients.append(revoked); revoked.attach(pane)
        cli('grant','revoke',f"--principal={issued['principal']}")
        while True:
            kind,_,data=revoked.recv()
            if kind==3:
                assert json.loads(data)['code']=='denied.read';break
        # Wildcard window grants expose topology, never terminal contents.
        issued=cli('grant','issue','--grants=[{"right":"read","scope":"window:*"}]')
        only_windows=Wire(path,issued['token']); clients.append(only_windows)
        assert 'ok' in only_windows.call('window.get',{'window':window})
        assert only_windows.call('pane.capture',{'pane':pane})['error']['code']=='denied.read'
        # Child environment strips inherited credentials and binds before exec.
        script='import os,json,subprocess; e=os.environ; r=subprocess.run(['+repr(EXE)+',"whoami","--json"],capture_output=True,text=True); print("IDENTITY:"+r.stdout.strip(),flush=True); print("SANITIZED:"+str("BORROWED_TOKEN" not in e and e["VENOMX_TOKEN"].startswith("vnt1.venomx.g")),flush=True)'
        child=cli('pane','split',f'--pane={pane}','--axis=cols','--cols=240',f'--argv={json.dumps([sys.executable,"-c",script])}')
        state=until(lambda:exited(child['pane']))
        assert 'SANITIZED:True' in state['text'],state
        assert f'"principal":"{child["principal"]}"' in state['text'] and '"kind":"pane"' in state['text'],state
        cli('pane','remove',f'--pane={child["pane"]}')
        # OSC status/command events are ordered before authoritative pane exit.
        osc="\x1b]7501;state=blocked:kind=permission:app=build:msg=QXBwcm92ZT8=\x07\x1b]133;C\x07"
        program='import os; os.write(1,'+repr(osc.encode())+')'
        marker=events()[-1]; cursor=f"{marker['source']}:{marker['seq']}"
        observed=cli('pane','split',f'--pane={pane}','--axis=rows',f'--argv={json.dumps([sys.executable,"-c",program])}')['pane']
        until(lambda:exited(observed))
        observed_events=[e for e in events(after=cursor) if e['data'].get('pane')==observed]
        kinds=[e['type'] for e in observed_events]
        assert kinds.index('command.finished') < kinds.index('pane.exited'),kinds
        statuses=[e['data'] for e in observed_events if e['type']=='program.status_changed']
        assert statuses[0]['records'][0]['msg']=='Approve?' and statuses[-1]['reason']=='process_exit' and statuses[-1]['records']==[],statuses
        # The blocked report above raised info attention.
        assert attention(observed)=='info'
        cli('pane','remove',f'--pane={observed}')
        # A BEL from the program sets info attention, a BEL that
        # ends an OSC title does not, and attention.from_bell=false turns it off.
        def ring(text):
            program='import os,time; os.write(1,'+repr(text.encode())+'); time.sleep(30)'
            return cli('pane','split',f'--pane={pane}','--axis=rows',f'--argv={json.dumps([sys.executable,"-c",program])}')['pane']
        title=ring('\x1b]0;quiet\x07READY')
        until(lambda:'READY' in cli('pane','capture',f'--pane={title}')['text'])
        assert attention(title)=='none'
        marker=events()[-1]; cursor=f"{marker['source']}:{marker['seq']}"
        rung=ring('\x07')
        until(lambda:attention(rung)=='info')
        bell=[e['data'] for e in events(after=cursor) if e['type']=='pane.attention_changed' and e['data']['pane']==rung]
        assert bell==[{'pane':rung,'level':'info','reason':'bell','revision':1}],bell
        cli('config','set','--key=attention.from_bell','--value=false'); cli('config','reload')
        muted=ring('\x07MUTED')
        until(lambda:'MUTED' in cli('pane','capture',f'--pane={muted}')['text'])
        time.sleep(.2)
        assert attention(muted)=='none'
        cli('config','set','--key=attention.from_bell','--value=true'); cli('config','reload')
        for p in (title,rung,muted): cli('pane','kill',f'--pane={p}','--remove=true')
        cli('pane','send',f'--pane={pane}',"--text=exit\n"); until(lambda:exited(pane))
        cli('pane','remove',f'--pane={pane}')
        assert cli('window','get',f'--window={window}')['nodes']==[]
        cli('window','remove',f'--window={window}'); cli('session','remove','--session=s0')
        assert cli('session','list')=={'sessions':[]}
        # Empty container snapshots persist; numeric ID ordering exceeds 9.
        for n in range(12): cli('session','create')
        assert [s['session'] for s in cli('session','list')['sessions']]==[f's{n}' for n in range(1,13)]
        entities=[e for item in events(types=['session.*']) if item['type']=='state.snapshot' for e in item['data']['entities']]
        assert len(entities)==12
        # An unbounded producer cannot starve the reactor. Other
        # clients' ping/capture/send, a pane stream and kill keep answering.
        flood=cli('window','create','--session=s1','--argv=["/bin/sh","-c","yes FLOOD"]')
        other=cli('pane','split',f'--pane={flood["pane"]}','--axis=cols','--argv=["/bin/sh"]')
        until(lambda:'FLOOD' in cli('pane','capture',f'--pane={flood["pane"]}')['text'])
        time.sleep(.3)
        def quick(fn,limit=1.5):
            started=time.monotonic(); value=fn(); took=time.monotonic()-started
            assert took<limit,(took,value); return value
        for _ in range(3): quick(lambda:cli('ping'))
        prompt=Wire(path,token); clients.append(prompt)
        for n in range(5): assert 'ok' in quick(lambda:prompt.call('ping'),.5)
        quick(lambda:cli('pane','send',f'--pane={other["pane"]}','--text=echo SIDE-$((6*7))\n'))
        until(lambda:'SIDE-42' in quick(lambda:cli('pane','capture',f'--pane={other["pane"]}'))['text'])
        assert 'FLOOD' in quick(lambda:cli('pane','capture',f'--pane={flood["pane"]}'))['text']
        viewer=Wire(path,token,binary=True); clients.append(viewer)
        quick(lambda:viewer.attach(flood['pane']))
        assert quick(lambda:cli('pane','kill',f'--pane={flood["pane"]}','--remove=true'),2)['removed'] is True
        assert not Path(f'/proc/{flood["pid"]}').exists() or 'zombie' in Path(f'/proc/{flood["pid"]}/status').read_text().lower()
        quick(lambda:cli('pane','send',f'--pane={other["pane"]}','--text=exit\n')); until(lambda:exited(other['pane']))
        cli('pane','remove',f'--pane={other["pane"]}')
        viewer.close(); prompt.close(); clients.remove(viewer); clients.remove(prompt)
        # Bound shutdown despite a connected client that never reads.
        slow=Wire(path,binary=True); clients.append(slow)
        stubborn=cli('window','create','--session=s1', '--argv=["/bin/sh","-c","trap \'\' HUP; echo ready; while :; do sleep 1; done"]')
        until(lambda:'ready' in cli('pane','capture',f'--pane={stubborn["pane"]}')['text'])
        started=time.monotonic(); d.send_signal(signal.SIGINT); out,err=d.communicate(timeout=5)
        assert d.returncode==0 and out=='{}\n' and not err,(d.returncode,out,err)
        assert time.monotonic()-started<3.5
        assert not Path(path).exists() and not (root/'d.owner').exists()
        assert not Path(f'/proc/{stubborn["pid"]}').exists()
        for c in clients: c.close()
        clients=[]
        d=start()
        assert events()[-1]['source']!=source
        assert cli('session','list')=={'sessions':[]}
        print('ok headless daemon: real socket, topology, grants, rollback, detach, OSC and shutdown')
    finally:
        for c in clients: c.close()
        if d.poll() is None: d.terminate()
        out,err=d.communicate(timeout=5)
        assert d.returncode==0 and out=='{}\n',(d.returncode,out,err)
