"""Explicit file-based benchmark, never invoked by the desktop recording path."""
import argparse
import importlib.metadata
import json
import platform
import resource
import sys
import time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from adapter import Adapter
from core import Config

p = argparse.ArgumentParser()
p.add_argument('--model', required=True)
p.add_argument('--audio', action='append', default=[])
p.add_argument('--output', default='docs/model-verification.json')
a = p.parse_args()
model = Adapter()
start = time.monotonic()
model.load(Config(local_model_path=a.model), a.model)
load = time.monotonic()-start
start = time.monotonic()
model.warmup()
warmup = time.monotonic()-start
results = []
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly
from math import gcd
for path in a.audio:
    audio, rate = sf.read(path, dtype='float32')
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if rate != 16000:
        divisor = gcd(rate, 16000)
        audio = resample_poly(audio, 16000//divisor, rate//divisor)
    pcm = (np.clip(audio, -1, 1)*32767).astype('<i2').tobytes()
    text, ms = model.transcribe(pcm)
    results.append({'file':Path(path).name, 'audio_seconds':len(audio)/16000, 'elapsed_ms':ms, 'text':text})
import mlx.core as mx
report = {'platform':platform.platform(), 'architecture':platform.machine(),
          'model_path':a.model, 'revision':Path(a.model).name,
          'load_seconds':load, 'warmup_seconds':warmup, 'peak_rss_bytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
          'mlx_peak_bytes':mx.get_peak_memory(),
          'versions':{x:importlib.metadata.version(x) for x in ('mlx','mlx-audio','mlx-whisper','transformers','huggingface-hub','webrtcvad-wheels')},
          'results':results}
Path(a.output).write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps(report, ensure_ascii=False, indent=2))
