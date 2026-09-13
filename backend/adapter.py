"""One loaded model at a time, with architecture-specific offline adapters."""
import gc
import importlib
import importlib.util
import json
import os
import platform
import sys
import time
from pathlib import Path

WHISPER_LANGUAGES = {'auto': None, 'Chinese': 'zh', 'English': 'en', 'Cantonese': 'yue', 'Japanese': 'ja', 'Korean': 'ko'}

class Adapter:
    capabilities = {'language': True, 'partial_snapshots': True, 'incremental_audio': False}

    def __init__(self):
        self.model = None
        self.config = None
        self.architecture = None
        self.path = None

    @staticmethod
    def validate_config(config, path):
        if platform.system() != 'Darwin' or platform.machine() != 'arm64':
            raise ValueError('MLX 后端需要 Apple Silicon macOS')
        path = Path(path)
        if not (path / 'config.json').is_file():
            raise ValueError('离线资源缺失: config.json')
        raw = json.loads((path / 'config.json').read_text())
        if raw.get('auto_map'):
            raise ValueError('不支持需要执行自定义远程代码的模型')
        architecture = raw.get('model_type')
        if architecture == 'qwen3_asr':
            for name in ('tokenizer_config.json', 'preprocessor_config.json', 'vocab.json', 'merges.txt'):
                if not (path / name).is_file():
                    raise ValueError(f'离线资源缺失: {name}')
            tokenizer = json.loads((path / 'tokenizer_config.json').read_text())
            if tokenizer.get('auto_map'):
                raise ValueError('不支持需要执行自定义远程代码的模型')
            if not list(path.glob('*.safetensors')):
                raise ValueError('离线资源缺失: *.safetensors 权重')
            index = path / 'model.safetensors.index.json'
            if index.exists():
                for name in set(json.loads(index.read_text())['weight_map'].values()):
                    if not (path / name).is_file():
                        raise ValueError(f'离线资源缺失: {name}')
        elif architecture == 'whisper':
            required = ('n_mels', 'n_audio_ctx', 'n_audio_state', 'n_audio_head', 'n_audio_layer',
                        'n_vocab', 'n_text_ctx', 'n_text_state', 'n_text_head', 'n_text_layer')
            if any(type(raw.get(k)) is not int or raw[k] <= 0 for k in required):
                raise ValueError('需要 MLX Whisper 格式的 config.json，不能直接加载 Transformers/PyTorch 权重')
            if not any((path / name).is_file() for name in ('weights.safetensors', 'weights.npz')):
                raise ValueError('离线资源缺失: weights.safetensors 或 weights.npz')
            spec = importlib.util.find_spec('mlx_whisper')
            if spec is None:
                raise ValueError('Whisper 运行环境缺失，请重新安装应用')
            assets = Path(spec.origin).parent / 'assets'
            for name in ('mel_filters.npz', 'multilingual.tiktoken', 'gpt2.tiktoken'):
                if not (assets / name).is_file():
                    raise ValueError(f'Whisper 离线辅助资源缺失: {name}')
        else:
            raise ValueError('仅支持 MLX Qwen3-ASR 和 MLX Whisper 架构')
        return path

    def load(self, config, path):
        path = self.validate_config(config, path)
        os.environ['HF_HUB_OFFLINE'] = '1'
        os.environ['TRANSFORMERS_OFFLINE'] = '1'
        self.unload()
        self.config = config
        self.path = str(path)
        self.architecture = json.loads((path / 'config.json').read_text())['model_type']
        try:
            if self.architecture == 'whisper':
                import mlx.core as mx
                backend = importlib.import_module('mlx_whisper.transcribe')
                self.model = backend.ModelHolder.get_model(self.path, mx.float16)
            else:
                from mlx_audio.stt.utils import load_model
                self.model = load_model(self.path)
        except Exception:
            self.unload()
            raise

    def warmup(self):
        self.transcribe(b'\0' * 16000)

    def unload(self):
        self.model = None
        # mlx-whisper caches its model globally. Clear this reference as well, otherwise
        # switching back to Qwen leaves both large models resident in memory.
        backend = sys.modules.get('mlx_whisper.transcribe')
        if backend is not None:
            backend.ModelHolder.model = None
            backend.ModelHolder.model_path = None
        self.architecture = None
        self.path = None
        gc.collect()
        if 'mlx.core' in sys.modules:
            sys.modules['mlx.core'].clear_cache()

    def transcribe(self, pcm):
        import numpy as np
        import mlx.core as mx
        samples = np.frombuffer(pcm, dtype='<i2').astype(np.float32) / 32768.0
        start = time.monotonic()
        if self.architecture == 'whisper':
            backend = importlib.import_module('mlx_whisper.transcribe')
            result = backend.transcribe(samples, path_or_hf_repo=self.path,
                language=WHISPER_LANGUAGES[self.config.language], task='transcribe',
                verbose=None, temperature=0.0, condition_on_previous_text=False,
                word_timestamps=False, sample_len=224)
            text = result['text']
        else:
            args = {'audio': mx.array(samples), 'verbose': False, 'max_tokens': 512}
            if self.config.language != 'auto':
                args['language'] = self.config.language
            text = self.model.generate(**args).text
        return text.strip(), (time.monotonic() - start) * 1000
