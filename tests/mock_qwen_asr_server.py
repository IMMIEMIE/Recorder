"""Qwen realtime fixture with input ASR and unrelated assistant output."""
import base64
import hashlib
import json
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs


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
            self.frame({'type':'session.created'})
            config = self.read_frame()
            assert config['type'] == 'session.update'
            session = config['session']
            assert session['modalities'] == ['text']
            assert session['turn_detection'] is None
            assert session['input_audio_format'] == 'pcm'
            if route.path == '/error':
                self.frame({'type':'error', 'error':{'code':'quota', 'message':'DO NOT DISPLAY mock-only'}}); return
            if route.path == '/wrong-mode': session['turn_detection'] = {'type':'server_vad'}
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
                    self.frame({'type':'response.text.done', 'text':'这是一条回答，必须忽略'})
                    delta = {'type':'conversation.item.input_audio_transcription.delta', 'event_id':'duplicate', 'item_id':'input', 'text':'你好', 'stash':'🌏'}
                    self.frame(delta); self.frame(delta)
                    self.frame({'type':'conversation.item.input_audio_transcription.delta', 'item_id':'input', 'text':'你好，', 'stash':'世界'})
                    self.frame({'type':'conversation.item.input_audio_transcription.completed', 'item_id':'input', 'transcript':'你好，世界🌏。'})
                else: raise AssertionError('Unexpected event: ' + event['type'])
        except (OSError, ValueError, TypeError): pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as output: output.write(str(server.server_port))
server.serve_forever()
