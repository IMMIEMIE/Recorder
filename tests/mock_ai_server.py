"""Local synthetic Chat Completions fixture. No user data or provider keys."""
import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length',0)))
        if self.path=='/unauthorized':
            self.send_response(401);self.end_headers();self.wfile.write(b'{"error":"mock-key"}');return
        if self.path=='/redirect':
            self.send_response(302);self.send_header('Location','/ok');self.end_headers();return
        self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
        try:
            if self.path=='/slow': time.sleep(2)
            if self.path=='/malformed': self.wfile.write(b'data: not-json\n\n');return
            if self.path in ('/truncated','/length'):
                reason='length' if self.path=='/length' else None
                self.wfile.write(('data: '+json.dumps({'choices':[{'delta':{'content':'partial'},'finish_reason':reason}]})+'\n\n').encode());return
            self.wfile.write(b': keepalive\r\n\r\n')
            for text in ['你好','，世界','🌏']:
                chunk=('data: '+json.dumps({'choices':[{'delta':{'content':text},'finish_reason':None}]},ensure_ascii=False)+'\r\n\r\n').encode()
                for byte in chunk:
                    self.wfile.write(bytes([byte]));self.wfile.flush()
            self.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
        except (BrokenPipeError,ConnectionResetError): pass
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
