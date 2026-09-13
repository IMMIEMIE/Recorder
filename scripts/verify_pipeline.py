"""Paced PCM socket integration check using the actual bundled runtime and model."""
import argparse
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from core import Config, encode_message, read_message
from dataclasses import asdict
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly
from math import gcd
p=argparse.ArgumentParser(); p.add_argument('--model',required=True); p.add_argument('--runtime',default='.venv/bin/python'); p.add_argument('--server'); p.add_argument('--output',default='docs/pipeline-verification.json'); a=p.parse_args()
root=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='recorder-check-',dir='/tmp') as temp:
    path=str(Path(temp)/'s.sock')
    env={**os.environ,'HF_HUB_OFFLINE':'1','TRANSFORMERS_OFFLINE':'1','TOKENIZERS_PARALLELISM':'false','PYTHONDONTWRITEBYTECODE':'1','NUMBA_CACHE_DIR':str(Path(temp)/'numba')}
    proc=subprocess.Popen([a.runtime,a.server or str(root/'backend/server.py'),'--socket',path,'--root',temp],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    sock=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
    try:
        for _ in range(200):
            try: sock.connect(path); break
            except OSError: time.sleep(.05)
        events=[]; lock=threading.Condition(); started=time.monotonic()
        def receive():
            try:
                while True:
                    event=json.loads(read_message(sock)[1]); event['received_at']=time.monotonic()-started
                    with lock: events.append(event); lock.notify_all()
            except (EOFError,OSError): pass
        threading.Thread(target=receive,daemon=True).start()
        def command(name,**kw):
            value={'command':name,'protocol_version':1,'session_id':'pipeline','request_id':name,**kw}
            sock.sendall(encode_message(b'J',json.dumps(value).encode()))
        def wait_for(predicate,timeout=60):
            with lock:
                assert lock.wait_for(lambda:any(predicate(e) for e in events),timeout), events[-5:]
        command('load',config=asdict(Config(local_model_path=a.model)))
        wait_for(lambda e:e.get('state')=='ready')
        reports=[]
        for index,fixture in enumerate(['chinese','english','mixed']):
            session=f'pipeline-{index}'
            command('start',session_id=session)
            wait_for(lambda e:e.get('state')=='recording' and e.get('session_id')==session)
            audio,sr=sf.read(root/f'tests/fixtures/{fixture}.aiff',dtype='float32')
            if audio.ndim>1: audio=audio.mean(axis=1)
            g=gcd(sr,16000); audio=resample_poly(audio,16000//g,sr//g)
            # One second leading silence verifies no hallucinated quiet output.
            audio=np.concatenate([np.zeros(16000,dtype=np.float32),audio])
            pcm=(audio*32767).astype('<i2').tobytes()
            begin=time.monotonic()
            for seq,offset in enumerate(range(0,len(pcm),640)):
                header=json.dumps({'session_id':session,'sequence':seq,'start_sample':offset//2,'sample_rate':16000,'channels':1,'format':'s16le'}).encode()
                sock.sendall(encode_message(b'A',struct.pack('!I',len(header))+header+pcm[offset:offset+640]))
                time.sleep(max(0,begin+(seq+1)*.02-time.monotonic()))
            stopped=time.monotonic()-started
            command('stop',session_id=session)
            wait_for(lambda e:e.get('state')=='ready' and e.get('session_id')==session)
            result=[e for e in events if e.get('session_id')==session and e['type'] in ('partial','final')]
            finals=[e for e in result if e['type']=='final']
            assert finals, events[-5:]
            assert len({e['segment_id'] for e in finals})==len(finals)
            assert not any(e['type']=='error' for e in events),events
            reports.append({'fixture':fixture,'partials':len(result)-len(finals),'finals':len(finals),'text':'\n'.join(e['text'] for e in finals),'stop_to_ready_seconds':events[-1]['received_at']-stopped})
        command('shutdown')
        proc.wait(timeout=10)
        report={'runtime':a.runtime,'paced_audio':True,'offline_environment':True,'sessions':reports,'exit_code':proc.returncode}
        Path(a.output).write_text(json.dumps(report,ensure_ascii=False,indent=2))
        print(json.dumps(report,ensure_ascii=False,indent=2))
    finally:
        sock.close()
        if proc.poll() is None: proc.terminate(); proc.wait(timeout=10)
