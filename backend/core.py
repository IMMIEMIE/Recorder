"""Dependency-free protocol, validated configuration, and bounded audio segmentation."""
import json
import os
import struct
from collections import deque
from dataclasses import asdict, dataclass
from pathlib import Path

RATE = 16000
FRAME = 320  # 20 ms, signed little-endian PCM16 mono
MAX_MESSAGE = 256 * 1024
DEFAULT_MODEL = 'mlx-community/Qwen3-ASR-1.7B-bf16'
DEFAULT_TRANSLATOR = 'mlx-community/Qwen3-4B-Instruct-2507-4bit'
# UI value -> (English name for prompts, Chinese name for Chinese-instruction prompts)
TRANSLATION_TARGETS = {
    '简体中文': ('Simplified Chinese', '简体中文'),
    '繁體中文': ('Traditional Chinese', '繁体中文'),
    'English': ('English', '英语'),
    '日本語': ('Japanese', '日语'),
    '한국어': ('Korean', '韩语'),
    'Français': ('French', '法语'),
    'Deutsch': ('German', '德语'),
    'Español': ('Spanish', '西班牙语'),
    'Русский': ('Russian', '俄语'),
}


def save_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2))
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def valid_model_id(model_id):
    parts = model_id.split('/')
    return len(parts) == 2 and all(parts) and '..' not in model_id


@dataclass
class Config:
    schema_version: int = 1
    model_id: str = DEFAULT_MODEL
    local_model_path: str = ''
    revision: str = ''
    language: str = 'auto'
    preview_interval_ms: int = 1200
    endpoint_silence_ms: int = 760
    max_segment_seconds: int = 18

    @classmethod
    def parse(cls, values):
        if not isinstance(values, dict):
            raise ValueError('配置必须为 JSON 对象')
        unknown = set(values) - set(cls.__dataclass_fields__)
        if unknown:
            raise ValueError(f'未知配置字段: {sorted(unknown)}')
        c = cls(**values)
        if c.schema_version != 1:
            raise ValueError('不支持的配置版本')
        for key, low, high in [('preview_interval_ms', 800, 10000), ('endpoint_silence_ms', 300, 2000), ('max_segment_seconds', 5, 25)]:
            v = getattr(c, key)
            if type(v) is not int or not low <= v <= high:
                raise ValueError(f'{key} 必须在 {low}–{high} 范围内')
        if c.language not in ('auto', 'Chinese', 'English', 'Cantonese', 'Japanese', 'Korean'):
            raise ValueError('不支持的语言选项')
        for key in ('model_id', 'local_model_path', 'revision'):
            if not isinstance(getattr(c, key), str):
                raise ValueError(f'{key} 必须为字符串')
        if not c.local_model_path and not valid_model_id(c.model_id):
            raise ValueError('请输入 owner/model 格式的模型 ID')
        return c

    def save(self, path):
        save_json(path, asdict(self))


@dataclass
class TranslationConfig:
    """Saved separately from the ASR config so each model role commits atomically on its own."""
    schema_version: int = 1
    enabled: bool = False
    target_language: str = '简体中文'
    model_id: str = DEFAULT_TRANSLATOR
    revision: str = ''

    @classmethod
    def parse(cls, values):
        if not isinstance(values, dict):
            raise ValueError('翻译配置必须为 JSON 对象')
        unknown = set(values) - set(cls.__dataclass_fields__)
        if unknown:
            raise ValueError(f'未知翻译配置字段: {sorted(unknown)}')
        c = cls(**values)
        if c.schema_version != 1:
            raise ValueError('不支持的翻译配置版本')
        if type(c.enabled) is not bool:
            raise ValueError('enabled 必须为布尔值')
        if c.target_language not in TRANSLATION_TARGETS:
            raise ValueError('不支持的翻译目标语言')
        for key in ('model_id', 'revision'):
            if not isinstance(getattr(c, key), str):
                raise ValueError(f'{key} 必须为字符串')
        if not valid_model_id(c.model_id):
            raise ValueError('请输入 owner/model 格式的翻译模型 ID')
        return c

    def save(self, path):
        save_json(path, asdict(self))


def read_exact(sock, count):
    result = bytearray()
    while len(result) < count:
        block = sock.recv(count - len(result))
        if not block:
            raise EOFError('推理连接已关闭')
        result.extend(block)
    return bytes(result)


def read_message(sock):
    size = struct.unpack('!I', read_exact(sock, 4))[0]
    if not 1 <= size <= MAX_MESSAGE:
        raise ValueError('消息帧超出限制')
    body = read_exact(sock, size)
    return body[:1], body[1:]


def encode_message(kind, payload):
    return struct.pack('!I', len(payload) + 1) + kind + payload


class Segmenter:
    """Non-overlapping final ranges preserve intentional repetitions without text dedup.

    Pre-roll applies only after silence. Forced cuts are exact contiguous boundaries.
    Every sample is owned by at most one final segment.
    """
    def __init__(self, config, emit):
        self.config, self.emit = config, emit
        self.preroll = deque(maxlen=12)
        self.frames = []
        self.position = 0
        self.start = 0
        self.segment = 0
        self.revision = 0
        self.silent = 0
        self.voiced = 0
        self.last_preview = 0
        self.continuing = False

    def feed(self, pcm, voiced):
        if len(pcm) != FRAME * 2:
            raise ValueError('VAD 要求 20 ms PCM16 音频帧')
        at = self.position
        self.position += FRAME
        if not self.frames:
            if not voiced and not self.continuing:
                self.preroll.append((at, pcm))
                return
            self.start = self.preroll[0][0] if self.preroll else at
            self.frames = [p for _, p in self.preroll]
            self.preroll.clear()
            self.segment += 1
            self.revision = 0
            self.continuing = False
        self.frames.append(pcm)
        self.voiced += int(voiced)
        self.silent = 0 if voiced else self.silent + 1
        elapsed = len(self.frames) * 20
        if self.silent * 20 >= self.config.endpoint_silence_ms:
            self.finish()
        elif elapsed >= self.config.max_segment_seconds * 1000:
            self.finish(forced=True)
            self.continuing = True
        elif self.voiced >= 3 and elapsed - self.last_preview >= self.config.preview_interval_ms:
            self.snapshot(False)
            self.last_preview = elapsed

    def snapshot(self, final, forced_cut=False):
        self.revision += 1
        self.emit(dict(segment_id=self.segment, revision=self.revision, start_sample=self.start,
                       end_sample=self.position, final=final, forced_cut=forced_cut, pcm=b''.join(self.frames)))

    def finish(self, forced=False):
        if self.frames and self.voiced >= 2:
            self.snapshot(True, forced)
        self.frames = []
        self.silent = self.voiced = self.last_preview = 0
        self.continuing = False

    def flush(self):
        self.finish()
        self.preroll.clear()
