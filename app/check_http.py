"""Loopback-only transport regression: synthetic data, no credentials or external network."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Thread
from pathlib import Path
import subprocess
import tempfile
import time

received = []

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path == '/sink':
            received.append(self.path)
            self.send_response(200)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        self.send_response(int(self.path.rsplit('/', 1)[1]))
        self.send_header('Location', f'http://localhost:{self.server.server_port}/sink')
        self.send_header('Content-Length', '0')
        self.end_headers()

    def do_GET(self):
        if self.path == '/sink':
            received.append(self.path)
        if self.path == '/slow':
            time.sleep(0.2)
        body = b'x' * 2048 if self.path in ('/large', '/streamed') else b'ok'
        self.send_response(200)
        if self.path != '/streamed':
            self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
Thread(target=server.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix='murmur-http-check-') as temp:
        executable = str(Path(temp) / 'check')
        subprocess.run(['swiftc', 'app/Cleanup.swift', 'app/Providers.swift', 'app/Credentials.swift', 'app/check_http.swift', '-o', executable], check=True)
        subprocess.run([executable, f'http://127.0.0.1:{server.server_port}'], check=True, timeout=20)
        assert received == [], 'Redirect destination received a request'
finally:
    server.shutdown()
    server.server_close()
