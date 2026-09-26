"""Dependency-free protocol, validated configuration, and bounded audio segmentation."""
import json
import os
import struct
import re
import threading
from urllib.parse import urlsplit
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
    # max_segment_seconds bounds inference chunks, never finalization.
    preview_interval_ms: int = 1200
    endpoint_mode: str = 'smart'
    endpoint_silence_ms: int = 1000
    max_segment_seconds: int = 18
    provider: str = 'local'
    api_base_url: str = ''
    api_model: str = ''
    api_protocol: str = 'openai'

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
        if c.endpoint_mode not in ('smart', 'fixed'):
            raise ValueError('不支持的定稿模式')
        if c.language not in ('auto', 'Chinese', 'English', 'Cantonese', 'Japanese', 'Korean'):
            raise ValueError('不支持的语言选项')
        if c.provider not in ('local', 'api'):
            raise ValueError('不支持的识别服务')
        if c.api_protocol not in ('openai', 'qwen_realtime'):
            raise ValueError('不支持的识别 API 类型')
        for key in ('model_id', 'local_model_path', 'revision', 'api_base_url', 'api_model'):
            if not isinstance(getattr(c, key), str):
                raise ValueError(f'{key} 必须为字符串')
        if c.provider == 'api':
            url = urlsplit(c.api_base_url)
            secure_scheme = 'wss' if c.api_protocol == 'qwen_realtime' else 'https'
            if (not url.hostname or url.username or url.password or url.query or url.fragment or
                (url.scheme != secure_scheme and not (c.api_protocol == 'openai' and url.scheme == 'http' and url.hostname in ('localhost', '127.0.0.1', '::1'))) or
                c.api_base_url.endswith('/') or not c.api_model.strip() or
                '\n' in c.api_model or '\r' in c.api_model):
                raise ValueError('请填写有效的 API Base URL 和模型 ID（远程服务须使用 HTTPS）')
        elif not c.local_model_path and not valid_model_id(c.model_id):
            raise ValueError('请输入 owner/model 格式的模型 ID')
        return c

    def save(self, path):
        save_json(path, asdict(self))


@dataclass
class TranslationConfig:
    """Saved separately from the ASR config so each model role commits atomically on its own."""
    schema_version: int = 1
    enabled: bool = False
    provider: str = 'local'
    api_profile: str = ''
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
        if c.provider not in ('local', 'api'):
            raise ValueError('不支持的翻译服务')
        if not isinstance(c.api_profile, str):
            raise ValueError('API 配置标识必须为字符串')
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


def sentence_complete(text):
    """Conservative terminal punctuation hint, never a semantic guarantee."""
    text = text.strip().rstrip('”’"\'」』）)]').rstrip()
    if not text or text.endswith(('...', '…')):
        return False
    if text.endswith(('。', '！', '？', '!', '?')):
        return True
    if not text.endswith('.'):
        return False
    # Avoid numeric endings, initials, dotted abbreviations and common honorifics.
    word = text.split()[-1]
    if re.search(r'\d\.$', text) or word.count('.') > 1:
        return False
    if re.fullmatch(r'[A-Za-z]\.', word):
        return False
    return word.lower() not in {'mr.', 'mrs.', 'ms.', 'dr.', 'prof.', 'sr.', 'jr.', 'etc.', 'vs.', 'e.g.', 'i.e.'}


class Segmenter:
    """One lock guards audio boundaries and asynchronous recognition feedback."""
    def __init__(self, config, emit, lock=None):
        self.config, self.emit = config, emit
        self.lock = lock or threading.RLock()
        self.preroll = deque(maxlen=12)
        self.frames = []
        self.position = self.start = self.segment = self.revision = 0
        self.silent = self.voiced = self.last_preview = 0
        self.last_voiced = self.snapshot_voiced = 0
        self.results = []

    def feed(self, pcm, voiced):
        with self.lock:
            self._feed(pcm, voiced)

    def _feed(self, pcm, voiced):
        if len(pcm) != FRAME * 2:
            raise ValueError('VAD 要求 20 ms PCM16 音频帧')
        at = self.position
        self.position += FRAME
        if not self.frames:
            if not voiced:
                self.preroll.append((at, pcm))
                return
            self.start = self.preroll[0][0] if self.preroll else at
            self.frames = [p for _, p in self.preroll]
            self.preroll.clear()
            self.segment += 1
            self.revision = 0
            self.results = []
        self.frames.append(pcm)
        self.voiced += int(voiced)
        if voiced:
            self.last_voiced = self.position
        self.silent = 0 if voiced else self.silent + 1
        if self.silent * 20 >= self.threshold():
            self.finish()
        elif (self.voiced >= 3 and self.last_voiced > self.snapshot_voiced
              and len(self.frames) * 20 - self.last_preview >= self.config.preview_interval_ms):
            self.snapshot(False)
            self.snapshot_voiced = self.last_voiced
            self.last_preview = len(self.frames) * 20

    def threshold(self):
        if self.config.endpoint_mode == 'fixed':
            return self.config.endpoint_silence_ms
        if not self.results:
            return 1800
        latest = self.results[-1]
        if latest['last_voiced_sample'] != self.last_voiced or not sentence_complete(latest['text']):
            return 1800
        if len(self.results) == 1:
            return 1000
        return 500 if self.results[-2]['text'] == latest['text'] else 1800

    def accept_preview(self, item, text):
        with self.lock:
            if (not self.frames or item['segment_id'] != self.segment
                    or item['start_sample'] != self.start
                    or (self.results and item['revision'] <= self.results[-1]['revision'])):
                return
            self.results.append({**{k: item[k] for k in ('revision', 'last_voiced_sample')}, 'text': text.strip()})
            self.results = self.results[-2:]
            if self.silent * 20 >= self.threshold():
                self.finish()

    def snapshot(self, final):
        self.revision += 1
        self.emit(dict(segment_id=self.segment, revision=self.revision, start_sample=self.start,
                       end_sample=self.position, last_voiced_sample=self.last_voiced,
                       final=final, forced_cut=False, pcm=b''.join(self.frames)))

    def finish(self):
        with self.lock:
            if self.frames and self.voiced >= 2:
                self.snapshot(True)
            self.frames = []
            self.results = []
            self.silent = self.voiced = self.last_preview = 0
            self.last_voiced = self.snapshot_voiced = 0

    def flush(self):
        with self.lock:
            self.finish()
            self.preroll.clear()
