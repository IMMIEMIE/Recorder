"""Offline benchmark-only instrumentation; baseline reproduces pre-smart endpoint behavior."""
import json
import os
import runpy
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
import core
import recognition
from adapter import Adapter
from translation import join_text

if os.environ.get('RECORDER_ENDPOINT_BASELINE') == '1':
    class LegacySegmenter(core.Segmenter):
        def threshold(self): return self.config.endpoint_silence_ms
        def accept_preview(self, item, text): pass
        def _feed(self, pcm, voiced):
            self.snapshot_voiced = 0  # Previous version also repeated previews through silence.
            super()._feed(pcm, voiced)
    core.Segmenter = LegacySegmenter
    def uncached(self, adapter, config, item, obsolete=lambda: False):
        text, duration = '', 0
        size = config.max_segment_seconds * core.RATE * 2
        for offset in range(0, len(item['pcm']), size):
            part, elapsed = adapter.transcribe(item['pcm'][offset:offset + size])
            text = join_text(text, part); duration += elapsed
            if obsolete(): break
        return text, duration
    recognition.RecognitionCache.transcribe = uncached

original = Adapter.transcribe
stats = {'calls': 0, 'inference_ms': 0}
def measured(self, pcm):
    text, elapsed = original(self, pcm)
    if not getattr(self, '_benchmark_warmup', False):
        stats['calls'] += 1; stats['inference_ms'] += elapsed
        Path(os.environ['RECORDER_ENDPOINT_METRICS']).write_text(json.dumps(stats))
    return text, elapsed
Adapter.transcribe = measured
warmup = Adapter.warmup
def warming(self):
    self._benchmark_warmup = True
    try: warmup(self)
    finally: self._benchmark_warmup = False
Adapter.warmup = warming
runpy.run_path(str(Path(__file__).resolve().parents[1] / 'backend/server.py'), run_name='__main__')
