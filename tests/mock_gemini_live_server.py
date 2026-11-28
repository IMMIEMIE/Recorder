"""Local RFC6455 Gemini Live (BidiGenerateContent) fixture; synthetic audio and credentials only, no dependencies."""
import base64
import hashlib
import json
import socket
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


dropped = set()


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def frame(self, data, opcode=1):
        if not isinstance(data, bytes):
            data = json.dumps(data).encode()
        length = len(data)
        header = bytes([0x80 | opcode])
        if length < 126:
            header += bytes([length])
        elif length < 65536:
            header += bytes([126]) + struct.pack('!H', length)
        else:
            header += bytes([127]) + struct.pack('!Q', length)
        self.wfile.write(header + data)
        self.wfile.flush()

    def close(self, code, reason):
        self.frame(struct.pack('!H', code) + reason.encode(), 8)
        try:
            self.connection.shutdown(socket.SHUT_WR)
            self.connection.settimeout(0.5)
            while self.connection.recv(4096):
                pass
        except OSError:
            pass

    def read_frame(self):
        header = self.rfile.read(2)
        if len(header) != 2:
            return None
        opcode, length = header[0] & 15, header[1] & 127
        if length == 126:
            length = struct.unpack('!H', self.rfile.read(2))[0]
        elif length == 127:
            length = struct.unpack('!Q', self.rfile.read(8))[0]
        mask = self.rfile.read(4) if header[1] & 128 else b''
        data = self.rfile.read(length)
        if mask:
            data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
        if opcode == 8:
            return None
        if opcode == 9:
            self.frame(data, 10)
            return self.read_frame()
        return json.loads(data)

    def do_GET(self):
        route = urlsplit(self.path)
        if route.query:
            # Credentials or model parameters must never be passed via query string in this fixture.
            self.send_error(400)
            return
        if route.path == '/unauthorized':
            self.send_response(401)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if route.path == '/forbidden':
            self.send_response(403)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if route.path == '/http-429':
            self.send_response(429)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if route.path == '/redirect':
            self.send_response(302)
            self.send_header('Location', '/ok')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return

        if route.path == '/bearer':
            if self.headers.get('Authorization') != 'Bearer ya29.mock-token' or self.headers.get('x-goog-api-key') is not None:
                self.send_error(401)
                return
        else:
            if self.headers.get('x-goog-api-key') != 'mock-gemini' or self.headers.get('Authorization') is not None:
                self.send_error(401)
                return

        key = self.headers['Sec-WebSocket-Key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
        self.end_headers()
        self.close_connection = True

        try:
            first = self.read_frame()
            if not first or 'setup' not in first:
                self.close(1007, 'Missing setup frame')
                return
            setup = first['setup']
            model = setup.get('model', '')
            assert model.startswith('models/') or model.startswith('projects/'), f'bad model: {model}'
            modalities = setup.get('generationConfig', {}).get('responseModalities', [])
            assert modalities in (['AUDIO'], ['TEXT']), f'bad modalities: {modalities}'
            audio_modality = 'AUDIO' in modalities
            if 'native-audio' in model.lower() and not audio_modality:
                self.close(1007, 'Cannot extract voices from a non-audio request')
                return
            assert 'inputAudioTranscription' in setup
            if audio_modality:
                assert 'outputAudioTranscription' in setup
            parts = setup.get('systemInstruction', {}).get('parts', [])
            assert parts and parts[0].get('text')

            if route.path == '/close-1007':
                self.close(1007, 'Invalid argument: DO NOT LEAK mock-gemini')
                return
            if route.path == '/rate-limited':
                self.close(1011, 'RESOURCE_EXHAUSTED: rate limit exceeded mock-gemini')
                return
            if route.path == '/json-error-auth':
                self.frame({'error': {'code': 401, 'status': 'UNAUTHENTICATED', 'message': 'DO NOT LEAK mock-gemini'}})
                return
            if route.path == '/json-error-rate':
                self.frame({'error': {'code': 429, 'status': 'RESOURCE_EXHAUSTED', 'message': 'DO NOT LEAK mock-gemini'}})
                return

            self.frame({'setupComplete': {}})

            drop = route.path.startswith('/drop-once/') and route.path not in dropped
            dropped.add(route.path)

            sent_partial = False
            total_bytes = 0
            # Split 4800 bytes of 24 kHz PCM16 across an odd boundary (2401 + 2399) to test reassembly.
            pcm_full = b'\x00\x40' * 2400
            pcm_part1 = pcm_full[:2401]
            pcm_part2 = pcm_full[2401:]

            while (msg := self.read_frame()) is not None:
                rt = msg.get('realtimeInput')
                if not isinstance(rt, dict):
                    continue
                if 'audio' in rt:
                    audio = rt['audio']
                    assert audio.get('mimeType') == 'audio/pcm;rate=16000'
                    total_bytes += len(base64.b64decode(audio['data']))
                    if drop:
                        self.frame({'serverContent': {'inputTranscription': {'text': 'Before the break'}}})
                        return
                    if not sent_partial:
                        sent_partial = True
                        if route.path == '/interrupted':
                            self.frame({'serverContent': {'inputTranscription': {'text': 'First part'}}})
                            self.frame({'serverContent': {'outputTranscription': {'text': '第一段'}}})
                            self.frame({'serverContent': {'interrupted': True}})
                            continue
                        self.frame({'serverContent': {'inputTranscription': {'text': 'Hello '}}})
                        # Thought parts must always be filtered out by the client.
                        self.frame({'serverContent': {'modelTurn': {'parts': [{'text': 'INTERNAL THOUGHT', 'thought': True}]}}})
                        if audio_modality:
                            self.frame({'serverContent': {'outputTranscription': {'text': '你好，'}}})
                            if route.path == '/bad-audio':
                                self.frame({'serverContent': {'modelTurn': {'parts': [{'inlineData': {'mimeType': 'audio/pcm;rate=24000', 'data': 'not valid base64!'}}]}}})
                            else:
                                self.frame({'serverContent': {'modelTurn': {'parts': [{'inlineData': {'mimeType': 'audio/pcm;rate=24000', 'data': base64.b64encode(pcm_part1).decode()}}]}}})
                        else:
                            self.frame({'serverContent': {'modelTurn': {'parts': [{'text': '你好，'}]}}})
                        if route.path == '/go-away':
                            self.frame({'serverContent': {'inputTranscription': {'text': 'world.'}}})
                            if audio_modality:
                                self.frame({'serverContent': {'outputTranscription': {'text': '世界🌏。'}}})
                            else:
                                self.frame({'serverContent': {'modelTurn': {'parts': [{'text': '世界🌏。'}]}}})
                            self.frame({'serverContent': {'generationComplete': True, 'turnComplete': True}})
                            self.frame({'goAway': {'timeLeft': '5s'}})
                            return
                elif rt.get('audioStreamEnd') is True:
                    if route.path == '/timeout':
                        threading.Event().wait(2)
                        return
                    if route.path == '/interrupted':
                        self.frame({'serverContent': {'inputTranscription': {'text': 'Second part.'}}})
                        self.frame({'serverContent': {'outputTranscription': {'text': '第二段。'}}})
                        self.frame({'serverContent': {'generationComplete': True, 'turnComplete': True}})
                        return
                    if sent_partial:
                        self.frame({'serverContent': {'inputTranscription': {'text': 'world.'}}})
                        if audio_modality:
                            self.frame({'serverContent': {'outputTranscription': {'text': '世界🌏。'}}})
                            if route.path != '/bad-audio':
                                self.frame({'serverContent': {'modelTurn': {'parts': [{'inlineData': {'mimeType': 'audio/pcm;rate=24000', 'data': base64.b64encode(pcm_part2).decode()}}]}}})
                        else:
                            self.frame({'serverContent': {'modelTurn': {'parts': [{'text': '世界🌏。'}]}}})
                        self.frame({'serverContent': {'generationComplete': True, 'turnComplete': True}})
                    return
        except (OSError, ValueError, TypeError, AssertionError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(sys.argv[1], 'w') as output:
    output.write(str(server.server_port))
server.serve_forever()
