"""Real GPU regression: Qwen -> Whisper -> Qwen in the same process, entirely offline."""
import argparse
import json
import os
import sys
import time
from pathlib import Path
os.environ['HF_HUB_OFFLINE']='1'
os.environ['TRANSFORMERS_OFFLINE']='1'
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from adapter import Adapter
from core import Config
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly
from math import gcd
p=argparse.ArgumentParser();p.add_argument('--qwen',required=True);p.add_argument('--whisper',required=True)
a=p.parse_args()
root=Path(__file__).resolve().parents[1]
audio,rate=sf.read(root/'tests/fixtures/chinese.aiff',dtype='float32')
g=gcd(rate,16000); audio=resample_poly(audio,16000//g,rate//g)
pcm=(audio*32767).astype('<i2').tobytes()
adapter=Adapter(); reports=[]
for path in [a.qwen,a.whisper,a.qwen]:
    started=time.monotonic()
    adapter.load(Config(local_model_path=path),path)
    adapter.warmup()
    load=time.monotonic()-started
    text,ms=adapter.transcribe(pcm)
    assert text, 'empty recognition'
    backend=sys.modules.get('mlx_whisper.transcribe')
    if adapter.architecture=='qwen3_asr' and backend:
        assert backend.ModelHolder.model is None, 'Whisper weights were retained after switching to Qwen'
    reports.append({'architecture':adapter.architecture,'load_and_warmup_seconds':load,'text':text,'elapsed_ms':ms})
adapter.unload()
assert adapter.model is None
report={'offline':True,'switches':reports,'global_cache_released':True}
(root/'docs/switching-verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps(report,ensure_ascii=False,indent=2))
