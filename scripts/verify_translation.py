"""Real ASR + local translation through the socket server: paced fixtures, per-unit latency, memory."""
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
from dataclasses import asdict
from math import gcd
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from core import Config, DEFAULT_TRANSLATOR, encode_message, read_message
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

p = argparse.ArgumentParser()
p.add_argument('--asr', default='', help='ASR snapshot directory; defaults to the cached default ASR model')
p.add_argument('--translator', default=DEFAULT_TRANSLATOR, help='translator model ID, resolved from --models')
p.add_argument('--models', default='models', help='Hugging Face cache containing the models')
p.add_argument('--runtime', default='.venv/bin/python')
p.add_argument('--output', default='docs/translation-verification.json')
a = p.parse_args()
root = Path(__file__).resolve().parents[1]
CASES = [('english', '简体中文'), ('english', '日本語'), ('chinese', 'English'), ('mixed', 'English'), ('chinese', '简体中文')]

with tempfile.TemporaryDirectory(prefix='recorder-translate-', dir='/tmp') as temp:
    os.symlink((root / a.models).resolve(), Path(temp) / 'models')
    path = str(Path(temp) / 's.sock')
    env = {**os.environ, 'HF_HUB_OFFLINE': '1', 'TRANSFORMERS_OFFLINE': '1', 'TOKENIZERS_PARALLELISM': 'false',
           'PYTHONDONTWRITEBYTECODE': '1', 'NUMBA_CACHE_DIR': str(Path(temp) / 'numba')}
    proc = subprocess.Popen([a.runtime, str(root / 'backend/server.py'), '--socket', path, '--root', temp],
                            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        for _ in range(200):
            try: sock.connect(path); break
            except OSError: time.sleep(.05)
        events = []; lock = threading.Condition(); started = time.monotonic()
        def receive():
            try:
                while True:
                    event = json.loads(read_message(sock)[1]); event['received_at'] = time.monotonic() - started
                    with lock: events.append(event); lock.notify_all()
            except (EOFError, OSError): pass
        threading.Thread(target=receive, daemon=True).start()
        def command(name, **kw):
            value = {'command': name, 'protocol_version': 1, 'session_id': '', 'request_id': name, **kw}
            sock.sendall(encode_message(b'J', json.dumps(value).encode()))
        def wait_for(predicate, start, timeout=180):
            deadline = time.monotonic() + timeout
            with lock:
                while True:
                    match = next((e for e in events[start:] if predicate(e)), None)
                    if match: return match
                    assert lock.wait(max(0, deadline - time.monotonic())), events[-5:]
        def mark():
            with lock: return len(events)
        def load_asr(**overrides):
            config = Config(local_model_path=a.asr, **overrides) if a.asr else Config(**overrides)
            begin = mark(); command('load', config=asdict(config))
            status = wait_for(lambda e: e['type'] == 'status' and e['state'] in ('ready', 'error'), begin)
            assert status['state'] == 'ready', status

        begin = mark(); load_start = time.monotonic()
        command('translation_settings', enabled=True)
        translator = wait_for(lambda e: e['type'] == 'translator' and e['state'] in ('ready', 'error'), begin)
        assert translator['state'] == 'ready', translator
        translator_load_seconds = time.monotonic() - load_start
        load_asr()

        def run(fixture, target, label):
            begin = mark()
            command('translation_settings', target_language=target)
            wait_for(lambda e: e['type'] == 'translator' and e['config']['target_language'] == target, begin)
            session = f'translate-{label}'
            command('start', session_id=session)
            wait_for(lambda e: e.get('state') == 'recording' and e.get('session_id') == session, begin)
            audio, sr = sf.read(root / f'tests/fixtures/{fixture}.aiff', dtype='float32')
            if audio.ndim > 1: audio = audio.mean(axis=1)
            g = gcd(sr, 16000); audio = resample_poly(audio, 16000 // g, sr // g)
            audio = np.concatenate([np.zeros(16000, dtype=np.float32), audio])
            pcm = (np.clip(audio, -1, 1) * 32767).astype('<i2').tobytes()
            clock = time.monotonic()
            for seq, offset in enumerate(range(0, len(pcm), 640)):
                header = json.dumps({'session_id': session, 'sequence': seq, 'start_sample': offset // 2,
                                     'sample_rate': 16000, 'channels': 1, 'format': 's16le'}).encode()
                sock.sendall(encode_message(b'A', struct.pack('!I', len(header)) + header + pcm[offset:offset + 640]))
                time.sleep(max(0, clock + (seq + 1) * .02 - time.monotonic()))
            stopped = time.monotonic() - started
            command('stop', session_id=session)
            ready = wait_for(lambda e: e.get('state') == 'ready' and e.get('session_id') == session, begin)
            def settled():
                done = {}
                for e in events[begin:]:
                    if e['type'] == 'translation' and e['session_id'] == session:
                        done[e['unit_id']] = e['done']
                return all(done.values())
            with lock:
                assert lock.wait_for(settled, 120), events[-5:]
                window = [e for e in events[begin:] if e.get('session_id') == session]
                errors = [e for e in events[begin:] if e['type'] == 'error']
            assert not errors, errors
            finals = {e['segment_id']: e for e in window if e['type'] == 'final'}
            units = []
            for unit in sorted({e['unit_id'] for e in window if e['type'] == 'translation'}):
                updates = [e for e in window if e['type'] == 'translation' and e['unit_id'] == unit]
                done, final = updates[-1], finals[updates[-1]['segment_id']]
                first = next((e for e in updates if e['text']), done)
                units.append({'segment_id': done['segment_id'], 'text': done['text'], 'skipped': done['skipped'],
                              'generation_ms': round(done['elapsed_ms']),
                              'final_to_first_text_seconds': round(first['received_at'] - final['received_at'], 3),
                              'final_to_done_seconds': round(done['received_at'] - final['received_at'], 3)})
            return {'fixture': fixture, 'target': target,
                    'finals': [{'segment_id': s, 'text': e['text'], 'forced_cut': e['forced_cut']} for s, e in finals.items()],
                    'units': units, 'stop_to_ready_seconds': round(ready['received_at'] - stopped, 3),
                    'stop_to_translations_done_seconds': round(max([e['received_at'] for e in window], default=stopped) - stopped, 3)}

        reports = [run(fixture, target, f'{index}') for index, (fixture, target) in enumerate(CASES)]
        for report in reports[:-1]:
            assert any(u['text'] for u in report['units']), report
        assert reports[-1]['units'] == [], reports[-1]
        # Short forced segments exercise carrying an unfinished sentence into the next final.
        load_asr(max_segment_seconds=5)
        forced = run('chinese', 'English', 'forced')
        assert any(f['forced_cut'] for f in forced['finals']), forced
        assert any(u['text'] for u in forced['units']), forced
        rss = int(subprocess.run(['ps', '-o', 'rss=', '-p', str(proc.pid)], capture_output=True, text=True).stdout.strip() or 0) * 1024
        command('shutdown')
        proc.wait(timeout=10)
        report = {'runtime': a.runtime, 'translator': a.translator, 'offline_environment': True, 'paced_audio': True,
                  'translator_load_and_warmup_seconds': round(translator_load_seconds, 3), 'server_rss_bytes': rss,
                  'sessions': reports, 'forced_cut_session': forced, 'exit_code': proc.returncode}
        Path(a.output).write_text(json.dumps(report, ensure_ascii=False, indent=2))
        print(json.dumps(report, ensure_ascii=False, indent=2))
    finally:
        sock.close()
        if proc.poll() is None:
            proc.terminate(); proc.wait(timeout=10)
        if proc.stderr:
            tail = proc.stderr.read().decode(errors='replace')[-2000:]
            if tail.strip(): print(tail, file=sys.stderr)
