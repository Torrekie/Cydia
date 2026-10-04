#!/usr/bin/env python3
"""Serve unchanged frozen bytes; no bridge injection or source mutation."""
import argparse
import http.server
import json
import mimetypes
from pathlib import Path
from urllib.parse import unquote, urlsplit

p = argparse.ArgumentParser()
p.add_argument('--baseline', required=True, type=Path)
p.add_argument('--port', type=int, default=18945)
args = p.parse_args(); root = args.baseline.resolve()
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = unquote(urlsplit(self.path).path)
        if '..' in Path(path).parts: self.send_error(400); return
        file = root / 'sources.html' if path == '/sources.html' else root / 'assets' / path.lstrip('/')
        if not file.is_file() or file.name.endswith('.headers'): self.send_error(404); return
        data = file.read_bytes(); self.send_response(200)
        self.send_header('Content-Type', mimetypes.guess_type(str(file))[0] or 'application/octet-stream')
        self.send_header('Content-Length', str(len(data))); self.send_header('Cache-Control', 'no-store')
        self.end_headers(); self.wfile.write(data)
    def log_message(self, fmt, *args):
        print(json.dumps(dict(path=self.path, result=fmt % args)), flush=True)
http.server.HTTPServer(('127.0.0.1', args.port), Handler).serve_forever()
