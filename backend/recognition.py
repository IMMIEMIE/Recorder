"""Worker-owned inference reuse, scoped to one model and bounded to live segments."""
from core import RATE
from translation import join_text


class RecognitionCache:
    def __init__(self):
        self.entries = {}

    def clear(self):
        self.entries.clear()

    def forget(self, item):
        self.entries.pop((item['session_id'], item['segment_id'], item['start_sample']), None)

    def transcribe(self, adapter, config, item, obsolete=lambda: False):
        key = (item['session_id'], item['segment_id'], item['start_sample'])
        entry = self.entries.setdefault(key, {'chunks': {}, 'last': None})
        last = entry['last']
        voiced = item.get('last_voiced_sample')
        if last is not None and voiced is not None and last[0] == voiced:
            return last[1], 0
        chunk_bytes = config.max_segment_seconds * RATE * 2
        text, duration = '', 0
        for offset in range(0, len(item['pcm']), chunk_bytes):
            if obsolete():
                return '', duration
            pcm = item['pcm'][offset:offset + chunk_bytes]
            if offset in entry['chunks']:
                part = entry['chunks'][offset]
            else:
                part, elapsed = adapter.transcribe(pcm)
                duration += elapsed
                if len(pcm) == chunk_bytes:
                    entry['chunks'][offset] = part
            text = join_text(text, part)
        if not obsolete():
            entry['last'] = (voiced, text)
        return text, duration
