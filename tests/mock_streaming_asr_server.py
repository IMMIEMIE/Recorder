"""DashScope duplex streaming ASR fixture: run-task, binary PCM, result-generated, finish-task."""
import base64
import hashlib
import json
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass

    def frame(self, data, opcode=1):
        if not isinstance(data, bytes): data = json.dumps(data, ensure_ascii=False).encode()
        length = len(data)
        header = bytes([0x80 | opcode])
        header += bytes([length]) if length < 126 else bytes([126]) + struct.pack('!H', length)
        self.wfile.write(header + data); self.wfile.flush()

    def event(self, task, name, payload=None, **header):
        self.frame({'header': {'task_id': task, 'event': name, 'attributes': {}, **header}, 'payload': payload or {}})

    def sentence(self, task, sentence_id, text, end, begin=0, heartbeat=False):
        self.event(task, 'result-generated', {'output': {'sentence': {
            'begin_time': begin, 'end_time': None, 'text': text, 'heartbeat': heartbeat,
            'sentence_end': end, 'sentence_id': sentence_id, 'words': []}}, 'usage': {'duration': 1} if end else None})

    def read_frame(self):
        """Returns (opcode, payload); None on close."""
        header = self.rfile.read(2)
        if len(header) != 2: return None
        opcode, length = header[0] & 15, header[1] & 127
        if length == 126: length = struct.unpack('!H', self.rfile.read(2))[0]
        elif length == 127: length = struct.unpack('!Q', self.rfile.read(8))[0]
        mask = self.rfile.read(4) if header[1] & 128 else b''
        data = self.rfile.read(length)
        if mask: data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
        if opcode == 8: return None
        if opcode == 9:
            self.frame(data, 10); return self.read_frame()
        return opcode, data

    def do_GET(self):
        route = urlsplit(self.path)
        if route.path in ('/unauthorized', '/redirect'):
            self.send_response(401 if route.path == '/unauthorized' else 302)
            if route.path == '/redirect': self.send_header('Location', '/ok')
            self.send_header('Content-Length', '0'); self.end_headers(); return
        assert not route.query
        assert self.headers.get('Authorization') == 'Bearer mock-only'
        key = self.headers['Sec-WebSocket-Key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
        self.send_response(101)
        self.send_header('Upgrade', 'websocket'); self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
        self.end_headers(); self.close_connection = True
        try:
            opcode, data = self.read_frame()
            assert opcode == 1
            run = json.loads(data)
            task = run['header']['task_id']
            assert run['header'] == {'action': 'run-task', 'task_id': task, 'streaming': 'duplex'}
            payload = run['payload']
            assert (payload['task_group'], payload['task'], payload['function']) == ('audio', 'asr', 'recognition')
            assert payload['model'] == 'qwen-audio-3.0-asr-flash-streaming' and payload['input'] == {}
            assert payload['parameters'] == {'format': 'pcm', 'sample_rate': 16000, 'max_sentence_silence': 800,
                                             'heartbeat': True, 'language_hints': ['zh']}
            if route.path == '/timeout': threading.Event().wait(2); return
            if route.path == '/failed':
                self.event(task, 'task-failed', error_code='InvalidParameter', error_message='Quota exceeded for key mock-only'); return
            if route.path == '/closed':
                self.frame(struct.pack('!H', 1008) + b'Access denied for model', 8); return
            self.event('another-task', 'task-started')  # Events of other tasks are ignored.
            self.event(task, 'task-started')
            if route.path == '/early-end':
                self.event(task, 'task-finished'); return
            audio, frames = bytearray(), 0
            while (message := self.read_frame()) is not None:
                opcode, data = message
                if opcode == 2:
                    audio.extend(data); frames += 1
                    if frames == 1:
                        self.sentence(task, 0, '', False, heartbeat=True)
                        self.sentence(task, 1, '', False)
                        self.sentence(task, 1, '你好', False)
                    continue
                finish = json.loads(data)
                assert finish == {'header': {'action': 'finish-task', 'task_id': task, 'streaming': 'duplex'}, 'payload': {'input': {}}}
                if route.path == '/finish-timeout': threading.Event().wait(2); return
                assert audio == bytes([1, 2]) * 3200, len(audio)
                assert frames == 2, frames  # ~100 ms frames, not one per capture callback
                self.sentence(task, 1, '你好，世界🌏。', True, begin=170)
                self.sentence(task, 2, '第二句', True, begin=1000)
                self.event(task, 'task-finished')
        except (OSError, ValueError, TypeError): pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as output: output.write(str(server.server_port))
server.serve_forever()
