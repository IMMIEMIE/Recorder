"""OpenAI-compatible audio transcription requests; credentials live only in memory."""
import io
import json
import time
import urllib.error
import urllib.request
import uuid
import wave

from core import RATE

LANGUAGES = {'Chinese': 'zh', 'English': 'en', 'Cantonese': 'yue',
             'Japanese': 'ja', 'Korean': 'ko'}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        return None


class APIRecognizer:
    def __init__(self):
        self.config = None
        self.key = ''
        self.opener = urllib.request.build_opener(NoRedirect())

    def load(self, config, key):
        if not key or '\r' in key or '\n' in key:
            raise ValueError('请填写有效的识别 API Key')
        self.config, self.key = config, key

    def transcribe(self, pcm):
        if not self.config or not self.key:
            raise ValueError('识别 API 尚未配置')
        start = time.monotonic()
        wav = io.BytesIO()
        with wave.open(wav, 'wb') as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(RATE)
            audio.writeframes(pcm)
        boundary = 'recorder-' + uuid.uuid4().hex
        def field(name, value):
            return (f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n').encode()
        body = field('model', self.config.api_model)
        language = LANGUAGES.get(self.config.language)
        if language:
            body += field('language', language)
        body += (f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\n'
                 'Content-Type: audio/wav\r\n\r\n').encode() + wav.getvalue() + f'\r\n--{boundary}--\r\n'.encode()
        request = urllib.request.Request(self.config.api_base_url + '/audio/transcriptions', body,
                    headers={'Authorization': 'Bearer ' + self.key,
                             'Content-Type': 'multipart/form-data; boundary=' + boundary,
                             'Accept': 'application/json'}, method='POST')
        try:
            with self.opener.open(request, timeout=90) as response:
                if response.status not in range(200, 300):
                    raise ValueError(f'识别 API 返回 HTTP {response.status}')
                raw = response.read(2_000_001)
        except urllib.error.HTTPError as exc:
            raise ValueError(f'识别 API 返回 HTTP {exc.code}；请检查地址、模型、密钥或额度') from None
        except urllib.error.URLError as exc:
            raise ValueError(f'无法连接识别 API：{exc.reason}') from None
        if len(raw) > 2_000_000:
            raise ValueError('识别 API 返回内容过长')
        try:
            result = json.loads(raw)
            text = result['text']
            if not isinstance(text, str):
                raise ValueError()
        except (ValueError, KeyError, TypeError):
            raise ValueError('识别 API 未返回 JSON 文本，请确认兼容音频转写接口') from None
        return text.strip(), (time.monotonic() - start) * 1000
