"""Phase 0 spike reference: same transcription via the shipped mlx_audio path.

Usage: .venv/bin/python spikes/qwen_asr_reference.py <snapshot-dir> <audio-file> [language]
Prints one JSON line: {"text": ..., "elapsed_s": ..., "gen_tokens": ...}
"""
import sys
import json
import time

import numpy as np
import soundfile as sf
from mlx_audio.stt.utils import load_model


def main():
    snap, audio_path = sys.argv[1], sys.argv[2]
    lang = sys.argv[3] if len(sys.argv) > 3 else None

    data, sr = sf.read(audio_path, dtype="float32", always_2d=False)
    if data.ndim > 1:
        data = data.mean(axis=1)
    if sr != 16000:
        raise SystemExit(f"need 16 kHz audio, got {sr}")

    model = load_model(snap)
    t0 = time.time()
    res = model.generate(audio=data, max_tokens=512, language=lang, verbose=False)
    dt = time.time() - t0
    print(json.dumps(
        {"text": res.text, "elapsed_s": dt, "gen_tokens": res.generation_tokens},
        ensure_ascii=False))


if __name__ == "__main__":
    main()
