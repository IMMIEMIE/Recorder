"""Local RFC6455 binary-Protobuf fixture for Seed-LiveInterpret 2.0 (volc-ast); no external dependencies."""
import base64
import hashlib
import socket
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


dropped = set()


# ── Minimal Protobuf wire helpers matching ast_service.proto ──

def encode_varint(value):
    if value < 0:
        value &= (1 << 64) - 1
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def encode_tag(field, wire):
    return encode_varint((field << 3) | wire)


def encode_int32(field, value):
    if value == 0:
        return b""
    return encode_tag(field, 0) + encode_varint(value)


def encode_bytes(field, data):
    if not data:
        return b""
    return encode_tag(field, 2) + encode_varint(len(data)) + data


def encode_string(field, text):
    if not text:
        return b""
    return encode_bytes(field, text.encode("utf-8"))


def decode_varint(buf, pos):
    result = 0
    shift = 0
    while pos < len(buf):
        b = buf[pos]
        pos += 1
        result |= (b & 0x7F) << shift
        if not (b & 0x80):
            return result, pos
        shift += 7
    raise ValueError("truncated varint")


def decode_fields(buf):
    pos = 0
    fields = []
    while pos < len(buf):
        tag, pos = decode_varint(buf, pos)
        field_num = tag >> 3
        wire = tag & 7
        if wire == 0:
            val, pos = decode_varint(buf, pos)
        elif wire == 1:
            val = buf[pos:pos + 8]
            pos += 8
        elif wire == 2:
            length, pos = decode_varint(buf, pos)
            val = buf[pos:pos + length]
            pos += length
        elif wire == 5:
            val = buf[pos:pos + 4]
            pos += 4
        else:
            raise ValueError(f"unsupported wire type {wire}")
        fields.append((field_num, wire, val))
    return fields


def decode_request_meta(buf):
    meta = {"resource_id": "", "connection_id": "", "session_id": "", "sequence": 0}
    for num, wire, val in decode_fields(buf):
        if num == 4 and wire == 2:
            meta["resource_id"] = val.decode("utf-8")
        elif num == 5 and wire == 2:
            meta["connection_id"] = val.decode("utf-8")
        elif num == 6 and wire == 2:
            meta["session_id"] = val.decode("utf-8")
        elif num == 7 and wire == 0:
            meta["sequence"] = val
    return meta


def decode_audio(buf):
    audio = {"format": "", "rate": 0, "bits": 0, "channel": 0, "binary_data": b""}
    for num, wire, val in decode_fields(buf):
        if num == 4 and wire == 2:
            audio["format"] = val.decode("utf-8")
        elif num == 7 and wire == 0:
            audio["rate"] = val
        elif num == 8 and wire == 0:
            audio["bits"] = val
        elif num == 9 and wire == 0:
            audio["channel"] = val
        elif num == 14 and wire == 2:
            audio["binary_data"] = val
    return audio


def decode_req_params(buf):
    params = {"mode": "", "source_language": "", "target_language": "", "speaker_id": ""}
    for num, wire, val in decode_fields(buf):
        if num == 1 and wire == 2:
            params["mode"] = val.decode("utf-8")
        elif num == 2 and wire == 2:
            params["source_language"] = val.decode("utf-8")
        elif num == 3 and wire == 2:
            params["target_language"] = val.decode("utf-8")
        elif num == 4 and wire == 2:
            params["speaker_id"] = val.decode("utf-8")
    return params


def decode_translate_request(buf):
    req = {
        "meta": {"resource_id": "", "connection_id": "", "session_id": "", "sequence": 0},
        "event": 0,
        "source_audio": None,
        "target_audio": None,
        "request": None,
    }
    for num, wire, val in decode_fields(buf):
        if num == 1 and wire == 2:
            req["meta"] = decode_request_meta(val)
        elif num == 2 and wire == 0:
            req["event"] = val
        elif num == 4 and wire == 2:
            req["source_audio"] = decode_audio(val)
        elif num == 5 and wire == 2:
            req["target_audio"] = decode_audio(val)
        elif num == 6 and wire == 2:
            req["request"] = decode_req_params(val)
    return req


def encode_translate_response(
    event,
    session_id="",
    status_code=20000000,
    message="",
    data=b"",
    text="",
    start_time=0,
    end_time=0,
):
    meta = (
        encode_string(1, session_id)
        + encode_int32(3, status_code)
        + encode_string(4, message)
    )
    return (
        encode_bytes(1, meta)
        + encode_int32(2, event)
        + encode_bytes(3, data)
        + encode_string(4, text)
        + encode_int32(5, start_time)
        + encode_int32(6, end_time)
    )


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def send_ws(self, data, opcode=2):
        length = len(data)
        header = bytearray([0x80 | opcode])
        if length < 126:
            header.append(length)
        elif length < 65536:
            header.append(126)
            header.extend(struct.pack("!H", length))
        else:
            header.append(127)
            header.extend(struct.pack("!Q", length))
        self.wfile.write(bytes(header) + data)
        self.wfile.flush()

    def close_ws(self, code, reason):
        self.send_ws(struct.pack("!H", code) + reason.encode("utf-8"), opcode=8)
        try:
            self.connection.shutdown(socket.SHUT_WR)
            self.connection.settimeout(0.5)
            while self.connection.recv(4096):
                pass
        except OSError:
            pass

    def read_ws(self):
        header = self.rfile.read(2)
        if len(header) != 2:
            return None
        opcode, length = header[0] & 15, header[1] & 127
        if length == 126:
            length = struct.unpack("!H", self.rfile.read(2))[0]
        elif length == 127:
            length = struct.unpack("!Q", self.rfile.read(8))[0]
        mask = self.rfile.read(4) if header[1] & 128 else b""
        data = self.rfile.read(length)
        if mask:
            data = bytes(c ^ mask[i % 4] for i, c in enumerate(data))
        if opcode == 8:
            return None
        if opcode == 9:
            self.send_ws(data, opcode=10)
            return self.read_ws()
        if opcode != 2:
            raise ValueError(f"expected binary frame, got opcode={opcode}")
        return data

    def do_GET(self):
        route = urlsplit(self.path)
        assert not route.query, f"AST v2 must not append query string: {route.query!r}"

        if route.path == "/unauthorized":
            self.send_response(401)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if route.path == "/http-429":
            self.send_response(429)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if route.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", "/ok")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if self.headers.get("X-Api-Resource-Id") != "volc.service_type.10053":
            self.send_error(403)
            return
        if not self.headers.get("X-Api-Connect-Id"):
            self.send_error(400)
            return

        if route.path == "/dual-auth":
            if (
                self.headers.get("X-Api-Key") is not None
                or self.headers.get("X-Api-App-Key") != "app-12345"
                or self.headers.get("X-Api-Access-Key") != "mock-volc-access"
            ):
                self.send_error(401)
                return
        else:
            if (
                self.headers.get("X-Api-Key") != "mock-volc-key"
                or self.headers.get("X-Api-App-Key") is not None
                or self.headers.get("X-Api-Access-Key") is not None
            ):
                self.send_error(401)
                return

        key = self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", base64.b64encode(hashlib.sha1(key.encode()).digest()).decode())
        self.end_headers()
        self.close_connection = True

        try:
            raw = self.read_ws()
            if raw is None:
                return
            start = decode_translate_request(raw)
            assert start["event"] == 100, f"expected StartSession(100), got {start['event']}"
            sid = start["meta"]["session_id"]
            assert sid, "StartSession must carry SessionID"
            src_audio = start["source_audio"]
            assert src_audio is not None and src_audio["format"] == "wav"
            assert src_audio["rate"] == 16000 and src_audio["bits"] == 16 and src_audio["channel"] == 1
            params = start["request"]
            assert params is not None and params["mode"] in ("s2t", "s2s")
            assert params["source_language"] and params["target_language"]
            audio_output = params["mode"] == "s2s"
            if audio_output:
                tgt_audio = start["target_audio"]
                assert tgt_audio is not None and tgt_audio["format"] == "pcm"
                assert tgt_audio["rate"] == 24000 and tgt_audio["bits"] == 16 and tgt_audio["channel"] == 1
            if route.path.startswith("/source-check/"):
                expected_src = route.path.split("/source-check/", 1)[1]
                assert params["source_language"] == expected_src, f"got {params['source_language']!r}, expected {expected_src!r}"

            if route.path == "/session-failed-auth":
                self.send_ws(encode_translate_response(153, session_id=sid, status_code=11200, message="permission denied mock-volc-key"))
                return
            if route.path == "/session-failed-quota":
                self.send_ws(encode_translate_response(153, session_id=sid, status_code=11302, message="quota exceeded mock-volc-key"))
                return
            if route.path == "/rate-limited":
                self.send_ws(encode_translate_response(153, session_id=sid, status_code=11301, message="QPS rate limit exceeded"))
                return
            if route.path == "/wrong-order":
                self.send_ws(encode_translate_response(650, session_id=sid))
                return
            if route.path == "/invalid-proto":
                self.send_ws(b"\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff")
                return

            self.send_ws(encode_translate_response(150, session_id=sid, status_code=20000000))

            sent = False
            total = 0
            drop = route.path.startswith("/drop-once/") and route.path not in dropped
            drop_after_final = route.path.startswith("/drop-after-final/") and route.path not in dropped
            if route.path.startswith("/drop-once/") or route.path.startswith("/drop-after-final/"):
                dropped.add(route.path)

            while (frame := self.read_ws()) is not None:
                req = decode_translate_request(frame)
                ev = req["event"]
                if ev == 200:  # TaskRequest
                    pcm = req["source_audio"]["binary_data"] if req["source_audio"] else b""
                    total += len(pcm)
                    if route.path == "/disconnect":
                        return
                    if route.path == "/finished-early":
                        self.send_ws(encode_translate_response(152, session_id=sid, status_code=20000000))
                        return
                    if drop:
                        self.send_ws(encode_translate_response(650, session_id=sid, start_time=500))
                        self.send_ws(encode_translate_response(651, session_id=sid, text="Before the break"))
                        return
                    if drop_after_final:
                        self.send_ws(encode_translate_response(650, session_id=sid, start_time=100))
                        self.send_ws(encode_translate_response(651, session_id=sid, text="First turn"))
                        self.send_ws(encode_translate_response(652, session_id=sid, text="First turn.", start_time=100, end_time=900))
                        self.send_ws(encode_translate_response(653, session_id=sid, start_time=100))
                        self.send_ws(encode_translate_response(655, session_id=sid, text="第一句。", start_time=100, end_time=900))
                        return
                    if not sent:
                        if route.path == "/repeat-words":
                            self.send_ws(encode_translate_response(650, session_id=sid, start_time=400))
                            self.send_ws(encode_translate_response(651, session_id=sid, text="yes "))
                            self.send_ws(encode_translate_response(651, session_id=sid, text="yes "))
                            self.send_ws(encode_translate_response(651, session_id=sid, text="to "))
                            self.send_ws(encode_translate_response(651, session_id=sid, text="today"))
                            self.send_ws(encode_translate_response(653, session_id=sid, start_time=400))
                            self.send_ws(encode_translate_response(654, session_id=sid, text="你好"))
                            self.send_ws(encode_translate_response(654, session_id=sid, text="世"))
                            sent = True
                            continue
                        self.send_ws(encode_translate_response(650, session_id=sid, start_time=1200))
                        self.send_ws(encode_translate_response(651, session_id=sid, text="Hello"))
                        self.send_ws(encode_translate_response(651, session_id=sid, text=" world"))
                        self.send_ws(encode_translate_response(653, session_id=sid, start_time=1200))
                        self.send_ws(encode_translate_response(654, session_id=sid, text="你好"))
                        self.send_ws(encode_translate_response(654, session_id=sid, text="，世界"))
                        if audio_output:
                            self.send_ws(encode_translate_response(350, session_id=sid))
                            if route.path == "/ogg-audio":
                                self.send_ws(encode_translate_response(352, session_id=sid, data=b"OggS\x00\x02compressed"))
                            else:
                                pcm_out = b"\x00\x40" * 2400  # 4800 bytes
                                # Split on an odd byte boundary to exercise PCM16 reassembly.
                                self.send_ws(encode_translate_response(352, session_id=sid, data=pcm_out[:2401]))
                                self.send_ws(encode_translate_response(352, session_id=sid, data=pcm_out[2401:]))
                            self.send_ws(encode_translate_response(351, session_id=sid))
                        sent = True
                elif ev == 102:  # FinishSession
                    if route.path == "/timeout":
                        threading.Event().wait(2)
                        return
                    if sent:
                        if route.path == "/repeat-words":
                            # Empty source End retains accumulated repeated words; non-empty translation End replaces provisional text authoritatively.
                            self.send_ws(encode_translate_response(652, session_id=sid, text="", start_time=400, end_time=1100))
                            self.send_ws(encode_translate_response(655, session_id=sid, text="你好，世界！", start_time=400, end_time=1100))
                        else:
                            self.send_ws(encode_translate_response(652, session_id=sid, text="Hello world.", start_time=1200, end_time=2400))
                            self.send_ws(encode_translate_response(655, session_id=sid, text="你好，世界🌏。", start_time=1200, end_time=2400))
                        if audio_output:
                            self.send_ws(encode_translate_response(359, session_id=sid))
                    self.send_ws(encode_translate_response(152, session_id=sid, status_code=20000000, message=f"audio_bytes={total}"))
                    return
        except (OSError, ValueError, TypeError, AssertionError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w") as output:
    output.write(str(server.server_port))
server.serve_forever()
