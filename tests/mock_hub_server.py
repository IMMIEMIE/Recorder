"""Local synthetic Hugging Face Hub for the model downloader tests. No real models or user data.

Serves the endpoints download.py (huggingface_hub 1.30) and ModelDownloader.swift use:
  GET  /api/models/<repo>[/revision/<rev>]?blobs=true   model_info(files_metadata=True)
  HEAD/GET /<repo>/resolve/<rev>/<file>                  git files inline, LFS files 302 to the "CDN"
  HEAD/GET /cdn/<repo>/<sha256>                          LFS bodies with Range support
  GET  /__log, POST /__reset                             request log for assertions
The CDN redirect points at `localhost` while the hub is `127.0.0.1`, so huggingface_hub treats it as a
foreign host exactly like the real LFS/Xet bridge.
"""
import hashlib
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit

SHA = '0123456789abcdef0123456789abcdef01234567'
WEIGHTS = bytes(range(256)) * 12288  # 3 MiB
FILES = {
    'config.json': (b'{"model_type": "qwen3"}\n', False),
    'tokenizer_config.json': (b'{"eos_token": "<|im_end|>"}\n', False),
    'chat_template.jinja': (b'{% for m in messages %}{{ m.content }}{% endfor %}\n', False),
    'nested/merges.txt': (b'#version: 0.2\na b\n', False),
    'model.safetensors': (WEIGHTS, True),
    'README.md': (b'# mock\n', False),
    '.gitattributes': (b'*.safetensors filter=lfs diff=lfs merge=lfs -text\n', False),
    'pytorch_model.bin': (b'x' * 100, True),
}
REPOS = {
    'mock/tiny': FILES,
    'mock/slow': FILES,
    'mock/norange': FILES,
    'mock/corrupt': FILES,
    'mock/noconfig': {k: v for k, v in FILES.items() if k != 'config.json'},
}
log = []
lock = threading.Lock()


def git_sha1(data):
    return hashlib.sha1(b'blob %d\0' % len(data) + data).hexdigest()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def split_repo(parts):
    """Longest known repo prefix of a path; returns (repo, rest)."""
    for size in (2,):
        repo = '/'.join(parts[:size])
        if repo in REPOS:
            return repo, parts[size:]
    return None, parts


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def record(self):
        with lock:
            log.append({'method': self.command, 'path': unquote(urlsplit(self.path).path),
                        'range': self.headers.get('Range')})

    def reply(self, status, body=b'', headers=None, head=False):
        self.send_response(status)
        headers = dict(headers or {})
        headers.setdefault('Content-Length', str(len(body)))
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        if not head and body:
            self.wfile.write(body)

    def not_found(self, code, head=False):
        self.reply(401 if code == 'RepoNotFound' else 404, b'{"error": "not found"}',
                   {'X-Error-Code': code, 'Content-Type': 'application/json'}, head)

    def do_POST(self):
        if self.path == '/__reset':
            with lock:
                log.clear()
            return self.reply(200, b'{}')
        self.reply(404)

    def do_HEAD(self):
        self.handle_get(head=True)

    def do_GET(self):
        if self.path == '/__log':
            with lock:
                body = json.dumps(log).encode()
            return self.reply(200, body, {'Content-Type': 'application/json'})
        self.handle_get(head=False)

    def handle_get(self, head):
        self.record()
        url = urlsplit(self.path)
        parts = [unquote(p) for p in url.path.strip('/').split('/')]
        if parts[:2] == ['api', 'models']:
            return self.model_info(parts[2:], head)
        if parts[0] == 'cdn':
            return self.cdn(parts[1:], head)
        repo, rest = split_repo(parts)
        if repo is None:
            return self.not_found('RepoNotFound', head)
        if len(rest) < 3 or rest[0] != 'resolve':
            return self.reply(404, head=head)
        revision, name = rest[1], '/'.join(rest[2:])
        if revision not in ('main', SHA):
            return self.not_found('RevisionNotFound', head)
        if name not in REPOS[repo]:
            return self.reply(404, b'', {'X-Error-Code': 'EntryNotFound', 'X-Repo-Commit': SHA}, head)
        data, lfs = REPOS[repo][name]
        if lfs:
            host = self.headers.get('Host', '').replace('127.0.0.1', 'localhost')
            return self.reply(302, b'', {'Location': f'http://{host}/cdn/{repo}/{sha256(data)}',
                                         'X-Repo-Commit': SHA, 'X-Linked-Etag': f'"{sha256(data)}"',
                                         'X-Linked-Size': str(len(data)), 'ETag': f'"{git_sha1(data)}"'}, head)
        self.reply(200, data, {'X-Repo-Commit': SHA, 'ETag': f'"{git_sha1(data)}"',
                               'Content-Type': 'application/octet-stream'}, head)

    def model_info(self, parts, head):
        repo, rest = split_repo(parts)
        if repo is None:
            return self.not_found('RepoNotFound', head)
        if rest and (len(rest) != 2 or rest[0] != 'revision' or rest[1] not in ('main', SHA)):
            return self.not_found('RevisionNotFound', head)
        siblings = []
        for name, (data, lfs) in REPOS[repo].items():
            entry = {'rfilename': name, 'size': len(data), 'blobId': git_sha1(data)}
            if lfs:
                entry['blobId'] = git_sha1(b'version https://git-lfs.github.com/spec/v1\noid sha256:' + sha256(data).encode())
                entry['lfs'] = {'sha256': sha256(data), 'size': len(data), 'pointerSize': 134}
            siblings.append(entry)
        body = json.dumps({'id': repo, 'modelId': repo, 'sha': SHA, 'siblings': siblings}).encode()
        self.reply(200, body, {'Content-Type': 'application/json'}, head)

    def cdn(self, parts, head):
        repo, rest = split_repo(parts)
        match = [data for data, lfs in REPOS.get(repo, {}).values() if lfs and rest and sha256(data) == rest[0]]
        if not match:
            return self.reply(404, head=head)
        data = match[0]
        if repo == 'mock/corrupt':
            data = b'\xff' + data[1:]
        start = 0
        requested = self.headers.get('Range')
        if requested and repo != 'mock/norange':
            start = int(requested.split('=')[1].split('-')[0])
            if start >= len(data):
                return self.reply(416, b'', {'Content-Range': f'bytes */{len(data)}'}, head)
            self.send_response(206)
            self.send_header('Content-Range', f'bytes {start}-{len(data) - 1}/{len(data)}')
        else:
            self.send_response(200)
        self.send_header('Content-Length', str(len(data) - start))
        self.send_header('Content-Type', 'application/octet-stream')
        self.end_headers()
        if head:
            return
        try:
            chunk = 64 * 1024
            for offset in range(start, len(data), chunk):
                self.wfile.write(data[offset:offset + chunk])
                if repo == 'mock/slow':
                    self.wfile.flush()
                    time.sleep(0.05)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
