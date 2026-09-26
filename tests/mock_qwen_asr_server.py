"""Qwen realtime fixture with input ASR and unrelated assistant output."""
import base64
import hashlib
import json
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

DEFAULT_SESSION = {'modalities':['text', 'audio'], 'input_audio_format':'pcm',
                   'input_audio_transcription':{'model':'qwen3-asr-flash-realtime'},
                   'turn_detection':{'type':'server_vad', 'threshold':0.5, 'silence_duration_ms':800}}
rejected_hints = []

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_): pass

    def frame(self, data, opcode=1):
        if not isinstance(data, bytes): data = json.dumps(data).encode()
        length = len(data)
        header = bytes([0x80 | opcode])
        header += bytes([length]) if length < 126 else bytes([126]) + struct.pack('!H', length)
        self.wfile.write(header + data); self.wfile.flush()

    def read_frame(self):
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
        return json.loads(data)

    def do_GET(self):
        route = urlsplit(self.path)
        if route.path in ('/unauthorized', '/redirect'):
            self.send_response(401 if route.path == '/unauthorized' else 302)
            if route.path == '/redirect': self.send_header('Location', '/ok')
            self.send_header('Content-Length', '0'); self.end_headers(); return
        assert parse_qs(route.query)['model'] == ['qwen-audio-3.1-realtime-plus']
        assert self.headers.get('Authorization') == 'Bearer mock-only'
        key = self.headers['Sec-WebSocket-Key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
        self.send_response(101)
        self.send_header('Upgrade', 'websocket'); self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
        self.end_headers(); self.close_connection = True
        try:
            self.frame({'type':'session.created', 'session':DEFAULT_SESSION})
            config = self.read_frame()
            assert config['type'] == 'session.update'
            update = config['session']
            # The service validates strictly: only documented fields, manual commit, text output.
            assert update['turn_detection'] is None
            if update != {'turn_detection': None}:
                assert set(update) <= {'modalities', 'input_audio_format', 'turn_detection', 'input_audio_transcription'}
                assert update['modalities'] == ['text']
                assert update['input_audio_format'] == 'pcm'
            if 'input_audio_transcription' in update:
                if route.path == '/no-language':
                    assert not rejected_hints, 'rejected language hint was sent again'
                    rejected_hints.append(update['input_audio_transcription'])
                    self.frame({'type':'error', 'error':{'code':'InvalidParameter', 'param':'session.input_audio_transcription',
                                                         'message':'Unsupported field'}}); return
                assert update['input_audio_transcription'] == {'model':'qwen3-asr-flash-realtime', 'language':'zh'}
            if route.path == '/error':
                self.frame({'type':'error', 'error':{'code':'Throttling.AllocationQuota', 'message':'Quota exceeded for mock-only'}}); return
            if route.path == '/closed':
                self.frame(struct.pack('!H', 1008) + b'Access denied for mock-only', 8); return
            session = {**DEFAULT_SESSION, **update}
            if route.path == '/wrong-mode': session['turn_detection'] = {'type':'server_vad'}
            if route.path == '/sparse': session = {'id':'sess_sparse'}  # null fields omitted from the echo
            self.frame({'type':'session.updated', 'session':session})
            audio = bytearray()
            while (event := self.read_frame()) is not None:
                if route.path == '/wrong-mode': raise AssertionError('audio sent before safe mode confirmed')
                if event['type'] == 'input_audio_buffer.append':
                    audio.extend(base64.b64decode(event['audio']))
                    if route.path == '/disconnect': return
                elif event['type'] == 'input_audio_buffer.commit':
                    if route.path == '/timeout': threading.Event().wait(2); return
                    if route.path == '/failed':
                        self.frame({'type':'conversation.item.input_audio_transcription.failed', 'error':{'message':'mock-only'}}); return
                    assert audio == bytes([1, 2]) * 3200
                    self.frame({'type':'input_audio_buffer.committed', 'item_id':'input'})
                    self.frame({'type':'conversation.item.input_audio_transcription.completed', 'item_id':'other', 'transcript':'不属于本次提交'})
                    self.frame({'type':'response.text.done', 'text':'这是一条回答，必须忽略'})
                    delta = {'type':'conversation.item.input_audio_transcription.delta', 'event_id':'duplicate', 'item_id':'input', 'text':'你好', 'stash':'🌏'}
                    self.frame(delta); self.frame(delta)
                    self.frame({'type':'conversation.item.input_audio_transcription.text', 'item_id':'input', 'text':'你好，', 'stash':'世界'})
                    self.frame({'type':'conversation.item.input_audio_transcription.completed', 'item_id':'input', 'transcript':'你好，世界🌏。'})
                else: raise AssertionError('Unexpected event: ' + event['type'])
        except (OSError, ValueError, TypeError): pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as output: output.write(str(server.server_port))
server.serve_forever()
