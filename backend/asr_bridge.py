"""Ask the native app to perform Qwen WebSocket requests without exposing its key."""
import base64
import threading
import time
import uuid


class NativeASRBridge:
    def __init__(self, send, alive):
        self.send, self.alive = send, alive
        self.cv = threading.Condition()
        self.call = None
        self.result = None

    def resolve(self, call, text, error):
        if not isinstance(text, str) or not isinstance(error, str) or len(text.encode()) > 200_000:
            raise ValueError('实时识别结果无效或过长')
        with self.cv:
            if self.call is None or call != self.call or self.result is not None:
                return
            self.result = (text, error[:500])
            self.cv.notify_all()

    def transcribe(self, pcm):
        started = time.monotonic()
        call = uuid.uuid4().hex
        with self.cv:
            self.call, self.result = call, None
        try:
            for offset in range(0, len(pcm), 48_000):
                self.send(type='asr_api_audio', call_id=call,
                          audio=base64.b64encode(pcm[offset:offset + 48_000]).decode(),
                          done=offset + 48_000 >= len(pcm))
            with self.cv:
                deadline = time.monotonic() + 110
                while self.result is None and self.alive() and time.monotonic() < deadline:
                    self.cv.wait(min(1, deadline - time.monotonic()))
                if self.result is None:
                    raise ValueError('千问实时识别超时或连接中断')
                text, error = self.result
            if error:
                raise ValueError(error)
            return text.strip(), (time.monotonic() - started) * 1000
        finally:
            with self.cv:
                self.call, self.result = None, None
